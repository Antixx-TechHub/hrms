#!/bin/bash
set -euo pipefail

echo "==== BOOT 1/8 :: ENV ===="
export PATH="/home/frappe/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
BENCH_DIR="/home/frappe/frappe-bench"
BENCH="/home/frappe/.local/bin/bench"
SITE="hrms.localhost"
SITE_DIR="${BENCH_DIR}/sites/${SITE}"
PUBLIC_URL="https://overflowing-harmony-production.up.railway.app"
NGINX_PORT="${PORT:-8080}"
WEB_PORT=8001

# DB (public TCP) + Redis (public TCP)
DB_HOST="trolley.proxy.rlwy.net"; DB_PORT="51999"
DB_ROOT_USER="root"; DB_ROOT_PASS="CYI-Vi3_B_4Ndf7C1e3.usRHOuU_zkRU"
DB_NAME="${DB_NAME:-way}"
REDIS_URI="redis://default:TUwUwNxPhXtoaysMLvnyssapQWtRbGpz@nozomi.proxy.rlwy.net:46645"

runf(){ su -s /bin/bash -c "cd ${BENCH_DIR} && $*" frappe; }
b(){ runf "${BENCH} $*"; }
bs(){ runf "${BENCH} --site ${SITE} $*"; }

echo "==== BOOT 2/8 :: VERIFY ===="
command -v ${BENCH} && command -v mysqladmin && command -v node && command -v nginx || { echo "missing bin"; exit 90; }
ls -la "${BENCH_DIR}"

echo "==== BOOT 3/8 :: DB READY ===="
getent hosts "${DB_HOST}" || { echo "DNS fail ${DB_HOST}"; exit 10; }
until mysqladmin --protocol=tcp -h "$DB_HOST" -P "$DB_PORT" -u "$DB_ROOT_USER" -p"$DB_ROOT_PASS" ping >/dev/null 2>&1; do
  echo "Waiting for MariaDB ${DB_HOST}:${DB_PORT}..."
  sleep 2
done
mysql --protocol=tcp -h "$DB_HOST" -P "$DB_PORT" -u "$DB_ROOT_USER" -p"$DB_ROOT_PASS" \
  -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;"

echo "==== BOOT 4/8 :: BENCH CONFIG ===="
b set-redis-cache-host    "$REDIS_URI" || true
b set-redis-queue-host    "$REDIS_URI" || true
b set-redis-socketio-host "$REDIS_URI" || true
b set-config -g db_host "$DB_HOST"
b set-config -g db_port "$DB_PORT"
b set-config -g webserver_port "$WEB_PORT"

echo "==== BOOT 5/8 :: SITE ENSURE ===="
echo "Sites folder:"; ls -la "${BENCH_DIR}/sites" || true
if [ ! -d "${SITE_DIR}" ]; then
  echo "Creating site folder ${SITE_DIR} (fresh new-site)..."
  set -x
  ${BENCH} new-site "${SITE}" \
    --admin-password "admin" \
    --db-name "${DB_NAME}" \
    --db-host "${DB_HOST}" --db-port "${DB_PORT}" \
    --db-root-username "${DB_ROOT_USER}" --db-root-password "${DB_ROOT_PASS}" \
    --no-mariadb-socket
  ${BENCH} --site "${SITE}" install-app erpnext hrms
  ${BENCH} --site "${SITE}" enable-scheduler
  ${BENCH} --site "${SITE}" clear-cache
  set +x
else
  echo "Site directory already present: ${SITE_DIR}"
fi
test -f "${SITE_DIR}/site_config.json" || { echo "FATAL: site_config.json missing after new-site"; exit 11; }
b "use ${SITE}"
b set-config -g default_site "${SITE}"
bs "set-config host_name '${PUBLIC_URL}'"

echo "==== BOOT 6/8 :: NGINX ===="
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

echo "==== BOOT 7/8 :: START ===="
bs "serve --port ${WEB_PORT}" &
bs "worker" &
bs "schedule" &
runf "node apps/frappe/socketio.js" &

echo "==== BOOT 8/8 :: READY ===="
echo "URL=${PUBLIC_URL} site=${SITE} site_dir=${SITE_DIR} web=${WEB_PORT} nginx=${NGINX_PORT}"
wait -n
