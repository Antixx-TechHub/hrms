# syntax=docker/dockerfile:1
FROM python:3.10-slim

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    BENCH_HOME=/home/frappe/frappe-bench

# OS deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential git curl ca-certificates \
    mariadb-client \
    redis-server \
    nodejs npm \
    wkhtmltopdf fonts-dejavu-core \
  && npm install -g yarn \
  && rm -rf /var/lib/apt/lists/*

# bench + init empty bench (no DB work here)
RUN pip install --no-cache-dir "frappe-bench>=5,<6"
RUN useradd -ms /bin/bash frappe
USER frappe
WORKDIR /home/frappe

# init bench skeleton (no production setup, no redis config generation)
RUN bench init --frappe-branch version-15 --no-setup-production \
    --skip-redis-config-generation frappe-bench

WORKDIR ${BENCH_HOME}

# get apps at build time so runtime isn’t cloning
RUN bench get-app --branch version-15 https://github.com/frappe/erpnext
RUN bench get-app --branch version-15 https://github.com/frappe/hrms

# copy entrypoint
USER root
COPY --chmod=0755 entrypoint.sh /entrypoint.sh

# runtime user
USER frappe
EXPOSE 8000
ENTRYPOINT ["/entrypoint.sh"]
