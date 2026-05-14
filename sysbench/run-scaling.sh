#!/bin/bash
# Test de ESCALABILIDAD: corre oltp_read_only con 1, 4, 8, 16, 32, 64 hilos
# Muestra como sube el TPS al aumentar la concurrencia (efecto del balanceo)
# Cada corrida dura 30s para no extender la prueba demasiado

set -e

HOST="${HOST:-db-nginx}"
PORT="${PORT:-3307}"
USER="${USER:-user}"
PASS="${PASS:-password}"
DB="${DB:-sbtest}"
TABLES="${TABLES:-1}"
ROWS="${ROWS:-5000000}"
TIME="${TIME:-30}"

THREAD_LIST="${THREAD_LIST:-1 4 8 16 32 64}"

echo "============================================================"
echo " Escalabilidad oltp_read_only sobre el pool de esclavos"
echo " Host: ${HOST}:${PORT}   Duracion por punto: ${TIME}s"
echo "============================================================"
printf "%-8s %-10s %-12s %-12s %-12s\n" "Hilos" "TPS" "QPS" "Lat avg" "Lat p95"
echo "------------------------------------------------------------"

for t in ${THREAD_LIST}; do
  out=$(sysbench oltp_read_only \
    --db-driver=mysql \
    --mysql-host="${HOST}" \
    --mysql-port="${PORT}" \
    --mysql-user="${USER}" \
    --mysql-password="${PASS}" \
    --mysql-db="${DB}" \
    --tables="${TABLES}" \
    --table-size="${ROWS}" \
    --threads="${t}" \
    --time="${TIME}" \
    --report-interval=0 \
    --percentile=95 \
    run 2>&1)

  tps=$(echo "$out"   | grep "transactions:"        | awk -F'[()]' '{print $2}' | awk '{print $1}')
  qps=$(echo "$out"   | grep "queries:"             | head -1 | awk -F'[()]' '{print $2}' | awk '{print $1}')
  lavg=$(echo "$out"  | grep "avg:"                 | awk '{print $2}')
  lp95=$(echo "$out"  | grep "95th percentile:"     | awk '{print $3}')

  printf "%-8s %-10s %-12s %-12s %-12s\n" "$t" "$tps" "$qps" "$lavg" "$lp95"
done

echo "============================================================"
