# syntax=docker/dockerfile:1
FROM frappe/erpnext-worker:edge

USER root
WORKDIR /home/frappe/frappe-bench

# need git for runtime get-app
RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*

# copy entrypoint with exec perms in one step
COPY --chmod=0755 entrypoint.sh /entrypoint.sh

USER frappe
ENTRYPOINT ["/entrypoint.sh"]
