#!/bin/bash
# Benchmark SOLO ESCRITURA: 10 hilos, 120 segundos
# Se conecta al puerto 3306 de NGINX = maestro
# Util para comparar el costo de las escrituras vs el mixto

set -e

HOST="${HOST:-db-nginx}"
PORT="${PORT:-3306}"
USER="${USER:-user}"
PASS="${PASS:-password}"
DB="${DB:-sbtest}"
TABLES="${TABLES:-1}"
ROWS="${ROWS:-5000000}"
THREADS="${THREADS:-10}"
TIME="${TIME:-120}"

echo ">> oltp_write_only contra el maestro via NGINX:${PORT}"
echo ">> ${THREADS} hilos x ${TIME}s sobre ${ROWS} filas"
echo ""

sysbench oltp_write_only \
  --db-driver=mysql \
  --mysql-host="${HOST}" \
  --mysql-port="${PORT}" \
  --mysql-user="${USER}" \
  --mysql-password="${PASS}" \
  --mysql-db="${DB}" \
  --tables="${TABLES}" \
  --table-size="${ROWS}" \
  --threads="${THREADS}" \
  --time="${TIME}" \
  --report-interval=10 \
  --histogram=on \
  --percentile=95 \
  run
