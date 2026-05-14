#!/bin/bash
# Demuestra el balanceo de NGINX consultando @@hostname desde varias conexiones
# Cada conexion abre un socket nuevo -> NGINX la dirige a un esclavo distinto (round-robin)
#
# Uso desde el host:
#   ./check-balance.sh
# Uso desde dentro del contenedor sysbench:
#   docker compose exec sysbench bash /scripts/../check-balance.sh

set -e

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-3307}"        # 3307 = lectura -> esclavos
USER="${USER:-user}"
PASS="${PASS:-password}"
N="${N:-10}"

echo "Conectando ${N} veces a ${HOST}:${PORT} (lectura, balanceado)"
echo ""

for i in $(seq 1 "${N}"); do
  hostname=$(mysql -h "${HOST}" -P "${PORT}" -u"${USER}" -p"${PASS}" \
    -N -s -e "SELECT @@hostname;" 2>/dev/null)
  echo "  Conexion #${i} -> ${hostname}"
done
