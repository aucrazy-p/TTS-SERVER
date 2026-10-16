#!/usr/bin/env bash
# TTS-SERVER 一键管理脚本
# 用法:
#   交互菜单:  ./tts-server.sh
#   一键安装:  ./tts-server.sh install   (可用于 curl|bash 非交互)
#   更改端口:  NEW_PORT=9090 ./tts-server.sh change-port   (或菜单选 8)
#   查看状态:  ./tts-server.sh status
set -euo pipefail
cd "$(dirname "$0")"

ENV_FILE=".env"
COMPOSE_FILE="docker-compose.yml"
# $DCC 默认项目名=目录名(tts-server)，镜像名即 tts-server-tts
IMAGE="tts-server-tts"

# root 用户不加 sudo；非 root 才加
SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

# 兼容 docker compose(插件) 与 docker-compose(v1)
if docker compose version >/dev/null 2>&1; then
  DCC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  DCC="docker-compose"
else
  DCC="docker compose"   # 兜底：ensure_docker 会补装插件
fi

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info(){ echo -e "${GREEN}[INFO]${NC} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $*"; }
err(){ echo -e "${RED}[ERROR]${NC} $*"; }

ensure_docker(){
  if command -v docker >/dev/null 2>&1; then
    info "docker 已安装"
    if ! docker compose version >/dev/null 2>&1; then
      warn "docker 存在但缺少 compose 插件，尝试安装..."
      if command -v apt-get >/dev/null 2>&1; then
        $SUDO apt-get update && $SUDO apt-get install -y docker-compose-plugin
      elif command -v yum >/dev/null 2>&1; then
        $SUDO yum install -y docker-compose-plugin
      elif command -v dnf >/dev/null 2>&1; then
        $SUDO dnf install -y docker-compose-plugin
      else
        warn "请手动安装 docker-compose-plugin 后重试"
      fi
    fi
  else
    warn "未检测到 docker，尝试安装..."
    if command -v apt-get >/dev/null 2>&1; then
      $SUDO apt-get update && $SUDO apt-get install -y docker.io docker-compose-plugin
    elif command -v yum >/dev/null 2>&1; then
      $SUDO yum install -y docker docker-compose-plugin
    elif command -v dnf >/dev/null 2>&1; then
      $SUDO dnf install -y docker docker-compose-plugin
    else
      err "无法自动安装 docker，请手动安装后重试"; exit 1
    fi
    $SUDO systemctl enable --now docker
  fi
}

get_port(){
  local p
  p=$(grep '^PORT=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2 | tr -d ' ')
  case "$p" in
    ''|*[!0-9]*) echo 8080 ;;
    *) echo "$p" ;;
  esac
}

port_in_use(){
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$"
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$"
  else
    return 1
  fi
}

check_port(){
  local p; p=$(get_port)
  if port_in_use "$p"; then
    err "端口 $p 已被占用（可能被 s-ui / new-api / 其他服务占用）。"
    err "请在 .env 里把 PORT 改成其他空闲端口后重试，例如："
    err "  sed -i 's/^PORT=.*/PORT=9090/' .env && bash ./tts-server.sh install"
    exit 1
  fi
}

gen_env(){
  if [ ! -f "$ENV_FILE" ]; then
    local tok port
    tok=$(openssl rand -hex 16)
    port="${PORT:-8080}"
    cat > "$ENV_FILE" <<EOF
# Cloudflare 隧道公开暴露时强烈建议设置，legado_NG 引擎里填同样的 token
TTS_TOKEN=$tok
PORT=$port
EOF
    info "已生成 $ENV_FILE (TTS_TOKEN=$tok, PORT=$port)"
  else
    info "$ENV_FILE 已存在，跳过生成"
  fi
}

show_url(){
  local tok="" port
  port=$(get_port)
  [ -f "$ENV_FILE" ] && tok=$(grep '^TTS_TOKEN=' "$ENV_FILE" | cut -d= -f2)
  echo "----------------------------------------"
  info "本地访问: http://127.0.0.1:$port"
  [ -n "$tok" ] && info "TTS_TOKEN: $tok"
  echo "legado_NG 引擎服务地址示例: https://tts.你的域名.com${tok:+?token=$tok}"
  echo "----------------------------------------"
}

install(){
  ensure_docker
  gen_env
  check_port
  if docker image inspect tts-server-tts >/dev/null 2>&1; then
    info "镜像已存在，直接启动 ($DCC up -d) ..."
    $DCC up -d
  else
    info "首次构建并启动服务 ($DCC up -d --build) ..."
    $DCC up -d --build
  fi
  show_url
}

uninstall(){
  info "停止并移除容器与卷..."
  $DCC down -v || true
  if docker image inspect "$IMAGE" >/dev/null 2>&1; then
    docker image rm -f "$IMAGE" || true
  fi
  info "已卸载（容器/镜像已移除，$ENV_FILE 保留以便重装）"
}

start(){ check_port; $DCC up -d; info "已启动"; }
stop(){ $DCC stop; info "已停止"; }

status(){
  $DCC ps
  echo "---- 当前配置 ----"
  [ -f "$ENV_FILE" ] && grep -E '^(TTS_TOKEN|PORT)=' "$ENV_FILE"
}

