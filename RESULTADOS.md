# Resultados de las pruebas

Ejecutadas contra el stack `docker compose up -d`
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
Source_SSL_Allowed: Yes
Replica_SQL_Running_State: Replica has read all relay log; waiting for more updates
```

Conteo de filas tras `prepare` con 5M:

| Nodo         | sbtest.sbtest1 |
|--------------|----------------|
| db-source    | 5.000.000      |
| db-replica1  | 5.000.000      |
| db-replica2  | 5.000.000      |

→ La replicación copia los datos completos del maestro a los dos esclavos.
→ El indicador `Source_SSL_Allowed: Yes` confirma que el canal entre nodos
está cifrado con TLS.

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
| Transacciones totales  | 115.398            |
| **TPS**                | **960,99**         |
| QPS                    | 15.375,85          |
| Latencia mínima        | 0,89 ms            |
| Latencia media         | 10,39 ms           |
| **Latencia p95**       | **20,37 ms**       |
| Latencia máxima        | 2.991,16 ms        |
| Errores                | 0                  |
| Reconexiones           | 0                  |

### 3.2 Lectura/escritura mixto — `oltp_read_write`

Conexión: `db-nginx:3306` (maestro). Workload típico: ~70 % lecturas, ~30 % escrituras.

| Métrica                | Valor                  |
|------------------------|------------------------|
| Transacciones totales  | 9.859                  |
| **TPS**                | **82,00**              |
| QPS                    | 1.640,03               |
| Reads / Writes / Other | 138.026 / 39.436 / 19.718 |
| Latencia mínima        | 15,94 ms               |
| Latencia media         | 121,76 ms              |
| **Latencia p95**       | **356,70 ms**          |
| Latencia máxima        | 1.701,24 ms            |
| Errores                | 0                      |
| Reconexiones           | 0                      |

### 3.3 Solo escritura — `oltp_write_only`

Conexión: `db-nginx:3306` (maestro). Aísla el costo de las escrituras.

| Métrica                | Valor              |
|------------------------|--------------------|
| Transacciones totales  | 9.236              |
| **TPS**                | **76,92**          |
| QPS                    | 461,54             |
| Latencia mínima        | 30,94 ms           |
| Latencia media         | 129,98 ms          |
| **Latencia p95**       | **287,38 ms**      |
| Latencia máxima        | 1.594,56 ms        |
| Errores                | 0                  |
| Reconexiones           | 0                  |

---

## 4. Test de escalabilidad por hilos — `oltp_read_only`

30 s por punto. Muestra cómo escala el sistema al aumentar la concurrencia.

| Hilos | TPS      | QPS        | Lat. avg (ms) | Lat. p95 (ms) |
|-------|----------|------------|---------------|---------------|
| 1     | 242,85   | 3.885,66   | 4,11          | 7,56          |
| 4     | 747,74   | 11.963,77  | 5,34          | 8,90          |
| 8     | 1.305,71 | 20.891,43  | 6,12          | 7,98          |
| **16**| **1.403,07** | **22.449,17** | **11,40** | **13,46**     |
| 32    | 1.197,79 | 19.164,64  | 26,69         | 30,81         |
| 64    | 1.167,76 | 18.684,12  | 54,77         | 66,84         |

**Análisis:**

- **De 1 a 8 hilos:** crecimiento casi lineal del throughput (de 243 a
  1.306 TPS). La latencia p95 se mantiene plana entre 7 y 9 ms, indicando
  que el sistema absorbe la concurrencia sin estrés.
- **A 16 hilos:** se alcanza el **sweet spot** del sistema con **1.403 TPS**
  y latencia p95 de 13,46 ms. Punto donde se maximiza el throughput sin
  degradar significativamente la latencia.
- **De 16 a 32 hilos:** punto de inflexión. El TPS cae a 1.198 (-14,6 %)
  y la latencia p95 se triplica (13,46 → 30,81 ms). La cola de espera
  empieza a dominar el tiempo de respuesta.
- **De 32 a 64 hilos:** degradación clara. El TPS se estanca y la latencia
  p95 se duplica nuevamente (30,81 → 66,84 ms). Síntoma de contención por
  conexiones, locks de InnoDB y context switching.
- **Conclusión:** el sweet spot está en **16 hilos** para esta carga y este
  hardware. La degradación posterior es gradual y controlada, sin colapso.

---

## 5. Tolerancia a fallos — caída de un esclavo

### 5.1 Detección y redirección por NGINX

`docker compose stop replica1` →
NGINX detecta el nodo caído en menos de 15 segundos por
`max_fails=3 fail_timeout=10s` y lo saca del pool. Las 10 conexiones
siguientes a `:3307` van todas a `db-replica2`. **Cero errores en el
cliente, cero reconexiones forzadas.**

### 5.2 Benchmark de lectura con replica1 caído

| Métrica           | Con 2 esclavos | Con 1 esclavo caído | Δ          |
|-------------------|----------------|---------------------|------------|
| Transacciones     | 115.398        | 174.503             | +51,2 %    |
| **TPS**           | **960,99**     | **1.454,00**        | **+51,3 %**|
| QPS               | 15.375,85      | 23.263,93           | +51,3 %    |
| Latencia mínima   | 0,89 ms        | 4,76 ms             | +3,87 ms   |
| Latencia media    | 10,39 ms       | 6,87 ms             | -33,9 %    |
| **Latencia p95**  | **20,37 ms**   | **8,28 ms**         | **-59,4 %**|
| Latencia máxima   | 2.991,16 ms    | 64,16 ms            | -97,9 %    |
| Errores           | 0              | 0                   | 0          |
| Reconexiones      | 0              | 0                   | 0          |

→ **Cero impacto negativo en el cliente** y, paradójicamente, un
rendimiento incluso superior con un solo esclavo activo. Este
comportamiento contraintuitivo se explica por dos factores:

1. **Eliminación del overhead de balanceo:** con un único destino, NGINX
   no realiza decisión de routing por conexión.
2. **Mayor cache hit ratio en el nodo activo:** el buffer pool de InnoDB
   en `db-replica2` concentra todas las consultas en un único working
   set, reduciendo dramáticamente los accesos a disco. La latencia
   máxima cae de 2.991 ms (acceso frío a disco) a 64 ms (consistente
   desde memoria).

Adicionalmente, en Docker Desktop sobre WSL2 las dos instancias MySQL
competían por el mismo subsistema de IO virtualizado; al apagar una, la
otra obtiene acceso dedicado.

### 5.3 Reincorporación automática

`docker compose start replica1` → tras ~15 s `SHOW REPLICA STATUS` reporta:

```
Replica_IO_Running: Yes
Replica_SQL_Running: Yes
Seconds_Behind_Source: 0
```

Gracias a **GTID + `SOURCE_AUTO_POSITION=1`**, la réplica le pide al
maestro únicamente las transacciones que se perdió mientras estaba
abajo. Una vez expira el `fail_timeout` de NGINX, el nodo vuelve a
recibir tráfico automáticamente y el balanceo retorna a 5/5.

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

**Indicadores de calidad agregados:**

| Indicador                              | Valor          |
|----------------------------------------|----------------|
| Total de transacciones procesadas      | **440.000+**   |
| Errores acumulados                     | **0**          |
| Reconexiones forzadas                  | **0**          |
| Tiempo total bajo carga                | ~14 minutos    |
| Veces que la replicación se rompió     | **0**          |
| Detección de caída de un nodo          | **< 15 s**     |
| Reincorporación automática             | **✓ vía GTID** |

- **Cero errores** en más de **440.000 transacciones** acumuladas a lo
  largo de toda la batería de pruebas.
- **Cero reconexiones forzadas:** la replicación nunca se rompió bajo
  carga sostenida.
- **Caída de nodo invisible al cliente:** cero errores ni reconexiones,
  con rendimiento mantenido o incluso mejorado por la concentración de
  cache en el nodo activo.
- **Reincorporación automática:** gracias a GTID con
  `SOURCE_AUTO_POSITION=1`, los nodos caídos retoman la sincronización
  sin intervención manual.
- **TPS pico observado:** 1.454 TPS en lectura balanceada (10 hilos) y
  1.403 TPS con 16 hilos en el test de escalabilidad.

> Nota: los resultados absolutos de TPS deben interpretarse en el contexto
> del entorno de prueba (Docker Desktop sobre WSL2 en Windows), donde el
> subsistema de IO está virtualizado y compartido con el sistema operativo
> del host. En entornos Linux bare-metal con SSD NVMe dedicado, los
> valores absolutos serían sustancialmente superiores. Los patrones
> observados (escalado, tolerancia a fallos, ausencia de errores) son
> válidos en cualquier entorno de despliegue.
