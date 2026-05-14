#!/bin/bash
# Verifica el estado de la replicacion en los dos esclavos
# Uso: docker compose exec source bash /scripts/check-replication.sh
# O directamente desde el host: ./check-replication.sh

set -e

ROOT_PASS="${DB_ROOT_PASSWORD:-root}"

echo "==============================================="
echo " MAESTRO (db-source) - SHOW BINARY LOG STATUS"
echo "==============================================="
docker exec db-source mysql -uroot -p"${ROOT_PASS}" \
  -e "SHOW BINARY LOG STATUS\G" 2>/dev/null || \
docker exec db-source mysql -uroot -p"${ROOT_PASS}" \
  -e "SHOW MASTER STATUS\G" 2>/dev/null

for replica in db-replica1 db-replica2; do
  echo ""
  echo "==============================================="
  echo " ESCLAVO (${replica}) - SHOW REPLICA STATUS"
  echo "==============================================="
  docker exec "${replica}" mysql -uroot -p"${ROOT_PASS}" \
    -e "SHOW REPLICA STATUS\G" 2>/dev/null | \
    grep -E "Replica_IO_Running|Replica_SQL_Running|Source_Host|Seconds_Behind_Source|Last_.*Error" || true
done

echo ""
echo "==============================================="
echo " Conteo de filas en sbtest.sbtest1 (si existe)"
echo "==============================================="
for node in db-source db-replica1 db-replica2; do
  count=$(docker exec "${node}" mysql -uroot -p"${ROOT_PASS}" -N -s \
    -e "SELECT COUNT(*) FROM sbtest.sbtest1;" 2>/dev/null || echo "N/A")
  echo "  ${node}: ${count} filas"
done
