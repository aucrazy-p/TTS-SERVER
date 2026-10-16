#!/usr/bin/env bash
# TTS-SERVER 一键部署
#
# 用法（仓库已设为 public，可直接拉取）:
#   基础安装(无需域名):
#     curl -fsSL https://raw.githubusercontent.com/aucrazy-p/TTS-SERVER/main/deploy.sh | bash
#   安装并自动建 Cloudflare 隧道(仍需在浏览器登录 Cloudflare):
#     DOMAIN=tts.example.com curl -fsSL https://raw.githubusercontent.com/aucrazy-p/TTS-SERVER/main/deploy.sh | bash
#   自定义端口(若 8080 被 s-ui/new-api 占用，例如改用 9090):
#     PORT=9090 curl -fsSL https://raw.githubusercontent.com/aucrazy-p/TTS-SERVER/main/deploy.sh | bash
#
# 说明: 服务本身只监听 127.0.0.1:${PORT}，安装阶段【不需要域名】。
#       域名仅在「想从手机 legado_NG 远程访问」时通过 Cloudflare 隧道使用。
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

if [ -n "${DOMAIN:-}" ]; then
  setup_tunnel "$DOMAIN"
elif [ -t 0 ]; then
  read -rp "是否现在配置 Cloudflare 隧道(需浏览器登录 Cloudflare)? (y/N): " ans
  [[ "$ans" == [yY] ]] && setup_tunnel
else
  echo
  echo "-------------------------------------------"
  echo "服务已在 127.0.0.1:${PORT} 启动。如需从手机(legado_NG)远程访问，"
  echo "再配置 Cloudflare 隧道即可（本步不需要域名）："
  echo "  cloudflared tunnel login"
  echo "  cloudflared tunnel create tts"
  echo "  cloudflared tunnel route dns tts tts.你的域名.com"
  echo "  cloudflared tunnel run --url http://localhost:${PORT} tts"
  echo "然后到 legado_NG 导入 self-hosted-edge-tts.json，服务地址填 https://tts.你的域名.com"
  echo "-------------------------------------------"
fi

echo "==> 完成。服务运行在 127.0.0.1:${PORT}"
