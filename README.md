# Introduction
This project provides Docker images to periodically back up a PostgreSQL database to AWS S3, and to restore from the backup as needed.

# Usage
## Backup
```yaml
services:
  postgres:
    image: postgres:16
    environment:
      POSTGRES_USER: user
      POSTGRES_PASSWORD: password

  backup:
    image: krystofbe/postgres-backup-s3:16
    environment:
      SCHEDULE: '@weekly'     # optional
      BACKUP_KEEP_DAYS: 7     # optional
      BACKUP_KEEP_HOURS: 72   # optional
      PASSPHRASE: passphrase  # optional
      IGNORE_DB_LIST: 'postgres template0 template1' # optional, with these as default
      S3_REGION: region
      S3_ACCESS_KEY_ID: key
      S3_SECRET_ACCESS_KEY: secret
      S3_BUCKET: my-bucket
      S3_PREFIX: backup
      POSTGRES_HOST: postgres
      POSTGRES_DATABASE: dbname
      POSTGRES_BACKUP_ALL: true
      POSTGRES_USER: user
      POSTGRES_PASSWORD: password
      POSTGRES_BACKUP_ALL: true     # optional, set to 'true' to back up all databases
```

- Images are tagged by the major PostgreSQL version supported: `12`, `13`, `14`, `15` or `16`.
- The `SCHEDULE` variable determines backup frequency. See go-cron schedules documentation [here](http://godoc.org/github.com/robfig/cron#hdr-Predefined_schedules). Omit to run the backup immediately and then exit.
- If `PASSPHRASE` is provided, the backup will be encrypted using GPG.
- Run `docker exec <container name> sh backup.sh` to trigger a backup ad-hoc.
- The `POSTGRES_BACKUP_ALL` variable allows backing up all databases when set to "true".
- This image now supports both hourly and daily backups.
# Backup Retention
The backup system implements a dual retention strategy:

- `BACKUP_KEEP_HOURS`: Determines how long regular backups are kept (e.g. 72 hours)
- `BACKUP_KEEP_DAYS`: Determines how long daily backups are kept (e.g. 30 days)

Using both values allows you to maintain frequent backups for recent history while keeping daily backups for longer-term retention. For example:

- Set `BACKUP_KEEP_HOURS=24` to keep hourly backups for the last day
- Set `BACKUP_KEEP_DAYS=30` to keep daily backups for a month

### Daily Backups
The first backup of each calendar day is automatically tagged as a daily backup. This ensures one backup per day is retained for the duration specified by `BACKUP_KEEP_DAYS`, regardless of your backup schedule frequency. All other backups within that day follow the `BACKUP_KEEP_HOURS` retention period.

For example, with hourly backups:
- 24 hourly backups available for the last day
- 30 daily backups available for the last month

- Set `S3_ENDPOINT` if you're using a non-AWS S3-compatible storage provider.

## Restore> **WARNING:** DATA LOSS! All database objects will be dropped and re-created.
### ... from latest backup
```sh
docker exec <container name> sh restore.sh
```
> **NOTE:** If your bucket has more than a 1000 files, the latest may not be restored -- only one S3 `ls` command is used
### ... from specific backup
```sh
docker exec <container name> sh restore.sh <timestamp>
```

# Development
## Build the image locally
`ALPINE_VERSION` determines Postgres version compatibility. See [`build-and-push-images.yml`](.github/workflows/build-and-push-images.yml) for the latest mapping.
```sh
DOCKER_BUILDKIT=1 docker build --build-arg ALPINE_VERSION=3.14 .
```
## Run a simple test environment with Docker Compose
```sh
cp template.env .env
# fill out your secrets/params in .env
docker compose up -d
```

# Acknowledgements
This project is a fork and re-structuring of @schickling's [postgres-backup-s3](https://github.com/schickling/dockerfiles/tree/master/postgres-backup-s3) and [postgres-restore-s3](https://github.com/schickling/dockerfiles/tree/master/postgres-restore-s3).

## Fork goals
These changes would have been difficult or impossible merge into @schickling's repo or similarly-structured forks.
  - dedicated repository
  - automated builds
  - support multiple PostgreSQL versions
  - backup and restore with one image

## Other changes and features
  - some environment variables renamed or removed
  - uses `pg_dump`'s `custom` format (see [docs](https://www.postgresql.org/docs/10/app-pgdump.html))
  - drop and re-create all database objects on restore
  - backup blobs and all schemas by default
  - no Python 2 dependencies
  - filter backups on S3 by database name
  - support encrypted (password-protected) backups
  - support for restoring from a specific backup by timestamp
  - support for auto-removal of old backups
