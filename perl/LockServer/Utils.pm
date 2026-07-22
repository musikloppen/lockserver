package LockServer::Utils;

use strict;
use warnings;
use utf8;

use Net::SMTP;
use Email::MIME;
use Encode qw(decode is_utf8);
use File::Basename;
use LockServer::Number::Phone;

use Exporter 'import';
our @EXPORT_OK = qw(
	send_notification 
	generate_guest_username 
	log_info 
	log_warn 
	log_die
);

# Autoflush output buffers
$| = 1;

binmode(STDOUT, ":encoding(UTF-8)");
binmode(STDERR, ":encoding(UTF-8)");

my $script_name = basename($0 || 'script', ".pl");

# -------------------------------------------------------------------------
# Helper: Generate Readable Guest Username (e.g., guest-swift-panda-42)
# -------------------------------------------------------------------------
sub generate_guest_username {
	my @adjectives = qw(
		swift happy bright brave calm clever eager gentle kind nimble solar cosmic
		keen stellar bold vivid loyal quiet grand prime arctic rapid
	);
	
	my @animals = qw(
		panda falcon otter lynx dolphin fox koala badger raven heron wolf tiger
		hawk bear bison cobra eagle finch gecko lemur moose owl puma
	);

	my $adj    = $adjectives[int rand @adjectives];
	my $animal = $animals[int rand @animals];
	my $num    = sprintf("%02d", int rand 100);

	return "guest-$adj-$animal-$num";
}

# -------------------------------------------------------------------------
# Helper: Send SMS via Configured SMTP Server (Supports DEBUG Dry-Run Mode)
# -------------------------------------------------------------------------
sub send_notification {
	my ($r, $sms_number, $message) = @_;
	return 0 unless $sms_number && $message;

	eval {
		# Validate and normalize phone number
		my $phone_obj = LockServer::Number::Phone->new($sms_number);
		unless ($phone_obj && $phone_obj->is_valid) {
			log_warn("Cannot send SMS: Invalid phone number format '$sms_number'", { -request => $r });
			return 0;
		}

		# Strictly enforce 00 prefix formatting (e.g., 004512345678)
		$sms_number = $phone_obj->international;

		# Check DEBUG mode
		my $debug = $ENV{DEBUG} || ($r ? $r->subprocess_env('DEBUG') : undef);
		if ($debug) {
			log_info("[DEBUG DRY-RUN] Skipping actual SMTP dispatch. SMS to $sms_number: \"$message\"", { -request => $r });
			return 1;
		}

		# Extract SMTP settings safely (%ENV takes precedence over Apache subprocess_env)
		my $smtp_host = $ENV{SMTP_HOST} || ($r ? $r->subprocess_env('SMTP_HOST') : undef);
		my $smtp_port = $ENV{SMTP_PORT} || ($r ? $r->subprocess_env('SMTP_PORT') : undef) || 25;

		unless ($smtp_host) {
			log_warn("Mandatory environment variable missing: SMTP_HOST", { -request => $r });
			return 0;
		}

		unless (is_utf8($message)) {
			$message = decode('UTF-8', $message);
		}

		my $email = Email::MIME->create(
			header_str => [
				From    => 'meterlogger@meterlogger',
				To      => $sms_number . '@meterlogger',
				Subject => $message,
			],
			attributes => {
				encoding     => 'quoted-printable',
				charset      => 'UTF-8',
				content_type => 'text/plain',
			},
			body => '',
		);

		# Standard SMTPS (Port 465) uses SSL upfront, STARTTLS (Port 587/25) upgrades after handshake
		my %smtp_opts = (
			Port    => $smtp_port,
			Timeout => 10,
		);
		if ($smtp_port == 465) {
			$smtp_opts{SSL} = 1;
		}

		my $smtp = Net::SMTP->new($smtp_host, %smtp_opts);
		unless ($smtp) {
			log_warn("Cannot connect to SMTP server at $smtp_host:$smtp_port", { -request => $r });
			return 0;
		}

		# Initiate STARTTLS if explicitly requested or standard submission port 587
		my $use_tls = $ENV{SMTP_USE_TLS} || ($r ? $r->subprocess_env('SMTP_USE_TLS') : undef);
		if ($use_tls || $smtp_port == 587) {
			$smtp->starttls();
			# 220 / 200 series means success in SMTP protocol
			unless ($smtp->code() == 220 || $smtp->code() == 200) {
				log_warn("SMTP STARTTLS failed (" . $smtp->code() . "): " . $smtp->message(), { -request => $r });
				$smtp->quit();
				return 0;
			}
		}

		# Authenticate if credentials are provided in environment
		my $smtp_user = $ENV{SMTP_USER} || ($r ? $r->subprocess_env('SMTP_USER') : undef);
		my $smtp_pass = $ENV{SMTP_PASSWORD} || ($r ? $r->subprocess_env('SMTP_PASSWORD') : undef);
		if ($smtp_user && $smtp_pass) {
			unless ($smtp->auth($smtp_user, $smtp_pass)) {
				log_warn("SMTP AUTH failed: " . $smtp->message(), { -request => $r });
				$smtp->quit();
				return 0;
			}
		}

		unless ($smtp->mail('meterlogger@meterlogger')) {
			log_warn("SMTP MAIL FROM failed: " . $smtp->message(), { -request => $r });
			$smtp->quit();
			return 0;
		}

		unless ($smtp->to("$sms_number\@meterlogger")) {
			log_warn("SMTP RCPT TO failed: " . $smtp->message(), { -request => $r });
			$smtp->quit();
			return 0;
		}

		unless ($smtp->data()) {
			log_warn("SMTP DATA failed: " . $smtp->message(), { -request => $r });
			$smtp->quit();
			return 0;
		}

		unless ($smtp->datasend($email->as_string)) {
			log_warn("SMTP DATASEND failed: " . $smtp->message(), { -request => $r });
			$smtp->quit();
			return 0;
		}

		unless ($smtp->dataend()) {
			log_warn("SMTP DATAEND failed: " . $smtp->message(), { -request => $r });
			$smtp->quit();
			return 0;
		}

		$smtp->quit();
		log_info("SMS sent to $sms_number via $smtp_host", { -request => $r });
		return 1;
	};

	if ($@) {
		log_warn("Failed to send SMS to $sms_number: $@", { -request => $r });
		return 0;
	}

	return 1;
}

