#!/usr/bin/perl -w

use strict;
use Data::Dumper;
use Device::BCM2835;
use Sys::Syslog;
use AnyEvent::JsonRPC::TCP::Client;
use DBI;
use Time::HiRes qw( usleep );

use lib qw( /etc/apache2/perl );
use LockServer::Db;

#use constant MY_SERVER_ROOT => '/var/www/lock_server';
my $MY_SERVER_ROOT = '/var/www/lock_server';

openlog($0, "ndelay,pid", "local0");
syslog('info', "starting...");

# connect to db
my $dbh;
if($dbh = LockServer::Db->my_connect) {
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
my $RPC_PORT = get_defaults('rpc_port') || 4004;

$SIG{INT} = \&stop_server;

# main
# set up lock interface
Device::BCM2835::init() || die "Could not init library";
# inputs
Device::BCM2835::gpio_fsel(&Device::BCM2835::RPI_V2_GPIO_P1_07, 
                            &Device::BCM2835::BCM2835_GPIO_FSEL_INPT );
Device::BCM2835::gpio_fsel(&Device::BCM2835::RPI_V2_GPIO_P1_11, 
                            &Device::BCM2835::BCM2835_GPIO_FSEL_INPT);

syslog('info', "$0 started");
while (1) {
	if (Device::BCM2835::gpio_lev(&Device::BCM2835::RPI_V2_GPIO_P1_07) || Device::BCM2835::gpio_lev(&Device::BCM2835::RPI_V2_GPIO_P1_11)) {
		my $client = AnyEvent::JSONRPC::TCP::Client->new(
			host => '127.0.0.1',
			port => $RPC_PORT,
		);
		$client->call( unlock_button => '')->recv;
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
	my $sth_thr = $dbh_thr->prepare(qq[INSERT INTO `log` (`user`, 
																												`rfid`, 
																												`action`, 
																												`source`, 
																												`time_stamp`) 
																		 VALUES (] . $dbh_thr->quote($user) . ', ' . 
																		 						 $dbh_thr->quote($rfid) . ', ' . 
																		 						 $dbh_thr->quote($message) . ', ' .
																		 						 $dbh_thr->quote($source) . ', ' .
																		 						 'NOW())');
	$sth_thr->execute || syslog('info', "can't log to db");
	$sth_thr->finish;
	$dbh_thr->disconnect;
}
