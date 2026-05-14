# Balanceo de carga de bases de datos MySQL con NGINX

Pool de MySQL 8 con replicación maestro-esclavo y balanceo de lectura usando NGINX
en modo stream (TCP). El objetivo es incrementar el throughput de lecturas y la
tolerancia a fallos. Se usa Sysbench para pruebas de carga.

## Arquitectura

```
                    +-----------------------------+
                    |          HOST               |
                    |  puerto 3306 (write)        |
                    |  puerto 3307 (read)         |
                    +--------------+--------------+
                                   |
                                   v
                    +-----------------------------+
                    |        NGINX (stream)       |
                    |  3306 -> mysql_write        |
                    |  3307 -> mysql_read (RR)    |
                    +------+----------+-----------+
                           |          |
              +------------+          +------------+
              v                                    v
   +----------+-----------+              +---------+----------+
   |    db-source         |  binlog SSL  |   db-replica1      |
   |    MAESTRO           |------------->|   ESCLAVO          |
   |    server-id=1       |              |   server-id=2      |
   |    /var/lib/mysql    |              |   read_only=1      |
   |    (volumen)         |              +--------------------+
   +----------------------+
              |                          +--------------------+
              |       binlog SSL         |   db-replica2      |
              +------------------------->|   ESCLAVO          |
                                         |   server-id=3      |
                                         |   read_only=1      |
                                         +--------------------+

   +----------------------+
   |     sysbench         |  (cliente de carga, contra NGINX:3306/3307)
   +----------------------+
```

- **Escritura (3306)**: NGINX redirige al maestro.
- **Lectura (3307)**: NGINX hace round-robin entre `db-replica1` y `db-replica2`.
  Health-check pasivo: si un esclavo cae (`max_fails=3, fail_timeout=10s`)
  NGINX lo saca del pool automáticamente.
- **Solo NGINX expone puertos al host.** Los MySQL viven en la red interna `db-network`.
- **TLS** activado en la replicación entre nodos (certificados en `./certs/`).

## Requisitos

- Docker + Docker Compose
- Archivo `.env` en la raíz.

Los **certificados TLS** se generan automáticamente la primera vez que se
levanta el stack (servicio `certs-gen` con `openssl` en una imagen alpine).
No hace falta crearlos a mano.

### `.env`

```env
DB_ROOT_PASSWORD=root
DB_USER=user
DB_PASSWORD=password
```

## Levantar el stack

```bash
docker compose up -d
```

Eso arranca:

| Servicio       | Rol                              | Puerto host |
|----------------|----------------------------------|-------------|
| `certs-gen`    | Genera certificados TLS (one-shot) | —         |
| `db-source`    | Maestro MySQL                    | —           |
| `db-replica1`  | Esclavo 1                        | —           |
| `db-replica2`  | Esclavo 2                        | —           |
| `db-nginx`     | Balanceador (stream TCP)         | 3306, 3307  |
| `db-sysbench`  | Cliente de benchmark             | —           |

La inicialización es automática:
- `init-user.sh` crea el usuario de replicación en el maestro
- `init.sql` + `data.sql` cargan el esquema demo
- `init-replica.sh` engancha los esclavos al maestro vía GTID + SSL

## Verificar la replicación

```bash
./check-replication.sh
```

Muestra `SHOW REPLICA STATUS\G` de cada esclavo (debe estar
`Replica_IO_Running: Yes` y `Replica_SQL_Running: Yes`) y el conteo de filas
de `sbtest.sbtest1` en los tres nodos para confirmar sincronización.

También se puede hacer manualmente:

```bash
docker compose exec replica1 mysql -uroot -proot -e "SHOW REPLICA STATUS\G"
docker compose exec replica2 mysql -uroot -proot -e "SHOW REPLICA STATUS\G"
```

## Demostrar el balanceo de lecturas

```bash
./check-balance.sh
```

Abre 10 conexiones contra `localhost:3307` (puerto de lectura de NGINX) y muestra
el `@@hostname` de cada una. Debe alternar entre `db-replica1` y `db-replica2`.

## Pruebas con Sysbench

El contenedor `db-sysbench` queda corriendo en `sleep infinity`. Los scripts
están en `./sysbench/` y se montan en `/scripts` dentro del contenedor.

### 1. Preparar dataset (5M filas por defecto)

```bash
docker compose exec sysbench bash /scripts/prepare.sh
```

Crea la DB `sbtest` y carga `sbtest1` con 5.000.000 de filas a través del
maestro (puerto 3306 de NGINX). La replicación copia el dataset a ambos
esclavos automáticamente. Tarda ~5 minutos.

### 2. Benchmark solo lectura (10 hilos, 120s)

```bash
docker compose exec sysbench bash /scripts/run-read.sh
```

Se conecta al puerto **3307** de NGINX (esclavos balanceados). Reporta:
- TPS (transacciones por segundo)
- Latencia (avg / p95 / max)

### 3. Benchmark mixto R/W (10 hilos, 120s)

```bash
docker compose exec sysbench bash /scripts/run-mixed.sh
```

Se conecta al puerto **3306** de NGINX (maestro). Reporta TPS y latencia
del mix lectura/escritura.

### 4. Benchmark solo escritura (10 hilos, 120s)

```bash
docker compose exec sysbench bash /scripts/run-write.sh
```

Aísla el costo de las escrituras puras contra el maestro.

### 5. Test de escalabilidad por hilos

```bash
docker compose exec sysbench bash /scripts/run-scaling.sh
```

Ejecuta `oltp_read_only` con 1, 4, 8, 16, 32 y 64 hilos (30s cada uno) y
muestra una tabla con TPS y latencia por nivel de concurrencia.

### Parámetros configurables

Todas las variables se pueden sobreescribir con env:

```bash
docker compose exec -e THREADS=20 -e TIME=120 sysbench bash /scripts/run-read.sh
docker compose exec -e ROWS=500000 sysbench bash /scripts/prepare.sh
```

### Limpiar dataset

```bash
docker compose exec sysbench bash /scripts/cleanup.sh
```

## Simular caída de un esclavo

```bash
docker compose stop replica1
./check-balance.sh                                       # todas caen a replica2
docker compose exec sysbench bash /scripts/run-read.sh   # sigue funcionando
docker compose start replica1                            # reincorporacion automatica
```

NGINX detecta el nodo caído por `max_fails` y redirige al esclavo
restante sin interrumpir el servicio.

## Comandos útiles

```bash
# CLI MySQL del maestro / esclavos (red interna, no expuestos al host)
docker compose exec source   mysql -uroot -proot
docker compose exec replica1 mysql -uroot -proot

# Ver logs de NGINX (incluye direcciones upstream)
docker compose logs -f nginx

# Tear-down completo (borra los volumenes!)
docker compose down -v
```
