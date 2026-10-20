#!/bin/bash
set -euo pipefail
export PYTHONUNBUFFERED=1

log() { 
  echo "[$(date '+%F %T')] $*" 
}

SERVER_BIN="/app/server"
PY="/app/venv/bin/python3"
export BACKUP_PREFIX="cilicili_data_"
export MAX_BACKUPS="5"

# ==========================================
# 1. 自动处理 WebDAV 地址与参数
# ==========================================
FOLDER_NAME="${WEBDAV_BACKUP_PATH:-${SYNC_FOLDER:-${SYNC_PATH:-cilicili}}}"
FOLDER_NAME="$(echo "${FOLDER_NAME}" | sed -e 's/^\/*//' -e 's/\/*$//')"

if [[ -n "${WEBDAV_URL:-}" ]] && [[ -n "${WEBDAV_USERNAME:-}" ]]; then
    _wurl="${WEBDAV_URL%/}"
    if [[ -n "${FOLDER_NAME}" ]]; then
        export FULL_WEBDAV_URL="${_wurl}/${FOLDER_NAME}/"
    else
        export FULL_WEBDAV_URL="${_wurl}/"
    fi
    export WEBDAV_CONFIGURED="true"
    log "[WebDAV] Target URL: ${FULL_WEBDAV_URL}"
else
    export WEBDAV_CONFIGURED="false"
    log "[WebDAV] Not configured."
fi

# ==========================================
# 2. 初始化运行环境与各挂载目录
# ==========================================
mkdir -p /data/auth-files /app/auths /root/.cli-proxy-api ~/.cli-proxy-api /CLIProxyAPI /var/log/nginx
SECRET="${SECRET_KEY:-112325}"

cat <<EOF > /app/config.yaml
port: 7862
host: "127.0.0.1"
auth-dir: "/data/auth-files"
remote-management:
  allow-remote: true
  secret-key: "${SECRET}"
EOF

# ==========================================
# 3. 增强版 WebDAV 恢复与备份引擎
# ==========================================
cat << 'PYEOF' > /tmp/_bkengine.py
import sys, os, tarfile, requests, re, time, urllib.parse
import xml.etree.ElementTree as ET

INITIAL_URL = os.environ.get("FULL_WEBDAV_URL", "").strip().rstrip("/") + "/"
USER        = os.environ.get("WEBDAV_USERNAME", "").strip()
PASS        = os.environ.get("WEBDAV_PASSWORD", "").strip()
PFX         = os.environ.get("BACKUP_PREFIX", "cilicili_data_")
MAX         = int(os.environ.get("MAX_BACKUPS", "5"))

BACKUP_PATHS = [
    "/app/config.yaml",
    "/data/auth-files",
    "/app/auths",
    "/root/.cli-proxy-api"
]

def t():
    return f"[{time.strftime('%H:%M:%S')}] "

def list_remote(url):
    if not url: return []
    print(f"{t()}[WebDAV] PROPFIND -> {url}")
    try:
        r = requests.request("PROPFIND", url, auth=(USER, PASS), headers={"Depth": "1"}, timeout=25, allow_redirects=True)
        print(f"{t()}[WebDAV] PROPFIND HTTP status: {r.status_code}")
        if r.status_code not in (200, 207):
            return []

        hrefs = re.findall(r"<[^:>]*:?href[^>]*>([^<]+)</[^:>]*:?href>", r.text, re.I)
        if not hrefs:
            try:
                root = ET.fromstring(r.text)
                hrefs = [h.text for h in root.iter() if h.tag.lower().endswith("href") and h.text]
            except Exception: pass

        backups = []
        for h in hrefs:
            clean = urllib.parse.unquote(h.strip()).rstrip("/").split("/")[-1]
            if clean.startswith(PFX) and clean.endswith(".tar.gz"):
                backups.append(clean)

        return sorted(list(set(backups)))
    except Exception as e:
        print(f"{t()}[WebDAV] Exception: {e}")
        return []

