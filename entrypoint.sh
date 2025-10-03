#!/bin/bash
set -euo pipefail

# ===== Constants =====
BENCH_DIR="/home/frappe/frappe-bench"
BENCH="/home/frappe/.local/bin/bench"
SITE="hrms.localhost"
PUBLIC_URL="https://overflowing-harmony-production.up.railway.app"

# MariaDB over public TCP (matches your DBeaver)
DB_HOST="trolley.proxy.rlwy.net"
DB_PORT="51999"
DB_ROOT_USER="root"
DB_ROOT_PASS="CYI-Vi3_B_4Ndf7C1e3.usRHOuU_zkRU"
BASE_DB="railway"          # preferred base; if taken we suffix with timestamp

# Redis over public TCP
REDIS_URI="redis://default:TUwUwNxPhXtoaysMLvnyssapQWtRbGpz@nozomi.proxy.rlwy.net:46645"

# Ports
NGINX_PORT="${PORT:-8080}"
WEB_PORT=8001

# ===== Helpers =====
runf(){ su -s /bin/bash -c "cd ${BENCH_DIR} && $*" frappe; }
b(){ runf "${BENCH} $*"; }
bs(){ runf "${BENCH} --site ${SITE} $*"; }
db_exists(){ mysql --protocol=tcp -h "$DB_HOST" -P "$DB_PORT" -u "$DB_ROOT_USER" -p"$DB_ROOT_PASS" -N -e "SHOW DATABASES LIKE '$1'" | grep -qx "$1"; }

echo "== 1/8 Ensure DB reachable =="
until mysqladmin --protocol=tcp -h "$DB_HOST" -P "$DB_PORT" -u "$DB_ROOT_USER" -p"$DB_ROOT_PASS" ping >/dev/null 2>&1; do
  echo "Waiting for MariaDB ${DB_HOST}:${DB_PORT}..."; sleep 2
done

echo "== 2/8 Bench config (Redis/DB/global) =="
cd "${BENCH_DIR}"
b set-redis-cache-host    "${REDIS_URI}" || true
b set-redis-queue-host    "${REDIS_URI}" || true
b set-redis-socketio-host "${REDIS_URI}" || true
b set-config -g db_host "${DB_HOST}"
b set-config -g db_port "${DB_PORT}"
b set-config -g webserver_port "${WEB_PORT}"

SITE_DIR="${BENCH_DIR}/sites/${SITE}"

echo "== 3/8 Ensure site existence =="
if [ ! -d "${SITE_DIR}" ]; then
  # pick a DB name that does not yet exist; let bench create it
  DB_NAME="${BASE_DB}"
  if db_exists "${DB_NAME}"; then DB_NAME="${BASE_DB}_$(date +%s)"; fi
  echo "Creating site ${SITE} on DB ${DB_NAME}"
  ${BENCH} new-site "${SITE}" \
    --admin-password "admin" \
    --db-name "${DB_NAME}" \
    --db-host "${DB_HOST}" --db-port "${DB_PORT}" \
    --db-root-username "${DB_ROOT_USER}" --db-root-password "${DB_ROOT_PASS}" \
    --mariadb-user-host-login-scope='%'
  ${BENCH} --site "${SITE}" install-app erpnext hrms
  ${BENCH} --site "${SITE}" enable-scheduler
  ${BENCH} --site "${SITE}" clear-cache
else
  # read db_name from existing site_config
  DB_NAME="$(python3 - <<'PY'
import json; print(json.load(open("/home/frappe/frappe-bench/sites/hrms.localhost/site_config.json")).get("db_name","railway"))
PY
  )"
  echo "Site dir exists. Using existing DB ${DB_NAME}"
fi
test -f "${SITE_DIR}/site_config.json"

echo "== 4/8 Force per-site DB config to root over public proxy =="
SITE_CFG="${SITE_DIR}/site_config.json"
cat >"${SITE_CFG}" <<JSON
{
  "db_name": "${DB_NAME}",
  "db_host": "${DB_HOST}",
  "db_port": ${DB_PORT},
  "db_user": "${DB_ROOT_USER}",
  "db_password": "${DB_ROOT_PASS}"
}
JSON
echo "Wrote ${SITE_CFG}"

echo "== 5/8 Final bench site globals =="
b "use ${SITE}"
b set-config -g default_site "${SITE}"
bs "set-config host_name '${PUBLIC_URL}'"

echo "== 6/8 Build static assets and clear cache =="
bs "build" || true
bs "clear-cache" || true

echo "== 7/8 Nginx proxy =="
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
echo "Nginx listening on ${NGINX_PORT} -> Frappe ${WEB_PORT}"

echo "== 8/8 Start services =="
bs "serve --port ${WEB_PORT}" &
bs "worker" &
bs "schedule" &
runf "node apps/frappe/socketio.js" &
echo "Startup complete. URL=${PUBLIC_URL}"
wait -n
