#!/usr/bin/env bash
# TTS-SERVER 一键部署
#
# 用法（仓库已设为 public，可直接拉取）:
#   基础安装(无域名时不自动配反代，仅本地 127.0.0.1:8080):
#     curl -fsSL https://raw.githubusercontent.com/aucrazy-p/TTS-SERVER/main/deploy.sh | bash
#   安装并自动配置 Caddy 反代(写 Caddyfile + reload; 若 VPS 未装 Caddy 会自动安装; 需域名已指向 VPS):
#     curl -fsSL https://raw.githubusercontent.com/aucrazy-p/TTS-SERVER/main/deploy.sh | DOMAIN=tts.example.com bash
#   改用 Cloudflare 隧道(零开放端口, 需浏览器登录 Cloudflare):
#     curl -fsSL https://raw.githubusercontent.com/aucrazy-p/TTS-SERVER/main/deploy.sh | TUNNEL=1 DOMAIN=tts.example.com bash
#   自定义端口(若 8080 被 s-ui/new-api 占用，例如改用 9090):
#     curl -fsSL https://raw.githubusercontent.com/aucrazy-p/TTS-SERVER/main/deploy.sh | PORT=9090 bash
#
# ⚠️ 环境变量(DOMAIN/PORT/TUNNEL)必须放在 bash 一侧，不能放在 curl 一侧——
#    `VAR=val curl | bash` 中 VAR 只传给 curl，脚本收不到，会自动退回手动配置。
#
# 说明: 服务只监听 127.0.0.1:${PORT}。手机要连需对外暴露，默认自动配置 Caddy 反代
#       (把域名写进 Caddyfile 并 reload)。也可 TUNNEL=1 走 Cloudflare 隧道(零开放端口)。
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

info(){ echo "[INFO] $*"; }
warn(){ echo "[WARN] $*"; }
err(){ echo "[ERROR] $*"; }

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
# 默认：自动把域名反代写进 Caddyfile 并 reload（Caddy 未装会自动安装；域名需已指向 VPS）。
# 备选：Cloudflare 隧道（零开放端口），设置 TUNNEL=1 启用（仍需浏览器登录）。

# 端口占用检测（判断是否已有 Nginx/Caddy 占 80/443）
port_in_use(){
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | grep -q ":$p "
  else
    (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null
  fi
}

# 自动安装 Caddy（静态二进制 + systemd），未安装时调用
install_caddy(){
  info "未检测到 caddy，开始自动安装..."
  local arch="amd64"
  case "$(uname -m)" in
    x86_64)  arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
  esac
  $SUDO curl -fsSL "https://github.com/caddyserver/caddy/releases/latest/download/caddy_linux_${arch}.tar.gz" -o /tmp/caddy.tar.gz \
    || { err "下载 Caddy 失败（无网络？）"; return 1; }
  $SUDO tar -xzf /tmp/caddy.tar.gz -C /usr/local/bin/ caddy \
    || { err "解压 Caddy 失败"; return 1; }
  $SUDO chmod +x /usr/local/bin/caddy
  $SUDO mkdir -p /etc/caddy
  if [ ! -f /etc/caddy/Caddyfile ]; then
    $SUDO tee /etc/caddy/Caddyfile >/dev/null <<'EOF'
{
    # Caddy 全局选项（如需证书到期通知可填 email）
}
EOF
  fi
  if command -v systemctl >/dev/null 2>&1; then
    $SUDO tee /etc/systemd/system/caddy.service >/dev/null <<'EOF'
[Unit]
Description=Caddy
After=network.target

[Service]
ExecStart=/usr/local/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable --now caddy || warn "caddy 启动失败，请检查 80/443 是否被占用"
  else
    $SUDO caddy start --config /etc/caddy/Caddyfile || warn "caddy 启动失败"
  fi
  command -v caddy >/dev/null 2>&1
}

# 仅在无法自动改 Caddyfile 时回退：把片段打印并写入文件供手动加。
print_caddy(){
  local domain="${1:-tts.example.com}"
  local tok=""
  [ -f "$ENV_FILE" ] && tok=$(grep '^TTS_TOKEN=' "$ENV_FILE" | cut -d= -f2)
  cat > "$INSTALL_DIR/caddy-snippet.txt" <<EOF
# 把下面这段加到你的 Caddyfile，然后执行  caddy reload  （或 systemctl restart caddy）
$domain {
    reverse_proxy 127.0.0.1:$PORT
}
EOF
  echo "-------------------------------------------"
  echo "请手动在 Caddy 中加入以下站点（反代到本机 $PORT），然后 reload Caddy："
  echo
  echo "    $domain {"
  echo "        reverse_proxy 127.0.0.1:$PORT"
  echo "    }"
  echo
  echo "legado_NG 引擎『服务地址』填： https://$domain${tok:+?token=$tok}"
  echo "（片段已写入 $INSTALL_DIR/caddy-snippet.txt）"
  echo "-------------------------------------------"
}

