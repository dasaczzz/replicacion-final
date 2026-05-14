#!/bin/bash
# Prepara el dataset OLTP: por defecto 5,000,000 filas (1 tabla)
# Se conecta al MAESTRO (puerto 3306 de NGINX = escritura)
#
# Configurable via env vars (ej: TABLES=4 ROWS=2000000 bash prepare.sh)

set -e

HOST="${HOST:-db-nginx}"
PORT="${PORT:-3306}"
USER="${USER:-user}"
PASS="${PASS:-password}"
DB="${DB:-sbtest}"
TABLES="${TABLES:-1}"
ROWS="${ROWS:-5000000}"

echo ">> Preparando dataset sysbench: ${TABLES} tabla(s) x ${ROWS} filas"
echo ">> Host: ${HOST}:${PORT}  DB: ${DB}"
echo ">> Tiempo estimado: ~$((ROWS / 200000)) min (depende del disco)"
echo ""

sysbench oltp_read_write \
  --db-driver=mysql \
  --mysql-host="${HOST}" \
  --mysql-port="${PORT}" \
  --mysql-user="${USER}" \
  --mysql-password="${PASS}" \
  --mysql-db="${DB}" \
  --tables="${TABLES}" \
  --table-size="${ROWS}" \
  --threads=4 \
  prepare

echo ""
echo ">> Dataset listo. La replicacion se encarga de copiarlo a los esclavos."
