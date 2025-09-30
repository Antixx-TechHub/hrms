# syntax=docker/dockerfile:1
FROM frappe/erpnext-worker:edge

# tools
USER root
RUN apt-get update && apt-get install -y jq && rm -rf /var/lib/apt/lists/*
USER frappe
WORKDIR /home/frappe/frappe-bench

# apps list lives in build context
COPY apps.json /tmp/apps.json

# bake ERPNext + HRMS into image
RUN bench version
RUN while read -r url branch; do bench get-app --branch "$branch" "$url"; done \
    < <(jq -r '.[] | "\(.url) \(.branch)"' /tmp/apps.json)
RUN bench setup requirements && bench build --apps erpnext hrms

# runtime entry
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
