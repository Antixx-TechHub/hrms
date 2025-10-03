#!/bin/bash
set -euo pipefail

BENCH_DIR="/home/frappe/frappe-bench"
BENCH="/home/frappe/.local/bin/bench"

# MariaDB via PUBLIC TCP (root works)
DB_HOST="trolley.proxy.rlwy.net"; DB_PORT="51999"
DB_ROOT_USER="root"; DB_ROOT_PASS="CYI-Vi3_B_4Ndf7C1e3.usRHOuU_zkRU"
DB_NAME="${DB_NAME:-railway}"

# Redis via PUBLIC TCP
REDIS_HOST="nozomi.proxy.rlwy.net"; REDIS_PORT="46645"
REDIS_URI="redis://default:TUwUwNxPhXtoaysMLvnyssapQWtRbGpz@${REDIS_HOST}:${REDIS_PORT}"

SITE="hrms.localhost"
ADMIN_PASSWORD="admin"
PUBLIC_URL="https://overflowing-harmony-production.up.railway.app"
PORT="${PORT:-8080}"
WEB_PORT=8001

runf(){ su -s /bin/bash -c "cd ${BENCH_DIR} && $*" frappe; }
b(){ runf "${BENCH} $*"; }
bs(){ runf "${BENCH} --site ${SITE} $*"; }

# 1) Prove DB and precreate schema
until mysqladmin --protocol=tcp -h "$DB_HOST" -P "$DB_PORT" -u "$DB_ROOT_USER" -p"$DB_ROOT_PASS" ping >/dev/null 2>&1; do
  echo "Waiting for MariaDB ${DB_HOST}:${DB_PORT}..."
  sleep 2
done
mysql --protocol=tcp -h "$DB_HOST" -P "$DB_PORT" -u "$DB_ROOT_USER" -p"$DB_ROOT_PASS" \
  -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;"

# 2) Bench config
runf "test -d ."
b set-redis-cache-host    "$REDIS_URI" || true
b set-redis-queue-host    "$REDIS_URI" || true
b set-redis-socketio-host "$REDIS_URI" || true
b set-config -g db_host "$DB_HOST"
b set-config -g db_port "$DB_PORT"
b set-config -g webserver_port "$WEB_PORT"

# 3) Ensure site exists (fail loud if new-site errors)
if ! b --site "$SITE" version >/dev/null 2>&1; then
  echo "Creating site ${SITE} on DB ${DB_NAME}..."
  runf "${BENCH} new-site '${SITE}' \
    --admin-password '${ADMIN_PASSWORD}' \
    --db-name '${DB_NAME}' \
    --db-host '${DB_HOST}' --db-port '${DB_PORT}' \
    --db-root-username '${DB_ROOT_USER}' --db-root-password '${DB_ROOT_PASS}' \
    --no-mariadb-socket" || { echo "new-site failed"; exit 1; }
  bs "install-app erpnext hrms"
  bs "enable-scheduler"
  bs "clear-cache"
fi
b "use ${SITE}"
b set-config -g default_site "${SITE}"
bs "set-config host_name '${PUBLIC_URL}'"

# 4) Nginx on $PORT -> Frappe 8001 / Socket.IO 9000
rm -f /etc/nginx/conf.d/* /etc/nginx/sites-enabled/* || true
cat >/etc/nginx/conf.d/frappe.conf <<EOF
server {
  listen ${PORT} default_server reuseport;
  listen [::]:${PORT} default_server;
  location / { proxy_set_header Host \$host; proxy_pass http://127.0.0.1:${WEB_PORT}; }
  location /socket.io/ {
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_pass http://127.0.0.1:9000/socket.io/;
  }
}
EOF
/usr/sbin/nginx -g "daemon on;"

# 5) Run services directly
bs "serve --port ${WEB_PORT}" &
bs "worker" &
bs "schedule" &
runf "node apps/frappe/socketio.js" &

wait -n
