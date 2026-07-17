#!/usr/bin/perl -w

use strict;
use warnings;
use Data::Dumper;
use Device::SerialPort;
use Sys::Syslog;
use Redis;
use DBI;
use Time::HiRes qw( usleep );

use lib qw( /usr/local/share/perl5 );
use LockServer::Db;

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
my $SERIAL_PORT_NAME = get_defaults('serial_port_name') || '/dev/ttyAMA0';

$SIG{INT} = \&stop_server;

# Initialize synchronous Redis client
my $redis_host = $ENV{REDIS_HOST} || 'lock-redis';
my $redis = Redis->new(server => "$redis_host:6379");

# Configure serial hardware boundaries
my ($port_obj, $count_in, $c);
my $rfid = '';
$port_obj = new Device::SerialPort($SERIAL_PORT_NAME) || die "Can't open $SERIAL_PORT_NAME: $!\n";
$port_obj->baudrate(9600);
$port_obj->databits(8);
$port_obj->stopbits(1);
$port_obj->parity("none");
$port_obj->read_const_time(20);
$port_obj->read_char_time(0);

syslog('info', "$0 started");
while (1) {
	($count_in, $c) = $port_obj->read(1);
	next unless ($count_in);
	
	unless (ord($c) == 13) {
		$rfid .= $c;
	}
	else {
		# Process completed hardware sequence
		$rfid =~ s/.*([\dabcdef]{10}).*/$1/i;
		
		# Stream the action message payload over Redis Bus
		$redis->publish('lock_events', "unlock_rfid:$rfid");
		
		usleep(get_defaults('open_time') * 1000_000);
		
		# Flush inputs accumulated during active operation
		$port_obj->lookclear;
		do {
			($count_in, $c) = $port_obj->read(1);
		} while ($count_in);
		$rfid = '';
	}
}


## END MAIN



sub stop_server {
	syslog('info', "$0 stopped");
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
		syslog('info', "$!");
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
