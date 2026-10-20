FROM eceasy/cli-proxy-api:latest AS original
FROM alpine:3.19

RUN apk add --no-cache curl tar bash tzdata python3 py3-pip libc6-compat nginx && \
    python3 -m venv /app/venv && \
    /app/venv/bin/pip install --no-cache-dir requests

WORKDIR /app

# 提取主程序
COPY --from=original /CLIProxyAPI /opt/original
RUN BIN=$(find /opt/original -maxdepth 1 -type f -name 'CLIProxyAPI*' ! -name '*.yaml' ! -name '*.md' ! -name '*.example' | head -n 1) && \
    cp "$BIN" /app/server && chmod +x /app/server && rm -rf /opt/original

# 部署静态页面与配置
COPY html/ /var/www/html/
COPY nginx.conf /etc/nginx/nginx.conf
COPY boot.sh /app/boot.sh
RUN chmod +x /app/boot.sh && sed -i 's/\r$//' /app/boot.sh

EXPOSE 7860
ENTRYPOINT ["/bin/bash", "/app/boot.sh"]
