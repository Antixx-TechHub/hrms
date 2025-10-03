#!/bin/bash
set -euo pipefail

BENCH_DIR="/home/frappe/frappe-bench"
BENCH="/home/frappe/.local/bin/bench"

# MariaDB via PUBLIC TCP (same as DBeaver)
DB_HOST="trolley.proxy.rlwy.net"
DB_PORT="51999"
DB_ROOT_USER="root"
DB_ROOT_PASS="CYI-Vi3_B_4Ndf7C1e3.usRHOuU_zkRU"
BASE_DB="railway"  # prefer this, or auto-suffix if taken

# Redis (public TCP)
REDIS_URI="redis://default:TUwUwNxPhXtoaysMLvnyssapQWtRbGpz@nozomi.proxy.rlwy.net:46645"

SITE="hrms.localhost"
ADMIN_PASSWORD="admin"
PUBLIC_URL="https://overflowing-harmony-production.up.railway.app"
NGINX_PORT="${PORT:-8080}"
WEB_PORT=8001

runf(){ su -s /bin/bash -c "cd ${BENCH_DIR} && $*" frappe; }
b(){ runf "${BENCH} $*"; }
bs(){ runf "${BENCH} --site ${SITE} $*"; }
mysql_q(){ mysql --protocol=tcp -h "$DB_HOST" -P "$DB_PORT" -u "$DB_ROOT_USER" -p"$DB_ROOT_PASS" -N -e "$1"; }

echo "== DB ping =="
until mysqladmin --protocol=tcp -h "$DB_HOST" -P "$DB_PORT" -u "$DB_ROOT_USER" -p"$DB_ROOT_PASS" ping >/dev/null 2>&1; do
  echo "Waiting for MariaDB ${DB_HOST}:${DB_PORT}..."; sleep 2
done

cd "${BENCH_DIR}"
b set-redis-cache-host    "${REDIS_URI}" || true
b set-redis-queue-host    "${REDIS_URI}" || true
b set-redis-socketio-host "${REDIS_URI}" || true
b set-config -g db_host "${DB_HOST}"
b set-config -g db_port "${DB_PORT}"
b set-config -g webserver_port "${WEB_PORT}"

SITE_DIR="${BENCH_DIR}/sites/${SITE}"
if [ ! -d "${SITE_DIR}" ]; then
  # pick a DB name that does NOT exist; do NOT create it here
  DB_NAME="${BASE_DB}"
  if mysql_q "SHOW DATABASES LIKE '${DB_NAME}'" | grep -qx "${DB_NAME}"; then
    DB_NAME="${BASE_DB}_$(date +%s)"
  fi
  echo "== Creating site ${SITE} on DB ${DB_NAME} (bench will create DB) =="
  ${BENCH} new-site "${SITE}" \
    --admin-password "${ADMIN_PASSWORD}" \
    --db-name "${DB_NAME}" \
    --db-host "${DB_HOST}" --db-port "${DB_PORT}" \
    --db-root-username "${DB_ROOT_USER}" --db-root-password "${DB_ROOT_PASS}" \
    --mariadb-user-host-login-scope='%'  # replace deprecated --no-mariadb-socket
  ${BENCH} --site "${SITE}" install-app erpnext hrms
  ${BENCH} --site "${SITE}" enable-scheduler
  ${BENCH} --site "${SITE}" clear-cache
else
  # read existing db_name from site_config if present
  DB_NAME="$(python3 - <<'PY'
import json,sys
p="/home/frappe/frappe-bench/sites/hrms.localhost/site_config.json"
print(json.load(open(p)).get("db_name","railway"))
PY
  )"
fi

b "use ${SITE}"
b set-config -g default_site "${SITE}"
bs "set-config host_name '${PUBLIC_URL}'"

echo "== Force per-site DB config to public proxy root =="
bs "set-config db_host '${DB_HOST}'"
bs "set-config db_port ${DB_PORT}"
bs "set-config db_name '${DB_NAME}'"
bs "set-config db_user '${DB_ROOT_USER}'"
bs "set-config db_password '${DB_ROOT_PASS}'"
bs "clear-cache"

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
