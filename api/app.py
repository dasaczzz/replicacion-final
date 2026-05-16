"""
API REST para el proyecto de Servicios Telemáticos:
Balanceo de carga MySQL + Replicación + Sysbench.

Expone endpoints para verificar replicación, balanceo de lectura
y ejecutar benchmarks Sysbench desde una interfaz HTTP.
"""

from flask import Flask, jsonify, request
from flask_cors import CORS
import mysql.connector
import subprocess
import os
import threading
import time

app = Flask(__name__)
CORS(app)

# ──────────────────────────────────────────────
# Configuración de conexión (variables de entorno)
# ──────────────────────────────────────────────
DB_HOST_WRITE  = os.getenv("DB_HOST_WRITE",  "db-nginx")
DB_HOST_READ   = os.getenv("DB_HOST_READ",   "db-nginx")
DB_PORT_WRITE  = int(os.getenv("DB_PORT_WRITE", 3306))
DB_PORT_READ   = int(os.getenv("DB_PORT_READ",  3307))
DB_USER        = os.getenv("DB_USER",        "user")
DB_PASSWORD    = os.getenv("DB_PASSWORD",    "password")
DB_ROOT_PASS   = os.getenv("DB_ROOT_PASSWORD", "rootpassword")
DB_NAME        = os.getenv("DB_NAME",        "replicacion")

NODES = [
    {"host": "db-source",   "port": 3306, "role": "maestro"},
    {"host": "db-replica1", "port": 3306, "role": "esclavo"},
    {"host": "db-replica2", "port": 3306, "role": "esclavo"},
]

# Estado en memoria del último benchmark
benchmark_status = {"running": False, "result": None, "error": None}


def get_conn(host, port, user=DB_USER, password=DB_PASSWORD, database=None):
    """Abre una conexión MySQL y la retorna."""
    kwargs = dict(host=host, port=port, user=user, password=password,
                  connection_timeout=5)
    if database:
        kwargs["database"] = database
    return mysql.connector.connect(**kwargs)


# ══════════════════════════════════════════════
# 1. Rutas principales
# ══════════════════════════════════════════════
@app.route("/", methods=["GET"])
@app.route("/api", methods=["GET"])
def api_info():
    return jsonify({
        "proyecto": "Balanceo de carga MySQL con NGINX stream",
        "version": "1.0.0",
        "ui": "http://localhost:5000/",
        "endpoints": [
            "GET  /health", "GET  /replication", "GET  /balance",
            "GET  /nodes", "GET  /data/users", "GET  /data/posts",
            "POST /sysbench/prepare", "POST /sysbench/run-read",
            "POST /sysbench/run-mixed", "GET  /sysbench/status",
        ]
    })


# ══════════════════════════════════════════════
# 2. Health check de los 3 nodos
# ══════════════════════════════════════════════
@app.route("/health", methods=["GET"])
def health():
    results = []
    for node in NODES:
        try:
            conn = get_conn(node["host"], node["port"])
            cur = conn.cursor()
            cur.execute("SELECT @@hostname, @@version, @@read_only;")
            row = cur.fetchone()
            conn.close()
            results.append({
                "node":      node["host"],
                "role":      node["role"],
                "status":    "UP",
                "hostname":  row[0],
                "version":   row[1],
                "read_only": bool(row[2]),
            })
        except Exception as e:
            results.append({
                "node":   node["host"],
                "role":   node["role"],
                "status": "DOWN",
                "error":  str(e),
            })

    all_up = all(r["status"] == "UP" for r in results)
    return jsonify({"cluster_ok": all_up, "nodes": results}), (200 if all_up else 207)


