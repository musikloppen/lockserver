package LockServer::Db;

use strict;
use warnings;
use DBI;
use Sys::Syslog;

# Fetch environment variables injected by Docker (with fallbacks if running outside Docker)
my $host = $ENV{DB_HOST} || 'lock-db';
my $port = $ENV{DB_PORT} || '3306';
my $db   = $ENV{DB_NAME} || 'lock_server';
my $user = $ENV{DB_USER} || 'lock_server';
my $pass = $ENV{DB_PASS} || 'secret';

# Dynamically build the connection strings
my $dsn		= "DBI:mysql:database=$db;host=$host;port=$port";

sub my_connect {
	return DBI->connect($dsn, $user, $pass, { mysql_auto_reconnect => 1 }) or warn $!;
}

1;

