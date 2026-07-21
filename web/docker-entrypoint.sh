#!/bin/bash
set -e

# Export environment variables into Apache's envvars file
# so mod_perl startup.pl can read them at server initialization
echo "export BASE_URL=\"${BASE_URL}\"" >> /etc/apache2/envvars
echo "export REDIS_HOST=\"${REDIS_HOST}\"" >> /etc/apache2/envvars
echo "export DB_HOST=\"${DB_HOST}\"" >> /etc/apache2/envvars
echo "export DB_PORT=\"${DB_PORT}\"" >> /etc/apache2/envvars
echo "export DB_NAME=\"${DB_NAME}\"" >> /etc/apache2/envvars
echo "export DB_USER=\"${DB_USER}\"" >> /etc/apache2/envvars
echo "export DB_PASS=\"${DB_PASS}\"" >> /etc/apache2/envvars
echo "export NOTIFICATION_SMS_CODE_MESSAGE=\"${NOTIFICATION_SMS_CODE_MESSAGE}\"" >> /etc/apache2/envvars
echo "export SMTP_HOST=\"${SMTP_HOST}\"" >> /etc/apache2/envvars
echo "export SMTP_PORT=\"${SMTP_PORT}\"" >> /etc/apache2/envvars
echo "export SMTP_USER=\"${SMTP_USER}\"" >> /etc/apache2/envvars
echo "export SMTP_PASSWORD=\"${SMTP_PASSWORD}\"" >> /etc/apache2/envvars
echo "export SMTP_USE_TLS=\"${SMTP_USE_TLS}\"" >> /etc/apache2/envvars
echo "export DEBUG=\"${DEBUG}\"" >> /etc/apache2/envvars
echo "export TZ=\"${TZ}\"" >> /etc/apache2/envvars

# Source envvars and start Apache in foreground
. /etc/apache2/envvars
exec apache2 -D FOREGROUND
