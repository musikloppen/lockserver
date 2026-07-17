#!/usr/bin/perl -w

use strict;
use warnings;
use Data::Dumper;
use Device::BCM2835;
use Sys::Syslog;
use Redis;
use DBI;
use Time::HiRes qw( usleep );

use lib qw( /usr/local/share/perl5 );
use LockServer::Db;

my $MY_SERVER_ROOT = '/var/www/lock_server';

openlog($0, "ndelay,pid", "local0");
syslog('info', "starting...");

# connect to db
my $dbh;
if ($dbh = LockServer::Db->my_connect) {
	$dbh->{'mysql_auto_reconnect'} = 1;
	syslog('info', "connected to db");
}
else {
	syslog('info', "cant't connect to db $!");
	die $!;
}

# get defaults from db
my $LOCK_PIN = get_defaults('lock_pin') || 0;
my $CONTACT_PIN = get_defaults('contact_pin') || 13;

$SIG{INT} = \&stop_server;

# main
# Initialize Redis client connection
my $redis_host = $ENV{REDIS_HOST} || 'lock-redis';
my $redis = Redis->new(server => "$redis_host:6379");

# set up lock interface
Device::BCM2835::init() || die "Could not init library";
# inputs
Device::BCM2835::gpio_fsel(&Device::BCM2835::RPI_V2_GPIO_P1_07,
                           &Device::BCM2835::BCM2835_GPIO_FSEL_INPT);
Device::BCM2835::gpio_fsel(&Device::BCM2835::RPI_V2_GPIO_P1_11,
                           &Device::BCM2835::BCM2835_GPIO_FSEL_INPT);

syslog('info', "$0 started");
while (1) {
	if (Device::BCM2835::gpio_lev(&Device::BCM2835::RPI_V2_GPIO_P1_07) || Device::BCM2835::gpio_lev(&Device::BCM2835::RPI_V2_GPIO_P1_11)) {
		
		# Publish the button trigger event over the Redis message bus
		$redis->publish('lock_events', "unlock_button");
		
		usleep(get_defaults('open_time') * 1000_000);
	}
	usleep(100_000);
}


## END MAIN



sub stop_server {
	syslog('info', "$0 stopped");
	exit 1;
}

sub get_defaults {
	my $pref_name = shift;
	my $dbh_thr = LockServer::Db->my_connect or warn $!;
	my $sth_thr = $dbh_thr->prepare(qq[SELECT `value` FROM default_prefs WHERE `name` = ] . $dbh_thr->quote($pref_name));
	if ($sth_thr->execute) {
		my ($pref) = $sth_thr->fetchrow;
		$sth_thr->finish;
		$dbh_thr->disconnect;
		return $pref;
	}
	else {
		$sth_thr->finish;
		$dbh_thr->disconnect;
		syslog('info', "$!");
		return undef;
	}
}

sub get_user_defaults {
	my ($user, $pref_name) = @_;
	my $dbh_thr = LockServer::Db->my_connect or warn $!;
	my $sth_thr = $dbh_thr->prepare(qq[SELECT `$pref_name` FROM users WHERE username = ] . $dbh_thr->quote($user));
	if ($sth_thr->execute) {
		my ($pref) = $sth_thr->fetchrow;
		$sth_thr->finish;
		$dbh_thr->disconnect;
		if (defined $pref) {
			return $pref;
		}
		else {
			$pref = get_defaults($pref_name);
			syslog('info', "no user pref $pref_name for $user, using default: $pref");
			return $pref;
		}
	}
	else {
		$sth_thr->finish;
		$dbh_thr->disconnect;
		syslog('info', "$!");
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
	$sth_thr->execute($user, $rfid, $message, $source) || syslog('info', "can't log to db");
	
	$sth_thr->finish;
	$dbh_thr->disconnect;
}
