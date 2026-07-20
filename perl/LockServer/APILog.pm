package LockServer::APILog;

use strict;
use warnings;
use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::Const -compile => qw(OK HTTP_INTERNAL_SERVER_ERROR);
use JSON::XS qw(encode_json);
use LockServer::Db;

sub handler {
	my $r = shift;

	# 1. Parse Query Parameters
	my %args = map { split '=', $_, 2 } split '&', ($r->args || '');
	my $limit  = int($args{limit}  || 50);
	my $offset = int($args{offset} || 0);
	my $search = $args{q} // '';

	# Cap limit to prevent memory bloat
	$limit = 100 if $limit > 100;

	# 2. Database Connection
	my $dbh = LockServer::Db::my_connect();
	unless ($dbh) {
		$r->status(Apache2::Const::HTTP_INTERNAL_SERVER_ERROR);
		$r->content_type('application/json');
		$r->print(encode_json({ error => 'Database connection failed' }));
		return Apache2::Const::OK;
	}

	# Force MariaDB session timezone to match system timezone (TZ=Europe/Copenhagen)
	$dbh->do("SET time_zone = 'SYSTEM'");

	# 3. Dynamic Query Execution
	my $where = "1=1";
	my @binds;

	if ($search ne '') {
		$where .= " AND (user LIKE ? OR rfid LIKE ? OR action LIKE ? OR source LIKE ?)";
		push @binds, ("%$search%", "%$search%", "%$search%", "%$search%");
	}

	# Explicitly format the timestamp to 'YYYY-MM-DD HH:MM:SS'
	my $sql = "SELECT id, DATE_FORMAT(time_stamp, '%Y-%m-%d %H:%i:%s') AS time_stamp, user, rfid, action, source 
	           FROM log 
	           WHERE $where 
	           ORDER BY time_stamp DESC, id DESC 
	           LIMIT ? OFFSET ?";
	push @binds, $limit, $offset;

	my $sth = $dbh->prepare($sql);
	unless ($sth && $sth->execute(@binds)) {
		warn "APILog DB query failed: " . ($dbh->errstr || 'Unknown error');
		$r->status(Apache2::Const::HTTP_INTERNAL_SERVER_ERROR);
		$r->content_type('application/json');
		$r->print(encode_json({ error => 'Failed to execute query' }));
		return Apache2::Const::OK;
	}

	my $logs = $sth->fetchall_arrayref({}) || [];

	# 4. JSON Output
	$r->content_type('application/json');
	$r->print(encode_json({
		status => 'ok',
		count  => scalar(@$logs),
		data   => $logs
	}));

	return Apache2::Const::OK;
}

1;
