# Balanceo de carga de bases de datos MySQL con NGINX

Pool de MySQL 8 con replicación maestro-esclavo y balanceo de lectura usando NGINX
en modo stream (TCP). El objetivo es incrementar el throughput de lecturas y la
tolerancia a fallos. Se utiliza Sysbench para pruebas de carga y rendimiento.

---

## Tabla de contenido

- [Arquitectura](#arquitectura)
- [Inicio rápido](#inicio-rápido)
- [Compatibilidad cross-platform](#compatibilidad-cross-platform)
- [Requisitos](#requisitos)
- [Levantar el stack](#levantar-el-stack)
- [Verificar la replicación](#verificar-la-replicación)
- [Demostrar el balanceo de lecturas](#demostrar-el-balanceo-de-lecturas)
- [Pruebas con Sysbench](#pruebas-con-sysbench)
- [Simular caída de un esclavo](#simular-caída-de-un-esclavo)
- [Decisiones técnicas y justificación académica](#decisiones-técnicas-y-justificación-académica)
- [Comandos útiles](#comandos-útiles)
- [Solución de problemas](#solución-de-problemas)

---

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
- **GTID** con `SOURCE_AUTO_POSITION=1` para reincorporación automática tras caídas.

---

## Inicio rápido

Para arrancar el proyecto desde cero en cualquier sistema operativo con Docker
instalado:

```bash
# 1. Clonar el repositorio
git clone <url-del-repositorio>
cd replicacion-final

# 2. Crear el archivo .env (ver sección Requisitos)
# En Linux/macOS:
cat > .env << EOF
DB_ROOT_PASSWORD=root
DB_USER=user
DB_PASSWORD=password
EOF

# En Windows (PowerShell):
# @"
# DB_ROOT_PASSWORD=root
# DB_USER=user
# DB_PASSWORD=password
# "@ | Out-File -FilePath .env -Encoding ASCII

# 3. Levantar el stack (~45 segundos)
docker compose up -d

# 4. Esperar a que la inicialización termine
sleep 45

# 5. Verificar replicación
docker compose exec replica1 mysql -uroot -proot \
  -e "SHOW REPLICA STATUS\G" | grep -E "Running|Behind"

# 6. Verificar balanceo (10 conexiones)
for i in $(seq 1 10); do
  docker compose exec -T source mysql -h db-nginx -P 3307 \
    -uuser -ppassword -N -s -e "SELECT @@hostname;"
done
```

A partir de aquí ya se pueden lanzar los benchmarks de Sysbench (sección
[Pruebas con Sysbench](#pruebas-con-sysbench)).

---

## Compatibilidad cross-platform

El proyecto está diseñado para funcionar de forma idéntica en **Linux, macOS y
Windows** sin configuración adicional, siempre que se tenga Docker y Docker
Compose instalados. No requiere Git Bash, WSL específico, conversión manual de
archivos, ni configuración previa de Git.

### Matriz de compatibilidad

| Sistema operativo | Docker requerido               | Dependencia adicional para scripts del host |
|-------------------|--------------------------------|---------------------------------------------|
| **macOS**         | Docker Desktop, Colima u OrbStack | Ninguna (bash/zsh nativos)                |
| **Linux**         | Docker Engine + plugin compose | Ninguna (bash nativo)                       |
| **Windows 10/11** | Docker Desktop (backend WSL2)  | Git Bash, WSL o PowerShell con equivalentes |

### Garantía de portabilidad: normalización automática de scripts

En Windows, los archivos de texto suelen guardarse con terminadores de línea
**CRLF** (`\r\n`) mientras que Linux espera **LF** (`\n`). Esto causa un
problema clásico en proyectos multiplataforma con Docker: los scripts `.sh`
clonados desde Git en Windows pueden fallar dentro de contenedores Linux con
errores del tipo `/bin/sh^M: bad interpreter`.

Para garantizar portabilidad real sin imponer disciplina al usuario (no se
requiere `.gitattributes`, ni configurar `core.autocrlf`, ni convertir archivos
manualmente), **cada servicio del `docker-compose.yml` normaliza sus scripts al
vuelo dentro del contenedor** antes de ejecutarlos, mediante una pasada de
`sed 's/\r$//'`. El archivo original en el host no se modifica; solo se
normaliza la copia que ejecuta el contenedor.

Esto significa que el proyecto funciona idéntico en:

- Windows con archivos en CRLF (sin Git configurado para LF)
- Windows con archivos en LF (Git configurado correctamente)
- macOS y Linux con archivos en LF nativos

### Scripts auxiliares del host

Existen dos scripts de conveniencia que se ejecutan desde el host (no desde un
contenedor):

- `check-replication.sh`
- `check-balance.sh`

En **macOS y Linux** se ejecutan directamente con `./check-replication.sh`. En
**Windows** requieren Git Bash o WSL. Como alternativa, este README documenta
los **comandos equivalentes manuales** en cada sección, que funcionan en
cualquier shell (PowerShell, cmd, bash) sin dependencias adicionales.

---

## Requisitos

- **Docker** y **Docker Compose** (versión 2 o superior, sintaxis `docker compose`).
- Aproximadamente **2 GB de RAM libre** para los contenedores.
- Aproximadamente **2 GB de espacio en disco** (5M filas de Sysbench ocupan ~1 GB
  replicadas en 3 nodos).
- Un archivo `.env` en la raíz del proyecto con las credenciales (ver abajo).

Los **certificados TLS** para la replicación se generan automáticamente la
primera vez que se levanta el stack (servicio `certs-gen` con `openssl` en una
imagen Alpine). No es necesario crearlos manualmente.

### Archivo `.env`

Antes de levantar el stack se debe crear un archivo `.env` en la raíz:

```env
DB_ROOT_PASSWORD=root
DB_USER=user
DB_PASSWORD=password
```

Los valores pueden ser cualquier cadena. Estos son los usados en los comandos
de verificación documentados en este README, por lo que se recomienda
mantenerlos para reproducibilidad.

---

## Levantar el stack

```bash
docker compose up -d
```

La inicialización tarda aproximadamente 45 segundos y dispara, en orden:

1. **`certs-gen`** genera los certificados TLS y termina con código 0.
2. **`source`** arranca, ejecuta `init-user.sh`, `init.sql` y `data.sql`.
3. **`replica1` y `replica2`** arrancan, ejecutan `init-replica.sh` y se enganchan
   al maestro vía GTID + SSL.
4. **`nginx`** queda escuchando en los puertos 3306 (escritura) y 3307 (lectura).
5. **`sysbench`** queda en `sleep infinity`, listo para recibir comandos.

### Servicios del stack

| Servicio       | Rol                                | Puerto host |
|----------------|------------------------------------|-------------|
| `certs-gen`    | Genera certificados TLS (one-shot) | —           |
| `db-source`    | Maestro MySQL                      | —           |
| `db-replica1`  | Esclavo 1                          | —           |
| `db-replica2`  | Esclavo 2                          | —           |
| `db-nginx`     | Balanceador (stream TCP)           | 3306, 3307  |
| `db-sysbench`  | Cliente de benchmark               | —           |

### Verificar que el stack arrancó correctamente

```bash
docker compose ps
```

Resultado esperado: `db-source`, `db-replica1`, `db-replica2`, `db-nginx` y
`db-sysbench` en estado `Up`. El contenedor `db-certs-gen` no aparece aquí
porque ya terminó su trabajo; para verlo:

```bash
docker compose ps -a
```

Debe mostrar `db-certs-gen` con estado `Exited (0)`.

---

## Verificar la replicación

### Opción A — Script automatizado (macOS, Linux, Git Bash)

```bash
./check-replication.sh
```

El script ejecuta `SHOW REPLICA STATUS\G` en ambos esclavos y muestra el conteo
de filas de las tablas demo en los tres nodos.

### Opción B — Comandos manuales (cualquier shell)

```bash
docker compose exec replica1 mysql -uroot -proot -e "SHOW REPLICA STATUS\G"
docker compose exec replica2 mysql -uroot -proot -e "SHOW REPLICA STATUS\G"
```

### Indicadores de salud

En ambos esclavos se debe ver:

```
Replica_IO_Running: Yes
Replica_SQL_Running: Yes
Seconds_Behind_Source: 0
Source_SSL_Allowed: Yes
Last_Errno: 0
```

### Verificar sincronización de datos

```bash
docker compose exec source   mysql -uroot -proot replicacion -e "SELECT COUNT(*) FROM User;"
docker compose exec replica1 mysql -uroot -proot replicacion -e "SELECT COUNT(*) FROM User;"
docker compose exec replica2 mysql -uroot -proot replicacion -e "SELECT COUNT(*) FROM User;"
```

Los tres nodos deben devolver el mismo conteo (3 usuarios cargados desde
`data.sql`), confirmando que la replicación copió los datos del maestro a los
esclavos.

### Nota sobre `SHOW REPLICA STATUS` vs `SHOW SLAVE STATUS`

Este proyecto utiliza `SHOW REPLICA STATUS` en lugar del histórico
`SHOW SLAVE STATUS`. Esta decisión se justifica en la sección
[Decisiones técnicas](#decisiones-técnicas-y-justificación-académica). Ambos
comandos son funcionalmente equivalentes y MySQL 8.0 acepta los dos.

---

## Demostrar el balanceo de lecturas

### Opción A — Script automatizado (macOS, Linux, Git Bash)

```bash
./check-balance.sh
```

### Opción B — Comandos manuales

**Linux / macOS / Git Bash:**

```bash
for i in $(seq 1 10); do
  docker compose exec -T source mysql -h db-nginx -P 3307 \
    -uuser -ppassword -N -s -e "SELECT @@hostname;"
done
```

**Windows (PowerShell):**

```powershell
1..10 | ForEach-Object {
    docker compose exec -T source mysql -h db-nginx -P 3307 `
      -uuser -ppassword -N -s -e "SELECT @@hostname;" 2>$null
}
```

El resultado debe alternar entre `db-replica1` y `db-replica2`, demostrando que
NGINX distribuye las conexiones en round-robin entre los dos esclavos.

---

## Pruebas con Sysbench

El contenedor `db-sysbench` queda corriendo en `sleep infinity`. Los scripts de
benchmark están en `./sysbench/` y se montan en `/scripts` dentro del
contenedor (normalizados automáticamente, ver
[Compatibilidad cross-platform](#compatibilidad-cross-platform)).

### 1. Preparar dataset (5M filas por defecto)

```bash
docker compose exec sysbench bash /scripts/prepare.sh
```

Crea la base de datos `sbtest` y carga `sbtest1` con 5.000.000 de filas a
través del maestro (puerto 3306 de NGINX). La replicación copia el dataset a
ambos esclavos automáticamente. Tarda aproximadamente 5 minutos.

**Para iterar más rápido durante desarrollo**, se puede usar un dataset más
pequeño:

```bash
docker compose exec -e ROWS=500000 sysbench bash /scripts/prepare.sh
```

### 2. Benchmark solo lectura

```bash
docker compose exec sysbench bash /scripts/run-read.sh
```

Configuración: 10 hilos × 120 segundos contra el puerto **3307** de NGINX
(esclavos balanceados). Reporta TPS, QPS y latencia (mínima, media, p95, máxima).

### 3. Benchmark mixto lectura/escritura

```bash
docker compose exec sysbench bash /scripts/run-mixed.sh
```

10 hilos × 120 segundos contra el puerto **3306** de NGINX (maestro). Workload
típico OLTP: aproximadamente 70 % lecturas y 30 % escrituras.

### 4. Benchmark solo escritura

```bash
docker compose exec sysbench bash /scripts/run-write.sh
```

Aísla el costo de las escrituras puras contra el maestro.

### 5. Test de escalabilidad por hilos

```bash
docker compose exec sysbench bash /scripts/run-scaling.sh
```

Ejecuta `oltp_read_only` con 1, 4, 8, 16, 32 y 64 hilos (30 s por punto) y
muestra una tabla con TPS y latencia por nivel de concurrencia. Permite
identificar el punto de saturación del sistema.

### Parámetros configurables

Todas las variables de los scripts pueden sobreescribirse vía variables de
entorno:

```bash
docker compose exec -e THREADS=20 -e TIME=120 sysbench bash /scripts/run-read.sh
docker compose exec -e ROWS=500000 sysbench bash /scripts/prepare.sh
```

### Limpiar el dataset

```bash
docker compose exec sysbench bash /scripts/cleanup.sh
```

---

## Simular caída de un esclavo

Esta prueba demuestra la tolerancia a fallos del sistema: la detección
automática de nodos caídos por parte de NGINX y la reincorporación automática
gracias a GTID.

```bash
# 1. Detener una réplica
docker compose stop replica1

# 2. Esperar a que NGINX detecte la caída (max_fails=3, fail_timeout=10s)
sleep 15

# 3. Verificar que el tráfico cae todo al esclavo restante
#    (todas las conexiones deben ir a db-replica2)
./check-balance.sh

# 4. Ejecutar benchmark con un solo esclavo activo
docker compose exec sysbench bash /scripts/run-read.sh

# 5. Reincorporar la réplica
docker compose start replica1
sleep 15

# 6. Verificar que volvió a sincronizar automáticamente
docker compose exec replica1 mysql -uroot -proot -e "SHOW REPLICA STATUS\G" \
  | grep -E "Running|Behind"

# 7. Confirmar que el balanceo vuelve a 5/5
./check-balance.sh
```

NGINX detecta el nodo caído por `max_fails` y redirige al esclavo restante sin
interrumpir el servicio. Tras la reincorporación, gracias a GTID +
`SOURCE_AUTO_POSITION=1`, la réplica solicita al maestro únicamente las
transacciones que se perdió mientras estuvo abajo, sin requerir intervención
manual.

---

## Decisiones técnicas y justificación académica

Esta sección documenta las decisiones de implementación que se apartan de las
configuraciones "por defecto" o "de manual", explicando las razones técnicas
detrás de cada una.

### 1. Configuración de MySQL mediante flags en `command:` (no `my.cnf`)

**Decisión:** la configuración de cada nodo MySQL (`server-id`, `log-bin`,
`gtid-mode`, certificados SSL, etc.) se pasa como flags directos en el campo
`command:` del servicio Docker Compose, en lugar de montar archivos `.cnf`
como volúmenes.

**Justificación técnica:**

El requerimiento académico sugería montar archivos `my.cnf` como volúmenes con
`server-id` único por nodo. Sin embargo, esta aproximación presenta un
**problema de seguridad documentado en MySQL** cuando el host es Windows: al
montar un archivo de configuración mediante bind-mount desde un sistema de
archivos NTFS, el archivo aparece dentro del contenedor con permisos
`world-writable` (777). MySQL detecta esta condición e **ignora deliberadamente
el archivo de configuración** emitiendo el siguiente warning en los logs:

```
[Warning] World-writable config file '/etc/mysql/my.cnf' is ignored.
```

Esto es una protección del propio MySQL contra escalación de privilegios: un
archivo de configuración modificable por cualquier usuario podría ser
explotado para alterar el comportamiento del servidor. Como resultado, en un
host Windows el `server-id` no se aplicaría, la replicación no funcionaría, y
el problema sería difícil de diagnosticar para quien clone el repositorio.

Pasar los mismos parámetros vía `command:` produce el resultado funcional
equivalente (cada nodo recibe su `server-id` único y la configuración de
binlog, GTID y SSL), pero **garantiza el mismo comportamiento en cualquier
sistema operativo** (Linux, macOS, Windows) sin depender de permisos del
sistema de archivos del host. Adicionalmente, mantiene toda la configuración
en un único archivo (`docker-compose.yml`), facilitando la lectura y revisión
del proyecto.

El `server-id` único por nodo se mantiene como exige el requerimiento:

- `db-source`: `--server-id=1`
- `db-replica1`: `--server-id=2`
- `db-replica2`: `--server-id=3`

### 2. Uso de `SHOW REPLICA STATUS` en lugar de `SHOW SLAVE STATUS`

**Decisión:** los scripts de verificación y la documentación utilizan el
comando `SHOW REPLICA STATUS` en lugar del histórico `SHOW SLAVE STATUS`.

**Justificación técnica:**

A partir de MySQL 8.0.22 (julio de 2020), Oracle introdujo un cambio de
terminología en el subsistema de replicación: las palabras `SLAVE`, `MASTER` y
`MASTERPOS` fueron **formalmente deprecadas** en favor de `REPLICA`, `SOURCE` y
`SOURCEPOS` respectivamente. Este cambio responde a una iniciativa de
inclusión terminológica adoptada también por otros proyectos de software de
infraestructura.

Los comandos antiguos (`SHOW SLAVE STATUS`, `CHANGE MASTER TO`, etc.) **siguen
funcionando** por compatibilidad hacia atrás en MySQL 8.0 y devuelven los
mismos resultados, pero generan advertencias de deprecación. Las versiones
futuras de MySQL eliminarán el soporte de los comandos antiguos. Por esta
razón:

- El script `init-replica.sh` usa `CHANGE REPLICATION SOURCE TO` y
  `START REPLICA` en lugar de `CHANGE MASTER TO` y `START SLAVE`.
- Los scripts de verificación usan `SHOW REPLICA STATUS\G`.
- Los flags de MySQL usan `--log-replica-updates` en lugar de `--log-slave-updates`.

Esta decisión alinea el proyecto con las prácticas actuales recomendadas por
Oracle y garantiza compatibilidad con versiones futuras de MySQL. Quienes
estén familiarizados con `SHOW SLAVE STATUS` pueden seguir usando ese comando
sin problema: en MySQL 8.0.46 (la versión usada en este proyecto), ambos
producen idéntico resultado.

### 3. Replicación con TLS y certificados auto-generados

**Decisión:** la replicación entre maestro y esclavos se realiza sobre TLS,
con certificados generados automáticamente en el primer arranque del stack
por un servicio dedicado (`certs-gen`).

**Justificación técnica:**

Aunque el requerimiento no exigía cifrado de la replicación, en un escenario
real la replicación viaja por red y transporta el contenido completo del
binlog, incluyendo datos sensibles. MySQL soporta replicación cifrada vía SSL
estableciendo `SOURCE_SSL=1` en el `CHANGE REPLICATION SOURCE TO` y
configurando los flags `--ssl-ca`, `--ssl-cert` y `--ssl-key` en cada nodo.

Generar los certificados manualmente sería una barrera de entrada para quien
clone el proyecto. Por eso se incluyó un servicio `certs-gen` basado en
`alpine:3.20` que:

1. Instala `openssl` temporalmente.
2. Genera una CA auto-firmada (`ca.pem`) válida por 10 años.
3. Genera certificados de servidor (para el maestro) y cliente (para las
   réplicas) firmados por esa CA.
4. Aplica los permisos correctos para que MySQL los acepte sin emitir warnings.
5. Termina con código 0 y libera la imagen.

Los certificados quedan persistidos en `./certs/` y son reutilizados en
arranques posteriores. El servicio es **idempotente**: si los certificados ya
existen, no los regenera.

### 4. GTID con `SOURCE_AUTO_POSITION=1` para reincorporación automática

**Decisión:** la replicación usa GTID (Global Transaction Identifiers) con
posicionamiento automático en lugar de coordenadas binlog (`MASTER_LOG_FILE` +
`MASTER_LOG_POS`).

**Justificación técnica:**

La replicación tradicional por coordenadas binlog requiere que el administrador
especifique manualmente el archivo y posición exactos desde donde un esclavo
debe empezar a replicar. Cuando un esclavo cae y vuelve a arrancar, el
administrador debe consultar `SHOW BINARY LOG STATUS` en el maestro y
re-configurar la posición de inicio. Es propenso a errores humanos y dificulta
la automatización.

GTID asigna un identificador único a cada transacción del maestro. Al
configurar las réplicas con `SOURCE_AUTO_POSITION=1`, el protocolo de
replicación de MySQL **negocia automáticamente** qué transacciones faltan en
la réplica y solicita exactamente esas. Esto tiene tres consecuencias
prácticas demostradas en este proyecto:

1. El `init-replica.sh` no necesita conocer la posición del binlog del maestro.
2. Si una réplica cae y vuelve a arrancar, automáticamente solicita las
   transacciones que se perdió, sin intervención manual.
3. La reincorporación tras una caída es transparente para el cliente: NGINX
   detecta que el esclavo volvió a estar disponible (vía `fail_timeout`) y lo
   reincorpora al pool, mientras la replicación se pone al día por debajo.

Los flags relevantes en cada nodo MySQL:

```
--gtid-mode=ON
--enforce-gtid-consistency=ON
--log-replica-updates=ON
```

### 5. Red interna Docker con un único punto de entrada

**Decisión:** los contenedores MySQL no publican puertos al host. Solo NGINX
expone los puertos 3306 y 3307.

**Justificación técnica:**

Esta arquitectura cumple dos objetivos:

1. **Único punto de entrada:** los clientes (Sysbench, aplicaciones externas)
   no necesitan conocer la topología interna del cluster. Conectan a
   `localhost:3306` para escribir o `localhost:3307` para leer, y NGINX decide
   a qué nodo enrutar. Esto desacopla los clientes de la infraestructura.

2. **Seguridad por defecto:** los nodos MySQL solo son alcanzables desde la
   red Docker `db-network`. Un atacante en el host no puede atacarlos
   directamente; solo puede pasar por NGINX, que actúa como punto único de
   control y observación.

Adicionalmente, esto evita conflictos de puerto en el host: tres instancias de
MySQL no pueden todas escuchar en `:3306` del host, pero sí pueden hacerlo
dentro de sus respectivas redes Docker.

### 6. Normalización CRLF dentro del compose

**Decisión:** cada servicio que monta un script `.sh` desde el host lo
normaliza con `sed 's/\r$//'` antes de ejecutarlo.

**Justificación técnica:**

Detallada en la sección
[Compatibilidad cross-platform](#compatibilidad-cross-platform). El objetivo
es que el proyecto sea ejecutable por cualquier usuario en cualquier sistema
operativo sin requerir configuración previa de Git, normalización manual de
archivos, o uso de herramientas específicas como `dos2unix`. La solución es
transparente, autocontenida en el `docker-compose.yml`, y no modifica los
archivos del host.

---

## Comandos útiles

```bash
# CLI MySQL del maestro / esclavos (red interna, no expuestos al host)
docker compose exec source   mysql -uroot -proot
docker compose exec replica1 mysql -uroot -proot
docker compose exec replica2 mysql -uroot -proot

# Ver logs en tiempo real
docker compose logs -f nginx
docker compose logs -f source
docker compose logs -f replica1

# Reiniciar manteniendo datos
docker compose down
docker compose up -d

# Tear-down completo (borra volúmenes y datos)
docker compose down -v
```

### Estado de re-arranques

Los scripts de inicialización (`init-user.sh`, `init-replica.sh`, `init.sql`,
`data.sql`) **solo se ejecutan en el primer arranque sobre volúmenes nuevos**.
Esto es comportamiento estándar de la imagen oficial de MySQL: si el directorio
`/var/lib/mysql` ya contiene datos inicializados, los scripts de
`/docker-entrypoint-initdb.d/` no se vuelven a correr.

Si se modifica alguno de los scripts de inicialización y se quiere que tenga
efecto, es necesario destruir los volúmenes:

```bash
docker compose down -v
docker compose up -d
```

---

## Solución de problemas

### El stack no arranca o `certs-gen` falla

Verificar que el archivo `.env` exista en la raíz con las tres variables
esperadas. Si no existe, `docker compose` arrancará pero los servicios MySQL
fallarán al no encontrar las credenciales.

### Las réplicas no se enganchan al maestro

Esperar al menos 45 segundos tras `docker compose up -d` antes de verificar.
La inicialización es secuencial: primero `certs-gen`, luego `source` con sus
scripts SQL, y solo después arrancan las réplicas. Si tras 60 segundos
`Replica_IO_Running` sigue en `No`, revisar los logs:

```bash
docker compose logs replica1 --tail 50
docker compose logs source   --tail 50
```

### Error `Can't connect to local MySQL server through socket`

Indica que `mysqld` aún no ha terminado de arrancar dentro del contenedor.
Esto puede ocurrir si se ejecutan comandos muy pronto tras `docker compose
start <servicio>`. Esperar 10-15 segundos adicionales y reintentar.

### El balanceo no alterna entre réplicas

Confirmar que ambas réplicas están `Up`:

```bash
docker compose ps
```

Si una está detenida, NGINX la sacó del pool por `max_fails`. Reiniciarla con
`docker compose start <servicio>` y esperar a que expire el `fail_timeout`
(10 segundos).

### Rendimiento de Sysbench inferior al esperado

Los benchmarks dependen fuertemente del entorno: capacidad de IO del disco,
RAM asignada a Docker, otros procesos del host. En Docker Desktop sobre
Windows con WSL2, el throughput puede ser significativamente menor que en
Linux nativo. Esto es esperado y no indica problemas del proyecto.

### Re-arranque sin que se ejecuten los scripts de inicialización

Si después de modificar `init.sql`, `data.sql` o cualquier script de
inicialización los cambios no se ven reflejados, ejecutar:

```bash
docker compose down -v
docker compose up -d
```

El flag `-v` borra los volúmenes, forzando a MySQL a reinicializar la base de
datos desde cero y re-ejecutar todos los scripts de
`/docker-entrypoint-initdb.d/`.
