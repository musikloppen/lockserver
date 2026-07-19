package LockServer::APIGrantTempAccess;

use strict;
use warnings;
use utf8;

use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::Const -compile => qw(OK HTTP_BAD_REQUEST HTTP_UNAUTHORIZED HTTP_INTERNAL_SERVER_ERROR);
use CGI::Cookie ();
use CGI ();
use JSON qw(decode_json encode_json);
use Redis;

# SMS Dependencies
use Net::SMTP;
use Email::MIME;
use Encode qw(decode is_utf8);
use LockServer::Number::Phone;

use LockServer::Db;

sub handler {
	my $r = shift;

	if ($r->method ne 'POST') {
		return send_json($r, Apache2::Const::HTTP_BAD_REQUEST, { error => 'POST request required' });
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

	# Verify requesting user is active
	my $quoted_token = $dbh->quote($cookie_token);
	my $sth = $dbh->prepare(qq[
		SELECT u.username
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

	unless ($row && $row->{username}) {
		return send_json($r, Apache2::Const::HTTP_UNAUTHORIZED, { error => 'User not authorized' });
	}

	my $created_by = $row->{username};

	# Read POST body via CGI slurped raw data with stream fallback
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

	# Fallback: Check if form parameters were submitted directly
	if ($@ || !$req_data->{phone}) {
		$req_data->{phone}          ||= $cgi->param('phone');
		$req_data->{duration_hours} ||= $cgi->param('duration_hours');
		$req_data->{name}           ||= $cgi->param('name');
	}

	if (!$req_data->{phone} || !$req_data->{duration_hours}) {
		return send_json($r, Apache2::Const::HTTP_BAD_REQUEST, { error => 'Invalid payload. "phone" and "duration_hours" required.' });
	}

	# Normalize phone number
	my $phone = $req_data->{phone};
	$phone =~ s/[\s\-]//g;
	$phone = '+45' . $phone unless $phone =~ /^\+/;

	my $hours = int($req_data->{duration_hours});
	if ($hours < 1 || $hours > 168) {
		return send_json($r, Apache2::Const::HTTP_BAD_REQUEST, { error => 'Duration must be between 1 and 168 hours' });
	}

	# Insert or Update guest user in 'users' table
	my $guest_name = $req_data->{name} || 'Guest';
	my $sth_chk = $dbh->prepare("SELECT id FROM users WHERE phone = ? LIMIT 1");
	$sth_chk->execute($phone);
	my ($existing_id) = $sth_chk->fetchrow;
	$sth_chk->finish();

	if ($existing_id) {
		$dbh->do("UPDATE users SET active=1, active_from=NOW(), expire_at=DATE_ADD(NOW(), INTERVAL ? HOUR), comment=?, created_by=? WHERE id=?", 
			undef, $hours, "Guest updated by $created_by", $created_by, $existing_id);
	} else {
		$dbh->do("INSERT INTO users (username, name, phone, `group`, active, active_from, expire_at, comment, created_by) VALUES (?, ?, ?, 'guest', 1, NOW(), DATE_ADD(NOW(), INTERVAL ? HOUR), ?, ?)",
			undef, 'guest_' . time(), $guest_name, $phone, "Guest created by $created_by", $created_by);
	}

	# SMS Notification
	my $base_url = "https://" . ($r->hostname || 'localhost');
	my $sms_text = "You have been granted door access for $hours hour(s) by $created_by. Log in here: $base_url";

	send_notification($r, $phone, $sms_text);

	return send_json($r, 200, {
		status     => 'ok',
		message    => 'Guest access created and SMS dispatched',
		phone      => $phone,
		expires_in => "$hours hour(s)"
	});
}

# -------------------------------------------------------------------------
# Helper: Send SMS via SMTP
# -------------------------------------------------------------------------
sub send_notification {
	my ($r, $sms_number, $message) = @_;
	
	eval {
		unless (is_utf8($message)) { $message = decode('UTF-8', $message); }

		my $phone_obj = LockServer::Number::Phone->new($sms_number);
		if ($phone_obj && $phone_obj->is_valid) {
			my $compact = $phone_obj->international;
			$compact =~ s/^\+//;
			$sms_number = $compact;
		}

		my $email = Email::MIME->create(
			header_str => [
				From    => 'meterlogger@meterlogger',
				To      => $sms_number . '@meterlogger',
				Subject => $message,
			],
			attributes => { encoding => 'quoted-printable', charset => 'UTF-8', content_type => 'text/plain' },
			body => '',
		);

		my $smtp_host = ($r ? $r->subprocess_env('SMTP_HOST') : undef) || $ENV{SMTP_HOST} || '10.8.0.66';
		my $smtp_port = ($r ? $r->subprocess_env('SMTP_PORT') : undef) || $ENV{SMTP_PORT} || 25;

		my $smtp = Net::SMTP->new($smtp_host, Port => $smtp_port, Timeout => 10);
		return unless $smtp;

		$smtp->mail('meterlogger@meterlogger');
		$smtp->to("$sms_number\@meterlogger");
		$smtp->data();
		$smtp->datasend($email->as_string);
		$smtp->dataend();
		$smtp->quit();
	};
}

# -------------------------------------------------------------------------
# Helper: Send JSON & set status code explicitly for mod_perl
# -------------------------------------------------------------------------
sub send_json {
	my ($r, $status_code, $data) = @_;

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
