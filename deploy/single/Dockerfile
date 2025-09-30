# syntax=docker/dockerfile:1
FROM frappe/erpnext-worker:edge

USER root
RUN apt-get update && apt-get install -y jq && rm -rf /var/lib/apt/lists/*
USER frappe
WORKDIR /home/frappe/frappe-bench

# put apps.json in the same folder as this Dockerfile
COPY apps.json /tmp/apps.json

# fetch apps and build requirements
RUN while read -r url branch; do bench get-app --branch "$branch" "$url"; done \
    < <(jq -r '.[] | "\(.url) \(.branch)"' /tmp/apps.json)

RUN bench setup requirements && bench build --apps erpnext hrms

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
