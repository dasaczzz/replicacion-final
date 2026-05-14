#!/bin/bash
# Limpia las tablas sysbench del dataset (sbtest)

set -e

HOST="${HOST:-db-nginx}"
PORT="${PORT:-3306}"
USER="${USER:-user}"
PASS="${PASS:-password}"
DB="${DB:-sbtest}"
TABLES="${TABLES:-1}"

sysbench oltp_read_write \
  --db-driver=mysql \
  --mysql-host="${HOST}" \
  --mysql-port="${PORT}" \
  --mysql-user="${USER}" \
  --mysql-password="${PASS}" \
  --mysql-db="${DB}" \
  --tables="${TABLES}" \
  cleanup
