#!/usr/bin/perl -w

use strict;
use warnings;
use Data::Dumper;
use Redis;
use DBI;
use Time::HiRes qw( usleep );

use lib qw( /usr/local/share/perl5 );
use LockServer::Db;

my $DEBUG = $ENV{DEBUG} || 0;

if (!$DEBUG) {
	require Device::BCM2835;
	Device::BCM2835->import();
}

my $MY_SERVER_ROOT = '/var/www/lock_server';

# Force autoflush on output handlers so logs appear instantly in Docker
$| = 1;

log_docker('info', "starting...");

# connect to db
my $dbh;
if ($dbh = LockServer::Db->my_connect) {
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

$SIG{INT} = \&stop_server;

# main
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

if (!$DEBUG) {
	# set up lock interface
	Device::BCM2835::init() || die "Could not init library";

	# inputs
	Device::BCM2835::gpio_fsel(&Device::BCM2835::RPI_V2_GPIO_P1_07,
	                           &Device::BCM2835::BCM2835_GPIO_FSEL_INPT);
	Device::BCM2835::gpio_fsel(&Device::BCM2835::RPI_V2_GPIO_P1_11,
	                           &Device::BCM2835::BCM2835_GPIO_FSEL_INPT);
} else {
	log_docker('info', "[DEBUG MODE] Button input pooling disabled. Sleeping idly.");
}

log_docker('info', "$0 started");
while (1) {
	if (!$DEBUG) {
		if (Device::BCM2835::gpio_lev(&Device::BCM2835::RPI_V2_GPIO_P1_07) || Device::BCM2835::gpio_lev(&Device::BCM2835::RPI_V2_GPIO_P1_11)) {
			$redis->publish('lock_events', "unlock_button");
			usleep(get_defaults('open_time') * 1000_000);
		}
		usleep(100_000);
	} else {
		# Keep running cleanly on Mac without infinite CPU execution loops
		sleep(3600);
	}
}

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

sub stop_server {
	log_docker('info', "$0 stopped");
	exit 1;
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
