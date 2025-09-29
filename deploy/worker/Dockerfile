# syntax=docker/dockerfile:1

ARG FRAPPE_PATH=https://github.com/frappe/frappe
ARG FRAPPE_BRANCH=version-15
ARG PYTHONUNBUFFERED=1

FROM frappe/erpnext-worker:version-15 AS base
# Copy apps.json into build context
COPY ../apps.json /tmp/apps.json

# Build-time install of apps into /home/frappe/frappe-bench/apps
# This mirrors the official "custom apps via apps.json" approach.
USER root
RUN apt-get update && apt-get install -y jq && rm -rf /var/lib/apt/lists/*
USER frappe
WORKDIR /home/frappe/frappe-bench

# Ensure bench is ready
RUN bench version

# Get apps listed in apps.json at build time
RUN while read -r url branch; do \
      bench get-app --branch "$branch" "$url"; \
    done < <(jq -r '.[] | "\(.url) \(.branch)"' /tmp/apps.json)

# Build python/node deps so runtime is faster
RUN bench setup requirements && bench build --apps erpnext hrms

# Default CMD is set per-service Dockerfile below