logs(){ $DCC logs -f --tail=50 tts; }

update(){
  info "拉取最新代码并重建镜像..."
  git pull || warn "非 git 目录或 pull 失败，跳过更新源码"
  $DCC up -d --build
  info "更新完成"
}

# 定位 Caddyfile（优先 systemd --config，否则常见路径）
find_caddyfile(){
  local cf=""
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files caddy.service >/dev/null 2>&1; then
    cf=$(systemctl show caddy.service -p ExecStart --value 2>/dev/null | grep -oE '(^| )--config[= ]\S+' | head -1 | sed -E 's/.*--config[= ]//')
  fi
  if [ -z "$cf" ]; then
    for p in /etc/caddy/Caddyfile /usr/local/etc/caddy/Caddyfile "$HOME/Caddyfile" /etc/caddy/caddy.json; do
      [ -f "$p" ] && cf="$p" && break
    done
  fi
  echo "$cf"
}

# 在 TTS 标记块内把反代端口改为 new，并 reload caddy
update_caddy_port(){
  local old="$1" new="$2" cf
  cf=$(find_caddyfile)
  if [ -z "$cf" ]; then
    warn "未找到 Caddyfile，无法自动更新反代端口，请手动把反代端口改为 $new"
    return 1
  fi
  if head -c1 "$cf" | grep -q '{'; then
    warn "Caddy 使用 JSON 配置，无法自动编辑，请手动把反代端口改为 $new"
    return 1
  fi
  if ! grep -q '# >>> Added by TTS-SERVER' "$cf"; then
    warn "Caddyfile 中未找到 TTS-SERVER 标记块（可能未走自动反代），请手动把反代端口改为 $new"
    return 1
  fi
  cp "$cf" "${cf}.bak.$(date +%s)"
  awk -v new="$new" '
    /# >>> Added by TTS-SERVER/ { inblk=1 }
    inblk && /reverse_proxy 127\.0\.0\.1:/ { print "    reverse_proxy 127.0.0.1:" new; next }
    /# >>> end TTS-SERVER/ { inblk=0 }
    { print }
  ' "$cf" > "${cf}.tmp" && mv "${cf}.tmp" "$cf"
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet caddy; then
    systemctl reload caddy && info "caddy 已 reload" || warn "caddy reload 失败，请手动: caddy reload"
  else
    caddy reload --config "$cf" >/dev/null 2>&1 && info "caddy 已 reload" || warn "caddy reload 失败，请手动: caddy reload"
  fi
}

# 更改监听端口：更新 .env -> 重启容器 -> 同步更新 Caddy 反代端口
change_port(){
  local old new
  old=$(get_port)
  if [ -n "${NEW_PORT:-}" ]; then
    new="$NEW_PORT"
  else
    read -rp "当前端口 $old，输入新端口 (留空取消): " new
  fi
  [ -z "$new" ] && { info "已取消更改"; return; }
  case "$new" in
    ''|*[!0-9]*) err "端口必须是数字"; return ;;
  esac
  if [ "$new" = "$old" ]; then
    info "新端口与当前相同，无需更改"; return
  fi
  if port_in_use "$new"; then
    err "端口 $new 已被占用，请换一个空闲端口"
    return
  fi
  if [ -f "$ENV_FILE" ]; then
    if grep -q '^PORT=' "$ENV_FILE"; then
      sed -i "s/^PORT=.*/PORT=$new/" "$ENV_FILE"
    else
      printf 'PORT=%s\n' "$new" >> "$ENV_FILE"
    fi
  else
    printf 'TTS_TOKEN=%s\nPORT=%s\n' "$(openssl rand -hex 16)" "$new" > "$ENV_FILE"
  fi
  info "已更新 .env -> PORT=$new"
  ensure_docker
  $DCC up -d
  info "容器已用新端口重启"
  if update_caddy_port "$old" "$new"; then
    info "反代端口已同步为 $new"
  fi
  show_url
}

menu(){
  while true; do
    clear
    echo "====== TTS-SERVER 管理菜单 ======"
    echo " 1) 安装 install"
    echo " 2) 卸载 uninstall"
    echo " 3) 启动 start"
    echo " 4) 停止 stop"
    echo " 5) 状态 status"
    echo " 6) 查看日志 logs"
    echo " 7) 更新 update"
    echo " 8) 更改端口 change-port"
    echo " 0) 退出"
    read -rp "请选择 [0-9]: " c
    case "$c" in
      1) install ;;
      2) uninstall ;;
      3) start ;;
      4) stop ;;
      5) status ;;
      6) logs ;;
      7) update ;;
      8) change_port ;;
      0) exit 0 ;;
      *) warn "无效选择" ;;
    esac
    echo; read -rp "按回车返回菜单..." _
  done
}

case "${1:-}" in
  install)     install; exit 0 ;;
  uninstall)   uninstall; exit 0 ;;
  start)       start; exit 0 ;;
  stop)        stop; exit 0 ;;
  status)      status; exit 0 ;;
  logs)        logs; exit 0 ;;
  update)      update; exit 0 ;;
  change-port) change_port; exit 0 ;;
esac

menu
