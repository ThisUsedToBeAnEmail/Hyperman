#!/usr/bin/perl
use strict;
use warnings;

# Benchmark Hyperman (optionally vs Gazelle / Starman) on an identical plaintext
# PSGI app, driven entirely from Perl: the load client is Fetch (its async event
# loop keeps N requests in flight, refilling each lane as it settles) and the
# timing core is the Benchmark module (timeit measures the wallclock of the load
# window, so requests/sec is simply completed-requests / wallclock).
#
# Everything runs co-resident on this box - server and client share cores - so
# the numbers are RELATIVE, good for comparing servers here, not absolute
# headline figures (those need a separate load box). Per (server, concurrency)
# we report requests/sec and any failed requests, so a degraded run is visible.
#
# Usage: perl bench/bench.pl [WORKERS] [SECONDS] [CONC...]
#   e.g. perl bench/bench.pl 4 5 50 200 1000
#
# Hyperman runs in-process (this script forks and calls Hyperman->run). Gazelle
# and Starman are benchmarked too if their plackup handlers are installed;
# otherwise they are skipped with a note.

use FindBin ();
use lib "$FindBin::Bin/../blib/lib", "$FindBin::Bin/../blib/arch";
use Benchmark qw(:hireswallclock timeit);
use Socket ();
use POSIX ();
use Time::HiRes ();
use Fetch;
use Fetch::Future;

my $HOST = '127.0.0.1';
my $APP  = "$FindBin::Bin/app.psgi";

my $WORKERS = defined $ARGV[0] ? $ARGV[0] : 4;
my $SECONDS = defined $ARGV[1] ? $ARGV[1] : 5;
my @CONC    = @ARGV[2 .. $#ARGV];
@CONC = (50, 200, 1000) unless @CONC;

# The PSGI app under test - the same coderef whether we host it in-process
# (Hyperman) or hand the file to plackup (Gazelle / Starman).
my $app = do $APP;
die "bench/app.psgi did not compile: " . ($@ || $!) . "\n" unless ref $app eq 'CODE';

# --- pick a free TCP port -----------------------------------------------------
sub free_port {
    socket(my $s, Socket::PF_INET(), Socket::SOCK_STREAM(), 0) or die "socket: $!";
    setsockopt($s, Socket::SOL_SOCKET(), Socket::SO_REUSEADDR(), 1);
    bind($s, Socket::pack_sockaddr_in(0, Socket::inet_aton($HOST))) or die "bind: $!";
    my $port = (Socket::unpack_sockaddr_in(getsockname $s))[0];
    close $s;
    return $port;
}

# --- start servers ------------------------------------------------------------
# Each starter forks and returns the child pid; the child never returns.
sub start_hyperman {
    my ($port) = @_;
    my $pid = fork;
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        open STDOUT, '>', '/dev/null';
        open STDERR, '>', '/dev/null';
        require Hyperman;
        Hyperman->run(
            app => $app, host => $HOST, port => $port, workers => $WORKERS,
        );
        POSIX::_exit(0);
    }
    return $pid;
}

sub start_plackup {
    my ($server, $port) = @_;
    my $pid = fork;
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        open STDOUT, '>', '/dev/null';
        open STDERR, '>', '/dev/null';
        exec('plackup', '-s', $server, '-E', 'deployment',
            '--workers', $WORKERS, '--host', $HOST, '--port', $port, $APP)
            or POSIX::_exit(127);
    }
    return $pid;
}

sub have_handler {
    my ($handler) = @_;
    return eval { require "Plack/Handler/$handler.pm"; 1 } ? 1 : 0;
}

sub stop_server {
    my ($pid) = @_;
    return unless $pid;
    kill 'TERM', $pid;
    # plackup masters need a moment to signal and reap their own workers.
    for (1 .. 50) {
        return if waitpid($pid, POSIX::WNOHANG()) == $pid;
        Time::HiRes::sleep(0.1);
    }
    kill 'KILL', $pid;
    waitpid($pid, 0);
}

