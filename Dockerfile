FROM frappe/bench:latest
SHELL ["/bin/bash", "-lc"]

# Procfile runner
RUN curl -fsSL https://github.com/ddollar/forego/releases/download/v0.17.2/forego_linux_amd64.tgz \
  | tar -xz -C /usr/local/bin && chmod +x /usr/local/bin/forego

# Bench CLI available at runtime
RUN pip install --no-cache-dir frappe-bench

# Create bench and fetch apps
USER frappe
WORKDIR /home/frappe
RUN bench init --skip-redis-config-generation --frappe-branch version-15 frappe-bench

WORKDIR /home/frappe/frappe-bench
RUN bench get-app --branch version-15 https://github.com/frappe/erpnext && \
    bench get-app --branch version-15 https://github.com/frappe/hrms

# Runtime
USER root
COPY entrypoint.sh /entrypoint.sh
RUN sed -i 's/\r$//' /entrypoint.sh && chmod +x /entrypoint.sh && chown -R frappe:frappe /home/frappe

ENV PORT=8000
EXPOSE 8000
VOLUME ["/home/frappe/frappe-bench/sites"]

USER frappe
WORKDIR /home/frappe/frappe-bench
ENTRYPOINT ["/entrypoint.sh"]
