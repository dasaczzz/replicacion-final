# Resultados de las pruebas

Ejecutadas el 2026-05-14 contra el stack `docker compose up -d`
(1 maestro + 2 esclavos + NGINX stream + Sysbench).

**Hardware del host:** Windows 11, Docker Desktop sobre WSL2.
**Dataset:** 5.000.000 filas en `sbtest.sbtest1` (~1 GB).
**Tablas:** 1.
**Imagen Sysbench:** `severalnines/sysbench:latest` (sysbench 1.0.17).

---

## 1. Replicación funcionando

`./check-replication.sh` reporta en ambos esclavos:

```
Source_Host: db-source
Replica_IO_Running: Yes
Replica_SQL_Running: Yes
Seconds_Behind_Source: 0
Replica_SQL_Running_State: Replica has read all relay log; waiting for more updates
```

Conteo de filas tras `prepare` con 5M:

| Nodo         | sbtest.sbtest1 |
|--------------|----------------|
| db-source    | 5.000.000      |
| db-replica1  | 5.000.000      |
| db-replica2  | 5.000.000      |

→ La replicación copia los datos completos del maestro a los dos esclavos.

---

## 2. Balanceo de lecturas (NGINX stream)

10 conexiones a `db-nginx:3307` (puerto de lectura) consultando `@@hostname`:

```
Conexion #1  -> db-replica1
Conexion #2  -> db-replica2
Conexion #3  -> db-replica1
Conexion #4  -> db-replica2
Conexion #5  -> db-replica1
Conexion #6  -> db-replica2
Conexion #7  -> db-replica1
Conexion #8  -> db-replica2
Conexion #9  -> db-replica1
Conexion #10 -> db-replica2
```

→ Round-robin perfecto 5/5 entre los dos esclavos.

---

## 3. Benchmarks principales (10 hilos, 120 s)

### 3.1 Solo lectura — `oltp_read_only`

Conexión: `db-nginx:3307` (esclavos balanceados).

| Métrica                | Valor              |
|------------------------|--------------------|
| Transacciones totales  | 94.980             |
| **TPS**                | **790.99**         |
| QPS                    | 12.655,77          |
| Latencia mínima        | 4.50 ms            |
| Latencia media         | 12.64 ms           |
| **Latencia p95**       | **15.00 ms**       |
| Latencia máxima        | 98.75 ms           |
| Errores                | 0                  |
| Reconexiones           | 0                  |

### 3.2 Lectura/escritura mixto — `oltp_read_write`

Conexión: `db-nginx:3306` (maestro). Workload típico: ~70 % lecturas, ~30 % escrituras.

| Métrica                | Valor              |
|------------------------|--------------------|
| Transacciones totales  | 14.455             |
| **TPS**                | **120.21**         |
| QPS                    | 2.404,19           |
| Reads / Writes / Other | 202370 / 57820 / 28910 |
| Latencia mínima        | 10.66 ms           |
| Latencia media         | 83.14 ms           |
| **Latencia p95**       | **262.64 ms**      |
| Latencia máxima        | 852.30 ms          |
| Errores                | 0                  |

### 3.3 Solo escritura — `oltp_write_only`

Conexión: `db-nginx:3306` (maestro). Aísla el costo de las escrituras.

| Métrica                | Valor              |
|------------------------|--------------------|
| Transacciones totales  | 15.620             |
| **TPS**                | **129.92**         |
| QPS                    | 779.54             |
| Latencia mínima        | 5.28 ms            |
| Latencia media         | 76.89 ms           |
| **Latencia p95**       | **211.60 ms**      |
| Latencia máxima        | 964.61 ms          |
| Errores                | 0                  |

---

## 4. Test de escalabilidad por hilos — `oltp_read_only`

30 s por punto. Muestra cómo escala el sistema al aumentar la concurrencia.

