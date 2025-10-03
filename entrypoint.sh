#!/bin/bash
set -euo pipefail

# Paths
BENCH_DIR="/home/frappe/frappe-bench"
BENCH_BIN="/home/frappe/.local/bin/bench"

# Railway services
DB_HOST="trolley.proxy.rlwy.net"; DB_PORT="51999"
DB_ROOT_USER="root"; DB_ROOT_PASS="CYI-Vi3_B_4Ndf7C1e3.usRHOuU_zkRU"
DB_NAME="railway"

REDIS_HOST="nozomi.proxy.rlwy.net"; REDIS_PORT="46645"
REDIS_USER="default"; REDIS_PASS="TUwUwNxPhXtoaysMLvnyssapQWtRbGpz"

SITE="hrms.localhost"; ADMIN_PASSWORD="admin"
PORT="${PORT:-8080}"
BENCH_WEB_PORT=8001    # avoid nginx clash

# Helpers
wait_tcp(){ timeout 20 bash -c "</dev/tcp/$1/$2" >/dev/null 2>&1; }
runf(){ su -s /bin/bash -c "cd ${BENCH_DIR} && $*" frappe; }          # run as frappe IN bench dir
bench(){ runf "${BENCH_BIN} $*"; }                                    # call bench by absolute path

# Sanity: bench dir exists
cd "${BENCH_DIR}"

# Wire external Redis/DB
REDIS_URI="redis://${REDIS_USER}:${REDIS_PASS}@${REDIS_HOST}:${REDIS_PORT}"
bench set-redis-cache-host    "${REDIS_URI}" || true
bench set-redis-queue-host    "${REDIS_URI}" || true
bench set-redis-socketio-host "${REDIS_URI}" || true
runf "sed -i '/^[[:space:]]*redis[[:space:]]*:/d;/^[[:space:]]*watch[[:space:]]*:/d' Procfile || true"

bench set-config -g db_host "${DB_HOST}"
bench set-config -g db_port "${DB_PORT}"

# Force web on 8001 and rewrite Procfile (bench start uses Procfile)
bench set-config -g webserver_port "${BENCH_WEB_PORT}"
runf "python3 - <<'PY'
import re, pathlib
p = pathlib.Path('Procfile'); s = p.read_text()
s = re.sub(r'^(web:\\s*bench\\s+serve\\s+--port\\s+)\\d+', r'\\g<1>8001', s, flags=re.M)
p.write_text(s)
print([l for l in s.splitlines() if l.startswith('web:')][0])
PY"

# Wait for externals
echo "Waiting for MariaDB ${DB_HOST}:${DB_PORT}..."; until wait_tcp "$DB_HOST" "$DB_PORT"; do sleep 2; done
echo "Waiting for Redis ${REDIS_HOST}:${REDIS_PORT}..."; until wait_tcp "$REDIS_HOST" "$REDIS_PORT"; do sleep 2; done

# Create site once with ROOT creds
if ! bench --site "${SITE}" version >/dev/null 2>&1; then
  echo "Creating site ${SITE}"
  bench new-site "${SITE}" \
    --force \
    --admin-password "${ADMIN_PASSWORD}" \
    --db-name "${DB_NAME}" \
    --db-host "${DB_HOST}" \
    --db-port "${DB_PORT}" \
    --db-root-username "${DB_ROOT_USER}" \
    --db-root-password "${DB_ROOT_PASS}" \
    --no-mariadb-socket
  bench --site "${SITE}" install-app erpnext hrms
  bench --site "${SITE}" set-config developer_mode 1
  bench --site "${SITE}" enable-scheduler
  bench --site "${SITE}" clear-cache
fi
bench use "${SITE}"

# Write nginx.conf at runtime (listen $PORT, proxy to 8001/9000)
rm -f /etc/nginx/conf.d/* /etc/nginx/sites-enabled/* || true
cat >/etc/nginx/conf.d/frappe.conf <<EOF
server {
    listen ${PORT} default_server reuseport;
    listen [::]:${PORT} default_server;

    location / {
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_http_version 1.1;
        proxy_pass http://127.0.0.1:${BENCH_WEB_PORT};
    }

    location /socket.io/ {
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_pass http://127.0.0.1:9000/socket.io/;
    }
}
EOF

grep -n 'listen' /etc/nginx/conf.d/frappe.conf || true
/usr/sbin/nginx -g "daemon on;"

# Start bench
exec su -s /bin/bash -c "cd ${BENCH_DIR} && ${BENCH_BIN} start --no-dev" frappe