# 自动定位 Caddyfile -> 备份 -> 追加域名反代块 -> reload（幂等）。
setup_caddy(){
  local domain="${1:-}"
  [ -z "$domain" ] && read -rp "输入你的公网域名 (如 tts.example.com): " domain
  [ -z "$domain" ] && { err "未提供域名，跳过对外暴露"; return; }

  if ! command -v caddy >/dev/null 2>&1; then
    if port_in_use 80 || port_in_use 443; then
      warn "检测到 80/443 已被其他服务占用（可能已跑 Nginx/Caddy），不再重复安装 Caddy，避免冲突。"
      warn "请把下面片段加进你现有的反代配置："
      print_caddy "$domain"; return
    fi
    warn "未检测到 caddy，尝试自动安装..."
    install_caddy || { warn "caddy 安装失败，改为打印片段："; print_caddy "$domain"; return; }
  fi

  # 定位 Caddyfile
  local cf=""
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files caddy.service >/dev/null 2>&1; then
    cf=$(systemctl show caddy.service -p ExecStart --value 2>/dev/null | grep -oE '(^| )--config[= ]\S+' | head -1 | sed -E 's/.*--config[= ]//')
  fi
  if [ -z "$cf" ]; then
    for p in /etc/caddy/Caddyfile /usr/local/etc/caddy/Caddyfile "$HOME/Caddyfile" /etc/caddy/caddy.json; do
      [ -f "$p" ] && cf="$p" && break
    done
  fi
  if [ -z "$cf" ]; then
    warn "未找到 Caddyfile，改为打印片段："; print_caddy "$domain"; return
  fi
  # JSON 配置无法直接追加 Caddyfile 片段
  if head -c1 "$cf" | grep -q '{'; then
    warn "检测到 Caddy 使用 JSON 配置，自动写入不适用，改为打印片段："
    print_caddy "$domain"; return
  fi

  # 备份
  cp "$cf" "${cf}.bak.$(date +%s)"
  # 已含该域名则跳过
  if grep -q "$domain {" "$cf"; then
    info "Caddyfile 已含 $domain，跳过重复写入"
  else
    cat >> "$cf" <<EOF

# >>> Added by TTS-SERVER deploy $(date +%F) <<<
$domain {
    reverse_proxy 127.0.0.1:$PORT
}
# >>> end TTS-SERVER <<<
EOF
    info "已向 $cf 追加 $domain 反代配置（原文件已备份为 ${cf}.bak.*）"
  fi
  # reload
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet caddy; then
    systemctl reload caddy && info "caddy 已 reload" || warn "caddy reload 失败，请手动执行: caddy reload"
  else
    caddy reload --config "$cf" >/dev/null 2>&1 && info "caddy 已 reload" || warn "caddy reload 失败，请手动执行: caddy reload"
  fi

  local tok=""
  [ -f "$ENV_FILE" ] && tok=$(grep '^TTS_TOKEN=' "$ENV_FILE" | cut -d= -f2)
  echo "-------------------------------------------"
  echo "✓ 对外暴露已配置： https://$domain${tok:+?token=$tok}"
  echo "  到 legado_NG 导入 self-hosted-edge-tts.json，服务地址填上面的 URL"
  echo "-------------------------------------------"
}

if [ "${TUNNEL:-0}" = "1" ]; then
  setup_tunnel "${DOMAIN:-}"
elif [ -n "${DOMAIN:-}" ]; then
  setup_caddy "$DOMAIN"
elif [ -t 0 ]; then
  echo "如何对外暴露（手机才能连）："
  echo "  1) Caddy 反代（默认，自动写 Caddyfile 并 reload；Caddy 未装会自动装，需域名指向 VPS）"
  echo "  2) Cloudflare 隧道（零开放端口，需浏览器登录 Cloudflare）"
  read -rp "选择 [1/2] (默认1): " m
  if [ "$m" = "2" ]; then
    setup_tunnel
  else
    setup_caddy
  fi
else
  # 非交互未给域名：仅打印片段，不自动改配置
  print_caddy
fi

echo "==> 完成。TTS 服务运行在 127.0.0.1:${PORT}"
