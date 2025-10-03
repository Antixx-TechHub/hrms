#!/bin/bash
set -euo pipefail

# ----- PATH so 'bench' resolves under su -----
export PATH="/home/frappe/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
AS_FRAPPE='su -l -s /bin/bash -c'

bench_run() { # usage: bench_run "<cmd>"
  ${AS_FRAPPE} "$1" frappe
}

wait_tcp() { # usage: wait_tcp host port
  timeout 20 bash -c "</dev/tcp/$1/$2" >/dev/null 2>&1
}

# ----- Railway services -----
# MariaDB (root creds VERIFIED by you)
DB_HOST="trolley.proxy.rlwy.net"
DB_PORT="51999"
DB_ROOT_USER="root"
DB_ROOT_PASS="CYI-Vi3_B_4Ndf7C1e3.usRHOuU_zkRU"
DB_NAME="railway"

# Redis
REDIS_HOST="nozomi.proxy.rlwy.net"
REDIS_PORT="46645"
REDIS_USER="default"
REDIS_PASS="TUwUwNxPhXtoaysMLvnyssapQWtRbGpz"

# Site/Admin
SITE="hrms.localhost"
ADMIN_PASSWORD="admin"

# Bind Nginx to Railway $PORT. Frappe web on 8001 to avoid clashes.
PORT="${PORT:-8080}"
BENCH_WEB_PORT=8001

cd /home/frappe/frappe-bench

# ----- Wire external Redis & DB BEFORE any start -----
REDIS_URI="redis://${REDIS_USER}:${REDIS_PASS}@${REDIS_HOST}:${REDIS_PORT}"
bench_run "bench set-redis-cache-host    '${REDIS_URI}' || true"
bench_run "bench set-redis-queue-host    '${REDIS_URI}' || true"
bench_run "bench set-redis-socketio-host '${REDIS_URI}' || true"
bench_run "sed -i '/^[[:space:]]*redis[[:space:]]*:/d;/^[[:space:]]*watch[[:space:]]*:/d' Procfile || true"

bench_run "bench set-config -g db_host '${DB_HOST}'"
bench_run "bench set-config -g db_port '${DB_PORT}'"

# Force Frappe web to 8001 and rewrite Procfile (bench start uses Procfile)
bench_run "bench set-config -g webserver_port ${BENCH_WEB_PORT}"
bench_run "python3 - <<'PY'
import re, pathlib
p = pathlib.Path('Procfile')
s = p.read_text()
s = re.sub(r'^(web:\s*bench\s+serve\s+--port\s+)\d+', r'\g<1>8001', s, flags=re.M)
p.write_text(s)
print([l for l in s.splitlines() if l.startswith('web:')][0])
PY"

# ----- Wait for externals -----
echo "Waiting for MariaDB ${DB_HOST}:${DB_PORT}..."; until wait_tcp "$DB_HOST" "$DB_PORT"; do sleep 2; done
echo "Waiting for Redis ${REDIS_HOST}:${REDIS_PORT}..."; until wait_tcp "$REDIS_HOST" "$REDIS_PORT"; do sleep 2; done

# ----- Create site once using ROOT creds -----
if ! bench_run "bench --site '${SITE}' version" >/dev/null 2>&1; then
  echo "Creating site ${SITE}"
  bench_run "bench new-site '${SITE}' \
    --force \
    --admin-password '${ADMIN_PASSWORD}' \
    --db-name '${DB_NAME}' \
    --db-host '${DB_HOST}' \
    --db-port '${DB_PORT}' \
    --db-root-username '${DB_ROOT_USER}' \
    --db-root-password '${DB_ROOT_PASS}' \
    --no-mariadb-socket"
  bench_run "bench --site '${SITE}' install-app erpnext hrms"
  bench_run "bench --site '${SITE}' set-config developer_mode 1"
  bench_run "bench --site '${SITE}' enable-scheduler && bench --site '${SITE}' clear-cache"
fi
bench_run "bench use '${SITE}'"

# ----- Write nginx.conf at runtime (listen $PORT, proxy to 8001/9000) -----
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

# ----- Start bench -----
exec ${AS_FRAPPE} "bench start --no-dev" frappe
