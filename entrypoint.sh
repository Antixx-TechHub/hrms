#!/bin/bash
set -euo pipefail
set -x  # verbose so we see the actual error

BENCH_DIR="/home/frappe/frappe-bench"
BENCH_BIN="/home/frappe/.local/bin/bench"

# Use Railway PRIVATE DB inside Railway
DB_HOST="mariadb.railway.internal"; DB_PORT="3306"
DB_ROOT_USER="root"; DB_ROOT_PASS="CYI-Vi3_B_4Ndf7C1e3.usRHOuU_zkRU"
DB_NAME="${DB_NAME:-hrms_${RAILWAY_SERVICE_ID:-$(date +%s)}}"

REDIS_HOST="nozomi.proxy.rlwy.net"; REDIS_PORT="46645"
REDIS_USER="default"; REDIS_PASS="TUwUwNxPhXtoaysMLvnyssapQWtRbGpz"

SITE="hrms.localhost"; ADMIN_PASSWORD="admin"
PUBLIC_URL="https://overflowing-harmony-production.up.railway.app"
PORT="${PORT:-8080}"
BENCH_WEB_PORT=8001

wait_tcp(){ timeout 20 bash -c "</dev/tcp/$1/$2" >/dev/null 2>&1; }
runf(){ su -s /bin/bash -c "cd ${BENCH_DIR} && $*" frappe; }
bench(){ runf "${BENCH_BIN} $*"; }
bench_site(){ runf "${BENCH_BIN} --site ${SITE} $*"; }

cd "${BENCH_DIR}"

# External Redis/DB wiring
REDIS_URI="redis://${REDIS_USER}:${REDIS_PASS}@${REDIS_HOST}:${REDIS_PORT}"
bench set-redis-cache-host    "${REDIS_URI}" || true
bench set-redis-queue-host    "${REDIS_URI}" || true
bench set-redis-socketio-host "${REDIS_URI}" || true
bench set-config -g db_host "${DB_HOST}"
bench set-config -g db_port "${DB_PORT}"
bench set-config -g webserver_port "${BENCH_WEB_PORT}"

echo "Waiting for MariaDB ${DB_HOST}:${DB_PORT}..."; until wait_tcp "$DB_HOST" "$DB_PORT"; do sleep 2; done
echo "Waiting for Redis ${REDIS_HOST}:${REDIS_PORT}..."; until wait_tcp "$REDIS_HOST" "$REDIS_PORT"; do sleep 2; done

# Sanity: prove DB auth and pre-create DB
mysql -h "${DB_HOST}" -P "${DB_PORT}" -u "${DB_ROOT_USER}" -p"${DB_ROOT_PASS}" \
  -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;"

# Site creation (show full output, fail on error)
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

# Route host -> site
bench set-config -g default_site "${SITE}"
bench_site "set-config host_name '${PUBLIC_URL}'"

# Nginx (listen $PORT, proxy to 8001/9000)
rm -f /etc/nginx/conf.d/* /etc/nginx/sites-enabled/* || true
cat >/etc/nginx/conf.d/frappe.conf <<EOF
server {
    listen ${PORT} default_server reuseport;
    listen [::]:${PORT} default_server;
    location / { proxy_set_header Host \$host; proxy_pass http://127.0.0.1:${BENCH_WEB_PORT}; }
    location /socket.io/ { proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host \$host; proxy_pass http://127.0.0.1:9000/socket.io/; }
}
EOF
/usr/sbin/nginx -g "daemon on;"

# Run services manually (correct CLI order)
bench_site "serve --port ${BENCH_WEB_PORT}" &
bench_site "worker" &
bench_site "schedule" &
runf "node apps/frappe/socketio.js" &

wait -n