# -------------------------------------------------------------------------
# Logging Utilities
# -------------------------------------------------------------------------
sub log_info {
	my (@msgs) = @_;
	my $opts = {};
	if (ref $msgs[-1] eq 'HASH') {
		$opts = pop @msgs;
	}
	_log_message(\*STDOUT, '', \@msgs, $opts);
}

sub log_warn {
	my (@msgs) = @_;
	my $opts = {};
	if (ref $msgs[-1] eq 'HASH') {
		$opts = pop @msgs;
	}
	_log_message(\*STDERR, 'WARN', \@msgs, $opts);
}

sub log_die {
	my (@msgs) = @_;
	my $opts = {};
	if (ref $msgs[-1] eq 'HASH') {
		$opts = pop @msgs;
	}

	# Log as WARN first
	_log_message(\*STDERR, 'WARN', \@msgs, $opts);

	# Exit immediately with joined messages
	my $text = join('', map { defined $_ ? $_ : '' } @msgs);
	chomp($text);
	die "[" . ($opts->{no_script_name} ? '' : $script_name) . "] [WARN] $text\n";
}

sub _log_message {
	my ($fh, $level, $msgs_ref, $opts) = @_;

	my $r                  = $opts->{-request};
	my $disable_tag        = $opts->{-no_tag};
	my $disable_script     = $opts->{-no_script_name};
	my $custom_tag         = $opts->{-custom_tag};
	my $custom_script_name = $opts->{-custom_script_name};

	my ($caller_package, $caller_file, $caller_line) = caller(2);
	$caller_package ||= 'main';

	my $script_display = $disable_script ? '' : ($custom_script_name || $script_name);
	my $prefix = (!$disable_tag && $level) ? "[$level] " : '';

	foreach my $msg (@$msgs_ref) {
		my $text = defined $msg ? $msg : '';
		chomp($text);

		my $line;
		if (defined $custom_tag) {
			my @parts;
			push @parts, "[$script_display]" if $script_display;
			push @parts, "[$custom_tag]";
			my $line_prefix = join(' ', @parts);
			$line = "$line_prefix $prefix$text";
		} elsif ($caller_package && $caller_package ne 'main' && !$disable_script) {
			$line = "[$script_display->$caller_package] $prefix$text";
		} elsif ($caller_package && $caller_package ne 'main') {
			$line = "[$caller_package] $prefix$text";
		} elsif (!$disable_script) {
			$line = "[$script_display] $prefix$text";
		} else {
			$line = "$prefix$text";
		}

		# Route to Apache log if $r request object is available
		if ($r && $r->can('log_error')) {
			$r->log_error($line);
		} else {
			print $fh "$line\n";
		}
	}
}

1;

__END__
