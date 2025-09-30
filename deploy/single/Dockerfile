# syntax=docker/dockerfile:1
FROM frappe/erpnext-worker:edge

USER root
RUN apt-get update && apt-get install -y jq && rm -rf /var/lib/apt/lists/*
USER frappe
WORKDIR /home/frappe/frappe-bench

# ensure this file is in the same folder
COPY apps.json /tmp/apps.json

RUN set -e; jq -r '.[] | "\(.url) \(.branch)"' /tmp/apps.json \
  | while read -r url branch; do bench get-app --branch "$branch" "$url"; done

RUN bench setup requirements && bench build --apps erpnext hrms

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
