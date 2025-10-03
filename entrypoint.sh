#!/bin/bash
set -euo pipefail

BENCH_DIR="/home/frappe/frappe-bench"
BENCH="/home/frappe/.local/bin/bench"

# --- Public MariaDB (works from your tests) ---
DB_HOST="trolley.proxy.rlwy.net"; DB_PORT="51999"
DB_ROOT_USER="root"; DB_ROOT_PASS="CYI-Vi3_B_4Ndf7C1e3.usRHOuU_zkRU"
DB_NAME="railway"
DB_APP_USER="railway"; DB_APP_PASS="hfxKFQNoMagViYHTotVOpsbiQ4Rzg_l-"

# --- Redis (public) ---
REDIS_URI="redis://default:TUwUwNxPhXtoaysMLvnyssapQWtRbGpz@nozomi.proxy.rlwy.net:46645"

SITE="hrms.localhost"; ADMIN_PASSWORD="admin"
PUBLIC_URL="https://overflowing-harmony-production.up.railway.app"
NGINX_PORT="${PORT:-8080}"
WEB_PORT=8001

runf(){ su -s /bin/bash -c "cd ${BENCH_DIR} && $*" frappe; }
b(){ runf "${BENCH} $*"; }
bs(){ runf "${BENCH} --site ${SITE} $*"; }

echo "== DB ping =="
until mysqladmin --protocol=tcp -h "$DB_HOST" -P "$DB_PORT" -u "$DB_ROOT_USER" -p"$DB_ROOT_PASS" ping >/dev/null 2>&1; do
  echo "Waiting for MariaDB ${DB_HOST}:${DB_PORT}..."; sleep 2
done

echo "== Ensure DB and app user =="
mysql --protocol=tcp -h "$DB_HOST" -P "$DB_PORT" -u "$DB_ROOT_USER" -p"$DB_ROOT_PASS" <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;
CREATE USER IF NOT EXISTS '${DB_APP_USER}'@'%' IDENTIFIED BY '${DB_APP_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_APP_USER}'@'%';
FLUSH PRIVILEGES;
SQL

echo "== Bench config =="
cd "${BENCH_DIR}"
b set-redis-cache-host    "${REDIS_URI}" || true
b set-redis-queue-host    "${REDIS_URI}" || true
b set-redis-socketio-host "${REDIS_URI}" || true
b set-config -g db_host "${DB_HOST}"
b set-config -g db_port "${DB_PORT}"
b set-config -g webserver_port "${WEB_PORT}"

SITE_DIR="${BENCH_DIR}/sites/${SITE}"
echo "== Ensure site directory =="
if [ ! -d "${SITE_DIR}" ]; then
  echo "Creating site ${SITE} on DB ${DB_NAME} as ${DB_APP_USER}"
  ${BENCH} new-site "${SITE}" \
    --admin-password "${ADMIN_PASSWORD}" \
    --db-name "${DB_NAME}" \
    --db-host "${DB_HOST}" --db-port "${DB_PORT}" \
    --db-username "${DB_APP_USER}" --db-password "${DB_APP_PASS}" \
    --no-mariadb-socket
  ${BENCH} --site "${SITE}" install-app erpnext hrms
  ${BENCH} --site "${SITE}" enable-scheduler
  ${BENCH} --site "${SITE}" clear-cache
fi
test -f "${SITE_DIR}/site_config.json"

b "use ${SITE}"
b set-config -g default_site "${SITE}"
bs "set-config host_name '${PUBLIC_URL}'"

echo "== Nginx =="
rm -f /etc/nginx/conf.d/* /etc/nginx/sites-enabled/* || true
cat >/etc/nginx/conf.d/frappe.conf <<EOF
server {
  listen ${NGINX_PORT} default_server reuseport;
  listen [::]:${NGINX_PORT} default_server;
  location / {
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_pass http://127.0.0.1:${WEB_PORT};
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

echo "== Start services =="
bs "serve --port ${WEB_PORT}" &
bs "worker" &
bs "schedule" &
runf "node apps/frappe/socketio.js" &
wait -n
