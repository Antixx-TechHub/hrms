FROM frappe/bench:latest

# Nginx + Node.js (Debian 12 ships Node 18.x which is fine for Frappe v15)
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
      nginx-light nodejs ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*

# Bake bench + apps (skip redis config at build)
USER frappe
WORKDIR /home/frappe
RUN bench init --skip-redis-config-generation --frappe-branch version-15 frappe-bench
WORKDIR /home/frappe/frappe-bench
RUN bench get-app --branch version-15 https://github.com/frappe/erpnext && \
    bench get-app --branch version-15 https://github.com/frappe/hrms

# Runtime entrypoint
USER root
COPY entrypoint.sh /entrypoint.sh
RUN sed -i 's/\r$//' /entrypoint.sh && chmod +x /entrypoint.sh

ENV PORT=8080
EXPOSE 8080
ENTRYPOINT ["/bin/bash","-lc","/entrypoint.sh"]
