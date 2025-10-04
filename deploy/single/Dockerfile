FROM frappe/bench:latest
SHELL ["/bin/bash","-lc"]

RUN pip install --no-cache-dir frappe-bench

USER frappe
WORKDIR /home/frappe

COPY init.sh /home/frappe/init.sh
RUN sed -i 's/\r$//' /home/frappe/init.sh && chmod +x /home/frappe/init.sh

EXPOSE 8000 9000
ENTRYPOINT ["/bin/bash","-lc","/home/frappe/init.sh"]
