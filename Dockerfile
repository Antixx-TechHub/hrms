FROM frappe/bench:latest

# OS deps for nginx
USER root
RUN apt-get update && apt-get install -y --no-install-recommends nginx-light && \
    rm -rf /var/lib/apt/lists/* && rm -f /etc/nginx/sites-enabled/default

# Bench + apps baked at build for faster boots
RUN useradd -ms /bin/bash frappe
USER frappe
WORKDIR /home/frappe
RUN bench init --frappe-branch version-15 frappe-bench
WORKDIR /home/frappe/frappe-bench
RUN bench get-app --branch version-15 https://github.com/frappe/erpnext && \
    bench get-app --branch version-15 https://github.com/frappe/hrms

# Nginx config and entrypoint
USER root
COPY nginx.conf /etc/nginx/conf.d/frappe.conf
COPY --chmod=0755 entrypoint.sh /entrypoint.sh
ENV PORT=8080
EXPOSE 8080
USER frappe
CMD ["/entrypoint.sh"]