# ══════════════════════════════════════════════
# 3. Estado de replicación
# ══════════════════════════════════════════════
@app.route("/replication", methods=["GET"])
def replication():
    replicas = [n for n in NODES if n["role"] == "esclavo"]
    report = []
    for node in replicas:
        try:
            conn = get_conn(node["host"], node["port"],
                            user="root", password=DB_ROOT_PASS)
            cur = conn.cursor(dictionary=True)
            cur.execute("SHOW REPLICA STATUS;")
            row = cur.fetchone()
            conn.close()
            if row:
                report.append({
                    "node":                node["host"],
                    "source_host":         row.get("Source_Host"),
                    "replica_io_running":  row.get("Replica_IO_Running"),
                    "replica_sql_running": row.get("Replica_SQL_Running"),
                    "seconds_behind":      row.get("Seconds_Behind_Source"),
                    "source_ssl_allowed":  row.get("Source_SSL_Allowed"),
                    "last_io_error":       row.get("Last_IO_Error") or "none",
                    "last_sql_error":      row.get("Last_SQL_Error") or "none",
                    "gtid_received":       row.get("Retrieved_Gtid_Set"),
                    "gtid_executed":       row.get("Executed_Gtid_Set"),
                    "replication_ok": (
                        row.get("Replica_IO_Running") == "Yes" and
                        row.get("Replica_SQL_Running") == "Yes"
                    ),
                })
            else:
                report.append({"node": node["host"], "error": "No replica status"})
        except Exception as e:
            report.append({"node": node["host"], "error": str(e)})

    all_synced = all(r.get("replication_ok") for r in report)
    return jsonify({"all_replicas_synced": all_synced, "replicas": report})


# ══════════════════════════════════════════════
# 4. Demostración de balanceo de lecturas
# ══════════════════════════════════════════════
@app.route("/balance", methods=["GET"])
def balance():
    n = int(request.args.get("n", 10))
    connections = []
    for i in range(1, n + 1):
        try:
            conn = get_conn(DB_HOST_READ, DB_PORT_READ)
            cur = conn.cursor()
            cur.execute("SELECT @@hostname;")
            hostname = cur.fetchone()[0]
            conn.close()
            connections.append({"connection": i, "served_by": hostname})
        except Exception as e:
            connections.append({"connection": i, "error": str(e)})

    # Conteo por nodo
    from collections import Counter
    counts = Counter(c.get("served_by", "error") for c in connections)
    return jsonify({
        "total_connections": n,
        "distribution":      dict(counts),
        "connections":       connections,
    })


# ══════════════════════════════════════════════
# 5. Hostname de cada nodo (verifica lectura directa)
# ══════════════════════════════════════════════
@app.route("/nodes", methods=["GET"])
def nodes():
    result = []
    for node in NODES:
        try:
            conn = get_conn(node["host"], node["port"])
            cur = conn.cursor()
            cur.execute("SELECT @@hostname, @@server_id;")
            row = cur.fetchone()
            conn.close()
            result.append({
                "node":      node["host"],
                "role":      node["role"],
                "hostname":  row[0],
                "server_id": row[1],
            })
        except Exception as e:
            result.append({"node": node["host"], "error": str(e)})
    return jsonify(result)


# ══════════════════════════════════════════════
# 6. Datos replicados — Usuarios
# ══════════════════════════════════════════════
@app.route("/data/users", methods=["GET"])
def data_users():
    source = request.args.get("source", "read")  # "read" o "write"
    host = DB_HOST_READ if source == "read" else DB_HOST_WRITE
    port = DB_PORT_READ  if source == "read" else DB_PORT_WRITE
    try:
        conn = get_conn(host, port, database=DB_NAME)
        cur = conn.cursor(dictionary=True)
        cur.execute(
            "SELECT HEX(id) AS id, username, email, profilePicture, createdAt "
            "FROM User ORDER BY createdAt DESC LIMIT 50;"
        )
        rows = cur.fetchall()
        conn.close()
        return jsonify({
            "source":        f"{host}:{port}",
            "total_returned": len(rows),
            "users":          rows
        })
    except Exception as e:
        return jsonify({"error": str(e)}), 500


# ══════════════════════════════════════════════
# 7. Datos replicados — Posts
# ══════════════════════════════════════════════
@app.route("/data/posts", methods=["GET"])
def data_posts():
    source = request.args.get("source", "read")
    host = DB_HOST_READ if source == "read" else DB_HOST_WRITE
    port = DB_PORT_READ  if source == "read" else DB_PORT_WRITE
    try:
        conn = get_conn(host, port, database=DB_NAME)
        cur = conn.cursor(dictionary=True)
        cur.execute(
            "SELECT HEX(p.id) AS id, p.text, p.deadline, p.isPublic, p.isActive, "
            "       u.username AS author "
            "FROM Post p JOIN User u ON p.idUser = u.id "
            "ORDER BY p.createdAt DESC LIMIT 50;"
        )
        rows = cur.fetchall()
        conn.close()
        return jsonify({
            "source":         f"{host}:{port}",
            "total_returned": len(rows),
            "posts":          rows
        })
    except Exception as e:
        return jsonify({"error": str(e)}), 500


