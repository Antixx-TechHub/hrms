# syntax=docker/dockerfile:1
FROM frappe/erpnext-worker:edge

USER frappe
WORKDIR /home/frappe/frappe-bench

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
