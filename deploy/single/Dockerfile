# syntax=docker/dockerfile:1
FROM frappe/erpnext-worker:edge

USER root
WORKDIR /home/frappe/frappe-bench

# git for app clones, redis-server for local cache/queue/socketio, gunicorn to serve http
RUN apt-get update && apt-get install -y git redis-server && rm -rf /var/lib/apt/lists/*
RUN /home/frappe/frappe-bench/env/bin/pip install --no-cache-dir -q gunicorn gevent

COPY --chmod=0755 entrypoint.sh /entrypoint.sh
USER frappe
ENTRYPOINT ["/entrypoint.sh"]
