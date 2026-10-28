#!/usr/bin/perl -w

use strict;
use warnings;
use Data::Dumper;
use Redis;
use DBI;
use Time::HiRes qw( usleep );

use lib qw( /usr/local/share/perl5 );
use LockServer::Db;
use LockServer::Utils qw(log_warn);

my $DEBUG = $ENV{DEBUG} || 0;

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

# 4rel4in HAT configuration: Stack 0, Input Channels 1 and 2
my $HAT_STACK = 0;
my $INPUT_CH1 = 1;
my $INPUT_CH2 = 2;

if (!$DEBUG) {
	# Verify the 4rel4in command line utility can communicate with the HAT
	my $probe = `4rel4in $HAT_STACK inread $INPUT_CH1 2>&1`;
	if ($? != 0) {
		log_docker('err', "Failed to read input from 4rel4in HAT: $probe");
	} else {
		log_docker('info', "4rel4in HAT inputs initialized on I2C bus (stack $HAT_STACK)");
	}
} else {
	log_docker('info', "[DEBUG MODE] Button input pooling disabled. Sleeping idly.");
}

log_docker('info', "$0 started");
while (1) {
	if (!$DEBUG) {
		my $in1 = `4rel4in $HAT_STACK inread $INPUT_CH1`;
		chomp($in1) if defined $in1;
		my $in2 = `4rel4in $HAT_STACK inread $INPUT_CH2`;
		chomp($in2) if defined $in2;

		if (($in1 && $in1 eq "1") || ($in2 && $in2 eq "1")) {
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