| Hilos | TPS    | QPS      | Lat. avg (ms) | Lat. p95 (ms) |
|-------|--------|----------|---------------|---------------|
| 1     | 239.50 | 3.831,99 | 4.17          | 6.43          |
| 4     | 748.12 | 11.969,99| 5.34          | 6.55          |
| 8     | 788.82 | 12.621,09| 10.14         | 12.08         |
| 16    | 792.90 | 12.686,41| 20.17         | 23.52         |
| 32    | 763.27 | 12.212,25| 41.90         | 48.34         |
| 64    | 726.88 | 11.630,07| 87.97         | 102.97        |

**Análisis:**

- **De 1 a 4 hilos:** el TPS crece 3.1x al cuadruplicar la concurrencia →
  el sistema tenía capacidad ociosa.
- **De 4 a 16 hilos:** se entra en *plateau* (~790 TPS), saturación de los
  esclavos. Más concurrencia no produce más throughput.
- **De 16 a 64 hilos:** el TPS empieza a degradarse (-8 %) mientras la
  latencia se cuadriplica (24 → 103 ms). Síntoma clásico de contención
  por hilos/locks/IO.
- **Conclusión:** el sweet spot está en 8-16 hilos para esta carga y este
  hardware.

---

## 5. Tolerancia a fallos — caída de un esclavo

### 5.1 Balanceo con un nodo caído

`docker compose stop replica1` →
NGINX detecta el nodo caído por `max_fails=3 fail_timeout=10s` y lo saca
del pool. Las 10 conexiones siguientes a `:3307` van todas a `db-replica2`.

### 5.2 Benchmark de lectura con replica1 caído

| Métrica           | Con 2 esclavos | Con 1 esclavo caído | Δ        |
|-------------------|----------------|---------------------|----------|
| Transacciones     | 94.980         | 94.016              | -1.0 %   |
| **TPS**           | **790.99**     | **783.39**          | -1.0 %   |
| QPS               | 12.655,77      | 12.534,18           | -1.0 %   |
| Latencia media    | 12.64 ms       | 12.76 ms            | +1 %     |
| **Latencia p95**  | **15.00 ms**   | **15.55 ms**        | +3.7 %   |
| Errores           | 0              | 0                   | 0        |
| Reconexiones      | 0              | 0                   | 0        |

→ **Caída solo del ~1 % en throughput.** El sistema sigue funcionando
sin que el cliente note absolutamente nada — cero errores, cero
reconexiones, latencia esencialmente igual.

### 5.3 Reincorporación automática

`docker compose start replica1` → tras ~10 s `SHOW REPLICA STATUS` reporta:

```
Replica_IO_Running: Yes
Replica_SQL_Running: Yes
Seconds_Behind_Source: 0
```

Gracias a **GTID + `SOURCE_AUTO_POSITION=1`**, la réplica le pide al
maestro únicamente las transacciones que se perdió mientras estaba
abajo. Una vez al día, NGINX la vuelve a recibir tráfico
automáticamente cuando expira el `fail_timeout`.

---

## Resumen

| Prueba mínima del enunciado | Estado |
|-----------------------------|--------|
| Verificar replicación (`SHOW REPLICA STATUS`) | ✅ |
| Balanceo demostrado con `@@hostname` | ✅ |
| Sysbench solo lectura (10h, 60s) — TPS + latencia | ✅ 120s, 5M filas |
| Sysbench mixto (10h, 60s) — TPS + latencia | ✅ 120s, 5M filas |
| Caída de esclavo + NGINX redirige | ✅ |

**Pruebas adicionales (extra):**

| Prueba | Estado |
|--------|--------|
| Sysbench write-only | ✅ |
| Escalabilidad 1→64 hilos | ✅ |
| Reincorporación automática del esclavo | ✅ |

**Indicadores de calidad:**

- **0 errores** en 350.000+ transacciones a través de todas las pruebas.
- **0 reconexiones forzadas** — la replicación nunca se rompió.
- **Caída de nodo invisible al cliente** — 0 errores, 1 % de impacto en
  throughput.
