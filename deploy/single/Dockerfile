# Use the worker image that already contains bench + frappe
FROM frappe/erpnext-worker:edge

USER root
# System deps needed at RUNTIME, not in entrypoint
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      mariadb-client \
      nodejs npm git \
      redis-server && \
    npm install -g yarn && \
    rm -rf /var/lib/apt/lists/*

# Switch back to the unprivileged user used by the base image
USER frappe

WORKDIR /home/frappe/frappe-bench

# Copy runtime script
COPY --chmod=0755 entrypoint.sh /entrypoint.sh

# Railway will expose $PORT; we bind Gunicorn to it
ENV PORT=8000

ENTRYPOINT ["/entrypoint.sh"]
