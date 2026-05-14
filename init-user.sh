#!/bin/bash

# Crea el usuario explicitamente para que la sentencia entre al binlog
# y se replique a los esclavos (asi pueden autenticarlo en las lecturas).

mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" <<EOF

CREATE USER IF NOT EXISTS '${DB_USER}'@'%'
  IDENTIFIED WITH mysql_native_password BY '${DB_PASSWORD}';

-- DB que usa sysbench para sus benchmarks
CREATE DATABASE IF NOT EXISTS sbtest;

-- Permisos minimos para que las replicas puedan leer el binlog
GRANT REPLICATION SLAVE ON *.* TO '${DB_USER}'@'%';

-- Permisos para que sysbench pueda crear/poblar la DB sbtest a traves de NGINX
GRANT ALL PRIVILEGES ON sbtest.* TO '${DB_USER}'@'%';

-- Permitir consultar @@hostname (para demostrar el balanceo de NGINX)
GRANT PROCESS ON *.* TO '${DB_USER}'@'%';

FLUSH PRIVILEGES;

EOF
