#! /bin/sh

set -u # `-e` omitted intentionally
set -o pipefail

source ./env.sh

s3_uri_base="s3://${S3_BUCKET}/${S3_PREFIX}"

if [ -z "$PASSPHRASE" ]; then
  file_type=".dump"
else
  file_type=".dump.gpg"
fi

if [ $# -eq 1 ]; then
  timestamp="$1"
  # Adjust to allow for restoring all databases if POSTGRES_BACKUP_ALL is set
  if [ "${POSTGRES_BACKUP_ALL}" = "true" ]; then
    key_suffix="postgres_${timestamp}${file_type}"
  else
    key_suffix="${POSTGRES_DATABASE}_${timestamp}${file_type}"
  fi
else
  echo "Finding latest backup..."
  # Adjust the search to consider all databases backup
  key_suffix=$(
    aws $aws_args s3 ls "${s3_uri_base}/" |
      grep -E "(postgres_|${POSTGRES_DATABASE}_).*${file_type}$" |
      sort |
      tail -n 1 |
      awk '{ print $4 }'
  )
fi

echo "Fetching backup from S3..."
aws $aws_args s3 cp "${s3_uri_base}/${key_suffix}" "db${file_type}"

if [ -n "$PASSPHRASE" ]; then
  echo "Decrypting backup..."
  gpg --decrypt --batch --passphrase "$PASSPHRASE" "db${file_type}" >db.dump
  rm "db${file_type}"
fi

# Adjust restoration process based on backup type
if [ "${POSTGRES_BACKUP_ALL}" = "true" ]; then
  echo "Restoring all databases from backup..."
  psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -f db.dump
else
  conn_opts="-h $POSTGRES_HOST -p $POSTGRES_PORT -U $POSTGRES_USER -d $POSTGRES_DATABASE"
  echo "Restoring from backup..."
  pg_restore $conn_opts --clean --if-exists db.dump
fi

rm db.dump

echo "Restore complete."
