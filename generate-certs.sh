#!/bin/sh
# Genera certificados TLS para la replicacion MySQL.
# Idempotente: si los certificados ya existen, no hace nada.
# Pensado para correr dentro de una imagen alpine con openssl instalado.

set -e

CERT_DIR="${CERT_DIR:-/certs}"
DAYS="${DAYS:-3650}"

mkdir -p "${CERT_DIR}"
cd "${CERT_DIR}"

if [ -f ca.pem ] && [ -f server-cert.pem ] && [ -f client-cert.pem ]; then
  echo ">> Certificados ya existen en ${CERT_DIR}, no se regeneran."
  exit 0
fi

echo ">> Generando certificados TLS en ${CERT_DIR}..."

# --- CA ---
openssl genrsa -out ca-key.pem 2048
openssl req -new -x509 -nodes -days "${DAYS}" \
  -key ca-key.pem \
  -subj "/CN=MySQL-Replication-CA" \
  -out ca.pem

# --- Server (maestro) ---
openssl req -newkey rsa:2048 -nodes -days "${DAYS}" \
  -keyout server-key.pem \
  -subj "/CN=db-source" \
  -out server-req.pem
openssl rsa -in server-key.pem -out server-key.pem
openssl x509 -req -in server-req.pem -days "${DAYS}" \
  -CA ca.pem -CAkey ca-key.pem -set_serial 01 \
  -out server-cert.pem

# --- Client (replicas) ---
openssl req -newkey rsa:2048 -nodes -days "${DAYS}" \
  -keyout client-key.pem \
  -subj "/CN=db-replica" \
  -out client-req.pem
openssl rsa -in client-key.pem -out client-key.pem
openssl x509 -req -in client-req.pem -days "${DAYS}" \
  -CA ca.pem -CAkey ca-key.pem -set_serial 02 \
  -out client-cert.pem

# Limpieza
rm -f server-req.pem client-req.pem

# Permisos que MySQL acepta (no demasiado abiertos)
chmod 644 *.pem
chmod 600 *-key.pem

# MySQL corre como uid 999 dentro del contenedor; permitirle leer
chown -R 999:999 "${CERT_DIR}" 2>/dev/null || true

echo ">> Certificados generados correctamente:"
ls -la "${CERT_DIR}"
