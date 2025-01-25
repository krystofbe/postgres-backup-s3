#!/bin/sh

set -eu
set -o pipefail

source /env.sh

timestamp=$(date +"%Y-%m-%dT%H:%M:%S")
today=$(date +"%Y-%m-%d")

IGNORE_DB_LIST="postgres template0 template1"

#------------------------------------------------------------------------------
# Function: check_if_daily_backup_exists
#   Checks if there's *any* object in S3 with:
#       db_<DBNAME>_<YYYY-MM-DD>_..._daily.dump
#   or   db_<DBNAME>_<YYYY-MM-DD>_..._daily.dump.gpg
#   If so, we say a "daily" backup already exists for *today*.
#------------------------------------------------------------------------------
check_if_daily_backup_exists() {
  db_name="$1"

  # We'll look for any object that starts with db_<db_name>_<YYYY-MM-DD>
  # and contains "_daily.dump" or "_daily.dump.gpg" anywhere after that.
  # If found, return 0 => "daily backup exists"
  found_daily=$(
    aws $aws_args s3api list-objects \
      --bucket "${S3_BUCKET}" \
      --prefix "${S3_PREFIX}/db_${db_name}_${today}" \
      --query "Contents[? (contains(Key, '_daily.dump') || contains(Key, '_daily.dump.gpg')) ].Key" \
      --output text 2>/dev/null || true
  )

  if [ -n "$found_daily" ] && [ "$found_daily" != "None" ]; then
    return 0
  else
    return 1
  fi
}

#------------------------------------------------------------------------------
# Function: dump_database
#   Dumps a single database to local .dump file.
#   - The first time each day => daily backup (suffix _daily).
#   - Otherwise => hourly backup (suffix _hourly).
#------------------------------------------------------------------------------
dump_database() {
  db_name="$1"

  # Skip if in the ignore list
  if echo "$IGNORE_DB_LIST" | grep -qw "$db_name"; then
    echo "Skipping backup of $db_name (ignore list)."
    return
  fi

  echo "Starting backup of database: $db_name ..."

  # Decide if we do a daily or an hourly backup
  suffix="_hourly"
  if ! check_if_daily_backup_exists "$db_name"; then
    suffix="_daily"
    echo "No daily backup found yet for '${db_name}' on ${today}. This backup will be tagged as daily."
  else
    echo "Daily backup already exists for '${db_name}' on ${today}. Proceeding with an hourly backup."
  fi

  # Construct filenames
  SRC_FILE="db_${db_name}_${timestamp}${suffix}.dump"
  DEST_FILE="${db_name}_${timestamp}${suffix}.dump"

  # Perform pg_dump
  pg_dump --format=custom \
    -h "$POSTGRES_HOST" \
    -p "$POSTGRES_PORT" \
    -U "$POSTGRES_USER" \
    -d "$db_name" \
    $PGDUMP_EXTRA_OPTS >"$SRC_FILE"

  # Encrypt and upload to S3
  process_file "$SRC_FILE" "$DEST_FILE"
}

#------------------------------------------------------------------------------
# Function: process_file
#   Optionally encrypt a file with GPG, then uploads it to S3.
#------------------------------------------------------------------------------
process_file() {
  src_file="$1"
  dest_file="$2"
  s3_uri_base="s3://${S3_BUCKET}/${S3_PREFIX}/${dest_file}"

  if [ -n "${PASSPHRASE:-}" ]; then
    echo "Encrypting backup: $src_file"
    gpg --symmetric --batch --passphrase "$PASSPHRASE" "$src_file"
    rm "$src_file"
    local_file="${src_file}.gpg"
    s3_uri="${s3_uri_base}.gpg"
  else
    local_file="$src_file"
    s3_uri="$s3_uri_base"
  fi

  echo "Uploading backup to: $s3_uri"
  aws $aws_args s3 cp "$local_file" "$s3_uri"
  rm "$local_file"
}

#------------------------------------------------------------------------------
# Main Backup Logic
#   If POSTGRES_BACKUP_ALL == "true", we backup every non-template DB individually.
#   Otherwise, just the single DB defined by POSTGRES_DATABASE.
#------------------------------------------------------------------------------
if [ "${POSTGRES_BACKUP_ALL:-}" = "true" ]; then
  echo "Backing up all non-template databases individually..."
  databases=$(psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -t -c "SELECT datname FROM pg_database WHERE datistemplate = false;")
  for db in $databases; do
    dump_database "$db"
  done
else
  dump_database "$POSTGRES_DATABASE"
fi

echo "All backups completed."

#------------------------------------------------------------------------------
# Retention Cleanup
#   1) Remove daily backups older than BACKUP_KEEP_DAYS
#   2) Remove hourly (and legacy) backups older than BACKUP_KEEP_HOURS
#------------------------------------------------------------------------------
current_time=$(date +%s)

#------------------------------
# 1) Daily backup cleanup
#------------------------------
if [ -n "${BACKUP_KEEP_DAYS:-}" ] && [ "$BACKUP_KEEP_DAYS" -gt 0 ]; then
  echo "Removing daily backups older than $BACKUP_KEEP_DAYS days..."
  cutoff_days_ago=$(date -d "@$((current_time - 86400 * BACKUP_KEEP_DAYS))" +"%Y-%m-%dT%H:%M:%S")

  # Find any object whose key contains '_daily.dump' (or .dump.gpg)
  # with LastModified older than cutoff.
  daily_removal_keys=$(
    aws $aws_args s3api list-objects \
      --bucket "${S3_BUCKET}" \
      --prefix "${S3_PREFIX}/" \
      --query "Contents[? (LastModified<=\`$cutoff_days_ago\`) && (contains(Key, '_daily.dump')) ].Key" \
      --output text 2>/dev/null || true
  )

  for key in $daily_removal_keys; do
    [ "$key" = "None" ] && continue
    echo "Removing old daily backup: $key"
    aws $aws_args s3 rm "s3://${S3_BUCKET}/${key}"
  done
fi

#------------------------------
# 2) Hourly + legacy backup cleanup
#------------------------------
if [ -n "${BACKUP_KEEP_HOURS:-}" ] && [ "$BACKUP_KEEP_HOURS" -gt 0 ]; then
  echo "Removing hourly (and legacy) backups older than $BACKUP_KEEP_HOURS hours..."
  cutoff_hours_ago=$(date -d "@$((current_time - 3600 * BACKUP_KEEP_HOURS))" +"%Y-%m-%dT%H:%M:%S")

  # We'll remove any backup that does NOT contain '_daily.dump'
  # That includes the new `_hourly` backups AND older "no-suffix" backups.
  hourly_removal_keys=$(
    aws $aws_args s3api list-objects \
      --bucket "${S3_BUCKET}" \
      --prefix "${S3_PREFIX}/" \
      --query "Contents[? (LastModified<=\`$cutoff_hours_ago\`) && (!contains(Key, '_daily.dump')) ].Key" \
      --output text 2>/dev/null || true
  )

  for key in $hourly_removal_keys; do
    [ "$key" = "None" ] && continue
    echo "Removing old hourly/legacy backup: $key"
    aws $aws_args s3 rm "s3://${S3_BUCKET}/${key}"
  done
fi

echo "Backup retention cleanup completed successfully."
