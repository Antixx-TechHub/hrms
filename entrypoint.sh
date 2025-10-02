# ---- Force bench web to 8001 (Procfile rewrite) ----
BENCH_WEB_PORT=8001
# replace the web command port in Procfile
sed -ri 's/^(web:\s*bench\s+serve\s+--port\s+)[0-9]+/\1'"${BENCH_WEB_PORT}"'/' Procfile
# prove it
grep -n '^web:' Procfile

# ---- Write nginx.conf to listen on Railway $PORT and proxy to 8001 ----
PORT="${PORT:-8080}"
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
exec su -s /bin/bash -c "bench start --no-dev" frappe
