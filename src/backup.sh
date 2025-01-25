#! /bin/sh

set -eu
set -o pipefail

source /env.sh

# Current date/time strings
timestamp=$(date +"%Y-%m-%dT%H:%M:%S")
today=$(date +"%Y-%m-%d")

IGNORE_DB_LIST="postgres template0 template1"
ignore_db_list_sql=$(echo "$IGNORE_DB_LIST" | sed "s/ /','/g" | sed "s/^/'/" | sed "s/$/'/")

#------------------------------------------------------------------------------
# Function: check_if_daily_backup_exists
#    Checks if an S3 object containing the pattern:
#      db_<DBNAME>_<YYYY-MM-DD>_daily.dump OR
#      db_<DBNAME>_<YYYY-MM-DD>_daily.dump.gpg
#    already exists for the given database.
#
# Returns:
#   0 (true)  - if a daily backup is found
#   1 (false) - if no daily backup is found
#------------------------------------------------------------------------------
check_if_daily_backup_exists() {
  db_name="$1"
  aws $aws_args s3api list-objects \
    --bucket "${S3_BUCKET}" \
    --prefix "${S3_PREFIX}/db_${db_name}_${today}_daily.dump" \
    --query 'Contents[].Key' \
    --output text 2>/dev/null | grep -q "${S3_PREFIX}/db_${db_name}_${today}_daily.dump" && return 0

  aws $aws_args s3api list-objects \
    --bucket "${S3_BUCKET}" \
    --prefix "${S3_PREFIX}/db_${db_name}_${today}_daily.dump.gpg" \
    --query 'Contents[].Key' \
    --output text 2>/dev/null | grep -q "${S3_PREFIX}/db_${db_name}_${today}_daily.dump.gpg" && return 0

  return 1
}

#------------------------------------------------------------------------------
# Function: dump_database
#   Dumps a single database to a local file.
#   If a daily backup has not yet been created for the day,
#   suffix is _daily. Otherwise, no suffix (hourly).
#------------------------------------------------------------------------------
dump_database() {
  db_name="$1"

  # Skip ignored DBs
  if echo "$IGNORE_DB_LIST" | grep -qw "$db_name"; then
    echo "Skipping backup of $db_name (ignore list)."
    return
  fi

  echo "Starting backup of database: $db_name"

  # Decide if we do a daily or hourly backup
  suffix=""
  if ! check_if_daily_backup_exists "$db_name"; then
    suffix="_daily"
    echo "No daily backup found for '${db_name}' on ${today}. This backup will be tagged as daily."
  else
    echo "Daily backup already exists for '${db_name}'. Proceeding with an hourly (regular) backup."
  fi

  # Prepare filenames
  SRC_FILE="db_${db_name}_${timestamp}${suffix}.dump"
  DEST_FILE="${db_name}_${timestamp}${suffix}.dump"

  # Perform pg_dump
  echo pg_dump >"$SRC_FILE"

  # Encrypt (if PASSPHRASE is set) and upload
  process_file "$SRC_FILE" "$DEST_FILE"
}

#------------------------------------------------------------------------------
# Function: process_file
#   Optionally encrypts a dump file with GPG, then uploads to S3.
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
# Main Backup Section
#   If POSTGRES_BACKUP_ALL == "true", backup each DB individually,
#   otherwise just do the single database indicated by $POSTGRES_DATABASE.
#------------------------------------------------------------------------------
if [ "${POSTGRES_BACKUP_ALL:-}" = "true" ]; then
  echo "Backing up all non-template databases individually..."
  databases=$(psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -t -c "SELECT datname FROM pg_database WHERE datistemplate = false AND datname NOT IN (${ignore_db_list_sql});")
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
#   2) Remove hourly backups older than BACKUP_KEEP_HOURS
#------------------------------------------------------------------------------

current_time=$(date +%s)

#------------------------------
# 1) Daily backup cleanup
#------------------------------
if [ -n "${BACKUP_KEEP_DAYS:-}" ] && [ "$BACKUP_KEEP_DAYS" -gt 0 ]; then
  echo "Removing daily backups older than $BACKUP_KEEP_DAYS days..."
  # Compute the cutoff date
  cutoff_days_ago=$(date -d "@$((current_time - 86400 * BACKUP_KEEP_DAYS))" +"%Y-%m-%dT%H:%M:%S")

  # This query finds all objects where:
  #   - The Key contains "_daily.dump" or "_daily.dump.gpg"
  #   - LastModified is older than the computed cutoff date
  daily_removal_keys=$(
    aws $aws_args s3api list-objects \
      --bucket "${S3_BUCKET}" \
      --prefix "${S3_PREFIX}/" \
      --query "Contents[? (contains(Key, '_daily.dump') && LastModified<=\`$cutoff_days_ago\`) ].Key" \
      --output text 2>/dev/null
  )

  # Remove them
  for key in $daily_removal_keys; do
    echo "Removing old daily backup: $key"
    aws $aws_args s3 rm "s3://${S3_BUCKET}/${key}"
  done
fi

#------------------------------
# 2) Hourly / regular backup cleanup
#------------------------------
if [ -n "${BACKUP_KEEP_HOURS:-}" ] && [ "$BACKUP_KEEP_HOURS" -gt 0 ]; then
  echo "Removing hourly backups older than $BACKUP_KEEP_HOURS hours..."
  # Compute the cutoff date/time
  cutoff_hours_ago=$(date -d "@$((current_time - 3600 * BACKUP_KEEP_HOURS))" +"%Y-%m-%dT%H:%M:%S")

  # This query finds all objects where:
  #   - The Key does NOT contain "_daily.dump"
  #   - LastModified is older than the computed cutoff date/time
  hourly_removal_keys=$(
    aws $aws_args s3api list-objects \
      --bucket "${S3_BUCKET}" \
      --prefix "${S3_PREFIX}/" \
      --query "Contents[? (!contains(Key, '_daily.dump') && LastModified<=\`$cutoff_hours_ago\`) ].Key" \
      --output text 2>/dev/null
  )

  # Remove them
  for key in $hourly_removal_keys; do
    echo "Removing old hourly backup: $key"
    aws $aws_args s3 rm "s3://${S3_BUCKET}/${key}"
  done
fi

echo "Backup retention cleanup completed successfully."
