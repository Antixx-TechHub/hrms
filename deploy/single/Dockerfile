FROM frappe/bench:latest
SHELL ["/bin/bash","-lc"]

RUN pip install --no-cache-dir frappe-bench

USER frappe
WORKDIR /home/frappe
RUN bench init --skip-redis-config-generation --frappe-branch version-15 frappe-bench

WORKDIR /home/frappe/frappe-bench
RUN bench get-app --branch version-15 https://github.com/frappe/erpnext && \
    bench get-app --branch version-15 https://github.com/frappe/hrms

COPY init.sh /home/frappe/init.sh
RUN chmod +x /home/frappe/init.sh

EXPOSE 8000 9000
ENTRYPOINT ["/bin/bash","-lc","/home/frappe/init.sh"]
