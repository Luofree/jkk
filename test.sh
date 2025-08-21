#!/usr/bin/env bash
# 极简 Python Xray Argo 代理：仅 VLESS + Trojan（更稳健）
set -Eeuo pipefail

PROJECT_DIR="python-xray-argo"
REPO_URL="https://github.com/eooce/python-xray-argo.git"
REPO_ZIP="https://codeload.github.com/eooce/python-xray-argo/zip/refs/heads/main"
NODE_INFO_FILE="$HOME/.xray_nodes_info"
WAIT_MAX=600
SLEEP=5

B='\033[0;34m'; G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; N='\033[0m'
info(){ printf "${B}[INFO]${N} %s\n" "$*"; }
ok(){   printf "${G}[OK]${N} %s\n"   "$*"; }
warn(){ printf "${Y}[WARN]${N} %s\n" "$*"; }
err(){  printf "${R}[ERR]${N} %s\n"  "$*" >&2; }

gen_uuid(){ command -v uuidgen >/dev/null && uuidgen | tr '[:upper:]' '[:lower:]' || python3 - <<'PY'
import uuid; print(uuid.uuid4())
PY
}

prep_workspace(){
  info "当前目录：$(pwd)"
  ls -la || true

  # 同名“文件”会挡住 clone；旧目录也清掉，避免脏状态
  if [ -e "$PROJECT_DIR" ] && [ ! -d "$PROJECT_DIR" ]; then
    warn "'$PROJECT_DIR' 是文件，删除以避免冲突"
    rm -f "$PROJECT_DIR"
  fi
  if [ -d "$PROJECT_DIR" ]; then
    warn "'$PROJECT_DIR' 目录已存在，清理后重拉"
    rm -rf "$PROJECT_DIR"
  fi
}

fetch_repo(){
  info "拉取项目（优先 git，失败走 zip 兜底）"
  if command -v git >/dev/null 2>&1; then
    if git clone --depth 1 "$REPO_URL" "$PROJECT_DIR"; then
      ok "git clone 成功"
    else
      warn "git 失败，改用 zip"
      curl -fsSL "$REPO_ZIP" -o repo.zip
      unzip -q repo.zip && rm -f repo.zip
      mv python-xray-argo-main "$PROJECT_DIR"
    fi
  else
    warn "未检测到 git，直接用 zip"
    curl -fsSL "$REPO_ZIP" -o repo.zip
    unzip -q repo.zip && rm -f repo.zip
    mv python-xray-argo-main "$PROJECT_DIR"
  fi

  [ -d "$PROJECT_DIR" ] || { err "拉取失败：未生成目录 $PROJECT_DIR"; exit 1; }
  [ -f "$PROJECT_DIR/app.py" ] || { err "拉取失败：$PROJECT_DIR/app.py 不存在"; exit 1; }
  ok "项目就绪：$PROJECT_DIR"
}

patch_app(){
  cd "$PROJECT_DIR"
  cp -f app.py app.py.bak || true

  python3 - "$UUID" "$CFIP" "$CFPORT" <<'PY'
import sys, re
uuid, cfip, cfport = sys.argv[1], sys.argv[2], sys.argv[3]
with open('app.py','r',encoding='utf-8') as f:
    s = f.read()

# UUID
s = re.sub(r"UUID\s*=\s*os\.environ\.get\('UUID','[^']*'\)",
           f"UUID=os.environ.get('UUID','{uuid}')", s, 1)

# CFIP/CFPORT（可选）
if cfip:
    s = re.sub(r"CFIP\s*=\s*os\.environ\.get\('CFIP','[^']*'\)",
               f"CFIP=os.environ.get('CFIP','{cfip}')", s, 1)
if cfport:
    s = re.sub(r"CFPORT\s*=\s*int\(os\.environ\.get\('CFPORT','[^']*'\)\)",
               f"CFPORT=int(os.environ.get('CFPORT','{cfport}'))", s, 1)

# 删掉 VMess inbound（端口 3003 那段）
s = re.sub(r'\{"port":3003.*?\},','',s, flags=re.S)

# 订阅文本里去掉 vmess:// 行
s = re.sub(r'vmess://.*\n','',s)

with open('app.py','w',encoding='utf-8') as f:
    f.write(s)
print("patched")
PY
  ok "只保留 VLESS / Trojan 完成"
}

start_and_wait(){
  pkill -f "python3 app.py" >/dev/null 2>&1 || true
  nohup python3 app.py > app.log 2>&1 &
  sleep 2
  APP_PID="$(pgrep -f 'python3 app.py' | head -1 || true)"
  [ -n "$APP_PID" ] || { err "启动失败，查看日志：$(pwd)/app.log"; exit 1; }
  ok "启动成功 PID=$APP_PID"

  info "等待订阅生成（最多 10 分钟）"
  local waited=0 NODES=""
  while [ $waited -lt $WAIT_MAX ]; do
    if   [ -f ".cache/sub.txt" ]; then NODES="$(cat .cache/sub.txt || true)"
    elif [ -f "sub.txt" ];      then NODES="$(cat sub.txt || true)"
    fi
    [ -n "$NODES" ] && break
    if (( waited % 30 == 0 )); then warn "已等待 ${waited}s，隧道建立中…"; fi
    sleep "$SLEEP"; waited=$((waited+SLEEP))
  done
  [ -n "$NODES" ] || { err "超时仍未生成订阅，日志：$(pwd)/app.log"; exit 1; }

  echo -e "\n${Y}=== 订阅（Base64） ===${N}\n$NODES\n"
  local decoded; decoded="$(echo "$NODES" | base64 -d 2>/dev/null || echo "$NODES")"
  echo -e "${Y}=== 解码后的节点（仅 vless/trojan） ===${N}"
  echo "$decoded" | grep -E "^(vless|trojan)://" || echo "$decoded"
  echo

  {
    echo "================ 节点信息保存 ================"
    echo "时间: $(date)"
    echo "UUID: $UUID"
    [ -n "$CFIP" ] && echo "CFIP: $CFIP"
    [ -n "$CFPORT" ] && echo "CFPORT: $CFPORT"
    echo
    echo "=== 订阅（Base64） ==="
    echo "$NODES"
    echo
    echo "=== 解码后的节点 ==="
    echo "$decoded"
  } > "$NODE_INFO_FILE"
  ok "已保存到 $NODE_INFO_FILE"
}

### 入口（只问三项，UUID 必填可自动生成）
read -rp "UUID（回车自动生成）: " UUID
[ -n "$UUID" ] || UUID="$(gen_uuid)"
read -rp "优选 IP/域名 CFIP（可空）: " CFIP
read -rp "优选端口 CFPORT（默认443）: " CFPORT
[ -z "$CFPORT" ] && CFPORT="443"

prep_workspace
fetch_repo
patch_app
start_and_wait
