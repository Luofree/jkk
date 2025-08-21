#!/usr/bin/env bash
# 极简 Python Xray Argo 代理，仅 VLESS + Trojan
set -Eeuo pipefail

PROJECT_DIR="python-xray-argo"
REPO_URL="https://github.com/eooce/python-xray-argo.git"
NODE_INFO_FILE="$HOME/.xray_nodes_info"
WAIT_MAX=600
SLEEP=5

# 生成 UUID
gen_uuid(){ command -v uuidgen >/dev/null && uuidgen | tr '[:upper:]' '[:lower:]' || \
python3 - <<'PY'
import uuid; print(uuid.uuid4())
PY
}

# 拉取项目
fetch_repo(){
  [ -d "$PROJECT_DIR" ] || git clone --depth 1 "$REPO_URL" "$PROJECT_DIR"
}

# 写配置：只保留 VLESS 和 Trojan
patch_app(){
  cd "$PROJECT_DIR"
  cp -f app.py app.py.bak || true
  python3 - "$UUID" "$CFIP" "$CFPORT" <<'PY'
import sys,re
uuid,cfip,cfport=sys.argv[1],sys.argv[2],sys.argv[3]
s=open('app.py').read()

# 替换 UUID
s=re.sub(r"UUID\s*=\s*os\.environ\.get\('UUID','[^']*'\)",
         f"UUID=os.environ.get('UUID','{uuid}')",s,1)

# 替换 CFIP/CFPORT
if cfip:
    s=re.sub(r"CFIP\s*=\s*os\.environ\.get\('CFIP','[^']*'\)",
             f"CFIP=os.environ.get('CFIP','{cfip}')",s,1)
if cfport:
    s=re.sub(r"CFPORT\s*=\s*int\(os\.environ\.get\('CFPORT','[^']*'\)\)",
             f"CFPORT=int(os.environ.get('CFPORT','{cfport}'))",s,1)

# 删除 VMess inbound
s=re.sub(r'\{"port":3003.*?\},','',s,flags=re.S)

# 删除生成 VMess 链接的部分（简单粗暴：去掉"vmess://"行）
s=re.sub(r'vmess://.*\n','',s)

open('app.py','w').write(s)
PY
}

# 启动并等待
start_and_wait(){
  pkill -f "python3 app.py" || true
  cd "$PROJECT_DIR"
  nohup python3 app.py > app.log 2>&1 &
  sleep 2
  echo "[INFO] 服务已启动 PID=$(pgrep -f 'python3 app.py'|head -1)"

  waited=0; NODES=""
  while [ $waited -lt $WAIT_MAX ]; do
    [ -f "sub.txt" ] && NODES=$(cat sub.txt)
    [ -n "$NODES" ] && break
    sleep $SLEEP; waited=$((waited+SLEEP))
  done
  [ -n "$NODES" ] || { echo "[ERR] 节点生成失败"; exit 1; }

  echo "[OK] 已生成订阅:"
  echo "$NODES" | grep -E "vless://|trojan://"

  echo "保存到 $NODE_INFO_FILE"
  echo "$NODES" > "$NODE_INFO_FILE"
}

### 入口
read -rp "UUID（回车自动生成）: " UUID
[ -n "$UUID" ] || UUID=$(gen_uuid)
read -rp "优选 IP/域名 CFIP（可空）: " CFIP
read -rp "优选端口 CFPORT（默认443）: " CFPORT
[ -z "$CFPORT" ] && CFPORT=443

fetch_repo
patch_app
start_and_wait
