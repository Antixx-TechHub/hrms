#!/usr/bin/env bash
set -euo pipefail

# ---- Hardcoded Railway creds (as requested) ----
# MariaDB (private network)
export DB_HOST="${RAILWAY_PRIVATE_DOMAIN:-${MARIADB_HOST:-"trolley.internal"}}"
export DB_PORT="3306"
export DB_USER="railway"
export DB_PASSWORD="hfxKFQNoMagViYHTotVOpsbiQ4Rzg_l-"
export DB_ROOT_PASSWORD="CYI-Vi3_B_4Ndf7C1e3.usRHOuU_zkRU"
export DB_NAME="new_ath_hrms"

# Redis (private network)
_redis_host="${RAILWAY_PRIVATE_DOMAIN:-${REDISHOST:-"trolley.internal"}}"
_redis_user="default"
_redis_pass="TUwUwNxPhXtoaysMLvnyssapQWtRbGpz"
_redis_port="6379"
export REDIS_URL="redis://${_redis_user}:${_redis_pass}@${_redis_host}:${_redis_port}"

# Frappe site
: "${SITE_NAME:=site1.local}"
: "${ADMIN_PASSWORD:=admin}"   # change in Railway env if you want

cd /home/frappe/frappe-bench

# Point bench to external services
bench set-config -g db_host "$DB_HOST"
bench set-config -g db_port "$DB_PORT"
bench set-config -g redis_cache "$REDIS_URL"
bench set-config -g redis_queue "$REDIS_URL"
bench set-config -g redis_socketio "$REDIS_URL"

# Create site if missing
if [[ ! -d "sites/${SITE_NAME}" ]]; then
  echo "Creating site ${SITE_NAME} against ${DB_HOST}:${DB_PORT}/${DB_NAME}"

  # Ensure DB exists and user has rights using root (you provided root password)
  mysql --protocol=TCP -h "$DB_HOST" -P "$DB_PORT" -u root -p"$DB_ROOT_PASSWORD" <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` DEFAULT CHARACTER SET utf8mb4;
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASSWORD}';
FLUSH PRIVILEGES;
SQL

  # Create Frappe site bound to that DB
  bench new-site "$SITE_NAME" \
    --mariadb-root-username root \
    --mariadb-root-password "$DB_ROOT_PASSWORD" \
    --admin-password "$ADMIN_PASSWORD" \
    --db-name "$DB_NAME" \
    --db-username "$DB_USER" \
    --db-password "$DB_PASSWORD"

  # Install apps
  bench --site "$SITE_NAME" install-app erpnext
  bench --site "$SITE_NAME" install-app hrms
fi

# Migrate each boot
bench --site "$SITE_NAME" migrate

# Honor Railway's PORT
export WEB_PORT="${PORT:-8000}"

# Minimal Procfile defaults if none present
if [[ ! -f Procfile ]]; then
  cat > Procfile <<'P'
web: bench serve --port $WEB_PORT --noreload --nothreading
schedule: bench schedule
worker-default: bench worker --queue default
worker-short: bench worker --queue short
worker-long: bench worker --queue long
socketio: node apps/frappe/socketio.js
P
fi

exec forego start -r
