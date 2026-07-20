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

	# Cap limit to prevent memory bloat on low-spec hardware (e.g., Raspberry Pi)
	$limit = 100 if $limit > 100;

	# 2. Database Connection via my_connect()
	my $dbh = LockServer::Db::my_connect();
	unless ($dbh) {
		$r->status(Apache2::Const::HTTP_INTERNAL_SERVER_ERROR);
		$r->content_type('application/json');
		$r->print(encode_json({ error => 'Database connection failed' }));
		return Apache2::Const::OK;
	}

	# 3. Dynamic Query Execution
	my $where = "1=1";
	my @binds;

	if ($search ne '') {
		$where .= " AND (user LIKE ? OR event_type LIKE ? OR message LIKE ?)";
		push @binds, ("%$search%", "%$search%", "%$search%");
	}

	my $sql = "SELECT id, timestamp, user, event_type, status, message 
	           FROM log 
	           WHERE $where 
	           ORDER BY timestamp DESC 
	           LIMIT ? OFFSET ?";
	push @binds, $limit, $offset;

	my $sth = $dbh->prepare($sql);
	$sth->execute(@binds);
	my $logs = $sth->fetchall_arrayref({});

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
