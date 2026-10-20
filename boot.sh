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
# 1. 修复：强制规范 WebDAV 目录 URL（必须以 / 结尾）
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
# 2. 初始化目录结构与默认配置（内部端口 7862）
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
# 3. 增强版同步与恢复引擎
# ==========================================
cat << 'PYEOF' > /tmp/_bkengine.py
import sys, os, tarfile, requests, re, time, urllib.parse
import xml.etree.ElementTree as ET

# 确保 URL 严格以 / 结尾，杜绝 301 重定向
URL  = os.environ.get("FULL_WEBDAV_URL", "").rstrip("/") + "/"
USER = os.environ.get("WEBDAV_USERNAME", "")
PASS = os.environ.get("WEBDAV_PASSWORD", "")
PFX  = os.environ.get("BACKUP_PREFIX", "cilicili_data_")
MAX  = int(os.environ.get("MAX_BACKUPS", "5"))

BACKUP_PATHS = [
    "/app/config.yaml",
    "/data/auth-files",
    "/app/auths",
    "/root/.cli-proxy-api"
]

def t():
    return f"[{time.strftime('%H:%M:%S')}] "

def list_remote():
    if not URL: return []
    print(f"{t()}[WebDAV] PROPFIND -> {URL}")
    try:
        r = requests.request("PROPFIND", URL, auth=(USER, PASS), headers={"Depth": "1"}, timeout=30, allow_redirects=True)
        print(f"{t()}[WebDAV] PROPFIND HTTP status: {r.status_code}")
        if r.status_code not in (200, 207):
            print(f"{t()}[WebDAV] HTTP {r.status_code} Error: {r.text[:200]}")
            return []

        # 不区分大小写匹配 <d:href>, <D:href>, <href>
        hrefs = re.findall(r"<[^:>]*:?href[^>]*>([^<]+)</[^:>]*:?href>", r.text, re.I)
        if not hrefs:
            try:
                root = ET.fromstring(r.text)
                hrefs = [h.text for h in root.iter() if h.tag.lower().endswith("href") and h.text]
            except Exception:
                pass

        backups = []
        for h in hrefs:
            clean_name = urllib.parse.unquote(h.strip()).rstrip("/").split("/")[-1]
            if clean_name.startswith(PFX) and clean_name.endswith(".tar.gz"):
                backups.append(clean_name)

        backups = sorted(list(set(backups)))
        print(f"{t()}[WebDAV] Matching backups: {backups}")
        return backups
    except Exception as e:
        print(f"{t()}[WebDAV] Scan exception: {e}")
        return []

def do_restore():
    backups = list_remote()
    if not backups:
        print(f"{t()}[Restore] No backups found in {URL} starting fresh.")
        return

    latest = backups[-1]
    print(f"{t()}[Restore] Selecting: {latest}")
    tmp = f"/tmp/{latest}"
    
    r = requests.get(f"{URL}{latest}", auth=(USER, PASS), stream=True, timeout=180, allow_redirects=True)
    if r.status_code != 200:
        print(f"{t()}[Restore] Download failed: HTTP {r.status_code}")
        return

    with open(tmp, "wb") as f:
        for chunk in r.iter_content(65536):
            if chunk: f.write(chunk)

    sz = os.path.getsize(tmp)
    print(f"{t()}[Restore] Downloaded {sz} bytes ({round(sz/1024/1024, 2)} MB)")
    if sz < 100:
        print(f"{t()}[Restore] File corrupted (too small).")
        return

    # 打印压缩包内的文件目录，彻底摸清原始数据位置
    print(f"{t()}[Restore] Inspecting files inside archive:")
    with tarfile.open(tmp, "r:gz") as tar:
        for m in tar.getmembers():
            print(f"  - {m.name} ({m.size} bytes)")
        tar.extractall("/")
    print(f"{t()}[Restore] Files extracted to system.")

    # 修正恢复出的旧 config.yaml 端口，防止与 Nginx 冲突
    cfg_file = "/app/config.yaml"
    if os.path.exists(cfg_file):
        with open(cfg_file, "r", encoding="utf-8") as f:
            c = f.read()
        c = re.sub(r'port:\s*\d+', 'port: 7862', c)
        c = re.sub(r'host:\s*["\']?[^"\'\n]+["\']?', 'host: "127.0.0.1"', c)
        # 强制指定 auth-dir 统一为 /data/auth-files
        if "auth-dir:" not in c:
            c += '\nauth-dir: "/data/auth-files"\n'
        else:
            c = re.sub(r'auth-dir:\s*["\']?[^"\'\n]+["\']?', 'auth-dir: "/data/auth-files"', c)
        with open(cfg_file, "w", encoding="utf-8") as f:
            f.write(c)
        print(f"{t()}[Restore] Corrected /app/config.yaml (port: 7862, auth-dir: /data/auth-files)")

def do_backup():
    ts = time.strftime("%Y%m%d_%H%M%S")
    fname = f"{PFX}{ts}.tar.gz"
    tmp = f"/tmp/{fname}"

    added = False
    with tarfile.open(tmp, "w:gz") as tar:
        for p in set(BACKUP_PATHS):
            if os.path.exists(p):
                tar.add(p, arcname=p.lstrip("/"))
                added = True

    if not added: return

    with open(tmp, "rb") as f:
        r = requests.put(f"{URL}{fname}", auth=(USER, PASS), data=f, timeout=180)
    print(f"{t()}[Backup] Upload {fname} -> HTTP {r.status_code}")
    if os.path.exists(tmp): os.remove(tmp)

    try:
        remotes = list_remote()
        if len(remotes) > MAX:
            for old in remotes[:-MAX]:
                requests.request("DELETE", f"{URL}{old}", auth=(USER, PASS), timeout=20)
                print(f"{t()}[Backup] Pruned old backup: {old}")
    except Exception:
        pass

if __name__ == "__main__":
    if len(sys.argv) > 1:
        if sys.argv[1] == "restore": do_restore()
        elif sys.argv[1] == "backup": do_backup()
PYEOF

# ==========================================
# 4. 执行恢复与数据目录互通同步
# ==========================================
if [[ "$WEBDAV_CONFIGURED" == "true" ]]; then
    curl -ms 5 -X MKCOL -u "${WEBDAV_USERNAME}:${WEBDAV_PASSWORD}" "${FULL_WEBDAV_URL}" >/dev/null 2>&1 || true
    log "[System] Running restore routine..."
    "$PY" /tmp/_bkengine.py restore

    # 关键修复：把所有可能存有历史凭据的目录全部同步到 /data/auth-files
    log "[System] Bridging auth credential directories..."
    cp -rn /root/.cli-proxy-api/* /data/auth-files/ 2>/dev/null || true
    cp -rn /app/auths/* /data/auth-files/ 2>/dev/null || true
    # 同时建立反向兼容，保证无论程序读哪个路径都能读到
    cp -rn /data/auth-files/* /root/.cli-proxy-api/ 2>/dev/null || true
    chmod -R 777 /data /root/.cli-proxy-api /app/auths 2>/dev/null || true

    # 注册定时备份守护进程
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
# 5. 启动核心与 Nginx 反向代理
# ==========================================
log "[System] Launching core service on 127.0.0.1:7862 ..."
cd /app
"${SERVER_BIN}" > /tmp/server.log 2>&1 &

# 等待核心服务就绪
sleep 2

log "[System] Launching Nginx on 0.0.0.0:7860 ..."
exec nginx -g "daemon off;"
