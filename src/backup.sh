#! /bin/sh

set -eu
set -o pipefail

source /env.sh

timestamp=$(date +"%Y-%m-%dT%H:%M:%S")

# Check if POSTGRES_BACKUP_ALL is set to "true"
if [ "${POSTGRES_BACKUP_ALL}" = "true" ]; then
  echo "Creating dump of all databases..."
  SRC_FILE="alldb_${timestamp}.dump"
  DEST_FILE="postgres_${timestamp}.dump"

  # Dump all databases
  pg_dumpall -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" $PGDUMP_EXTRA_OPTS >"$SRC_FILE"
else
  echo "Creating backup of $POSTGRES_DATABASE database..."
  SRC_FILE="db_${timestamp}.dump"
  DEST_FILE="${POSTGRES_DATABASE}_${timestamp}.dump"

  # Dump the specified database
  pg_dump --format=custom -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DATABASE" $PGDUMP_EXTRA_OPTS >"$SRC_FILE"
fi

s3_uri_base="s3://${S3_BUCKET}/${S3_PREFIX}/${DEST_FILE}"

if [ -n "$PASSPHRASE" ]; then
  echo "Encrypting backup..."
  rm -f "${SRC_FILE}.gpg"
  gpg --symmetric --batch --passphrase "$PASSPHRASE" "$SRC_FILE"
  rm "$SRC_FILE"
  local_file="${SRC_FILE}.gpg"
  s3_uri="${s3_uri_base}.gpg"
else
  local_file="$SRC_FILE"
  s3_uri="$s3_uri_base"
fi

echo "Uploading backup to $S3_BUCKET..."
aws $aws_args s3 cp "$local_file" "$s3_uri"
rm "$local_file"

echo "Backup complete."

# Calculate the time limits for deletion
current_time=$(date +%s)
days_in_seconds=$((86400 * BACKUP_KEEP_DAYS))
hours_in_seconds=$((3600 * BACKUP_KEEP_HOURS))

# Remove backups older than BACKUP_KEEP_DAYS
if [ -n "$BACKUP_KEEP_DAYS" ]; then
  date_from_remove_days=$(date -d "@$((current_time - days_in_seconds))" +%Y-%m-%d)
  daily_backups_query="Contents[?LastModified<='${date_from_remove_days} 00:00:00'].{Key: Key}"

  echo "Removing old daily backups from $S3_BUCKET..."
  aws $aws_args s3api list-objects \
    --bucket "${S3_BUCKET}" \
    --prefix "${S3_PREFIX}" \
    --query "${daily_backups_query}" \
    --output text |
    xargs -r -n1 -t -I 'KEY' aws $aws_args s3 rm s3://"${S3_BUCKET}"/'KEY'
  echo "Daily backup removal complete."
fi

# Remove hourly backups that are older than BACKUP_KEEP_HOURS but newer than BACKUP_KEEP_DAYS
if [ -n "$BACKUP_KEEP_HOURS" ]; then
  date_from_remove_hours=$(date -d "@$((current_time - hours_in_seconds))" +%Y-%m-%d-%H)
  date_to_keep_hours=$(date -d "@$((current_time - days_in_seconds))" +%Y-%m-%d)
  hourly_backups_query="Contents[?LastModified<='${date_from_remove_hours}' && LastModified>='${date_to_keep_hours}'].{Key: Key}"

  echo "Removing old hourly backups from $S3_BUCKET..."
  aws $aws_args s3api list-objects \
    --bucket "${S3_BUCKET}" \
    --prefix "${S3_PREFIX}" \
    --query "${hourly_backups_query}" \
    --output text |
    xargs -r -n1 -t -I 'KEY' aws $aws_args s3 rm s3://"${S3_BUCKET}"/'KEY'
  echo "Hourly backup removal complete."
fi
