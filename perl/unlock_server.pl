#!/usr/bin/perl -w

use strict;
use warnings;
use Data::Dumper;
use AnyEvent;
use AnyEvent::Redis;
use DBI;
use Time::HiRes qw( usleep );
use Proc::Simple;

use lib qw( /usr/local/share/perl5 );
use LockServer::Db;
use LockServer::Utils qw(log_info log_warn log_die);

my $DEBUG = $ENV{DEBUG} || 0;

# Dynamically load hardware libraries only if not debugging
if (!$DEBUG) {
	require Device::BCM2835;
	Device::BCM2835->import();
}

#use constant MY_SERVER_ROOT => '/var/www/lock_server';
my $MY_SERVER_ROOT = '/var/www/lock_server';

# Force autoflush on output handlers so logs appear instantly in Docker
$| = 1;

log_docker('info', "starting...");

# connect to db
my $dbh;
if($dbh = LockServer::Db->my_connect) {
	$dbh->{'mysql_auto_reconnect'} = 1;
	log_docker('info', "connected to db");
}
else {
	log_docker('err', "cant't connect to db $!");
	die $!;
}

# get defaults from db
my $LOCK_PIN = get_defaults('lock_pin') || 0;
my $CONTACT_PIN = get_defaults('contact_pin') || 13;

if (!$DEBUG) {
	# set up and clear lock interface
	Device::BCM2835::init() || die "Could not init library";

	 # outputs
	Device::BCM2835::gpio_fsel(&Device::BCM2835::RPI_V2_GPIO_P1_13,
	                           &Device::BCM2835::BCM2835_GPIO_FSEL_OUTP);
	Device::BCM2835::gpio_fsel(&Device::BCM2835::RPI_V2_GPIO_P1_26,
	                           &Device::BCM2835::BCM2835_GPIO_FSEL_OUTP);
} else {
	log_docker('info', "[DEBUG MODE] Skipping physical hardware library initialization");
}

ls_lock();
#syslog('info', "locked...");

# start servers...

# --- Redis Connection Initialization ---
my $redis_host = $ENV{REDIS_HOST} || 'lock-redis';
my $redis_port = $ENV{REDIS_PORT} || 6379;

my $redis;
eval {
	$redis = Redis->new(
		server    => "$redis_host:$redis_port",
		reconnect => 10,     # try reconnecting for up to 10 seconds
		every     => 1000,   # wait 1000ms between reconnect attempts
	);
};
if ($@ || !$redis) {
	log_warn("Failed to connect to Redis at $redis_host:$redis_port: $@");
}

# Asynchronously subscribe to the centralized message bus channel
$redis->subscribe('lock_events', sub {
	my ($message, $channel) = @_;
	return unless defined $message;

	if ($message =~/^unlock_rfid:(.+)$/) {
		handler_unlock_rfid(undef, $1);
	}
	elsif ($message eq 'unlock_button') {
		handler_unlock_button(undef);
	}
	elsif ($message =~ /^unlock_web:(.+)$/) {
		handler_unlock_web(undef, $1);
	}
	elsif ($message =~ /^validate_web:(.+)$/) {
		handler_validate_web(undef, $1);
	}
});

log_docker('info', "Redis event listener initialized on channel: lock_events");
log_docker('info', "$0 started");

# runs forever...
my $s = AnyEvent->signal(signal => 'INT', cb => \&stop_server);
AnyEvent->condvar->recv;

log_docker('info', "all threads stopped...");
log_docker('info', "$0 stopped");
ls_lock();
#syslog('info', "locked...");
exit 1;

## END MAIN

sub log_docker {
	my ($level, $message) = @_;
	my $timestamp = gmtime();
	if ($level eq 'err') {
		print STDERR "[$level] $message\n";
	} else {
		print STDOUT "[$level] $message\n";
	}
}

sub handler_unlock_web {
	my ($res_cv, $user) = @_;

	# Reject empty or undefined username — DO NOT UNLOCK
	if (!defined $user || $user eq '') {
		log_docker('err', "unlock_web rejected: empty or invalid username");
		db_log(undef, undef, 'unauthorized_web_attempt', 'web');
		$res_cv->result(undef) if defined $res_cv;
		return;
	}

	unlock_web($user);
}

