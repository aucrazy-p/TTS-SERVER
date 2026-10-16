#!/usr/bin/env bash
# TTS-SERVER 一键部署
#
# 用法（仓库已设为 public，可直接拉取）:
#   基础安装:
#     curl -fsSL https://raw.githubusercontent.com/aucrazy-p/TTS-SERVER/main/deploy.sh | bash
#   安装并直接生成 Caddy/Nginx 反代片段(用你的公网域名, 如已把 tts.xxx.org 指向 VPS):
#     DOMAIN=tts.example.com curl -fsSL https://raw.githubusercontent.com/aucrazy-p/TTS-SERVER/main/deploy.sh | bash
#   改用 Cloudflare 隧道(零开放端口, 需浏览器登录 Cloudflare):
#     TUNNEL=1 DOMAIN=tts.example.com curl -fsSL https://raw.githubusercontent.com/aucrazy-p/TTS-SERVER/main/deploy.sh | bash
#   自定义端口(若 8080 被 s-ui/new-api 占用，例如改用 9090):
#     PORT=9090 curl -fsSL https://raw.githubusercontent.com/aucrazy-p/TTS-SERVER/main/deploy.sh | bash
#
# 说明: 服务只监听 127.0.0.1:${PORT}。手机要连，需对外暴露：
#       推荐用你已有的 Caddy/Nginx 反代(脚本会打印片段)；或选 Cloudflare 隧道(零开放端口)。
set -euo pipefail

REPO_URL="https://github.com/aucrazy-p/TTS-SERVER.git"
REPO_RAW="https://raw.githubusercontent.com/aucrazy-p/TTS-SERVER/main"

# root -> /opt/tts-server ; 非 root -> ~/tts-server ; 可用 TTS_SERVER_DIR 覆盖
if [ -n "${TTS_SERVER_DIR:-}" ]; then
  INSTALL_DIR="$TTS_SERVER_DIR"
elif [ "$(id -u)" -eq 0 ]; then
  INSTALL_DIR="/opt/tts-server"
else
  INSTALL_DIR="$HOME/tts-server"
fi

ENV_FILE=".env"

echo "==> TTS-SERVER 一键部署"
echo "    安装目录: $INSTALL_DIR"

# 端口可覆盖 (默认 8080；若被 s-ui / new-api / 其他服务占用请改，如 PORT=9090)
export PORT="${PORT:-8080}"
echo "    监听端口: $PORT"

SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

# ---------- 1. 获取项目文件 ----------
echo "==> 获取项目文件..."
if command -v git >/dev/null 2>&1; then
  if [ -d "$INSTALL_DIR/.git" ]; then
    git -C "$INSTALL_DIR" pull --ff-only || true
  else
    rm -rf "$INSTALL_DIR"
    git clone --depth 1 "$REPO_URL" "$INSTALL_DIR"
  fi
else
  echo "    未检测到 git，改为逐个下载文件..."
  mkdir -p "$INSTALL_DIR"
  cd "$INSTALL_DIR"
  for f in server.py requirements.txt Dockerfile docker-compose.yml tts-server.sh .env.example .gitignore README.md; do
    curl -fsSL "$REPO_RAW/$f" -o "$f"
  done
fi

cd "$INSTALL_DIR"

# ---------- 2. 安装并启动 (本步不需要域名) ----------
echo "==> 安装 docker / 构建镜像 / 启动服务 (本步不需要域名)..."
bash ./tts-server.sh install

# ---------- 3. (可选) Cloudflare 隧道 ----------
setup_tunnel(){
  local domain="${1:-}"
  echo "==> 安装 cloudflared ..."
  local cfarch="amd64"
  case "$(uname -m)" in
    x86_64)  cfarch="amd64" ;;
    aarch64) cfarch="arm64" ;;
  esac
  $SUDO curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$cfarch" -o /usr/local/bin/cloudflared
  $SUDO chmod +x /usr/local/bin/cloudflared

  echo "==> 请在浏览器打开下方链接完成 Cloudflare 登录:"
  cloudflared tunnel login

  if [ -z "$domain" ]; then
    read -rp "输入要绑定的域名 (如 tts.example.com): " domain
  fi
  cloudflared tunnel create tts
  cloudflared tunnel route dns tts "$domain"
  nohup cloudflared tunnel run --url "http://localhost:${PORT}" tts >/var/log/cloudflared.log 2>&1 &
  sleep 2
  echo "==> 隧道已启动 -> https://$domain"
  echo "    到 legado_NG 导入 self-hosted-edge-tts.json，服务地址填 https://$domain"
  echo "    (设为开机自启: cloudflared service install)"
}

# ---------- 3. 对外暴露 ----------
# 默认推荐：用你已有的 Caddy/Nginx 反代（把你的域名解析到 VPS 公网 IP 即可）。
# 备选：Cloudflare 隧道（零开放端口），设置 TUNNEL=1 启用。

print_caddy(){
  local domain="${1:-tts.你的域名.com}"
  local port="$PORT"
  local tok=""
  [ -f "$ENV_FILE" ] && tok=$(grep '^TTS_TOKEN=' "$ENV_FILE" | cut -d= -f2)
  cat > "$INSTALL_DIR/caddy-snippet.txt" <<EOF
# 把下面这段加到你的 Caddyfile，然后执行  caddy reload  （或 systemctl restart caddy）
$domain {
    reverse_proxy 127.0.0.1:$port
}
EOF
  echo "-------------------------------------------"
  echo "在 Caddy 中加入以下站点（反代到本机 $port），然后 reload Caddy："
  echo
  echo "    $domain {"
  echo "        reverse_proxy 127.0.0.1:$port"
  echo "    }"
  echo
  echo "legado_NG 引擎『服务地址』填： https://$domain${tok:+?token=$tok}"
  echo "Caddy 会自动签发 HTTPS 证书；服务本身只监听 127.0.0.1，VPS 无需开放 $port 端口。"
  echo "（片段已同时写入 $INSTALL_DIR/caddy-snippet.txt 方便复制）"
  echo "-------------------------------------------"
}

if [ "${TUNNEL:-0}" = "1" ]; then
  setup_tunnel "${DOMAIN:-}"
elif [ -n "${DOMAIN:-}" ]; then
  print_caddy "$DOMAIN"
elif [ -t 0 ]; then
  echo "如何对外暴露（手机才能连）："
  echo "  1) Caddy/Nginx 反代 (推荐，把你的域名指向 VPS 即可)"
  echo "  2) Cloudflare 隧道 (零开放端口，需浏览器登录 Cloudflare)"
  read -rp "选择 [1/2] (默认1): " m
  if [ "$m" = "2" ]; then
    setup_tunnel
  else
    read -rp "输入你的公网域名 (如 tts.example.com): " d
    print_caddy "$d"
  fi
else
  print_caddy   # 非交互默认给 Caddy 片段（占位域名，用户自行替换）
fi

echo "==> 完成。TTS 服务运行在 127.0.0.1:${PORT}"
