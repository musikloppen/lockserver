package LockServer::SMSAuth;

use strict;
use warnings;
use utf8;

use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::SubRequest ();
use Apache2::Const -compile => qw(OK REDIRECT HTTP_NOT_FOUND HTTP_SERVICE_UNAVAILABLE);
use CGI::Cookie ();
use CGI;
use Math::Random::Secure qw(rand);
use DBI;
use POSIX qw(floor round);
use File::Basename;
use Net::SMTP;
use Email::MIME;
use Encode qw(encode decode is_utf8);

use LockServer::Db;
use LockServer::Utils qw(send_notification log_info log_warn log_die);
use LockServer::Number::Phone;

# -------------------------------------------------------------------------
# Internal Logging Setup
# -------------------------------------------------------------------------
$| = 1;  # Autoflush STDOUT

binmode(STDOUT, ":encoding(UTF-8)");
binmode(STDERR, ":encoding(UTF-8)");

my $script_name = basename($0, ".pl");

# -------------------------------------------------------------------------
# Main Apache Request Handler
# -------------------------------------------------------------------------
sub handler {
	my $r = shift;

	my $logout_path     = $r->dir_config('LogoutPath') || 'logout';
	my $logged_out_path = $r->dir_config('LoggedOutPath') || '/logged_out.html';
	my $public_access   = $r->dir_config('PublicAccess') || '';

	# Use original request URI to avoid internal_redirect side effects
	my $orig_uri = $r->unparsed_uri || $r->uri;

	# Check PublicAccess paths
	if ($public_access) {
		foreach (split(/,\s*/, $public_access)) {
			if ($r->uri eq $_) {
				$r->warn("we dont handle this: $orig_uri");
				return Apache2::Const::OK;
			}
		}
	}

	if ($orig_uri eq $logged_out_path) {
		$r->warn("we dont handle this: $orig_uri");
		return Apache2::Const::OK;
	}

	my ($dbh, $sth, $d);
	if ($dbh = LockServer::Db->my_connect) {
		my $passed_cookie = $r->headers_in->{Cookie} || '';
		if ($passed_cookie) {
			# Handle logout requests
			if (index($orig_uri, $logout_path) >= 0) {
				return logout_handler($r);
			}
		}	

		# Default to login handler
		return login_handler($r);
	}

	# If DB connection fails, instruct client to retry later
	$r->err_headers_out->set('Retry-After' => '60');
	return Apache2::Const::HTTP_SERVICE_UNAVAILABLE;
}

