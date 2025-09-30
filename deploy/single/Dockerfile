# ERPNext v15 base with Python 3.10 (not edge)
FROM frappe/erpnext-worker:v15

WORKDIR /home/frappe/frappe-bench

# Minimal OS deps for build/runtime
USER root
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      mariadb-client redis-server nodejs npm git && \
    npm install -g yarn && \
    rm -rf /var/lib/apt/lists/*

# Entrypoint
COPY --chmod=0755 entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
