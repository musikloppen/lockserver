#!/usr/bin/perl -w

use strict;
use warnings;
use Data::Dumper;
use Redis;
use DBI;
use IO::Select;
use Time::HiRes qw( usleep );

use lib qw( /usr/local/share/perl5 );
use LockServer::Db;

my $DEBUG = $ENV{DEBUG} || 0;

if (!$DEBUG) {
	require Device::SerialPort;
	Device::SerialPort->import();
}

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
my $SERIAL_PORT_NAME = get_defaults('serial_port_name') || '/dev/ttyAMA0';

$SIG{INT} = \&stop_server;

# Initialize synchronous Redis client
my $redis_host = $ENV{REDIS_HOST} || 'lock-redis';
my $redis = Redis->new(server => "$redis_host:6379");

# Configure serial hardware boundaries
my ($port_obj, $count_in, $c, $select);
my $rfid = '';

if (!$DEBUG) {
	$port_obj = new Device::SerialPort($SERIAL_PORT_NAME) || die "Can't open $SERIAL_PORT_NAME: $!\n";
	$port_obj->baudrate(9600);
	$port_obj->databits(8);
	$port_obj->stopbits(1);
	$port_obj->parity("none");
	
	# Adjust read times to play nicely with select()
	$port_obj->read_const_time(0);
	$port_obj->read_char_time(0);

	# Create the IO::Select object and add the serial port file descriptor
	$select = IO::Select->new();
	$select->add($port_obj->FILENO) || die "Failed to add serial port to IO::Select: $!\n";
} else {
	log_docker('info', "[DEBUG MODE] Simulating runtime loop. Publishing dummy tag 'cafebabe12' every 10 seconds.");
}

log_docker('info', "$0 started");
while (1) {
	if (!$DEBUG) {
		# Block up to 1 second waiting for data to arrive on the serial port
		if ($select->can_read(1)) {
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
	} else {
		# Mocking loop interval for testing environments
		sleep(10);
		$redis->publish('lock_events', "unlock_rfid:cafebabe12");
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
