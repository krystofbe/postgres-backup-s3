#! /bin/sh

set -eu
set -o pipefail

source /env.sh

timestamp=$(date +"%Y-%m-%dT%H:%M:%S")

# List of databases to ignore
IGNORE_DB_LIST="postgres template0 template1"

# Function to dump a single database
dump_database() {
  db_name=$1
  if echo "$IGNORE_DB_LIST" | grep -qw "$db_name"; then
    echo "Skipping backup of $db_name database, because it is in the ignore list."
    return
  fi
  echo "Creating backup of $db_name database..."
  SRC_FILE="db_${db_name}_${timestamp}.dump"
  DEST_FILE="${db_name}_${timestamp}.dump"
  pg_dump --format=custom -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$db_name" $PGDUMP_EXTRA_OPTS >"$SRC_FILE"

  process_file "$SRC_FILE" "$DEST_FILE"
}

# Function to process and upload a file
process_file() {
  src_file=$1
  dest_file=$2
  s3_uri_base="s3://${S3_BUCKET}/${S3_PREFIX}/${dest_file}"

  if [ -n "$PASSPHRASE" ]; then
    echo "Encrypting backup of $src_file..."
    gpg --symmetric --batch --passphrase "$PASSPHRASE" "$src_file"
    rm "$src_file"
    local_file="${src_file}.gpg"
    s3_uri="${s3_uri_base}.gpg"
  else
    local_file="$src_file"
    s3_uri="$s3_uri_base"
  fi

  echo "Uploading $dest_file to $S3_BUCKET..."
  aws $aws_args s3 cp "$local_file" "$s3_uri"
  rm "$local_file"
}

# Check if POSTGRES_BACKUP_ALL is set to "true"
if [ "${POSTGRES_BACKUP_ALL}" = "true" ]; then
  echo "Creating dump of all databases individually..."
  # Get list of all databases
  databases=$(psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -t -c "SELECT datname FROM pg_database WHERE datistemplate = false;")

  for db in $databases; do
    dump_database $db
  done
else
  dump_database "$POSTGRES_DATABASE"
fi

echo "Backup complete."

# Calculate the time limits for deletion
current_time=$(date +%s)
days_in_seconds=$((86400 * BACKUP_KEEP_DAYS))
hours_in_seconds=$((3600 * BACKUP_KEEP_HOURS))

# Remove backups older than BACKUP_KEEP_DAYS
if [ -n "$BACKUP_KEEP_DAYS" ]; then
  date_from_remove_days=$(date -d "@$((current_time - days_in_seconds))" +%Y-%m-%d)
  daily_backups_query="Contents[?contains(Key, '_daily') && LastModified<='${date_from_remove_days} 00:00:00'].{Key: Key}"

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
  hourly_backups_query="Contents[?!contains(Key, '_daily') && LastModified<='${date_from_remove_hours}' && LastModified>='${date_to_keep_hours}'].{Key: Key}"

  echo "Removing old hourly backups from $S3_BUCKET..."
  aws $aws_args s3api list-objects \
    --bucket "${S3_BUCKET}" \
    --prefix "${S3_PREFIX}" \
    --query "${hourly_backups_query}" \
    --output text |
    xargs -r -n1 -t -I 'KEY' aws $aws_args s3 rm s3://"${S3_BUCKET}"/'KEY'
  echo "Hourly backup removal complete."
fi

# Tag the first backup of the day as daily
if [ $(date +"%H") -eq 0 ]; then
  echo "Tagging current backup as daily backup"
  aws $aws_args s3 cp "s3://${S3_BUCKET}/${S3_PREFIX}/${POSTGRES_DATABASE}_${timestamp}.dump" "s3://${S3_BUCKET}/${S3_PREFIX}/${POSTGRES_DATABASE}_${timestamp}_daily.dump"
  aws $aws_args s3 rm "s3://${S3_BUCKET}/${S3_PREFIX}/${POSTGRES_DATABASE}_${timestamp}.dump"
fi
