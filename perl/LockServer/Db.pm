package LockServer::Db;

use strict;
use warnings;
use DBI;

my $dsn = "DBI:mysql:;mysql_read_default_file=/etc/mysql/conf.d/99-client.cnf";

sub my_connect {
	my $dbh = DBI->connect($dsn, undef, undef, {
		mysql_auto_reconnect => 1,
		RaiseError => 0,
		PrintError => 0
	}) or die "DB Error: " . ($DBI::errstr || $!) . "\n";
	
	return $dbh;
}

1;

__END__
