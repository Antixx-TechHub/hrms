# syntax=docker/dockerfile:1
FROM frappe/bench:edge

USER root
WORKDIR /home/frappe/frappe-bench
RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*
COPY --chmod=0755 entrypoint.sh /entrypoint.sh

USER frappe
ENTRYPOINT ["/entrypoint.sh"]
