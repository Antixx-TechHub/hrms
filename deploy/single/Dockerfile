FROM frappe/bench:latest
SHELL ["/bin/bash","-lc"]

# Tools required by Frappe runtime (node for socket.io, yarn)
USER root
RUN apt-get update && apt-get install -y --no-install-recommends nodejs npm \
 && npm i -g yarn \
 && rm -rf /var/lib/apt/lists/*

# Bench CLI
RUN pip install --no-cache-dir frappe-bench

# Pre-bake bench + apps
USER frappe
WORKDIR /home/frappe
RUN bench init --skip-redis-config-generation --frappe-branch version-15 frappe-bench

WORKDIR /home/frappe/frappe-bench
RUN bench get-app --branch version-15 https://github.com/frappe/erpnext && \
    bench get-app --branch version-15 https://github.com/frappe/hrms

# Entrypoint (copy as root to fix perms for mounted volume later)
USER root
COPY --chown=frappe:frappe init.sh /home/frappe/init.sh
RUN chmod 0755 /home/frappe/init.sh

USER frappe
WORKDIR /home/frappe/frappe-bench
EXPOSE 8000 9000
ENTRYPOINT ["/bin/bash","-lc","/home/frappe/init.sh"]
