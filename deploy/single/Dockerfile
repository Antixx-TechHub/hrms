# syntax=docker/dockerfile:1
FROM frappe/erpnext-worker:edge

USER root
WORKDIR /home/frappe/frappe-bench
RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*
# gunicorn just in case the base doesn’t include it
RUN /home/frappe/frappe-bench/env/bin/pip install --no-cache-dir -q gunicorn gevent

# copy entrypoint with exec perms
COPY --chmod=0755 entrypoint.sh /entrypoint.sh

USER frappe
ENTRYPOINT ["/entrypoint.sh"]
