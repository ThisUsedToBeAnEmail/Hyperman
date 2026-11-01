#!/usr/bin/env perl
use strict;
use warnings;
use Hyperman;

# The server side of bench/proto-bench.sh: ONE listener serving HTTP/1.1,
# HTTP/2 and HTTP/3 at the same address, so a three-way comparison changes
# only the protocol.
#
# TLS is not optional here and that is the point. HTTP/3 has no cleartext
# mode, so measuring it against plaintext h1 or h2c would fold the cost of
# the record layer into "the cost of HTTP/3". Everything below is behind the
# same certificate.

my $port    = $ENV{PORT}    || 19700;
my $workers = $ENV{WORKERS} || 1;
my $cert    = $ENV{CERT}    or die "CERT is required\n";
my $key     = $ENV{KEY}     or die "KEY is required\n";

# The canonical PSGI micro-benchmark body, identical to bench/app.psgi, so
# these numbers sit beside the existing ones rather than beside nothing.
my $body = 'Hello, World!';
my $len  = length $body;

# A second, larger route: a 64KB body says something the 13-byte one cannot,
# because it is the only one of the two that crosses a QUIC flow-control
# window or fills a TCP segment.
my $big  = 'x' x 65536;
my $blen = length $big;

Hyperman->run(
    app => sub {
        my $env = shift;
        return [ 200, [ 'Content-Type' => 'text/plain',
                        'Content-Length' => $blen ], [$big] ]
            if $env->{PATH_INFO} eq '/big';
        return [ 200, [ 'Content-Type' => 'text/plain',
                        'Content-Length' => $len ], [$body] ];
    },
    host     => '127.0.0.1',
    port     => $port,
    workers  => $workers,
    http2    => 1,
    http3    => 1,
    tls_cert => $cert,
    tls_key  => $key,
);
