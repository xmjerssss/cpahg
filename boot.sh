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
# 1. 自动兼容环境变量名称 (WEBDAV_BACKUP_PATH / SYNC_FOLDER / SYNC_PATH)
# ==========================================
FOLDER_NAME="${WEBDAV_BACKUP_PATH:-${SYNC_FOLDER:-${SYNC_PATH:-cilicili}}}"
# 去除首尾的斜杠，保持干净目录名
FOLDER_NAME="$(echo "${FOLDER_NAME}" | sed -e 's/^\/*//' -e 's/\/*$//')"

if [[ -n "${WEBDAV_URL:-}" ]] && [[ -n "${WEBDAV_USERNAME:-}" ]]; then
    _wurl="${WEBDAV_URL%/}"
    if [[ -n "${FOLDER_NAME}" ]]; then
        export FULL_WEBDAV_URL="${_wurl}/${FOLDER_NAME}/"
    else
        export FULL_WEBDAV_URL="${_wurl}/"
    fi
    export WEBDAV_CONFIGURED="true"
    log "[Config] WebDAV URL: ${FULL_WEBDAV_URL}"
else
    export WEBDAV_CONFIGURED="false"
    log "[Config] WebDAV credentials missing, backup/restore disabled."
fi

# ==========================================
# 2. 初始化本地运行环境与默认配置 (内部端口 7862)
# ==========================================
mkdir -p /data/auth-files /app/auths ~/.cli-proxy-api /root/.cli-proxy-api /var/log/nginx
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
# 3. 增强版 WebDAV 备份与恢复引擎
# ==========================================
cat << 'PYEOF' > /tmp/_bkengine.py
import sys, os, tarfile, requests, re, time, urllib.parse
import xml.etree.ElementTree as ET

URL  = os.environ.get("FULL_WEBDAV_URL", "").rstrip("/") + "/"
USER = os.environ.get("WEBDAV_USERNAME", "")
PASS = os.environ.get("WEBDAV_PASSWORD", "")
PFX  = os.environ.get("BACKUP_PREFIX", "cilicili_data_")
MAX  = int(os.environ.get("MAX_BACKUPS", "5"))

BACKUP_PATHS = [
    "/app/config.yaml",
    "/data/auth-files",
    "/app/auths",
    os.path.expanduser("~/.cli-proxy-api"),
    "/root/.cli-proxy-api"
]

def t():
    return f"[{time.strftime('%H:%M:%S')}] "

def list_remote():
    if not URL: return []
    print(f"{t()}[WebDAV] Querying: {URL}")
    try:
        r = requests.request("PROPFIND", URL, auth=(USER, PASS), headers={"Depth": "1"}, timeout=25, allow_redirects=True)
        print(f"{t()}[WebDAV] PROPFIND response: HTTP {r.status_code}")
        if r.status_code not in (200, 207):
            print(f"{t()}[WebDAV] Query failed: {r.text[:200]}")
            return []
        
        # 兼容各种大小写与命名空间的 href 标签 (d:href, D:href, href)
        hrefs = re.findall(r"<[^:>]*:?href[^>]*>([^<]+)</[^:>]*:?href>", r.text, re.I)
        if not hrefs:
            try:
                root = ET.fromstring(r.text)
                hrefs = [h.text for h in root.iter() if h.tag.lower().endswith("href") and h.text]
            except Exception:
                pass
        
        res = []
        for h in hrefs:
            # URL 解码，防止文件名中出现 %20 等符号
            decoded_h = urllib.parse.unquote(h.strip())
            name = decoded_h.rstrip("/").split("/")[-1]
            if name.startswith(PFX) and name.endswith(".tar.gz"):
                res.append(name)
        
        res = sorted(list(set(res)))
        print(f"{t()}[WebDAV] Available backups detected: {res}")
        return res
    except Exception as e:
        print(f"{t()}[WebDAV] Network/Parser error: {e}")
        return []

def do_restore():
    backups = list_remote()
    if not backups:
        print(f"{t()}[Restore] No backup archive matched prefix '{PFX}'. Starting fresh.")
        return
        
    latest = backups[-1]
    print(f"{t()}[Restore] Target latest archive: {latest}")
    
    tmp = f"/tmp/{latest}"
    target_url = f"{URL}{latest}"
    r = requests.get(target_url, auth=(USER, PASS), stream=True, timeout=180, allow_redirects=True)
    print(f"{t()}[Restore] Download HTTP status: {r.status_code}")
    
    if r.status_code != 200:
        print(f"{t()}[Restore] Download error: {r.text[:300]}")
        return
        
    with open(tmp, "wb") as f:
        for chunk in r.iter_content(65536):
            if chunk: f.write(chunk)
            
    sz = os.path.getsize(tmp)
    print(f"{t()}[Restore] Archive downloaded successfully: {sz} bytes ({round(sz/1024/1024, 2)} MB)")
    
    if sz < 100:
        print(f"{t()}[Restore] File too small or invalid, skipping.")
        return

    print(f"{t()}[Restore] Unpacking files to system root...")
    with tarfile.open(tmp, "r:gz") as tar:
        tar.extractall("/")
    print(f"{t()}[Restore] Extract complete.")
    
    # 核心保护：解压出来的历史 config.yaml 会把端口重置为 7860，必须强制修正为 7862
    cfg_file = "/app/config.yaml"
    if os.path.exists(cfg_file):
        with open(cfg_file, "r", encoding="utf-8") as f:
            content = f.read()
        content = re.sub(r'port:\s*\d+', 'port: 7862', content)
        content = re.sub(r'host:\s*["\']?[^"\'\n]+["\']?', 'host: "127.0.0.1"', content)
        with open(cfg_file, "w", encoding="utf-8") as f:
            f.write(content)
        print(f"{t()}[Restore] Successfully patched /app/config.yaml to port: 7862")

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
                
    if not has_files:
        print(f"{t()}[Backup] No auth or config files to backup.")
        return
        
    with open(tmp, "rb") as f:
        r = requests.put(f"{URL}{fname}", auth=(USER, PASS), data=f, timeout=180)
    
    if r.status_code in (200, 201, 204):
        print(f"{t()}[Backup] Backup created successfully: {fname}")
    else:
        print(f"{t()}[Backup] Upload failed: HTTP {r.status_code}")
        
    if os.path.exists(tmp): os.remove(tmp)
    
    # 清理多余旧版本
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
# 4. 执行数据恢复（前台运行，输出关键信息）
# ==========================================
if [[ "$WEBDAV_CONFIGURED" == "true" ]]; then
    # 若文件夹不存在尝试创建
    curl -ms 5 -X MKCOL -u "${WEBDAV_USERNAME}:${WEBDAV_PASSWORD}" "${FULL_WEBDAV_URL}" >/dev/null 2>&1 || true
    log "[System] Initiating data restore sequence..."
    "$PY" /tmp/_bkengine.py restore
    
    # 启动后台守护定时备份
    (
        trap 'exit 0' TERM INT
        INTERVAL=${SYNC_INTERVAL:-3600}
        while true; do
            sleep "$INTERVAL"
            "$PY" /tmp/_bkengine.py backup || true
        done
    ) &
    log "[Daemon] Backup daemon registered (Interval: ${SYNC_INTERVAL:-3600}s)."
fi

# ==========================================
# 5. 启动主程序与前台 Nginx
# ==========================================
log "[System] Starting backend service on 127.0.0.1:7862 ..."
"${SERVER_BIN}" > /tmp/server.log 2>&1 &

log "[System] Starting Nginx on 0.0.0.0:7860 ..."
exec nginx -g "daemon off;"
