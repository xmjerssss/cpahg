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
# 1. 账号自检诊断（输出关键调试信息）
# ==========================================
if [[ -n "${WEBDAV_USERNAME:-}" ]] && [[ -n "${WEBDAV_PASSWORD:-}" ]]; then
    export WEBDAV_CONFIGURED="true"
    log "[Debug] Using WebDAV Username: ${WEBDAV_USERNAME}"
    log "[Debug] Using WebDAV Password Length: ${#WEBDAV_PASSWORD} chars"
else
    export WEBDAV_CONFIGURED="false"
    log "[WebDAV] Username or Password not configured."
fi

# ==========================================
# 2. 初始化核心配置
# ==========================================
mkdir -p /data/auth-files /app/auths /root/.cli-proxy-api ~/.cli-proxy-api /var/log/nginx
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
# 3. 增强版全路径智能探测引擎
# ==========================================
cat << 'PYEOF' > /tmp/_bkengine.py
import sys, os, tarfile, requests, re, time, urllib.parse
import xml.etree.ElementTree as ET

USER = os.environ.get("WEBDAV_USERNAME", "").strip()
PASS = os.environ.get("WEBDAV_PASSWORD", "").strip()
PFX  = os.environ.get("BACKUP_PREFIX", "cilicili_data_")
MAX  = int(os.environ.get("MAX_BACKUPS", "5"))

# 待测试的候选地址列表（自动覆盖标准路径与 v2 路径、新旧域名）
CANDIDATE_URLS = [
    "https://mori.infini-cloud.net/dav/cilicili/",
    "https://mori.teracloud.jp/dav/cilicili/",
    "https://mori.infini-cloud.net/v2/dav/cilicili/",
    "https://mori.teracloud.jp/v2/dav/cilicili/",
    "https://mori.infini-cloud.net/dav/",
    "https://mori.teracloud.jp/dav/"
]

def t():
    return f"[{time.strftime('%H:%M:%S')}] "

def probe_and_list(url):
    print(f"{t()}[WebDAV Probe] Trying: {url}")
    try:
        r = requests.request("PROPFIND", url, auth=(USER, PASS), headers={"Depth": "1"}, timeout=15, allow_redirects=True)
        print(f"{t()}[WebDAV Probe] -> HTTP {r.status_code}")
        if r.status_code not in (200, 207):
            return [], r.status_code

        hrefs = re.findall(r"<[^:>]*:?href[^>]*>([^<]+)</[^:>]*:?href>", r.text, re.I)
        if not hrefs:
            try:
                root = ET.fromstring(r.text)
                hrefs = [h.text for h in root.iter() if h.tag.lower().endswith("href") and h.text]
            except Exception: pass

        backups = []
        for h in hrefs:
            clean_name = urllib.parse.unquote(h.strip()).rstrip("/").split("/")[-1]
            if clean_name.startswith(PFX) and clean_name.endswith(".tar.gz"):
                backups.append(clean_name)

        return sorted(list(set(backups))), r.status_code
    except Exception as e:
        print(f"{t()}[WebDAV Probe] Error: {e}")
        return [], 500

def do_restore():
    selected_url = None
    selected_backups = []

    # 循环探测每一个候选地址
    for url in CANDIDATE_URLS:
        backups, code = probe_and_list(url)
        if backups:
            print(f"{t()}[Restore] SUCCESS! Found backup files at: {url}")
            print(f"{t()}[Restore] Matched archives: {backups}")
            selected_url = url
            selected_backups = backups
            break
        elif code in (200, 207):
            print(f"{t()}[Restore] Connected to {url} but no matching {PFX}*.tar.gz found.")

    if not selected_url or not selected_backups:
        print(f"{t()}[Restore] All candidate URLs failed or returned 401/404. Could not restore.")
        return

    latest = selected_backups[-1]
    print(f"{t()}[Restore] Downloading target: {latest}")
    tmp = f"/tmp/{latest}"

    r = requests.get(f"{selected_url}{latest}", auth=(USER, PASS), stream=True, timeout=180, allow_redirects=True)
    if r.status_code != 200:
        print(f"{t()}[Restore] Download failed: HTTP {r.status_code}")
        return

    with open(tmp, "wb") as f:
        for chunk in r.iter_content(65536):
            if chunk: f.write(chunk)

    sz = os.path.getsize(tmp)
    print(f"{t()}[Restore] Archive downloaded: {sz} bytes ({round(sz/1024/1024, 2)} MB)")

    with tarfile.open(tmp, "r:gz") as tar:
        for m in tar.getmembers():
            print(f"  - {m.name} ({m.size} bytes)")
        tar.extractall("/")
    print(f"{t()}[Restore] Extracted successfully.")

    # 自动重置旧配置里的端口为 7862，防端口冲突
    cfg = "/app/config.yaml"
    if os.path.exists(cfg):
        with open(cfg, "r") as f: c = f.read()
        c = re.sub(r'port:\s*\d+', 'port: 7862', c)
        c = re.sub(r'host:\s*["\']?[^"\'\n]+["\']?', 'host: "127.0.0.1"', c)
        with open(cfg, "w") as f: f.write(c)

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "restore":
        do_restore()
PYEOF

# ==========================================
# 4. 执行恢复流程
# ==========================================
if [[ "$WEBDAV_CONFIGURED" == "true" ]]; then
    log "[System] Running multi-path restore sequence..."
    "$PY" /tmp/_bkengine.py restore || true

    log "[System] Bridging auth credential directories..."
    cp -rn /root/.cli-proxy-api/* /data/auth-files/ 2>/dev/null || true
    cp -rn /app/auths/* /data/auth-files/ 2>/dev/null || true
    cp -rn /data/auth-files/* /root/.cli-proxy-api/ 2>/dev/null || true
    chmod -R 777 /data /root/.cli-proxy-api /app/auths 2>/dev/null || true
fi

# ==========================================
# 5. 启动主程序与前台 Nginx
# ==========================================
log "[System] Launching backend service on 127.0.0.1:7862 ..."
cd /app
"${SERVER_BIN}" > /tmp/server.log 2>&1 &

sleep 2
log "[System] Launching Nginx on 0.0.0.0:7860 ..."
exec nginx -g "daemon off;"
