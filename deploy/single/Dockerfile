# syntax=docker/dockerfile:1
FROM frappe/erpnext-worker:edge

USER root
WORKDIR /home/frappe/frappe-bench

# git for cloning apps, redis-server for local cache/queue/socketio, gunicorn to serve http
RUN apt-get update && apt-get install -y git redis-server && rm -rf /var/lib/apt/lists/*
RUN /home/frappe/frappe-bench/env/bin/pip install --no-cache-dir -q gunicorn gevent

# make redis listen localhost without supervision; no password, no persistence needed
RUN sed -i 's/^supervised .*/supervised no/' /etc/redis/redis.conf \
 && sed -i 's/^bind .*/bind 127.0.0.1/' /etc/redis/redis.conf \
 && sed -i 's/^protected-mode .*/protected-mode no/' /etc/redis/redis.conf

COPY --chmod=0755 entrypoint.sh /entrypoint.sh
USER frappe
ENTRYPOINT ["/entrypoint.sh"]
