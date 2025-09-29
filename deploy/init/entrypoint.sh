#!/usr/bin/env bash
set -euo pipefail
cd /home/frappe/frappe-bench

bench new-site "$SITE_NAME" \
  --mariadb-root-password "$DB_ROOT_PASSWORD" \
  --admin-password "$ADMIN_PASSWORD" \
  --db-host "$DB_HOST" --db-port "$DB_PORT"

bench --site "$SITE_NAME" install-app erpnext
bench --site "$SITE_NAME" install-app hrms
bench build
echo "OK: site initialized"
