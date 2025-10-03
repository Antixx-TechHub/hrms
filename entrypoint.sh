#!/bin/bash
set -euo pipefail

BENCH_DIR="/home/frappe/frappe-bench"
BENCH_BIN="/home/frappe/.local/bin/bench"

# --- Railway public MariaDB (your verified root creds) ---
DB_HOST="trolley.proxy.rlwy.net"
DB_PORT="51999"
DB_ROOT_USER="root"
DB_ROOT_PASS="CYI-Vi3_B_4Ndf7C1e3.usRHOuU_zkRU"
DB_NAME="${DB_NAME:-railway}"   # change if you want a fresh DB

# --- Railway public Redis ---
REDIS_HOST="nozomi.proxy.rlwy.net"
REDIS_PORT="46645"
REDIS_USER="default"
REDIS_PASS="TUwUwNxPhXtoaysMLvnyssapQWtRbGpz"

SITE="hrms.localhost"
ADMIN_PASSWORD="admin"
PUBLIC_URL="https://overflowing-harmony-production.up.railway.app"

PORT="${PORT:-8080}"     # nginx listen
BENCH_WEB_PORT=8001      # Frappe dev server

# --- helpers (always run in bench dir as frappe) ---
runf(){ su -s /bin/bash -c "cd ${BENCH_DIR} && $*" frappe; }
bench(){ runf "${BENCH_BIN} $*"; }
bench_site(){ runf "${BENCH_BIN} --site ${SITE} $*"; }

# --- prove DNS + reachability and fail fast with clear error ---
echo "Resolving ${DB_HOST}..."
getent hosts "${DB_HOST}" || { echo "ERROR: DNS failed for ${DB_HOST}"; exit 2; }

echo "Pinging MariaDB via mysqladmin..."
until mysqladmin --protocol=tcp -h "${DB_HOST}" -P "${DB_PORT}" \
        -u "${DB_ROOT_USER}" -p"${DB_ROOT_PASS}" --connect-timeout=5 ping >/dev/null 2>&1; do
  echo "Waiting for MariaDB ${DB_HOST}:${DB_PORT}..."
  sleep 3
done

echo "Ensuring database ${DB_NAME} exists..."
mysql --protocol=tcp -h "${DB_HOST}" -P "${DB_PORT}" \
      -u "${DB_ROOT_USER}" -p"${DB_ROOT_PASS}" \
      -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;"

# --- bench dir ---
cd "${BENCH_DIR}"

# External Redis + DB config
REDIS_URI="redis://${REDIS_USER}:${REDIS_PASS}@${REDIS_HOST}:${REDIS_PORT}"
bench set-redis-cache-host    "${REDIS_URI}" || true
bench set-redis-queue-host    "${REDIS_URI}" || true
bench set-redis-socketio-host "${REDIS_URI}" || true
bench set-config -g db_host "${DB_HOST}"
bench set-config -g db_port "${DB_PORT}"
bench set-config -g webserver_port "${BENCH_WEB_PORT}"

# Create site once
if ! bench --site "${SITE}" version >/dev/null 2>&1; then
  echo "Creating site ${SITE} on DB ${DB_NAME}"
  bench new-site "${SITE}" \
    --force \
    --admin-password "${ADMIN_PASSWORD}" \
    --db-name "${DB_NAME}" \
    --db-host "${DB_HOST}" \
    --db-port "${DB_PORT}" \
    --db-root-username "${DB_ROOT_USER}" \
    --db-root-password "${DB_ROOT_PASS}" \
    --no-mariadb-socket
  bench_site "install-app erpnext hrms"
  bench_site "enable-scheduler"
  bench_site "clear-cache"
fi
bench "use ${SITE}"

# Host routing so /login works on Railway URL
bench set-config -g default_site "${SITE}"
bench_site "set-config host_name '${PUBLIC_URL}'"

# Nginx on $PORT -> Frappe 8001 and SocketIO 9000
rm -f /etc/nginx/conf.d/* /etc/nginx/sites-enabled/* || true
cat >/etc/nginx/conf.d/frappe.conf <<EOF
server {
    listen ${PORT} default_server reuseport;
    listen [::]:${PORT} default_server;

    location / {
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass http://127.0.0.1:${BENCH_WEB_PORT};
    }

    location /socket.io/ {
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_pass http://127.0.0.1:9000/socket.io/;
    }
}
EOF
/usr/sbin/nginx -g "daemon on;"

# Run processes directly (no honcho)
bench_site "serve --port ${BENCH_WEB_PORT}" &
bench_site "worker" &
bench_site "schedule" &
runf "node apps/frappe/socketio.js" &

wait -n
