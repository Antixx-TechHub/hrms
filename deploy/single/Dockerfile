# syntax=docker/dockerfile:1
FROM frappe/erpnext-worker:edge

USER root
WORKDIR /home/frappe/frappe-bench
RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*
# serve via gunicorn (worker image has no `bench start`)
RUN /home/frappe/frappe-bench/env/bin/pip install --no-cache-dir -q gunicorn gevent

COPY --chmod=0755 entrypoint.sh /entrypoint.sh
USER frappe
ENTRYPOINT ["/entrypoint.sh"]
