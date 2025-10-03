FROM frappe/bench:latest

# Nginx
USER root
RUN apt-get update && apt-get install -y --no-install-recommends nginx-light && \
    rm -rf /var/lib/apt/lists/* && \
    rm -f /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*

# Bench + apps (skip redis config at build)
USER frappe
WORKDIR /home/frappe
RUN bench init --skip-redis-config-generation --frappe-branch version-15 frappe-bench
WORKDIR /home/frappe/frappe-bench
RUN bench get-app --branch version-15 https://github.com/frappe/erpnext && \
    bench get-app --branch version-15 https://github.com/frappe/hrms

# Runtime entrypoint (normalize CRLF, ensure shebang, make exec)
USER root
COPY entrypoint.sh /entrypoint.sh
RUN sed -i 's/\r$//' /entrypoint.sh && \
    (head -n1 /entrypoint.sh | grep -q '^#!' || (printf '%s\n' '#!/bin/bash' | cat - /entrypoint.sh > /tmp/ep && mv /tmp/ep /entrypoint.sh)) && \
    chmod +x /entrypoint.sh

ENV PORT=8080
EXPOSE 8080

# Call via bash to avoid shebang/CRLF issues
ENTRYPOINT ["/bin/bash","-lc","/entrypoint.sh"]
