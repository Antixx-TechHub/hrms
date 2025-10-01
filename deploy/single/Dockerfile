# syntax=docker/dockerfile:1
FROM python:3.10-slim

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    BENCH_HOME=/home/frappe/frappe-bench

# OS deps (+ cron to satisfy bench init backups step)
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential git curl ca-certificates \
    mariadb-client \
    redis-server \
    nodejs npm \
    fontconfig libjpeg62-turbo libxrender1 libxext6 libfreetype6 \
    xz-utils \
    cron \
 && rm -rf /var/lib/apt/lists/*

# wkhtmltopdf 0.12.6
RUN curl -L -o /tmp/wk.deb \
      https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6-1/wkhtmltox_0.12.6-1.bookworm_amd64.deb \
 && apt-get update && apt-get install -y --no-install-recommends libpng16-16 libssl3 \
 && dpkg -i /tmp/wk.deb || apt-get -y -f install \
 && rm -f /tmp/wk.deb

RUN npm install -g yarn
RUN pip install --no-cache-dir "frappe-bench>=5,<6"

RUN useradd -ms /bin/bash frappe
USER frappe
WORKDIR /home/frappe

# plain init (no deprecated flags)
RUN bench init --frappe-branch version-15 frappe-bench

WORKDIR ${BENCH_HOME}
RUN bench get-app --branch version-15 https://github.com/frappe/erpnext
RUN bench get-app --branch version-15 https://github.com/frappe/hrms

USER root
COPY --chmod=0755 entrypoint.sh /entrypoint.sh
USER frappe
EXPOSE 8000
ENTRYPOINT ["/entrypoint.sh"]
