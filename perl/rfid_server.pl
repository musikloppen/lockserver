#!/usr/bin/perl -w

use strict;
use Data::Dumper;
use Device::SerialPort;
use Sys::Syslog;
use AnyEvent::JSONRPC::TCP::Client;
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
my $RPC_PORT = get_defaults('rpc_port') || 4004;
my $SERIAL_PORT_NAME = get_defaults('serial_port_name') || '/dev/ttyAMA0';

$SIG{INT} = \&stop_server;

# main
my ($port_obj, $count_in, $c);
my $rfid = '';
$port_obj = new Device::SerialPort($SERIAL_PORT_NAME) || die "Can't open $SERIAL_PORT_NAME: $!\n"; #, $quiet, $lockfile)
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
		# we got a rfid tag...
		$rfid =~ s/.*([\dabcdef]{10}).*/$1/i;
		my $client = AnyEvent::JSONRPC::TCP::Client->new(
			host => '127.0.0.1',
			port => $RPC_PORT,
		);
		$client->call( unlock_rfid => $rfid )->recv;
		usleep(get_defaults('open_time') * 1000_000);
		# discard rfid received while we are open
		$port_obj->lookclear;
		do {
			($count_in, $c) = $port_obj->read(1);
		}
		while ($count_in);
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
