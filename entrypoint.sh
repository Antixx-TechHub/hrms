#!/bin/bash
set -euo pipefail

BENCH_DIR="/home/frappe/frappe-bench"
BENCH="/home/frappe/.local/bin/bench"
SITE="hrms.localhost"
PUBLIC_URL="https://overflowing-harmony-production.up.railway.app"

DB_HOST="trolley.proxy.rlwy.net"
DB_PORT="51999"
DB_ROOT_USER="root"
DB_ROOT_PASS="CYI-Vi3_B_4Ndf7C1e3.usRHOuU_zkRU"
BASE_DB="railway"

REDIS_URI="redis://default:TUwUwNxPhXtoaysMLvnyssapQWtRbGpz@nozomi.proxy.rlwy.net:46645"

NGINX_PORT="${PORT:-8080}"
WEB_PORT=8001

runf(){ su -s /bin/bash -c "cd ${BENCH_DIR} && $*" frappe; }
b(){ runf "${BENCH} $*"; }
bs(){ runf "${BENCH} --site ${SITE} $*"; }
db_exists(){ mysql --protocol=tcp -h "$DB_HOST" -P "$DB_PORT" -u "$DB_ROOT_USER" -p"$DB_ROOT_PASS" -N -e "SHOW DATABASES LIKE '$1'" | grep -qx "$1"; }

echo "== 1/7 DB ping =="
until mysqladmin --protocol=tcp -h "$DB_HOST" -P "$DB_PORT" -u "$DB_ROOT_USER" -p"$DB_ROOT_PASS" ping >/dev/null 2>&1; do
  echo "Waiting for MariaDB ${DB_HOST}:${DB_PORT}..."; sleep 2
done

echo "== 2/7 Bench globals =="
cd "${BENCH_DIR}"
b set-redis-cache-host    "${REDIS_URI}" || true
b set-redis-queue-host    "${REDIS_URI}" || true
b set-redis-socketio-host "${REDIS_URI}" || true
b set-config -g db_host "${DB_HOST}"
b set-config -g db_port "${DB_PORT}"
b set-config -g webserver_port "${WEB_PORT}"

SITE_DIR="${BENCH_DIR}/sites/${SITE}"

echo "== 3/7 Ensure site =="
if [ ! -d "${SITE_DIR}" ]; then
  DB_NAME="${BASE_DB}"; db_exists "${DB_NAME}" && DB_NAME="${BASE_DB}_$(date +%s)"
  echo "Creating site ${SITE} on DB ${DB_NAME}"
  ${BENCH} new-site "${SITE}" \
    --admin-password "admin" \
    --db-name "${DB_NAME}" \
    --db-host "${DB_HOST}" --db-port "${DB_PORT}" \
    --db-root-username "${DB_ROOT_USER}" --db-root-password "${DB_ROOT_PASS}" \
    --mariadb-user-host-login-scope='%'
  ${BENCH} --site "${SITE}" install-app erpnext hrms
else
  DB_NAME="$(python3 - <<'PY'
import json; print(json.load(open("/home/frappe/frappe-bench/sites/hrms.localhost/site_config.json")).get("db_name","railway"))
PY
  )"
fi
test -f "${SITE_DIR}/site_config.json"

echo "== 4/7 Hostname, assets, no-cache =="
b "use ${SITE}"
b set-config -g default_site "${SITE}"
bs "set-config host_name '${PUBLIC_URL}'"
# build once; avoid further bench writes later
bs "build" || true
bs "clear-cache" || true

echo "== 5/7 Nginx =="
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

echo "== 6/7 HARD-OVERRIDE site_config.json (LAST WRITE) =="
SITE_CFG="${SITE_DIR}/site_config.json"
cat >"${SITE_CFG}" <<JSON
{
  "db_type": "mariadb",
  "db_name": "${DB_NAME}",
  "db_host": "${DB_HOST}",
  "db_port": ${DB_PORT},
  "db_user": "${DB_ROOT_USER}",
  "db_password": "${DB_ROOT_PASS}"
}
JSON
chmod 640 "${SITE_CFG}"
echo "site_config.json now:"
sed -n '1,120p' "${SITE_CFG}"

echo "== 7/7 Start services (no more bench writes) =="
# start processes AFTER final override to ensure they read the forced creds
bs "serve --port ${WEB_PORT}" &
bs "worker" &
bs "schedule" &
runf "node apps/frappe/socketio.js" &

echo "Startup complete. URL=${PUBLIC_URL}"
wait -n
