FROM frappe/bench:latest

USER root
# Add nodejs + npm + yarn, mariadb-client, nginx
RUN apt-get update && apt-get install -y --no-install-recommends \
      nginx-light nodejs npm mariadb-client ca-certificates curl \
 && npm install -g yarn@1.22.22 \
 && rm -rf /var/lib/apt/lists/* \
 && rm -f /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*

# Make sure bench CLI is importable
RUN pip install --no-cache-dir frappe-bench

# Build bench + apps
USER frappe
WORKDIR /home/frappe
RUN bench init --skip-redis-config-generation --frappe-branch version-15 frappe-bench
WORKDIR /home/frappe/frappe-bench
RUN bench get-app --branch version-15 https://github.com/frappe/erpnext && \
    bench get-app --branch version-15 https://github.com/frappe/hrms

# Entrypoint
USER root
COPY entrypoint.sh /entrypoint.sh
RUN sed -i 's/\r$//' /entrypoint.sh && chmod +x /entrypoint.sh

ENV PORT=8080
EXPOSE 8080
ENTRYPOINT ["/bin/bash","-lc","/entrypoint.sh"]
