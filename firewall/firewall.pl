#!/usr/bin/env perl

use strict;
use warnings;
use utf8;
use feature ":5.16";
use Kubernetes::REST;
use Linux::NFTables;
use File::Slurp;
use JSON::MaybeXS qw(decode_json);
use Data::Dumper;

my($pod_ip)=$ENV{POD_IP};

my($config)=decode_json(read_file('config.json')) or die $!;

my($target_labels) = [];
if ($config->{targetLabels} && ref $config->{targetLabels} eq 'ARRAY') {
    $target_labels = $config->{targetLabels};
}

my($nft_table_name)=$config->{nftTableName};

my($nft) = Linux::NFTables->new();
my($api) = Kubernetes::REST->new(
    server => $config->{server},
    credentials => { token => read_file($config->{tokenFile}) }
    );

sub match_hash_item {
    my($hashref)=@_;
    if (! $target_labels->@* || ! $hashref || ref $hashref ne 'HASH') {
        return 1;
    }
    foreach my $target_label ($target_labels->@*) {
        next if (! $target_label || ref $target_label ne 'HASH' || ! $target_label->{name});
        if ($target_label->{values} && ref $target_label->{values} eq 'ARRAY' && $target_label->{values}->@*) {
            my(%values) = map { $_ => 1 } $target_label->{values}->@*;
            return 1 if (defined($hashref->{$target_label->{name}}) && $values{$hashref->{$target_label->{name}}});
        } else {
            return 1 if (defined($hashref->{$target_label->{name}}));
        }
    }
    return 0;
}

sub process_pod {
    my($pod)=@_;
    return if (! match_hash_item($pod->metadata->labels));
    # say $pod->metadata->name . " " . $pod->status->phase;
    if ($pod->status->phase eq 'Running') {
        $nft->run_cmd("add element inet ${nft_table_name} _${pod_ip} { " . $pod->status->podIP . ' }');
    }
#    elsif ($pod->status->podIP) {
#    # elsif ($pod->status->phase =~ '^(Terminating|Error|Failed|Completed|Succeeded)$') {
#        $nft->run_cmd("delete element inet ${nft_table_name} _${pod_ip} { " . $pod->status->podIP . ' }');
#    }
}

sub handle_event {
    my($event) = @_;
    process_pod($event->object);
}

my(@targetPorts) = $config->{targetPorts}->@*;
my($source_network)=$config->{sourceNetwork};
if ($nft_table_name && @targetPorts && $pod_ip && $source_network) {
    $SIG{INT} = sub {
        $nft->run_cmd("delete table inet $nft_table_name");
        $nft = undef;
        exit 0;
    };
    $nft->run_cmd(<<"EOS"
add table inet $nft_table_name
add set inet $nft_table_name _${pod_ip} { type ipv4_addr; }
add chain inet $nft_table_name _${pod_ip} { type filter hook prerouting priority filter; policy accept; }
flush set inet $nft_table_name _${pod_ip}
flush chain inet $nft_table_name _${pod_ip}
EOS
    );
    foreach my $port (@targetPorts) {
        $nft->run_cmd(<<"EOS"
add rule inet $nft_table_name _${pod_ip} ip saddr \@_${pod_ip} ip daddr ${pod_ip} tcp dport ${port} accept
add rule inet $nft_table_name _${pod_ip} ip saddr ${source_network} ip daddr ${pod_ip} tcp dport ${port} reject with icmp host-unreachable
EOS
        );
    }
}

my($pods) = $api->list('Pod');
if ($pods && $pods->items)
{
    foreach my $pod ($pods->items->@*) {
        process_pod($pod);
    }
}

my($rv) = undef;
while (1) {
    $rv = eval {
        $api->watch('Pod',
            resourceVersion => $rv,
            on_event        => \&handle_event,
        );
    };
    if ($@ && $@ =~ /410 Gone/) {
        # resourceVersion expired, re-list to get fresh version
        my($pods) = $api->list('Pod');
        if ($pods && $pods->items)
        {
            foreach my $pod ($pods->items->@*) {
                process_pod($pod);
            }
        }
        $rv = undef;  # start fresh
    }
}
