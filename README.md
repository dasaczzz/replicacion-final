# Replicación final
Este proyecto busca crear una base de datos MySQL que sea disponible y tolerante a fallos, gracias a replicar la informacion en varios contenedores Docker.

## Requisitos

- **Docker** instalado en tu sistema
- Archivo `.env` configurado en la raíz del proyecto

## Primeros pasos

### 1. Crear archivo `.env`

Crea un archivo `.env` en la raíz del proyecto con las siguientes variables:

```env
DB_ROOT_PASSWORD=root
DB_USER=user
DB_PASSWORD=password
```

### 2. Iniciar los contenedores

Ejecuta el siguiente comando para iniciar los servicios:

```bash
docker-compose up -d
```

Este comando:
- Descarga las imágenes de MySQL 8.0 si es necesario
- Crea e inicia dos contenedores: `db-source` y `db-replica`
- Crea el usuario para la conexion de la replica y le otorga privilegios minimos

## Configuración
Para entrar al CLI de MySQL de cada contenedor usamos el siguiente comando Docker

```bash
docker exec -it {contenedor} mysql -uroot -p
```

donde {contenedor} puede ser `db-source` o `db-replica`.

### 1. Revisar configuracion de replica de la fuente
desde el CLI de MySQL en `db-source` usamos el siguiente comando
```sql
SHOW MASTER STATUS\G
```
Desplegara la informacion del archivo donde esta guardando los eventos a replicar y una posicion para sincronizar los eventos.

### 2. Sincronizar replica
en el CLI de MySQL de `db-replica`, tendremos que asignar los valores para que se comuniquen las BDs. Usamos los siguientes comandos sql para esta configuracion

```sql
CHANGE REPLICATION SOURCE TO
SOURCE_HOST='db-source',
SOURCE_USER='user',
SOURCE_PASSWORD='password',
SOURCE_LOG_FILE='mysql-bin.000001',
SOURCE_LOG_POS=1;

START REPLICA;
```

> [!IMPORTANT]
> En los campos de `SOURCE_LOG_FILE` y `SOURCE_LOG_POS` usamos los obtenidos con el comando `SHOW MASTER STATUS\G` desde la fuente

## Comprobar que todo esta funcionando

desde el CLI de MySQL de `db-replica`, usamos el siguiente comando para ver el estado de la replica

```SHOW REPLICA STATUS\G```

comprobamos que los `campos Replica_IO_Running` y `Replica_SQL_Running` tengan el valor de `Yes`.

## Primera replica de informacion
Agreguamos informacion a la BD fuente para comprobar que se esta copiando la informacion en la BD de replica. Usamos el siguiente comando
```bash
cat init.sql | docker exec -i db-source mysql -uroot -p{root} replicacion
```
donde {root} es la contraseña que le definimos para el usuario root en `.env`.
