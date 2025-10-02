#!/bin/bash
set -euo pipefail

# ---- Railway MariaDB (public TCP) ----
DB_HOST="trolley.proxy.rlwy.net"
DB_PORT="51999"
DB_NAME="railway"
DB_USER="railway"
DB_PASS="hfxKFQNoMagViYHTotVOpsbiQ4Rzg_l-"
DB_ROOT_USER="root"                                # if blocked, switch to DB_USER/DB_PASS
DB_ROOT_PASS="CYI-Vi3_B_4Ndf7C1e3.usRHOuU_zkRU"

# ---- Railway Redis (public TCP) ----
REDIS_HOST="nozomi.proxy.rlwy.net"
REDIS_PORT="46645"
REDIS_USER="default"
REDIS_PASS="TUwUwNxPhXtoaysMLvnyssapQWtRbGpz"

SITE="hrms.localhost"
ADMIN_PASSWORD="admin"

cd /home/frappe

if [ -d "/home/frappe/frappe-bench/apps/frappe" ]; then
  echo "Bench already exists, skipping init"
  cd frappe-bench
  exec bench start
fi

echo "Creating new bench..."
bench init --skip-redis-config-generation frappe-bench
cd frappe-bench

# ---- External DB + Redis ----
bench set-config -g db_host "${DB_HOST}"
bench set-config -g db_port "${DB_PORT}"

REDIS_URI="redis://${REDIS_USER}:${REDIS_PASS}@${REDIS_HOST}:${REDIS_PORT}"
bench set-redis-cache-host    "${REDIS_URI}"
bench set-redis-queue-host    "${REDIS_URI}"
bench set-redis-socketio-host "${REDIS_URI}"

# Clean Procfile of local redis/watch
sed -i '/^redis.*$/d' Procfile || true
sed -i '/^watch.*$/d' Procfile || true

# ---- Apps ----
bench get-app erpnext
bench get-app hrms

# ---- Site on external MariaDB ----
bench new-site "${SITE}" \
  --force \
  --admin-password "${ADMIN_PASSWORD}" \
  --db-name "${DB_NAME}" \
  --db-host "${DB_HOST}" \
  --db-port "${DB_PORT}" \
  --db-root-username "${DB_ROOT_USER}" \
  --db-root-password "${DB_ROOT_PASS}" \
  --no-mariadb-socket

bench --site "${SITE}" install-app hrms
bench --site "${SITE}" set-config developer_mode 1
bench --site "${SITE}" enable-scheduler
bench --site "${SITE}" clear-cache
bench use "${SITE}"

exec bench start
