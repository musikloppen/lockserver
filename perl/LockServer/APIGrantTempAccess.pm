package LockServer::APIGrantTempAccess;

use strict;
use warnings;
use utf8;

use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::Log ();
use Apache2::Const -compile => qw(OK HTTP_BAD_REQUEST HTTP_UNAUTHORIZED HTTP_INTERNAL_SERVER_ERROR);
use CGI::Cookie ();
use CGI ();
use JSON qw(decode_json encode_json);

use LockServer::Db;
use LockServer::Utils qw(send_notification generate_guest_username log_info log_warn log_die);
use LockServer::Number::Phone;

sub handler {
	my $r = shift;

	if ($r->method ne 'POST') {
		return send_json($r, Apache2::Const::HTTP_BAD_REQUEST, { error => 'POST request required' });
	}

	# 1. Extract session cookie
	my $cookie_header = $r->headers_in->{Cookie} || '';
	my %cookies = CGI::Cookie->parse($cookie_header);
	my $cookie_token = $cookies{'auth_token'} ? scalar $cookies{'auth_token'}->value : undef;

	unless ($cookie_token) {
		return send_json($r, Apache2::Const::HTTP_UNAUTHORIZED, { error => 'Unauthorized' });
	}

	my $dbh = LockServer::Db->my_connect();
	unless ($dbh) {
		$r->log_error("[APIGrantTempAccess] DB Connection Failed");
		return send_json($r, Apache2::Const::HTTP_INTERNAL_SERVER_ERROR, { error => 'Database error' });
	}

	# 2. Look up the verified user who made this request
	my $quoted_token = $dbh->quote($cookie_token);
	my $sth = $dbh->prepare(qq[
		SELECT u.username
		FROM sms_auth a
		JOIN users u ON a.phone = u.phone
		WHERE a.cookie_token = $quoted_token
			AND a.auth_state = 'sms_code_verified'
			AND u.active = 1
			AND (u.active_from IS NULL OR u.active_from < NOW())
			AND (u.expire_at IS NULL OR NOW() < u.expire_at)
		LIMIT 1
	]);
	$sth->execute();
	my $row = $sth->fetchrow_hashref();
	$sth->finish();

	unless ($row && $row->{username}) {
		return send_json($r, Apache2::Const::HTTP_UNAUTHORIZED, { error => 'User not authorized' });
	}

	my $created_by = $row->{username};

	# 3. Read POST payload
	my $post_data = '';
	my $cgi = CGI->new($r);
	$post_data = $cgi->param('POSTDATA') || '';

	if (!$post_data) {
		my $buffer = '';
		while ($r->read($buffer, 1024)) {
			$post_data .= $buffer;
		}
	}

	my $req_data = {};
	eval { $req_data = decode_json($post_data); };

	if ($@ || !ref $req_data || !$req_data->{phone}) {
		$req_data ||= {};
		$req_data->{phone}          ||= $cgi->param('phone');
		$req_data->{duration_hours} ||= $cgi->param('duration_hours');
		$req_data->{name}           ||= $cgi->param('name');
	}

	if (!$req_data->{phone} || !$req_data->{duration_hours}) {
		return send_json($r, Apache2::Const::HTTP_BAD_REQUEST, { error => 'Invalid payload. "phone" and "duration_hours" required.' });
	}

	# 4. Normalize phone number
	my $phone = $req_data->{phone};
	$phone =~ s/[\s\-]//g;
	$phone = '+45' . $phone unless $phone =~ /^\+/;

	my $hours = int($req_data->{duration_hours});
	if ($hours < 1 || $hours > 168) {
		return send_json($r, Apache2::Const::HTTP_BAD_REQUEST, { error => 'Duration must be between 1 and 168 hours' });
	}

	# --- Check if normalized phone number already has active/unexpired access ---
	my $sth_check = $dbh->prepare(qq[
		SELECT username FROM users
		WHERE phone = ?
			AND active = 1
			AND (expire_at IS NULL OR expire_at > NOW())
		LIMIT 1
	]);
	$sth_check->execute($phone);
	my ($existing_user) = $sth_check->fetchrow();
	$sth_check->finish();

	if ($existing_user) {
		return send_json($r, Apache2::Const::HTTP_BAD_REQUEST, { error => 'Phone number already has active access' });
	}

	# 5. Generate human-readable username & write to MySQL
	my $unique_username = generate_guest_username();
	my $guest_name      = $req_data->{name} || $unique_username;
	my $comment         = "Guest access created by $created_by";

	$dbh->{AutoCommit} = 1;

	my $sth_ins = $dbh->prepare(qq[
		INSERT INTO users (
			`username`, `name`, `phone`, `group`, `active`,
			`active_from`, `expire_at`, `comment`, `created_by`
		) VALUES (
			?, ?, ?, 'guest', 1,
			NOW(), DATE_ADD(NOW(), INTERVAL ? HOUR), ?, ?
		)
	]);

	my $insert_ok = $sth_ins->execute($unique_username, $guest_name, $phone, $hours, $comment, $created_by);
	$sth_ins->finish();

	unless ($insert_ok) {
		$r->log_error("[APIGrantTempAccess] INSERT failed: " . ($dbh->errstr || 'unknown error'));
		return send_json($r, Apache2::Const::HTTP_INTERNAL_SERVER_ERROR, { error => 'Failed to write to database' });
	}

	# 6. Send SMS Notification
	my $base_url = "https://" . ($r->hostname || 'localhost');
	my $sms_text = "You have been granted door access for $hours hour(s) by $created_by. Log in here: $base_url";

	my $sms_ok = send_notification($r, $phone, $sms_text);

	return send_json($r, 200, {
		status     => 'ok',
		message    => $sms_ok ? 'Guest access created and SMS dispatched' : 'Guest access created (SMS delivery failed)',
		username   => $unique_username,
		phone      => $phone,
		expires_in => "$hours hour(s)",
		sms_sent   => $sms_ok ? 1 : 0
	});
}

# -------------------------------------------------------------------------
# Helper: Send JSON and set HTTP status line explicitly for mod_perl
# -------------------------------------------------------------------------
sub send_json {
	my ($r, $status_code, $data) = @_;

	if ($status_code == 200) {
		$r->status_line("200 OK");
		$r->status(200);
	} else {
		$r->status($status_code);
	}

	# Ensure $data is always a Hash or Array reference to prevent encode_json crashes
	my $payload;
	if (ref $data eq 'HASH') {
		$payload = { %$data };
	} elsif (ref $data eq 'ARRAY') {
		$payload = [ @$data ];
	} else {
		if ($status_code >= 400) {
			$payload = { error => defined $data ? "$data" : 'An error occurred' };
		} else {
			$payload = { message => defined $data ? "$data" : 'OK' };
		}
	}

	$r->content_type('application/json; charset=UTF-8');
	$r->print(encode_json($payload));

	return Apache2::Const::OK;
}

1;

__END__
