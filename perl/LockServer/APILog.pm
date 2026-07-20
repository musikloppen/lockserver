package LockServer::APILog;

use strict;
use warnings;
use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::Const -compile => qw(OK HTTP_INTERNAL_SERVER_ERROR);
use JSON::XS qw(encode_json);
use URI::Escape qw(uri_unescape);
use LockServer::Db;

sub handler {
	my $r = shift;

	# 1. Parse Query Parameters safely with URI unescaping
	my %args;
	for my $pair (split '&', ($r->args || '')) {
		my ($k, $v) = split '=', $pair, 2;
		next unless defined $k;
		$v //= '';
		$v =~ s/\+/ /g; # Replace URL pluses with spaces
		$args{uri_unescape($k)} = uri_unescape($v);
	}

	my $limit           = int($args{limit}  || 50);
	my $offset          = int($args{offset} || 0);
	my $search          = $args{q} // '';
	my $hide_unverified = int($args{hide_unverified} // 0);

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

	# 3. Build Dynamic Queries (Restricted to the latest 1 year)
	my $where_log = "time_stamp >= NOW() - INTERVAL 1 YEAR";
	my @binds_log;

	my $where_sms = "unix_time >= UNIX_TIMESTAMP(NOW() - INTERVAL 1 YEAR)";
	my @binds_sms;

	# Exclude unverified/failed attempts (auth_state = 'new') if requested
	if ($hide_unverified) {
		$where_sms .= " AND auth_state != 'new'";
	}

	# Unified Search Filter
	if ($search ne '') {
		$where_log .= " AND (user LIKE ? OR rfid LIKE ? OR action LIKE ? OR source LIKE ?)";
		push @binds_log, ("%$search%", "%$search%", "%$search%", "%$search%");

		$where_sms .= " AND (phone LIKE ? OR auth_state LIKE ? OR remote_host LIKE ? OR user_agent LIKE ?)";
		push @binds_sms, ("%$search%", "%$search%", "%$search%", "%$search%");
	}

	# 4. UNION Query Execution (Limits applied per subquery before sorting)
	my $sql = "
		SELECT * FROM (
			(
				SELECT 
					id, 
					DATE_FORMAT(time_stamp, '%Y-%m-%d %H:%i:%s') AS time_stamp, 
					user, 
					rfid, 
					action, 
					source
				FROM log 
				WHERE $where_log
				ORDER BY time_stamp DESC, id DESC
				LIMIT ?
			)
			UNION ALL
			(
				SELECT 
					id, 
					DATE_FORMAT(FROM_UNIXTIME(unix_time), '%Y-%m-%d %H:%i:%s') AS time_stamp, 
					phone AS user, 
					'' AS rfid, 
					auth_state AS action, 
					remote_host AS source
				FROM sms_auth 
				WHERE $where_sms AND unix_time IS NOT NULL
				ORDER BY unix_time DESC, id DESC
				LIMIT ?
			)
		) combined
		ORDER BY time_stamp DESC, id DESC 
		LIMIT ? OFFSET ?
	";

	my @all_binds = (@binds_log, $limit, @binds_sms, $limit, $limit, $offset);

	my $sth = $dbh->prepare($sql);
	unless ($sth && $sth->execute(@all_binds)) {
		warn "APILog DB query failed: " . ($dbh->errstr || 'Unknown error');
		$r->status(Apache2::Const::HTTP_INTERNAL_SERVER_ERROR);
		$r->content_type('application/json');
		$r->print(encode_json({ error => 'Failed to execute query' }));
		return Apache2::Const::OK;
	}

	my $logs = $sth->fetchall_arrayref({}) || [];

	# 5. JSON Output
	$r->content_type('application/json');
	$r->print(encode_json({
		status => 'ok',
		count  => scalar(@$logs),
		data   => $logs
	}));

	return Apache2::Const::OK;
}

1;
