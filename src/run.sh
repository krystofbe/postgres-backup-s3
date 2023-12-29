#!/bin/sh

set -eu

# Configure AWS S3 if required
if [ "$S3_S3V4" = "yes" ]; then
  aws configure set default.s3.signature_version s3v4
fi

# Check if SCHEDULE is set
if [ -z "$SCHEDULE" ]; then
  # Run backup script immediately if no schedule is set
  sh backup.sh
else
  # Add the backup script to the crontab
  echo "$SCHEDULE /bin/sh /backup.sh" >/etc/crontabs/root

  # Start the cron daemon
  crond -f -l 8
fi
