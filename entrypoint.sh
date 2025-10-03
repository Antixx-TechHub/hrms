#!/bin/bash
set -euo pipefail

echo "==== BOOT 1/9 :: ENV + PATH ===="
export PATH="/home/frappe/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
echo "USER=$(whoami)  SHELL=$SHELL  PWD=$(pwd)"
echo "PORT=${PORT:-unset}"

BENCH_DIR="/home/frappe/frappe-bench"
BENCH="/home/frappe/.local/bin/bench"

# ---- MariaDB via PUBLIC TCP (your verified root) ----
DB_HOST="trolley.proxy.rlwy.net"
DB_PORT="51999"
DB_ROOT_USER="root"
DB_ROOT_PASS="CYI-Vi3_B_4Ndf7C1e3.usRHOuU_zkRU"
DB_NAME="${DB_NAME:-ath_hrms}"

# ---- Redis via PUBLIC TCP ----
REDIS_HOST="nozomi.proxy.rlwy.net"
REDIS_PORT="46645"
REDIS_URI="redis://default:TUwUwNxPhXtoaysMLvnyssapQWtRbGpz@${REDIS_HOST}:${REDIS_PORT}"

SITE="hrms.localhost"
ADMIN_PASSWORD="admin"
PUBLIC_URL="https://overflowing-harmony-production.up.railway.app"

NGINX_PORT="${PORT:-8080}"
WEB_PORT=8001

runf(){ su -s /bin/bash -c "cd ${BENCH_DIR} && $*" frappe; }
b(){ runf "${BENCH} $*"; }
bs(){ runf "${BENCH} --site ${SITE} $*"; }

echo "==== BOOT 2/9 :: VERIFY BINARIES ===="
command -v ${BENCH} || { echo "ERROR: bench missing"; exit 90; }
command -v mysqladmin || { echo "ERROR: mysqladmin missing"; exit 91; }
command -v node || { echo "ERROR: node missing"; exit 92; }
command -v nginx || { echo "WARN: nginx wrapper missing, using /usr/sbin/nginx"; }

echo "==== BOOT 3/9 :: SHOW BENCH DIR ===="
ls -la /home/frappe || true
ls -la ${BENCH_DIR} || true

echo "==== BOOT 4/9 :: DB REACHABILITY ===="
echo "Resolving ${DB_HOST}…"; getent hosts "${DB_HOST}" || true
echo "Pinging MariaDB ${DB_HOST}:${DB_PORT} with mysqladmin…"
try=0
until mysqladmin --protocol=tcp -h "${DB_HOST}" -P "${DB_PORT}" \
  -u "${DB_ROOT_USER}" -p"${DB_ROOT_PASS}" --connect-timeout=5 ping >/dev/null 2>&1; do
  try=$((try+1))
  echo "[${try}] waiting for MariaDB…"
  sleep 2
  if [ "$try" -ge 20 ]; then
    echo "ERROR: DB not reachable/auth failed"; exit 10
  fi
done
echo "Ensuring database ${DB_NAME} exists…"
mysql --protocol=tcp -h "${DB_HOST}" -P "${DB_PORT}" \
  -u "${DB_ROOT_USER}" -p"${DB_ROOT_PASS}" \
  -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;"

echo "==== BOOT 5/9 :: BENCH CONFIG ===="
echo "Configuring Redis/DB into common_site_config.json…"
b set-redis-cache-host    "${REDIS_URI}" || true
b set-redis-queue-host    "${REDIS_URI}" || true
b set-redis-socketio-host "${REDIS_URI}" || true
b set-config -g db_host "${DB_HOST}"
b set-config -g db_port "${DB_PORT}"
b set-config -g webserver_port "${WEB_PORT}"

echo "==== BOOT 6/9 :: SITE CHECK/CREATE ===="
echo "Existing sites folder contents:"; ls -la ${BENCH_DIR}/sites || true
if ! b --site "${SITE}" version >/dev/null 2>&1; then
  echo "Creating site ${SITE} on DB ${DB_NAME}…"
  set -x
  ${BENCH} new-site "${SITE}" \
    --admin-password "${ADMIN_PASSWORD}" \
    --db-name "${DB_NAME}" \
    --db-host "${DB_HOST}" --db-port "${DB_PORT}" \
    --db-root-username "${DB_ROOT_USER}" --db-root-password "${DB_ROOT_PASS}" \
    --no-mariadb-socket
  ${BENCH} --site "${SITE}" install-app erpnext hrms
  ${BENCH} --site "${SITE}" enable-scheduler
  ${BENCH} --site "${SITE}" clear-cache
  set +x
else
  echo "Site ${SITE} already exists."
fi
echo "Sites now:"; ls -la ${BENCH_DIR}/sites; ls -la ${BENCH_DIR}/sites/${SITE} || true
b "use ${SITE}"
b set-config -g default_site "${SITE}"
bs "set-config host_name '${PUBLIC_URL}'"

echo "==== BOOT 7/9 :: NGINX WRITE/START ===="
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
echo "Nginx conf listen lines:"; grep -n 'listen' /etc/nginx/conf.d/frappe.conf || true
/usr/sbin/nginx -g "daemon on;"

echo "==== BOOT 8/9 :: START SERVICES ===="
echo "Starting: web:${WEB_PORT}, worker, schedule, socketio…"
bs "serve --port ${WEB_PORT}" &
bs "worker" &
bs "schedule" &
runf "node apps/frappe/socketio.js" &

echo "==== BOOT 9/9 :: READY ===="
echo "URL: ${PUBLIC_URL}  | default_site=${SITE}  | web_port=${WEB_PORT}  | nginx_port=${NGINX_PORT}"
wait -n