# -------------------------------------------------------------------------
# Login Handler State Machine: new -> login -> sms_code_sent -> sms_code_verified
# -------------------------------------------------------------------------
sub login_handler {
	my $r = shift;
	
	my $login_path = $r->dir_config('LoginPath') || '/private/login.html';
	my $logout_path = $r->dir_config('LogoutPath') || 'logout';
	my $logged_out_path = $r->dir_config('LoggedOutPath') || '/logged_out.html';
	my $sms_code_path = $r->dir_config('SMSCodePath') || '/private/sms_code.html';
	my $default_path = $r->dir_config('DefaultPath') || '/';

	# Check request environment first, then system %ENV
	my $sms_template = $r->subprocess_env('NOTIFICATION_SMS_CODE_MESSAGE') 
	                || $ENV{'NOTIFICATION_SMS_CODE_MESSAGE'} 
	                || 'SMS Code: {sms_code}';
	
	my ($dbh, $sth, $d);
	if ($dbh = LockServer::Db->my_connect) {

		my $cgi = CGI->new($r);

		# Parse existing cookie
		my $cookie_header = $r->headers_in->{Cookie} || '';
		my %cookies = CGI::Cookie->parse($cookie_header);
		my $passed_cookie_token = $cookies{'auth_token'} ? scalar $cookies{'auth_token'}->value : undef;

		my $cookie_token;
		my $cookie;

		if ($passed_cookie_token) {
			# Use existing token/cookie
			$cookie_token = $passed_cookie_token;
			$cookie = $cookies{'auth_token'};
		} else {
			# Generate new token and cookie
			$cookie_token = unpack('H*', join('', map(chr(int Math::Random::Secure::rand(256)), 1..16)));
			$cookie = CGI::Cookie->new(
				-name    => 'auth_token',
				-value   => $cookie_token,
				-expires => '+1y',
				-httponly => 1,
				-secure   => 0
			);
			# Set the new cookie early so it's only set once
			add_set_cookie_once($r, $cookie);
		}
	
		my $quoted_passed_cookie_token = $dbh->quote($passed_cookie_token || $cookie_token);
	
		# Look up authentication state by token
		$sth = $dbh->prepare(qq[SELECT `id`, `auth_state` FROM sms_auth WHERE cookie_token LIKE $quoted_passed_cookie_token LIMIT 1]);
		$sth->execute;
		if ($d = $sth->fetchrow_hashref) {
			if ($d->{auth_state} =~ /new/i) {
				# Update state to 'login'
				$dbh->do(qq[UPDATE sms_auth SET auth_state = 'login', unix_time = ] . time() . qq[ WHERE cookie_token = $quoted_passed_cookie_token]) or warn $!;
				
				add_set_cookie_once($r, $cookie);
				$r->err_headers_out->add('Location' => $login_path);
				return Apache2::Const::REDIRECT;
			}
			elsif ($d->{auth_state} =~ /login/i) {
				# Attempt to match user's phone number
				my $id = $cgi->param('id');
				my $normalized_phone = undef;
	
				if ($id) {
					# Validate and normalize phone number using LockServer::Number::Phone
					my $phone_obj = LockServer::Number::Phone->new($id);
					if ($phone_obj && $phone_obj->is_valid) {
						$normalized_phone = $phone_obj->compact;
					}
				}

				my $authenticated_user_id = undef;

				if ($normalized_phone) {
					my $quoted_normalized = $dbh->quote($normalized_phone);

					# Query the active user ID from targeted schema definitions
					my $query = qq[
						SELECT `id` FROM users 
						WHERE `phone` = $quoted_normalized 
							AND `active` = 1 
							AND (`active_from` IS NULL OR `active_from` < NOW()) 
							AND (`expire_at` IS NULL OR NOW() < `expire_at`) 
						LIMIT 1
					];
					$sth = $dbh->prepare($query);
					$sth->execute;
					if (my $user_row = $sth->fetchrow_hashref) {
						$authenticated_user_id = $user_row->{id};
					}
				}
	
				if ($authenticated_user_id) {
					# Generate and send SMS code
					my $sms_code = join('', map(int(Math::Random::Secure::rand(10)), 1..6));
					my $quoted_sms_code = $dbh->quote($sms_code);
					my $quoted_phone_db = $dbh->quote($normalized_phone);

					# Save status flags over state parameters
					$dbh->do(qq[UPDATE sms_auth SET `auth_state` = 'sms_code_sent', `sms_code` = $quoted_sms_code, `phone` = $quoted_phone_db, unix_time = ] . time() . qq[ WHERE cookie_token = $quoted_passed_cookie_token]) or warn $!;

					# Replace placeholder with actual code
					my $sms_message = $sms_template;
					$sms_message =~ s/\{sms_code\}/$sms_code/g;

					send_notification($r, $normalized_phone, $sms_message);

					# Start with a session cookie
					$cookie = CGI::Cookie->new(
						-name    => 'auth_token',
						-value   => $cookie_token,
						-httponly => 1,
						-secure   => 0
					);
					add_set_cookie_once($r, $cookie);
					$r->err_headers_out->add('Location' => $sms_code_path);
					return Apache2::Const::REDIRECT;
				} else {
					# Redirect to login form to re-enter phone number
					add_set_cookie_once($r, $cookie);
					$r->internal_redirect($login_path);
					return Apache2::Const::OK;
				}
			}
			elsif ($d->{auth_state} =~ /sms_code_sent/i) {
				# Validate submitted SMS code
				my $sms_code = $cgi->param('sms_code');
				my $quoted_sms_code = $dbh->quote($sms_code);
				my $stay_logged_in = $cgi->param('stay_logged_in');

				if ($stay_logged_in) {
					# Recreate persistent cookie (1 year expiration)
					$cookie = CGI::Cookie->new(
						-name    => 'auth_token',
						-value   => $passed_cookie_token,
						-expires => '+1y',
						-httponly => 1,
						-secure   => 0,
					);
				} else {
					# Create session cookie (no expiration)
					$cookie = CGI::Cookie->new(
						-name    => 'auth_token',
						-value   => $passed_cookie_token,
						-httponly => 1,
						-secure   => 0
					);
				}

				$sth = $dbh->prepare(qq[SELECT `sms_code`, `orig_uri` FROM sms_auth WHERE `cookie_token` LIKE $quoted_passed_cookie_token AND `sms_code` LIKE $quoted_sms_code LIMIT 1]);
				$sth->execute;
				if ($d = $sth->fetchrow_hashref) {
					# SMS code is valid
					$dbh->do(qq[UPDATE sms_auth SET `auth_state` = 'sms_code_verified', `session` = ] . ($stay_logged_in ? 0 : 1) . qq[, unix_time = ] . time() . qq[ WHERE cookie_token = $quoted_passed_cookie_token]) or warn $!;

					# Log user login
					log_auth_event($dbh, $r, 'login', $dbh->quote($passed_cookie_token));

					add_set_cookie_once($r, $cookie);
					$r->err_headers_out->add('Location' => $d->{orig_uri});
					return Apache2::Const::REDIRECT;
				} else {
					# Invalid code, reload SMS form
					add_set_cookie_once($r, $cookie);
					$r->internal_redirect($sms_code_path);
					return Apache2::Const::OK;
				}
			}
			elsif ($d->{auth_state} =~ /sms_code_verified/i) {
				# User is authenticated; possibly use session cookie
				$sth = $dbh->prepare(qq[SELECT `session` FROM sms_auth WHERE `cookie_token` LIKE $quoted_passed_cookie_token LIMIT 1]);
				$sth->execute;
				$d = $sth->fetchrow_hashref;
				
				if ($d->{session}) {
					# Session cookie (no expiration)
					$cookie = CGI::Cookie->new(
						-name    => 'auth_token',
						-value   => $passed_cookie_token,
						-httponly => 1,
						-secure   => 0
					);
				} else {
					# Persistent cookie (1 year expiration)
					$cookie = CGI::Cookie->new(
						-name    => 'auth_token',
						-value   => $passed_cookie_token,
						-expires => '+1y',
						-httponly => 1,
						-secure   => 0
					);
				}
				# Update last used timestamp
				$dbh->do(qq[UPDATE sms_auth SET unix_time = ] . time() . qq[ WHERE cookie_token = $quoted_passed_cookie_token]) or warn $!;
				add_set_cookie_once($r, $cookie);
				
				return Apache2::Const::OK;
			}
			elsif ($d->{auth_state} =~ /deny/i) {
				# Denied state, restart auth flow
				return login_handler($r);
			}
		}
		else {
			# No record found, create a new login session
			my $quoted_cookie_token = $dbh->quote($passed_cookie_token || $cookie_token);
			my $quoted_remote_host = $dbh->quote($r->headers_in->{'X-Real-IP'} || $r->headers_in->{'X-Forwarded-For'} || $r->useragent_ip || $r->connection->remote_ip);
			my $quoted_user_agent = $dbh->quote($r->headers_in->{'User-Agent'});

			if (index($r->uri, $login_path) >= 0 || index($r->uri, $logout_path) >= 0 || index($r->uri, $logged_out_path) >= 0 || index($r->uri, $sms_code_path) >= 0) {
				my $quoted_default_path = $dbh->quote($default_path);
				$dbh->do(qq[INSERT INTO sms_auth (cookie_token, auth_state, orig_uri, remote_host, user_agent, unix_time) VALUES ($quoted_cookie_token, 'new', $quoted_default_path, $quoted_remote_host, $quoted_user_agent, ] . time() . qq[)]) or warn $!;
			} else {
				my $quoted_orig_uri = $dbh->quote($r->uri . ($r->args ? ('?' . $r->args) : ''));
				$dbh->do(qq[INSERT INTO sms_auth (cookie_token, auth_state, orig_uri, remote_host, user_agent, unix_time) VALUES ($quoted_cookie_token, 'new', $quoted_orig_uri, $quoted_remote_host, $quoted_user_agent, ] . time() . qq[)]) or warn $!;
			}
	
			add_set_cookie_once($r, $cookie);
			$r->err_headers_out->add('Location' => $login_path);
			return Apache2::Const::REDIRECT;
		}
	}

	$r->err_headers_out->set('Retry-After' => '60');
	return Apache2::Const::HTTP_SERVICE_UNAVAILABLE;
}