sub handler_validate_web {
	my ($res_cv, $user) = @_;

	my $dbh_thr = LockServer::Db->my_connect or warn $!;
	if ($dbh_thr) {
		my $query = qq[
			SELECT `username`, `active`, `sound_on_rfid_open` 
			FROM users 
			WHERE username = ? 
				AND (`active_from` is NULL OR (`active_from` < NOW())) 
				AND (`expire_at` is NULL OR (NOW() < `expire_at`))
		];
		my $sth_thr = $dbh_thr->prepare($query);
		$sth_thr->execute($user) || warn $!;
		my ($found_user, $active, $sound_on_rfid_open) = $sth_thr->fetchrow;
		$sth_thr->finish;
		$dbh_thr->disconnect;

#		db_log($user, undef, 'validate', 'web');
#		log_docker('info', "user $user validate");
		if ($active) {
			$res_cv->result(1) if defined $res_cv;
		}
		else {
			$res_cv->result(undef) if defined $res_cv;
		}
	}
}

sub handler_unlock_rfid {
	my ($res_cv, $rfid) = @_;
	my $dbh_thr = LockServer::Db->my_connect or warn $!;
	if ($dbh_thr) {
		my $query = qq[
			SELECT `username`, `name`, `active`, `sound_on_rfid_open` 
			FROM users 
			WHERE rfid = ? 
				AND (`active_from` is NULL OR (`active_from` < NOW())) 
				AND (`expire_at` is NULL OR (NOW() < `expire_at`))
		];
		my $sth_thr = $dbh_thr->prepare($query);
		$sth_thr->execute($rfid) || warn $!;
		my ($user, $name, $active, $sound_on_rfid_open) = $sth_thr->fetchrow;
		$sth_thr->finish;
		$dbh_thr->disconnect;

		if ($active) {
			$res_cv->result(undef) if defined $res_cv;

			my $thr_buzzer = Proc::Simple->new();
			if ($sound_on_rfid_open) {
				$thr_buzzer->start(\&buzzer, $user);
			}

			unlock_rfid($user || $name, $rfid);

			if ($sound_on_rfid_open) {
				if ($thr_buzzer->poll) {
					$thr_buzzer->kill;
				}
			}
		}
		else {
			$res_cv->result(undef) if defined $res_cv;
			db_log(undef, $rfid, 'unauthorized', 'rfid');
			log_docker('info', "rfid $rfid not authorized");

			#brute force resitance
			usleep(1000_000);
		}
	}
}

sub handler_unlock_button {
	my ($res_cv) = @_;

	$res_cv->result(undef) if defined $res_cv;

	my $thr_buzzer = Proc::Simple->new();
#	if ($sound_on_rfid_open) {
#		$thr_buzzer->start(\&buzzer, $user);
#	}

	unlock_button();

#	if ($sound_on_rfid_open) {
#		if ($thr_buzzer->poll) {
#			$thr_buzzer->kill;
#		}
#	}
}

sub stop_server {
	log_docker('info', "$0 stopped");
	exit 1; 
}

sub buzzer {
	my $user = shift;
	my $sound = get_user_defaults($user, 'sound_file');
	if (get_user_defaults($user, 'sound_repeat')) {
		while (1) {
#			`/usr/bin/aplay $MY_SERVER_ROOT/sounds/$sound -q`;
		}
	}
	else {
#			`/usr/bin/aplay $MY_SERVER_ROOT/sounds/$sound -q`;
	}
}

sub get_defaults {
	my $pref_name = shift;
	my $dbh_thr = LockServer::Db->my_connect or warn $!;
	my $query = qq[
		SELECT `value` 
		FROM default_prefs 
		WHERE `name` = ?
	];
	my $sth_thr = $dbh_thr->prepare($query);
	if ($sth_thr->execute($pref_name)) {
		my ($pref) = $sth_thr->fetchrow;
		$sth_thr->finish;
		$dbh_thr->disconnect;
		return $pref;
	}
	else {
		$sth_thr->finish;
		$dbh_thr->disconnect;
		log_docker('err', "$!");
		return undef;
	}
}

