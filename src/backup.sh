#!/bin/sh

set -eu
set -o pipefail

source /env.sh

# Current date/time strings
timestamp=$(date +"%Y-%m-%dT%H:%M:%S")
today=$(date +"%Y-%m-%d")

# Databases to skip
IGNORE_DB_LIST="postgres template0 template1"

#------------------------------------------------------------------------------
# Function: check_if_daily_backup_exists
#   Checks if there's ANY object in S3 whose Key starts with:
#       "<DBNAME>_<YYYY-MM-DD>"
#   and also contains "_daily.dump" or "_daily.dump.gpg" later in the name.
#   Example existing daily: "mystartup_prod_2025-01-25T18:00:00_daily.dump.gpg"
#
#   Return:
#     0 (true)  - if we find at least one "daily" object for that DB on that day
#     1 (false) - if no daily backup is found
#------------------------------------------------------------------------------
check_if_daily_backup_exists() {
  db_name="$1"

  # Our prefix is "<db_name>_<today>"
  # We'll filter for any Key that also has "_daily.dump" or "_daily.dump.gpg".
  found_daily=$(
    aws $aws_args s3api list-objects \
      --bucket "${S3_BUCKET}" \
      --prefix "${S3_PREFIX}/${db_name}_${today}" \
      --query "Contents[? (contains(Key, '_daily.dump') || contains(Key, '_daily.dump.gpg')) ].Key" \
      --output text 2>/dev/null || true
  )

  if [ -n "$found_daily" ] && [ "$found_daily" != "None" ]; then
    return 0 # daily exists
  else
    return 1
  fi
}

#------------------------------------------------------------------------------
# Function: dump_database
#   - If there's NO daily backup for today => create one => suffix "_daily"
#   - Otherwise => create "hourly" => suffix "_hourly"
#------------------------------------------------------------------------------
dump_database() {
  db_name="$1"

  # Check ignore list
  if echo "$IGNORE_DB_LIST" | grep -qw "$db_name"; then
    echo "Skipping backup of $db_name (ignore list)."
    return
  fi

  echo "Starting backup of database: $db_name ..."

  # Decide daily vs. hourly
  suffix="_hourly"
  if ! check_if_daily_backup_exists "$db_name"; then
    suffix="_daily"
    echo "No daily backup found yet for '${db_name}' on ${today}. Tagging as daily."
  else
    echo "Daily backup already exists for '${db_name}' on ${today}, tagging as hourly."
  fi

  # Generate local dump filenames without "db_" prefix
  SRC_FILE="${db_name}_${timestamp}${suffix}.dump"
  DEST_FILE="${db_name}_${timestamp}${suffix}.dump"

  # Perform the pg_dump
  pg_dump --format=custom \
    -h "$POSTGRES_HOST" \
    -p "$POSTGRES_PORT" \
    -U "$POSTGRES_USER" \
    -d "$db_name" \
    $PGDUMP_EXTRA_OPTS >"$SRC_FILE"

  # Optionally encrypt + upload
  process_file "$SRC_FILE" "$DEST_FILE" "$db_name"
}

