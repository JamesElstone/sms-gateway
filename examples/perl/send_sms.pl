#!/usr/bin/env perl

use strict;
use warnings;
use Encode qw(encode);
use HTTP::Tiny;

if (@ARGV < 4) {
    print STDERR "Usage: perl examples/perl/send_sms.pl BASE_URL TOKEN MOBILE MESSAGE [MESSAGE...]\n";
    print STDERR "Example: perl examples/perl/send_sms.pl http://sms.example.net/sms-gateway \$TOKEN +447700900000 Hello from Perl\n";
    exit 2;
}

my ($base_url, $token, $mobile, @message_parts) = @ARGV;
$base_url =~ s{/+\z}{};
my $message = join ' ', @message_parts;
my $send_url = $base_url . '/send/' . encode_path_segment($mobile);

my $response = HTTP::Tiny->new->post(
    $send_url,
    {
        headers => {
            'X-SMS-Gateway-Token' => $token,
            'Content-Type' => 'text/plain; charset=utf-8',
        },
        content => $message,
    }
);

print $response->{content}, "\n" if length $response->{content};

if (!$response->{success}) {
    print STDERR "Gateway returned HTTP $response->{status}\n";
    exit 1;
}

sub encode_path_segment {
    my ($value) = @_;
    return join '', map {
        /[A-Za-z0-9._~-]/ ? $_ : sprintf '%%%02X', ord $_
    } split //, encode('UTF-8', $value);
}
