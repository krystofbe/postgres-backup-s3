#! /bin/sh

set -u # `-e` omitted intentionally
set -o pipefail

source /env.sh

s3_uri_base="s3://${S3_BUCKET}/${S3_PREFIX}"

restore_database() {
  db_name=$1
  key_suffix=$2
  local_file="db_${db_name}${file_type}"

  echo "Fetching $key_suffix from S3..."
  aws $aws_args s3 cp "${s3_uri_base}/${key_suffix}" "$local_file"

  if [ -n "$PASSPHRASE" ]; then
    echo "Decrypting backup for $db_name..."
    gpg --decrypt --batch --passphrase "$PASSPHRASE" "$local_file" >"db_${db_name}.dump"
    rm "$local_file"
    local_file="db_${db_name}.dump"
  fi

  # Restoration process
  echo "Restoring $db_name from backup..."
  # Ensure connection options include the database name
  pg_restore -h $POSTGRES_HOST -p $POSTGRES_PORT -U $POSTGRES_USER -d $db_name --clean --if-exists $local_file
  echo "Finished restore of $db_name."

  rm "$local_file"
}

if [ -z "$PASSPHRASE" ]; then
  file_type=".dump"
else
  file_type=".dump.gpg"
fi

if [ $# -eq 1 ]; then
  timestamp="$1"
  key_suffix="${POSTGRES_DATABASE}_${timestamp}${file_type}"
  restore_database "$POSTGRES_DATABASE" "$key_suffix"

else
  echo "Finding latest backup..."
  # Adjust the search to consider all databases backup
  latest_backup=$(aws $aws_args s3 ls "${s3_uri_base}/" | grep "${POSTGRES_DATABASE}_.*${file_type}$" | sort | tail -n 1 | awk '{ print $4 }')
  if [ -z "$latest_backup" ]; then
    echo "No backup found."
    exit 1
  fi
  restore_database "$POSTGRES_DATABASE" "$latest_backup"
fi

echo "Restore complete."
