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

# 1. Clean stale sms_auth entries with row counts
log_info("Cleaning sms_auth table...");

my $del_new = $dbh->do(qq[
	DELETE FROM sms_auth 
	WHERE `auth_state` = 'new' 
	  AND FROM_UNIXTIME(`unix_time`) < NOW() - INTERVAL 1 HOUR
]);
if (defined $del_new && $del_new > 0) {
	log_info("Deleted $del_new stale 'new' sms_auth entry/entries.");
}

my $del_login = $dbh->do(qq[
	DELETE FROM sms_auth 
	WHERE `auth_state` = 'login' 
	  AND FROM_UNIXTIME(`unix_time`) < NOW() - INTERVAL 1 DAY
]);
if (defined $del_login && $del_login > 0) {
	log_info("Deleted $del_login stale 'login' sms_auth entry/entries.");
}

my $del_sent = $dbh->do(qq[
	DELETE FROM sms_auth 
	WHERE `auth_state` = 'sms_code_sent' 
	  AND FROM_UNIXTIME(`unix_time`) < NOW() - INTERVAL 1 DAY
]);
if (defined $del_sent && $del_sent > 0) {
	log_info("Deleted $del_sent stale 'sms_code_sent' sms_auth entry/entries.");
}

my $total_sms_deleted = ($del_new || 0) + ($del_login || 0) + ($del_sent || 0);
if ($total_sms_deleted == 0) {
	log_info("No stale sms_auth entries found.");
}

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