def do_restore():
    url = INITIAL_URL
    backups = list_remote(url)

    if not backups and url.count("/") > 4:
        parts = url.strip("/").split("/")
        root_url = "/".join(parts[:4]) + "/"
        print(f"{t()}[Auto-Fallback] Subdir empty, trying: {root_url}")
        root_backups = list_remote(root_url)
        if root_backups:
            url = root_url
            backups = root_backups

    if not backups:
        print(f"{t()}[Restore] No backups found. Starting fresh.")
        return

    latest = backups[-1]
    print(f"{t()}[Restore] Target archive: {latest}")
    tmp = f"/tmp/{latest}"

    r = requests.get(f"{url}{latest}", auth=(USER, PASS), stream=True, timeout=180, allow_redirects=True)
    if r.status_code != 200:
        print(f"{t()}[Restore] Download failed: HTTP {r.status_code}")
        return

    with open(tmp, "wb") as f:
        for chunk in r.iter_content(65536):
            if chunk: f.write(chunk)

    sz = os.path.getsize(tmp)
    print(f"{t()}[Restore] Archive downloaded: {sz} bytes")

    with tarfile.open(tmp, "r:gz") as tar:
        tar.extractall("/")
    print(f"{t()}[Restore] Successfully unpacked to system.")

    cfg_file = "/app/config.yaml"
    if os.path.exists(cfg_file):
        with open(cfg_file, "r", encoding="utf-8") as f:
            c = f.read()
        c = re.sub(r'port:\s*\d+', 'port: 7862', c)
        c = re.sub(r'host:\s*["\']?[^"\'\n]+["\']?', 'host: "127.0.0.1"', c)
        if "auth-dir:" not in c:
            c += '\nauth-dir: "/data/auth-files"\n'
        else:
            c = re.sub(r'auth-dir:\s*["\']?[^"\'\n]+["\']?', 'auth-dir: "/data/auth-files"', c)
        with open(cfg_file, "w", encoding="utf-8") as f:
            f.write(c)
        print(f"{t()}[Restore] Patched /app/config.yaml (port: 7862, auth-dir: /data/auth-files, size: {len(c)} bytes)")

def do_backup():
    ts = time.strftime("%Y%m%d_%H%M%S")
    fname = f"{PFX}{ts}.tar.gz"
    tmp = f"/tmp/{fname}"

    has_files = False
    with tarfile.open(tmp, "w:gz") as tar:
        for p in set(BACKUP_PATHS):
            if os.path.exists(p):
                tar.add(p, arcname=p.lstrip("/"))
                has_files = True

    if not has_files: return

    with open(tmp, "rb") as f:
        r = requests.put(f"{INITIAL_URL}{fname}", auth=(USER, PASS), data=f, timeout=180)
    print(f"{t()}[Backup] Upload {fname} -> HTTP {r.status_code}")
    if os.path.exists(tmp): os.remove(tmp)

    try:
        remotes = list_remote(INITIAL_URL)
        if len(remotes) > MAX:
            for old in remotes[:-MAX]:
                requests.request("DELETE", f"{INITIAL_URL}{old}", auth=(USER, PASS), timeout=20)
    except Exception: pass

if __name__ == "__main__":
    if len(sys.argv) > 1:
        if sys.argv[1] == "restore": do_restore()
        elif sys.argv[1] == "backup": do_backup()
PYEOF

# ==========================================
# 4. 执行数据恢复与多路径全兼容绑定
# ==========================================
if [[ "$WEBDAV_CONFIGURED" == "true" ]]; then
    log "[System] Running restore routine..."
    "$PY" /tmp/_bkengine.py restore

    mkdir -p /CLIProxyAPI
    cp -f /app/config.yaml /CLIProxyAPI/config.yaml 2>/dev/null || true
    ln -sf /app/config.yaml /CLIProxyAPI/config.yaml 2>/dev/null || true

    log "[System] Bridging auth credential directories..."
    cp -rn /root/.cli-proxy-api/* /data/auth-files/ 2>/dev/null || true
    cp -rn /app/auths/* /data/auth-files/ 2>/dev/null || true
    cp -rn /data/auth-files/* /root/.cli-proxy-api/ 2>/dev/null || true
    chmod -R 777 /data /root/.cli-proxy-api /app/auths /app/config.yaml /CLIProxyAPI 2>/dev/null || true

    (
        trap 'exit 0' TERM INT
        INTERVAL=${SYNC_INTERVAL:-3600}
        while true; do
            sleep "$INTERVAL"
            "$PY" /tmp/_bkengine.py backup || true
        done
    ) &
    log "[Daemon] Backup daemon started."
fi

# ==========================================
# 5. 启动核心服务（显式加载恢复出的 config.yaml）
# ==========================================
log "[System] Launching core service on 127.0.0.1:7862 with config..."
cd /app
"${SERVER_BIN}" -config /app/config.yaml > /tmp/server.log 2>&1 &

sleep 2
log "[System] Core service startup log preview:"
head -n 25 /tmp/server.log || true

# ==========================================
# 6. 启动前台 Nginx 反向代理
# ==========================================
log "[System] Launching Nginx on 0.0.0.0:7860 ..."
exec nginx -g "daemon off;"
