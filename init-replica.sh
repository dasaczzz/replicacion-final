#!/bin/bash

# Esperar a que el master esté listo
until mysql -h db-source -u"${DB_USER}" -p"${DB_PASSWORD}" -e "SELECT 1" &>/dev/null; do
  echo "Esperando al master..."
  sleep 2
done

# Obtener el UUID del master dinámicamente
MASTER_UUID=$(mysql -h db-source -u"${DB_USER}" -p"${DB_PASSWORD}" \
  -se "SELECT @@server_uuid")

echo "Master UUID: ${MASTER_UUID}"

# Configurar y arrancar la réplica
mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" <<EOF
STOP REPLICA;
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='db-source',
  SOURCE_USER='${DB_USER}',
  SOURCE_PASSWORD='${DB_PASSWORD}',
  SOURCE_SSL=1,
  SOURCE_SSL_CA='/etc/mysql/certs/ca.pem',
  SOURCE_SSL_CERT='/etc/mysql/certs/client-cert.pem',
  SOURCE_SSL_KEY='/etc/mysql/certs/client-key.pem',
  SOURCE_AUTO_POSITION=1;
SET GLOBAL gtid_purged='${MASTER_UUID}:1';
START REPLICA;
EOF