#------------------------------------------------------------------------------
# Function: process_file
#   Optionally encrypt the local dump with GPG, then upload to S3.
#------------------------------------------------------------------------------
process_file() {
  src_file="$1"
  dest_file="$2"
  db_name="$3"

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

  # ---------------------------------------------------------------------------
  # Now do a server-side COPY in S3 to "latest"
  # We'll infer the DB name from $dest_file by taking everything
  # up to the first '_' so that "insights_prod" becomes $db_name.
  # Alternatively, pass $db_name into process_file if that is easier.
  # ---------------------------------------------------------------------------
  # Example: if $dest_file="insights_prod_2025-01-25T21:28:00_daily.dump"
  # you can parse out "insights_prod" from the front. Or, simpler:
  #   - Just keep the entire name but replace the date/time with "latest".
  #
  # Let's do a quick approach:
  #   latest_key="${db_name}_latest.dump" or ".dump.gpg"
  #
  # But for clarity, let's pass DB name as a separate argument. Then:
  # process_file "$SRC_FILE" "$DEST_FILE" "$db_name"
  #
  # For this snippet, let's parse it from $dest_file (a bit hacky but works).

  # If your filenames always start with <db_name>_, we can do this:
  db_name=$(echo "$dest_file" | cut -d_ -f1)

  # If you have multiple DBs, each DB has its own "latest"
  # => "insights_prod_latest.dump" or ".dump.gpg"
  # Let's see if we also ended with .gpg (i.e. if encryption is used).
  # We'll check if $s3_uri ends with .gpg:
  if echo "$s3_uri" | grep -q ".gpg$"; then
    latest_key="${db_name}_latest.dump.gpg"
  else
    latest_key="${db_name}_latest.dump"
  fi

  echo "Copying newest backup to 'latest' object: ${latest_key}"

  # Now do a server-side copy
  # "copy-source" must include bucket + key. We know $dest_file might have .gpg appended
  # so let's get the exact "dest key" from $s3_uri.
  # $s3_uri is "s3://BUCKET/PREFIX/filename.ext"
  # we can strip off "s3://BUCKET/" to get the rest as our "copy-source"

  copy_source="$(echo "$s3_uri" | sed "s|^s3://${S3_BUCKET}/||")"
  # Example: "backup/insights_prod_2025-01-25T21:28:00_daily.dump.gpg"

  # Perform the copy
  aws $aws_args s3api copy-object \
    --copy-source "${S3_BUCKET}/${copy_source}" \
    --bucket "${S3_BUCKET}" \
    --key "${S3_PREFIX}/${latest_key}" >/dev/null

  echo "=> S3 'latest' object updated: s3://${S3_BUCKET}/${S3_PREFIX}/${latest_key}"
}

#------------------------------------------------------------------------------
# Main backup logic
#   If POSTGRES_BACKUP_ALL=true, backup each non-template DB individually.
#   Otherwise, just backup $POSTGRES_DATABASE.
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
#   1) Daily backups => keep for BACKUP_KEEP_DAYS
#   2) Hourly + legacy => keep for BACKUP_KEEP_HOURS
#------------------------------------------------------------------------------
current_time=$(date +%s)

#------------------------------
# 1) Daily backup cleanup
#   e.g. "mystartup_prod_2025-01-25T18:00:00_daily.dump.gpg"
#------------------------------
if [ -n "${BACKUP_KEEP_DAYS:-}" ] && [ "$BACKUP_KEEP_DAYS" -gt 0 ]; then
  echo "Removing daily backups older than ${BACKUP_KEEP_DAYS} days..."
  cutoff_days_ago=$(date -d "@$((current_time - 86400 * BACKUP_KEEP_DAYS))" +"%Y-%m-%dT%H:%M:%S")

  # Query for any key with "_daily.dump" or "_daily.dump.gpg"
  # that is older than the cutoff
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
# 2) Hourly + Legacy backup cleanup
#   e.g. "mystartup_prod_2025-01-25T18:00:00.dump" (no suffix)
#   or    "mystartup_prod_2025-01-25T20:00:00_hourly.dump"
#------------------------------
if [ -n "${BACKUP_KEEP_HOURS:-}" ] && [ "$BACKUP_KEEP_HOURS" -gt 0 ]; then
  echo "Removing hourly (and legacy) backups older than ${BACKUP_KEEP_HOURS} hours..."
  cutoff_hours_ago=$(date -d "@$((current_time - 3600 * BACKUP_KEEP_HOURS))" +"%Y-%m-%dT%H:%M:%S")

  # We'll remove any backup NOT containing "_daily.dump"
  # that is older than the cutoff.
  # This includes new "_hourly" backups and old no-suffix backups.
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
