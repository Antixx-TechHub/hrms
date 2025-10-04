FROM frappe/bench:latest
SHELL ["/bin/bash","-lc"]

# Node + pip
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
      nodejs npm python3-pip \
 && npm i -g yarn \
 && rm -rf /var/lib/apt/lists/*

# Install bench for the frappe user (no system-wide pip)
USER frappe
RUN python3 -m pip install --user --no-cache-dir frappe-bench

# Pre-bake bench + apps
WORKDIR /home/frappe
RUN bench init --skip-redis-config-generation --frappe-branch version-15 frappe-bench

WORKDIR /home/frappe/frappe-bench
RUN bench get-app --branch version-15 https://github.com/frappe/erpnext && \
    bench get-app --branch version-15 https://github.com/frappe/hrms

# Entrypoint
USER root
COPY --chown=frappe:frappe init.sh /home/frappe/init.sh
RUN chmod 0755 /home/frappe/init.sh

USER frappe
WORKDIR /home/frappe/frappe-bench
EXPOSE 8000 9000
ENTRYPOINT ["/bin/bash","-lc","/home/frappe/init.sh"]