sub get_user_defaults {
	my ($user, $pref_name) = @_;
	my $dbh_thr = LockServer::Db->my_connect or warn $!;
	my $query = qq[
		SELECT `$pref_name` 
		FROM users 
		WHERE username = ?
	];
	my $sth_thr = $dbh_thr->prepare($query);
	if ($sth_thr->execute($user)) {
		my ($pref) = $sth_thr->fetchrow;
		$sth_thr->finish;
		$dbh_thr->disconnect;
		if (defined $pref) {
			return $pref;
		}
		else {
			$pref = get_defaults($pref_name);
			log_docker('info', "no user pref $pref_name for $user, using default: $pref");
			return $pref;
		}
	}
	else {
		$sth_thr->finish;
		$dbh_thr->disconnect;
		log_docker('err', "$!");
		return undef;
	}
}

sub db_log {
	my ($user, $rfid, $message, $source) = @_;
	my $dbh_thr = LockServer::Db->my_connect or warn $!;
	my $query = qq[
		INSERT INTO `log` 
			(`user`, `rfid`, `action`, `source`, `time_stamp`) 
		VALUES 
			(?, ?, ?, ?, NOW())
	];
	my $sth_thr = $dbh_thr->prepare($query);
	$sth_thr->execute($user, $rfid, $message, $source) || log_docker('err', "can't log to db");
	$sth_thr->finish;
	$dbh_thr->disconnect;
}

sub unlock_rfid {
	my ($user, $rfid) = @_;

	ls_unlock();
	my $thr_buzzer;
#	if ($sound_on_rfid_open) {
#		$thr_buzzer = threads->create('buzzer', $user);
#	}
	db_log($user, $rfid, 'unlock', 'rfid');
	log_docker('info', "user $user unlocked with rfid: $rfid");
	usleep(get_user_defaults($user, 'open_time') * 1000_000);

	ls_lock();
#	if ($sound_on_rfid_open) {
#		$thr_buzzer->suspend;
#		$thr_buzzer->detach;
#	}
	db_log($user, $rfid, 'lock', 'rfid');
	log_docker('info', "locked...");
}

sub unlock_web {
	my $user = shift;

	ls_unlock();
	db_log($user, undef, 'unlock', 'web');
	log_docker('info', "user $user unlocked");
	usleep(get_user_defaults($user, 'open_time') * 1000_000);

	ls_lock();
	db_log($user, undef, 'lock', 'web');
	log_docker('info', "locked...");
}

sub unlock_button {
	ls_unlock();
	my $thr_buzzer;
#	if ($sound_on_rfid_open) {
#		$thr_buzzer = threads->create('buzzer', $user);
#	}
	db_log('', undef, 'unlock', 'button');
	log_docker('info', "button unlocked");
	usleep(get_defaults('open_time') * 1000_000);

	ls_lock();
#	if ($sound_on_rfid_open) {
#		$thr_buzzer->suspend;
#		$thr_buzzer->detach;
#	}
	db_log('', undef, 'lock', 'button');
	log_docker('info', "locked...");
}

sub ls_unlock {
	if (!$DEBUG) {
		Device::BCM2835::gpio_write(&Device::BCM2835::RPI_V2_GPIO_P1_13, 1);
		Device::BCM2835::gpio_write(&Device::BCM2835::RPI_V2_GPIO_P1_26, 1);
		`echo 0 >/sys/class/leds/ath9k_htc-phy0/brightness ; echo 1 >/sys/class/leds/ath9k_htc-phy0/brightness`;
	} else {
		log_docker('info', "[DEBUG MODE] Executing virtual action: RELAY UNLOCKED");
	}
}

sub ls_lock {
	if (!$DEBUG) {
		Device::BCM2835::gpio_write(&Device::BCM2835::RPI_V2_GPIO_P1_13, 0);
		Device::BCM2835::gpio_write(&Device::BCM2835::RPI_V2_GPIO_P1_26, 0);
		`echo "phy0tpt"> /sys/class/leds/ath9k_htc-phy0/trigger`;
	} else {
		log_docker('info', "[DEBUG MODE] Executing virtual action: RELAY LOCKED");
	}
}
