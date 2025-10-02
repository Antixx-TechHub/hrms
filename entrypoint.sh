#!/bin/bash
set -euo pipefail

# Railway endpoints
DB_HOST="trolley.proxy.rlwy.net"; DB_PORT="51999"
DB_NAME="railway"; DB_USER="railway"
DB_PASS="hfxKFQNoMagViYHTotVOpsbiQ4Rzg_l-"

REDIS_HOST="nozomi.proxy.rlwy.net"; REDIS_PORT="46645"
REDIS_USER="default"; REDIS_PASS="TUwUwNxPhXtoaysMLvnyssapQWtRbGpz"

SITE="hrms.localhost"; ADMIN_PASSWORD="admin"
cd /home/frappe/frappe-bench

# Force external Redis and DB
REDIS_URI="redis://${REDIS_USER}:${REDIS_PASS}@${REDIS_HOST}:${REDIS_PORT}"
as_frappe(){ su -s /bin/bash -c "$*" frappe; }

as_frappe "bench set-redis-cache-host    '${REDIS_URI}' || true"
as_frappe "bench set-redis-queue-host    '${REDIS_URI}' || true"
as_frappe "bench set-redis-socketio-host '${REDIS_URI}' || true"
as_frappe "sed -i '/^[[:space:]]*redis[[:space:]]*:/d;/^[[:space:]]*watch[[:space:]]*:/d' Procfile || true"

as_frappe "bench set-config -g db_host '${DB_HOST}'"
as_frappe "bench set-config -g db_port '${DB_PORT}'"

# wait for externals
wait_tcp(){ timeout 20 bash -c "</dev/tcp/$1/$2" >/dev/null 2>&1; }
echo "Waiting for MariaDB ${DB_HOST}:${DB_PORT}..."; until wait_tcp "$DB_HOST" "$DB_PORT"; do sleep 2; done
echo "Waiting for Redis ${REDIS_HOST}:${REDIS_PORT}..."; until wait_tcp "$REDIS_HOST" "$REDIS_PORT"; do sleep 2; done

# create site if missing (use DB user creds)
if ! as_frappe "bench --site '${SITE}' version" >/dev/null 2>&1; then
  as_frappe "bench new-site '${SITE}' \
    --force --admin-password '${ADMIN_PASSWORD}' \
    --db-name '${DB_NAME}' --db-host '${DB_HOST}' --db-port '${DB_PORT}' \
    --db-username '${DB_USER}' --db-password '${DB_PASS}' \
    --no-mariadb-socket"
  as_frappe "bench --site '${SITE}' install-app erpnext hrms"
  as_frappe "bench --site '${SITE}' set-config developer_mode 1"
  as_frappe "bench --site '${SITE}' enable-scheduler && bench --site '${SITE}' clear-cache"
fi
as_frappe "bench use '${SITE}'"

# start nginx then bench
/usr/sbin/nginx -g "daemon on;"
exec su -s /bin/bash -c "bench start --no-dev" frappe
