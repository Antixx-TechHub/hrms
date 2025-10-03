FROM frappe/bench:latest

USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
      nginx-light nodejs mariadb-client ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*

# Build bench + apps (skip redis cfg at build)
USER frappe
WORKDIR /home/frappe
RUN bench init --skip-redis-config-generation --frappe-branch version-15 frappe-bench
WORKDIR /home/frappe/frappe-bench
RUN bench get-app --branch version-15 https://github.com/frappe/erpnext && \
    bench get-app --branch version-15 https://github.com/frappe/hrms

# Runtime
USER root
COPY entrypoint.sh /entrypoint.sh
RUN sed -i 's/\r$//' /entrypoint.sh && chmod +x /entrypoint.sh

ENV PORT=8080
EXPOSE 8080
ENTRYPOINT ["/bin/bash","-lc","/entrypoint.sh"]
