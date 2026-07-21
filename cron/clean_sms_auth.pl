#!/usr/bin/perl

use strict;
use warnings;
use LockServer::Db;
use LockServer::Utils qw(log_info log_warn log_die);

log_info("Starting cleanup task...");

my $dbh = LockServer::Db->my_connect();
unless ($dbh) {
	log_die("Can't connect to DB: $!");
}
$dbh->{mysql_auto_reconnect} = 1;

# 1. Clean stale sms_auth entries
log_info("Cleaning sms_auth table...");
$dbh->do(qq[DELETE FROM sms_auth WHERE `auth_state` = 'new' AND FROM_UNIXTIME(`unix_time`) < NOW() - INTERVAL 1 HOUR])
	or log_warn("Failed to clean 'new' sms_auth: " . $dbh->errstr);

$dbh->do(qq[DELETE FROM sms_auth WHERE `auth_state` = 'login' AND FROM_UNIXTIME(`unix_time`) < NOW() - INTERVAL 1 DAY])
	or log_warn("Failed to clean 'login' sms_auth: " . $dbh->errstr);

$dbh->do(qq[DELETE FROM sms_auth WHERE `auth_state` = 'sms_code_sent' AND FROM_UNIXTIME(`unix_time`) < NOW() - INTERVAL 1 DAY])
	or log_warn("Failed to clean 'sms_code_sent' sms_auth: " . $dbh->errstr);

# 2. Delete expired guest users
log_info("Cleaning expired guest users...");
my $rows_deleted = $dbh->do(qq[
	DELETE FROM users 
	WHERE `group` = 'guest' 
	  AND `expire_at` IS NOT NULL 
	  AND `expire_at` < NOW()
]);

if (defined $rows_deleted && $rows_deleted > 0) {
	log_info("Deleted $rows_deleted expired guest user(s).");
} else {
	log_info("No expired guest users found.");
}

log_info("Cleanup task completed successfully.");

1;

__END__