# Poll the root URL with Fetch until it answers 2xx (server came up) or we give
# up. Returns true on success.
sub wait_ready {
    my ($ua, $url) = @_;
    for (1 .. 100) {
        my $res = eval { $ua->get($url)->get };
        return 1 if $res && $res->is_success;
        Time::HiRes::sleep(0.1);
    }
    return 0;
}

# --- the load: an open-loop generator on Fetch's event loop, timed by Benchmark
# Keep $conc requests in flight at all times (a fresh one is issued the instant
# one settles), pump Fetch's loop for the window, then stop and count what
# completed. This is the right shape for a load generator: it never blocks on a
# single slow request, so it measures every server honestly - an event-driven
# server (Hyperman) keeps all lanes flowing, while a blocking prefork server
# (Gazelle/Starman) simply completes fewer in the window rather than deadlocking
# the client. Benchmark::timeit provides the wallclock the throughput divides by.
sub bench_server {
    my ($url, $conc) = @_;
    # Persistent keep-alive lanes (like wrk's -c connections), one idle slot per
    # unit of concurrency so a settled request reuses its socket, not churns it.
    my $ua   = Fetch->new(timeout => 5, keep_alive => 1, pool_size => $conc);
    my $loop = $ua->loop;

    my ($done, $err, $stop, $seq) = (0, 0, 0, 0);
    my %live;   # in-flight futures, so we can abandon starved lanes at the end

    my $fire;
    $fire = sub {
        return if $stop;
        my $id = ++$seq;
        my $f  = $ua->get($url);
        $live{$id} = $f;
        $f->on_ready(sub {
            my ($ff) = @_;
            delete $live{$id};
            if    ($ff->is_cancelled) { }                 # window closed - ignore
            elsif ($ff->is_failed)    { $err++ }
            else {
                my $res = eval { $ff->get };
                ($res && $res->is_success) ? $done++ : $err++;
            }
            $fire->() unless $stop;                        # refill the lane
        });
        return;
    };

    $fire->() for 1 .. $conc;                              # prime all lanes
    $loop->timer($SECONDS, sub { $stop = 1; $loop->stop });

    my $bench = timeit(1, sub { $loop->run });             # pumps until stop()
    my $real  = $bench->real || $SECONDS;

    $_->cancel for grep { $_ && !$_->is_ready } values %live;

    my $rps = $done / $real;
    return ($rps, $done, $err, $real);
}

# --- run ----------------------------------------------------------------------
$| = 1;

# Which servers to bench: Hyperman always (in-process); the others when present.
my @servers = ({ name => 'Hyperman', start => \&start_hyperman });
for my $h (['Gazelle', 'Gazelle'], ['Starman', 'Starman']) {
    my ($name, $handler) = @$h;
    if (have_handler($handler)) {
        push @servers, { name => $name, start => sub { start_plackup($name, $_[0]) } };
    }
}

my $probe = Fetch->new(timeout => 5);

print "Hyperman benchmark - load: Fetch (open-loop), timing: Benchmark::timeit\n";
printf "workers=%s  window=%ss/run  app=plaintext 'Hello, World!'  (co-resident, RELATIVE)\n",
    $WORKERS, $SECONDS;
my @skipped = grep { !have_handler($_) } qw(Gazelle Starman);
print "skipped (handler not installed): @skipped\n" if @skipped;
print "=" x 79, "\n";

my $failures = 0;
for my $conc (@CONC) {
    printf "concurrency = %s\n", $conc;
    for my $srv (@servers) {
        my $port = free_port();
        my $pid  = $srv->{start}->($port);
        my $url  = "http://$HOST:$port/";

        unless (wait_ready($probe, $url)) {
            printf "  %-9s  FAILED TO START\n", $srv->{name};
            stop_server($pid);
            next;
        }

        my ($rps, $reqs, $err) = bench_server($url, $conc);
        $failures += $err;
        printf "  %-9s %12.0f req/s   (%d reqs%s)\n",
            $srv->{name}, $rps, $reqs,
            $err ? sprintf(", %d FAILED", $err) : '';

        stop_server($pid);
    }
    print "\n";
}

print "-" x 79, "\n";
print $failures ? "note: $failures failed request(s) - inspect above\n"
                : "PASS: no failed requests\n";