# -------------------------------------------------------------------------
# Logout Handler: Deletes session token & expires client cookie
# -------------------------------------------------------------------------
sub logout_handler {
	my $r = shift;
	
	my $logged_out_path = $r->dir_config('LoggedOutPath') || '/logged_out.html';

	my ($dbh, $sth, $d);
	if ($dbh = LockServer::Db->my_connect) {
		my $passed_cookie = $r->headers_in->{Cookie} || '';
		my $passed_cookie_token;
		if ($passed_cookie) {
			my %cookies = CGI::Cookie->parse($passed_cookie);
			$passed_cookie_token = $cookies{'auth_token'} ? scalar $cookies{'auth_token'}->value : undef;
		}
		my $cookie = CGI::Cookie->new(
			-name    => 'auth_token',
			-value   => $passed_cookie_token,
			-expires => '-1y',
			-httponly => 1,
			-secure   => 0
		);
		
		# Log user logout
		log_auth_event($dbh, $r, 'logout', $dbh->quote($passed_cookie_token));

		my $quoted_cookie_token = $dbh->quote($passed_cookie_token);
		$dbh->do(qq[DELETE FROM sms_auth WHERE cookie_token = $quoted_cookie_token]) or warn $!;
		
		add_set_cookie_once($r, $cookie);
		$r->internal_redirect($logged_out_path);
		return Apache2::Const::OK;
	}

	$r->err_headers_out->set('Retry-After' => '60');
	return Apache2::Const::HTTP_SERVICE_UNAVAILABLE;
}

