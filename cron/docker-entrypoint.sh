#!/bin/bash

# Export environment variables for cron jobs to source
echo "export DB_HOST=${DB_HOST}" > /etc/cron_env
echo "export DB_PORT=${DB_PORT}" >> /etc/cron_env
echo "export DB_NAME=${DB_NAME}" >> /etc/cron_env
echo "export DB_USER=${DB_USER}" >> /etc/cron_env
echo "export DB_PASS=${DB_PASS}" >> /etc/cron_env
echo "export REDIS_HOST=${REDIS_HOST}" >> /etc/cron_env
echo "export REDIS_PORT=${REDIS_PORT}" >> /etc/cron_env
echo "export TZ=${TZ}" >> /etc/cron_env
echo "export PERL5LIB=/usr/local/share/perl5" >> /etc/cron_env
echo "export DEBUG=${DEBUG}" >> /etc/cron_env

# Start cron in background
cron -f &
cron_pid=$!

# Tail the cron log to stdout for Docker logging
tail -f /var/log/cron.log &
tail_cron_pid=$!

# Wait for background processes; kill remainder if one stops
wait -n
kill $(jobs -p)
