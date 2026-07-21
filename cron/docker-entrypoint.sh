#!/bin/bash
set -e

# Export environment variables for cron jobs to use
env | grep -E '^(DB_|REDIS_|TZ|PERL5LIB)' > /etc/cron_env

# Start cron daemon in foreground
exec cron -f
