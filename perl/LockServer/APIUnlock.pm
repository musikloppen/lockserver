package LockServer::APIUnlock;

use strict;
use warnings;
use utf8;

use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::Const -compile => qw(OK HTTP_METHOD_NOT_ALLOWED HTTP_UNAUTHORIZED HTTP_INTERNAL_SERVER_ERROR);
use CGI::Cookie ();
use JSON qw(encode_json);
use Redis ();

use LockServer::Db;

sub handler {
	my $r = shift;

	# Only accept POST requests
	if ($r->method ne 'POST') {
		return send_json($r, Apache2::Const::HTTP_METHOD_NOT_ALLOWED, { error => 'Method not allowed' });
	}

	# Extract session cookie
	my $cookie_header = $r->headers_in->{Cookie} || '';
	my %cookies = CGI::Cookie->parse($cookie_header);
	my $cookie_token = $cookies{'auth_token'} ? scalar $cookies{'auth_token'}->value : undef;

	unless ($cookie_token) {
		return send_json($r, Apache2::Const::HTTP_UNAUTHORIZED, { error => 'Unauthorized' });
	}

	my $dbh = LockServer::Db->my_connect();
	unless ($dbh) {
		return send_json($r, Apache2::Const::HTTP_INTERNAL_SERVER_ERROR, { error => 'Database error' });
	}

	# Identify user tied to verified cookie token
	my $quoted_token = $dbh->quote($cookie_token);
	my $sth = $dbh->prepare(qq[
		SELECT u.username
		FROM users u
		JOIN sms_auth a ON u.phone = a.phone
		WHERE a.cookie_token = $quoted_token
			AND a.auth_state = 'sms_code_verified'
		LIMIT 1
	]);
	$sth->execute();
	my $row = $sth->fetchrow_hashref();
	$sth->finish();

	my $username = $row ? $row->{username} : 'web';

	# Connect to Redis and publish the unlock event
	my $redis_host = $r->subprocess_env('REDIS_HOST') || $ENV{REDIS_HOST} || 'lock-redis';
	my $redis;
	eval {
		$redis = Redis->new(server => "$redis_host:6379", timeout => 3);
	};

	if ($@ || !$redis) {
		$r->log_error("Redis connection failed to $redis_host: $@");
		return send_json($r, Apache2::Const::HTTP_INTERNAL_SERVER_ERROR, { error => 'Message bus connection failed' });
	}

	eval {
		$redis->publish('lock_events', "unlock_web:$username");
	};

	if ($@) {
		$r->log_error("Failed to publish Redis unlock event: $@");
		return send_json($r, Apache2::Const::HTTP_INTERNAL_SERVER_ERROR, { error => 'Failed to dispatch unlock event' });
	}

	return send_json($r, Apache2::Const::OK, { status => 'ok', message => 'Door unlocked' });
}

sub send_json {
	my ($r, $status, $data) = @_;
	$r->status($status);
	$r->content_type('application/json; charset=UTF-8');
	$r->print(encode_json($data));
	return Apache2::Const::OK;
}

1;

__END__
