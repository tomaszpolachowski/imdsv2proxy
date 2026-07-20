#!/usr/bin/env perl

# Automatically enables "strict", "warnings", "utf8" and Perl 5.16 features
use Mojolicious::Lite -signatures;
use Mojo::UserAgent;
use CHI;
use Digest::SHA3 qw(sha3_256_hex);
use Fcntl qw(:flock);
use JSON::MaybeXS;

my($cache) = CHI->new(
  driver     => 'BerkeleyDB',
  root_dir   => '/tmp/proxy-cache'
);

my($lock_file) = '/tmp/proxy-cache-lock';

helper 'handle' => sub ($c) {
  my($method) = $c->req->method;
  my($path) = $c->req->url;
  my($X_aws_ec2_metadata_token_ttl_seconds) = $c->req->headers->header('X-aws-ec2-metadata-token-ttl-seconds') || q{};
  my($X_aws_ec2_metadata_token) = $c->req->headers->header('X-aws-ec2-metadata-token') || q{};

  my($cache_key) = sha3_256_hex("${method}${path}${X_aws_ec2_metadata_token_ttl_seconds}${X_aws_ec2_metadata_token}");

  my($tries) = 3;

  do {
    my($encoded_response) = $cache->get($cache_key);

    if (defined $encoded_response)
    {
      # Return cached response
      my($response) = decode_json($encoded_response);
      $c->res->code($response->{code});
      $c->res->headers->header('X-cached' => 'True');
      return $c->render(text => $response->{body});
    }

    # Acquire lock
    open(my $lock_fh, ">>", $lock_file) or die "Can't open lock file: $!";
    my($lock) = flock($lock_fh, LOCK_EX | LOCK_NB);
    if (! $lock) {
      sleep 2;
      continue;
    }
    # Request IMDSv2 with X-headers if any
    my $ua = Mojo::UserAgent->new;
    my $tx = $ua->build_tx((uc $method) => "http://169.254.169.254$path");
    if ($X_aws_ec2_metadata_token_ttl_seconds) {
      $tx->req->headers->header('X-aws-ec2-metadata-token-ttl-seconds' => $X_aws_ec2_metadata_token_ttl_seconds);
    }
    if ($X_aws_ec2_metadata_token) {
      $tx->req->headers->header('X-aws-ec2-metadata-token' => $X_aws_ec2_metadata_token);
    }
    $tx = $ua->start($tx);
    my ($res) = $tx->result;
    # Cache response
    $cache->set($cache_key, encode_json({code => $res->code, body => $res->body}), '2 minutes');
    # Release lock
    flock($lock_fh, LOCK_UN);
    # Return fresh response
    $c->res->code($res->code);
    return $c->render(text => $res->body);
  }
  while (--$tries);
};

# Route without placeholder
any '/' => sub ($c) {
  $c->handle;
};

# Route with placeholder
any '/*' => sub ($c) {
  $c->handle;
};

# Start the Mojolicious command system
app->start;
