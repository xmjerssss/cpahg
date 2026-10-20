#!/bin/bash
set -euo pipefail
export PYTHONUNBUFFERED=1

SERVER_BIN="/app/server"
PY="/app/venv/bin/python3"

# 1. 确保后台服务的配置文件端口与 Nginx 代理端口匹配（7862）
mkdir -p /data/auth-files /app/auths ~/.cli-proxy-api
SECRET="${SECRET_KEY:-ChangeMeToAStrongPassword}"

cat <<EOF > /app/config.yaml
port: 7862
host: "127.0.0.1"
auth-dir: "/data/auth-files"
remote-management:
  allow-remote: true
  secret-key: "${SECRET}"
EOF

# 2. 生成 WebDAV 备份引擎
cat << 'PYEOF' > /tmp/_bkengine.py
import sys, os, tarfile, requests, re, time
import xml.etree.ElementTree as ET

URL  = os.environ.get("FULL_WEBDAV_URL", "")
USER = os.environ.get("WEBDAV_USERNAME", "")
PASS = os.environ.get("WEBDAV_PASSWORD", "")
PFX  = os.environ.get("BACKUP_PREFIX", "cilicili_data_")
MAX  = int(os.environ.get("MAX_BACKUPS", "5"))

BACKUP_PATHS = [
    "/app/config.yaml",
    "/data/auth-files",
    os.path.expanduser("~/.cli-proxy-api")
]

def list_remote():
    if not URL: return []
    try:
        r = requests.request("PROPFIND", URL, auth=(USER, PASS), headers={"Depth": "1"}, timeout=20)
        try:
            root = ET.fromstring(r.text)
            hrefs = [h.text for h in root.iter("{DAV:}href")]
        except Exception:
            hrefs = re.findall(r"<D:href>([^<]+)</D:href>", r.text)
        return sorted([h.rstrip("/").split("/")[-1] for h in hrefs if h.rstrip("/").split("/")[-1].startswith(PFX)])
    except Exception as e:
        return []

def do_restore():
    if not URL: return
    backups = list_remote()
    if not backups: return
    latest = backups[-1]
    tmp = f"/tmp/_bkrestore_{latest}"
    r = requests.get(f"{URL.rstrip('/')}/{latest}", auth=(USER, PASS), stream=True, timeout=120)
    if r.status_code == 200:
        with open(tmp, "wb") as f:
            for chunk in r.iter_content(65536): f.write(chunk)
        if os.path.getsize(tmp) > 100:
            with tarfile.open(tmp, "r:gz") as tar: tar.extractall("/")
        if os.path.exists(tmp): os.remove(tmp)

def do_backup():
    if not URL: return
    fname = f"{PFX}{time.strftime('%Y%m%d_%H%M%S')}.tar.gz"
    tmp = f"/tmp/{fname}"
    with tarfile.open(tmp, "w:gz") as tar:
        for p in set(BACKUP_PATHS):
            if os.path.exists(p): tar.add(p, arcname=p.lstrip("/"))
    with open(tmp, "rb") as f:
        requests.put(f"{URL.rstrip('/')}/{fname}", auth=(USER, PASS), data=f, timeout=120)
    if os.path.exists(tmp): os.remove(tmp)
    
    remotes = list_remote()
    if len(remotes) > MAX:
        for old in remotes[:len(remotes) - MAX]:
            try: requests.request("DELETE", f"{URL.rstrip('/')}/{old}", auth=(USER, PASS), timeout=20)
            except Exception: pass

if __name__ == "__main__":
    if len(sys.argv) > 1:
        if sys.argv[1] == "restore": do_restore()
        elif sys.argv[1] == "backup": do_backup()
PYEOF

# 3. 检查 WebDAV 并执行初始化恢复
if [[ -n "${WEBDAV_URL:-}" ]] && [[ -n "${WEBDAV_USERNAME:-}" ]]; then
    _wurl="${WEBDAV_URL%/}"
    export FULL_WEBDAV_URL="${_wurl}/${WEBDAV_BACKUP_PATH:-}"
    curl -ms 5 -X MKCOL -u "${WEBDAV_USERNAME}:${WEBDAV_PASSWORD}" "${FULL_WEBDAV_URL}/" >/dev/null 2>&1 || true
    "$PY" /tmp/_bkengine.py restore || true

    # 启动后台定期同步守护进程
    (
        INTERVAL=${SYNC_INTERVAL:-3600}
        while true; do
            sleep "$INTERVAL"
            "$PY" /tmp/_bkengine.py backup || true
        done
    ) &
fi

# 4. 启动后台 API 核心服务（静默标准输出，错误日志写入系统临时目录）
"${SERVER_BIN}" >/dev/null 2>&1 &

# 5. 启动 Nginx 作为前台进程
exec nginx -g "daemon off;"