# ══════════════════════════════════════════════
# 8. Sysbench — helpers internos
# ══════════════════════════════════════════════
def _run_sysbench_async(script_name, extra_env=None):
    """Ejecuta un script Sysbench en segundo plano y guarda el resultado."""
    global benchmark_status
    benchmark_status = {"running": True, "result": None, "error": None}

    env = {
        "HOST":     DB_HOST_WRITE,
        "PORT":     str(DB_PORT_WRITE),
        "USER":     DB_USER,
        "PASS":     DB_PASSWORD,
        "DB":       "sbtest",
        "TABLES":   "1",
        "ROWS":     "1000000",
        "THREADS":  "10",
        "TIME":     "60",
        **os.environ,
        **(extra_env or {}),
    }

    try:
        proc = subprocess.run(
            ["bash", f"/scripts/{script_name}"],
            capture_output=True, text=True, env=env, timeout=600
        )
        benchmark_status = {
            "running":  False,
            "result":   proc.stdout,
            "error":    proc.stderr if proc.returncode != 0 else None,
            "exit_code": proc.returncode,
        }
    except subprocess.TimeoutExpired:
        benchmark_status = {"running": False, "result": None, "error": "Timeout (600s)"}
    except Exception as e:
        benchmark_status = {"running": False, "result": None, "error": str(e)}


# ══════════════════════════════════════════════
# 9. Sysbench — preparar dataset
# ══════════════════════════════════════════════
@app.route("/sysbench/prepare", methods=["POST"])
def sysbench_prepare():
    if benchmark_status["running"]:
        return jsonify({"error": "Ya hay un benchmark en ejecución"}), 409
    rows   = request.json.get("rows",   1_000_000) if request.json else 1_000_000
    tables = request.json.get("tables", 1)          if request.json else 1
    t = threading.Thread(
        target=_run_sysbench_async,
        args=("prepare.sh", {"ROWS": str(rows), "TABLES": str(tables)}),
        daemon=True,
    )
    t.start()
    return jsonify({
        "message": "Preparando dataset Sysbench en segundo plano",
        "rows":    rows,
        "tables":  tables,
        "status_endpoint": "/sysbench/status",
    }), 202


# ══════════════════════════════════════════════
# 10. Sysbench — benchmark solo lectura
# ══════════════════════════════════════════════
@app.route("/sysbench/run-read", methods=["POST"])
def sysbench_run_read():
    if benchmark_status["running"]:
        return jsonify({"error": "Ya hay un benchmark en ejecución"}), 409
    body    = request.json or {}
    threads = str(body.get("threads", 10))
    time_s  = str(body.get("time",    60))
    t = threading.Thread(
        target=_run_sysbench_async,
        args=("run-read.sh", {
            "HOST":    DB_HOST_READ,
            "PORT":    str(DB_PORT_READ),
            "THREADS": threads,
            "TIME":    time_s,
        }),
        daemon=True,
    )
    t.start()
    return jsonify({
        "message": "Benchmark solo-lectura iniciado",
        "threads": threads,
        "time_s":  time_s,
        "target":  f"{DB_HOST_READ}:{DB_PORT_READ} (esclavos)",
        "status_endpoint": "/sysbench/status",
    }), 202


# ══════════════════════════════════════════════
# 11. Sysbench — benchmark mixto
# ══════════════════════════════════════════════
@app.route("/sysbench/run-mixed", methods=["POST"])
def sysbench_run_mixed():
    if benchmark_status["running"]:
        return jsonify({"error": "Ya hay un benchmark en ejecución"}), 409
    body    = request.json or {}
    threads = str(body.get("threads", 10))
    time_s  = str(body.get("time",    60))
    t = threading.Thread(
        target=_run_sysbench_async,
        args=("run-mixed.sh", {"THREADS": threads, "TIME": time_s}),
        daemon=True,
    )
    t.start()
    return jsonify({
        "message": "Benchmark mixto iniciado",
        "threads": threads,
        "time_s":  time_s,
        "target":  f"{DB_HOST_WRITE}:{DB_PORT_WRITE} (maestro)",
        "status_endpoint": "/sysbench/status",
    }), 202


# ══════════════════════════════════════════════
# 12. Estado del último benchmark
# ══════════════════════════════════════════════
@app.route("/sysbench/status", methods=["GET"])
def sysbench_status():
    return jsonify(benchmark_status)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=False)
