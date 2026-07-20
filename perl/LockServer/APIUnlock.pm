package LockServer::APIUnlock;

use strict;
use warnings;
use utf8;

use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::Log ();
use Apache2::Const -compile => qw(OK HTTP_METHOD_NOT_ALLOWED HTTP_UNAUTHORIZED HTTP_INTERNAL_SERVER_ERROR);
use CGI::Cookie ();
use JSON qw(encode_json);
use Redis;

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

	# Retrieve actual username by matching verified phone in sms_auth with active users
	my $quoted_token = $dbh->quote($cookie_token);
	my $sth = $dbh->prepare(qq[
		SELECT u.username, u.open_time
		FROM sms_auth a
		JOIN users u ON a.phone = u.phone
		WHERE a.cookie_token = $quoted_token
			AND a.auth_state = 'sms_code_verified'
			AND u.active = 1
		LIMIT 1
	]);
	$sth->execute();
	my $row = $sth->fetchrow_hashref();
	$sth->finish();

	# Safeguard: Refuse to proceed if user is not verified or inactive
	unless ($row && defined $row->{username} && $row->{username} ne '') {
		return send_json($r, Apache2::Const::HTTP_UNAUTHORIZED, { error => 'User not verified or active' });
	}

	my $username  = $row->{username};
	my $open_time = defined $row->{open_time} ? int($row->{open_time}) : 2;

	# Prefer system/Docker %ENV first, then Apache subprocess_env
	my $redis_host = $ENV{REDIS_HOST} || ($r ? $r->subprocess_env('REDIS_HOST') : undef) || 'lock-redis';
	my $redis_port = $ENV{REDIS_PORT} || ($r ? $r->subprocess_env('REDIS_PORT') : undef) || 6379;

	eval {
		my $redis = Redis->new(
			server       => "$redis_host:$redis_port",
			sock_timeout => 3,
			reconnect    => 5,
			every        => 500,
		);
		$redis->publish('lock_events', "unlock_web:$username");
	};

	if ($@) {
		$r->log_error("Failed to publish Redis unlock event: $@");
		return send_json($r, Apache2::Const::HTTP_INTERNAL_SERVER_ERROR, { error => 'Failed to dispatch unlock event' });
	}

	return send_json($r, 200, {
		status    => 'ok',
		message   => 'Door unlocked',
		user      => $username,
		open_time => $open_time,
	});
}

# -------------------------------------------------------------------------
# Helper: Send JSON and set HTTP status line explicitly for mod_perl
# -------------------------------------------------------------------------
sub send_json {
	my ($r, $status_code, $data) = @_;

	# Explicitly set status line and status code on Apache request object
	if ($status_code == 200) {
		$r->status_line("200 OK");
		$r->status(200);
	} else {
		$r->status($status_code);
	}

	$r->content_type('application/json; charset=UTF-8');
	$r->print(encode_json($data));

	return Apache2::Const::OK;
}

1;

__END__
