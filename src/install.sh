#! /bin/sh

set -eux
set -o pipefail

apk update

# install pg_dump
apk add postgresql-client

# install gpg
apk add gnupg

# install aws-cli
apk add aws-cli

# cleanup
rm -rf /var/cache/apk/*
