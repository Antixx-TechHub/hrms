# syntax=docker/dockerfile:1
FROM frappe/erpnext-worker:edge

WORKDIR /home/frappe/frappe-bench

# Tools required at runtime build (node/yarn/git + mariadb client)
USER root
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      mariadb-client nodejs npm git && \
    npm install -g yarn && \
    rm -rf /var/lib/apt/lists/*

# entrypoint
COPY --chmod=0755 entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