sub add_set_cookie_once {
	my ($r, $cookie) = @_;
	my @cookies = $r->err_headers_out->get('Set-Cookie');
	foreach my $c (@cookies) {
		if ($c eq $cookie->as_string) {
			return;  # Cookie already set
		}
	}
	$r->err_headers_out->add('Set-Cookie' => $cookie);
}

# -------------------------------------------------------------------------
# Helper: Log Authentication Events
# -------------------------------------------------------------------------
sub log_auth_event {
	my ($dbh, $r, $action, $quoted_cookie_token) = @_;

	# Join users directly to sms_auth matching phone strings
	my $sth = $dbh->prepare(qq[
		SELECT u.username
		FROM users u
		JOIN sms_auth a ON u.phone = a.phone
		WHERE a.cookie_token LIKE $quoted_cookie_token
			AND a.auth_state = 'sms_code_verified'
		LIMIT 1
	]);
	$sth->execute;
	if (my $d = $sth->fetchrow_hashref) {
		$dbh->do(qq[
			INSERT INTO log
			(`user`, `rfid`, `action`, `source`, `time_stamp`)
			VALUES (
				] . $dbh->quote($d->{username}) . qq[,
				NULL,
				] . $dbh->quote("web_" . $action) . qq[,
				'web_auth',
				NOW()
			)
		]) or warn $!;
	}
}

1;

__END__
