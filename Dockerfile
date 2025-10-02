FROM frappe/bench:latest

# Nginx
USER root
RUN apt-get update && apt-get install -y --no-install-recommends nginx-light && \
    rm -rf /var/lib/apt/lists/*

# Remove any default vhosts that might bind 80/8000
RUN rm -f /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*

# Bench + apps baked (skip redis config so no redis-server needed at build)
USER frappe
WORKDIR /home/frappe
RUN bench init --skip-redis-config-generation --frappe-branch version-15 frappe-bench
WORKDIR /home/frappe/frappe-bench
RUN bench get-app --branch version-15 https://github.com/frappe/erpnext && \
    bench get-app --branch version-15 https://github.com/frappe/hrms

# Runtime
USER root
COPY --chmod=0755 entrypoint.sh /entrypoint.sh
ENV PORT=8080
EXPOSE 8080
CMD ["/entrypoint.sh"]
