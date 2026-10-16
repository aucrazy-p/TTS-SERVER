#!/usr/bin/env bash
# TTS-SERVER 一键管理脚本
# 用法:
#   交互菜单:  ./tts-server.sh
#   一键安装:  ./tts-server.sh install   (可用于 curl|bash 非交互)
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

gen_env(){
  if [ ! -f "$ENV_FILE" ]; then
    local tok
    tok=$(openssl rand -hex 16)
    cat > "$ENV_FILE" <<EOF
# Cloudflare 隧道公开暴露时强烈建议设置，legado_NG 引擎里填同样的 token
TTS_TOKEN=$tok
PORT=8080
EOF
    info "已生成 $ENV_FILE (TTS_TOKEN=$tok)"
  else
    info "$ENV_FILE 已存在，跳过生成"
  fi
}

show_url(){
  local tok=""
  [ -f "$ENV_FILE" ] && tok=$(grep '^TTS_TOKEN=' "$ENV_FILE" | cut -d= -f2)
  echo "----------------------------------------"
  info "本地访问: http://127.0.0.1:8080"
  [ -n "$tok" ] && info "TTS_TOKEN: $tok"
  echo "legado_NG 引擎服务地址示例: https://tts.你的域名.com${tok:+?token=$tok}"
  echo "----------------------------------------"
}

install(){
  ensure_docker
  gen_env
  info "构建并启动服务 ($DCC up -d --build) ..."
  $DCC up -d --build
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

start(){ $DCC up -d; info "已启动"; }
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

tunnel_help(){
  echo "Cloudflare 隧道（VPS 防火墙零开放端口）："
  echo "  cloudflared tunnel login"
  echo "  cloudflared tunnel create tts"
  echo "  cloudflared tunnel route dns tts tts.你的域名.com"
  echo "  cloudflared tunnel run --url http://localhost:8080 tts"
  echo "然后在 legado_NG 导入 self-hosted-edge-tts.json，"
  echo "把\"服务地址\"改成 https://tts.你的域名.com（设了 token 就加 ?token=...）"
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
    echo " 8) Cloudflare 隧道指引 tunnel"
    echo " 0) 退出"
    read -rp "请选择 [0-8]: " c
    case "$c" in
      1) install ;;
      2) uninstall ;;
      3) start ;;
      4) stop ;;
      5) status ;;
      6) logs ;;
      7) update ;;
      8) tunnel_help ;;
      0) exit 0 ;;
      *) warn "无效选择" ;;
    esac
    echo; read -rp "按回车返回菜单..." _
  done
}

case "${1:-}" in
  install)   install; exit 0 ;;
  uninstall) uninstall; exit 0 ;;
  start)     start; exit 0 ;;
  stop)      stop; exit 0 ;;
  status)    status; exit 0 ;;
  logs)      logs; exit 0 ;;
  update)    update; exit 0 ;;
esac

menu
