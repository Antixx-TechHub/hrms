FROM frappe/bench:latest

# install nginx and drop default site
USER root
RUN apt-get update && apt-get install -y --no-install-recommends nginx-light && \
    rm -rf /var/lib/apt/lists/* && rm -f /etc/nginx/sites-enabled/default

# config + entrypoint
COPY nginx.conf /etc/nginx/conf.d/frappe.conf
COPY --chmod=0755 entrypoint.sh /entrypoint.sh
ENV PORT=8080
EXPOSE 8080

# bake bench + apps as existing 'frappe' user
USER frappe
WORKDIR /home/frappe
RUN bench init --frappe-branch version-15 frappe-bench
WORKDIR /home/frappe/frappe-bench
RUN bench get-app --branch version-15 https://github.com/frappe/erpnext && \
    bench get-app --branch version-15 https://github.com/frappe/hrms

# runtime
USER root
CMD ["/entrypoint.sh"]
