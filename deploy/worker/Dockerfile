# ---------- common base stage (TOP OF FILE) ----------
# syntax=docker/dockerfile:1
FROM frappe/erpnext-worker:version-15 AS base

# Bake apps at build time
USER root
RUN apt-get update && apt-get install -y jq && rm -rf /var/lib/apt/lists/*
USER frappe
WORKDIR /home/frappe/frappe-bench

# Copy app list
COPY /apps.json /tmp/apps.json

# Sanity
RUN bench version

# Fetch apps
RUN while read -r url branch; do \
      bench get-app --branch "$branch" "$url"; \
    done < <(jq -r '.[] | "\(.url) \(.branch)"' /tmp/apps.json)

# Prepare deps and build assets
RUN bench setup requirements && bench build --apps erpnext hrms
# ---------- end common base ----------

FROM base
CMD ["bash","-lc","supervisord -n"]