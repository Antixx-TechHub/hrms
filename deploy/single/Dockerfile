# Use a real, existing base
FROM frappe/erpnext-worker:edge

WORKDIR /home/frappe/frappe-bench
USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
      mariadb-client redis-server nodejs npm git \
    && npm install -g yarn \
    && rm -rf /var/lib/apt/lists/*

COPY --chmod=0755 entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
