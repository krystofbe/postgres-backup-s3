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

# install go-crond
GOCROND_VERSION=22.9.1
GOCRON_OS=linux
GOCRON_ARCH=amd64
wget -O /usr/local/bin/go-crond "https://github.com/webdevops/go-crond/releases/download/${GOCROND_VERSION}/go-crond.${GOCRON_OS}.${GOCRON_ARCH}"
chmod +x /usr/local/bin/go-crond

# cleanup
rm -rf /var/cache/apk/*
