#!/usr/bin/env bash
# TTS-SERVER 一键部署
#
# 用法（仓库已设为 public，可直接拉取）:
#   交互安装（推荐，菜单可靠弹出）:
#     bash <(curl -fsSL https://raw.githubusercontent.com/aucrazy-p/TTS-SERVER/main/deploy.sh)
#   ⚠️ 不要写成 `curl ... | bash`：那样 bash 的 stdin 是管道、不是终端，交互菜单会失效。
#      需要无人值守时才用管道，并配合环境变量（变量写在 bash 一侧）:
#     curl -fsSL .../deploy.sh | DOMAIN=tts.example.com bash   # 自动配 Caddy 反代
#     curl -fsSL .../deploy.sh | PORT=9090 bash                # 改端口(被占会自动分配空闲端口)
#
# 交互流程：先问「Caddy 反代 / 暂不对外」并输入域名 -> 再装 docker/构建/启动 -> 自动写 Caddyfile + reload。
# 域名需已解析到本机公网 IP。服务只监听 127.0.0.1:${PORT}。
set -uo pipefail

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

SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

info(){ echo "[INFO] $*"; }
warn(){ echo "[WARN] $*"; }
err(){ echo "[ERROR] $*"; }

# 交互读取：优先用 stdin（bash <(curl...) 时 stdin 即终端），否则用 /dev/tty；两者皆无则返回默认值不卡住
have_tty(){ [ -t 0 ] || [ -c /dev/tty ]; }
prompt(){
  local q="$1" def="$2" ans=""
  if [ -t 0 ]; then
    read -r -p "$q${def:+ [$def]}: " ans || true
  elif [ -c /dev/tty ]; then
    read -r -p "$q${def:+ [$def]}: " ans < /dev/tty || true
  else
    printf '%s' "$def"; return
  fi
  printf '%s' "${ans:-$def}"
}

# ---------- 1. 交互：对外访问方式 + 域名（放在最前，装之前就问）----------
EXPOSE_MODE=""     # caddy | none | ""(未交互)
DOMAIN_IN=""
if have_tty && [ -z "${DOMAIN:-}" ]; then
  echo
  echo "====== 对外访问配置（手机才能连）======"
  echo "  1) Caddy 反代（推荐：自动写 Caddyfile + reload；未装 Caddy 会自动装）"
  echo "  2) 暂不对外（仅本机/局域网可用）"
  m=$(prompt "请选择" "1")
  if [ "$m" = "2" ]; then
    EXPOSE_MODE="none"
  else
    EXPOSE_MODE="caddy"
    DOMAIN_IN=$(prompt "请输入你的公网域名（需已解析到本机 IP，如 tts.example.com）" "")
    [ -z "$DOMAIN_IN" ] && echo "（未输入域名，稍后只打印 Caddy 反代片段）"
  fi
elif [ -n "${DOMAIN:-}" ]; then
  EXPOSE_MODE="caddy"; DOMAIN_IN="$DOMAIN"
fi

# ---------- 2. 端口（被占用时安装过程会自动分配空闲端口）----------
export PORT="${PORT:-8080}"
echo "    默认端口: $PORT（若被占用会自动分配空闲端口）"

# ---------- 3. 获取项目文件 ----------
echo "==> 获取项目文件..."
if command -v git >/dev/null 2>&1; then
  if [ -d "$INSTALL_DIR/.git" ]; then
    git -C "$INSTALL_DIR" pull --ff-only || true
  else
    rm -rf "$INSTALL_DIR"
    git clone --depth 1 "$REPO_URL" "$INSTALL_DIR" || { err "git clone 失败（网络？）"; exit 1; }
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

# ---------- 4. 安装并启动（本步不需要域名）----------
echo "==> 安装 docker / 构建镜像 / 启动服务..."
bash ./tts-server.sh install || { err "安装/启动失败，请查看上方输出"; exit 1; }

# install 内部可能因端口冲突自动改了 PORT，重新读取以同步 Caddy 反代端口
if [ -f "$ENV_FILE" ]; then
  _p=$(grep '^PORT=' "$ENV_FILE" | head -1 | cut -d= -f2 | tr -d ' ')
  [ -n "$_p" ] && PORT="$_p"
fi
echo "    监听端口: $PORT"

# ---------- 5. 对外暴露（Caddy 反代）----------
# 端口占用检测（判断是否已有 Nginx/Caddy 占 80/443）
port_in_use(){
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | grep -q ":$p "
  else
    (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null
  fi
}

# 自动安装 Caddy：三级回退（apt 官方仓库 -> caddyserver.com 官方接口 -> GitHub Release）
install_caddy(){
  info "未检测到 caddy，开始自动安装..."
  local arch="amd64"
  case "$(uname -m)" in
    x86_64)  arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
  esac

  local ok=0
  # [1/3] 官方 apt 仓库 (Debian/Ubuntu，自带 systemd 服务与 /etc/caddy/Caddyfile)
  if [ "$ok" -eq 0 ] && command -v apt-get >/dev/null 2>&1; then
    info "[1/3] 尝试官方 apt 仓库安装..."
    $SUDO apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https >/dev/null 2>&1 || true
    $SUDO mkdir -p /usr/share/keyrings
    $SUDO curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' -o /tmp/caddy.gpg.key 2>/dev/null \
      && $SUDO gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg /tmp/caddy.gpg.key 2>/dev/null \
      && $SUDO curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' -o /etc/apt/sources.list.d/caddy-stable.list 2>/dev/null \
      && $SUDO apt-get update -qq >/dev/null 2>&1 \
      && $SUDO apt-get install -y -qq caddy >/dev/null 2>&1
    command -v caddy >/dev/null 2>&1 && ok=1
    [ "$ok" -eq 0 ] && warn "apt 仓库安装失败，换下一种方式..."
  fi

  # [2/3] caddyserver.com 官方下载接口（返回静态二进制）
  if [ "$ok" -eq 0 ]; then
    info "[2/3] 尝试从 caddyserver.com 下载静态二进制..."
    if $SUDO curl -fsSL "https://caddyserver.com/api/download?os=linux&arch=${arch}" -o /tmp/caddy.bin 2>/dev/null \
       && [ -s /tmp/caddy.bin ] \
       && $SUDO install -m 0755 /tmp/caddy.bin /usr/local/bin/caddy; then
      ok=1
    else
      warn "官方接口下载失败，换下一种方式..."
    fi
  fi

  # [3/3] GitHub Release（资产名带版本号，需先取 latest tag）
  if [ "$ok" -eq 0 ]; then
    info "[3/3] 尝试从 GitHub Release 下载..."
    local ver
    ver=$(curl -fsSL https://api.github.com/repos/caddyserver/caddy/releases/latest 2>/dev/null \
          | grep -oE '"tag_name": *"[^"]+"' | head -1 | sed 's/.*: *"//;s/"//')
    if [ -n "$ver" ] \
       && $SUDO curl -fsSL "https://github.com/caddyserver/caddy/releases/download/${ver}/caddy_${ver#v}_linux_${arch}.tar.gz" -o /tmp/caddy.tar.gz 2>/dev/null \
       && $SUDO tar -xzf /tmp/caddy.tar.gz -C /usr/local/bin caddy 2>/dev/null \
       && $SUDO chmod +x /usr/local/bin/caddy \
       && command -v caddy >/dev/null 2>&1; then
      ok=1
    fi
  fi

  [ "$ok" -eq 0 ] && { err "三种方式均安装失败（检查网络/代理后重试）"; return 1; }
  info "Caddy 安装完成: $(caddy version 2>/dev/null || echo unknown)"

  # 兜底：确保存在 Caddyfile 与 systemd 服务（apt 安装已自带，会自动跳过）
  $SUDO mkdir -p /etc/caddy
  if [ ! -s /etc/caddy/Caddyfile ]; then
    $SUDO tee /etc/caddy/Caddyfile >/dev/null <<'EOF'
{
    # Caddy 全局选项（如需证书到期通知可填 email）
}
EOF
  fi
  if command -v systemctl >/dev/null 2>&1 \
     && ! systemctl list-unit-files 2>/dev/null | grep -q '^caddy.service'; then
    $SUDO tee /etc/systemd/system/caddy.service >/dev/null <<'EOF'
[Unit]
Description=Caddy
After=network.target network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --force
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    $SUDO systemctl daemon-reload
  fi
  $SUDO systemctl enable --now caddy >/dev/null 2>&1 || warn "caddy 服务启动失败，请检查 80/443 是否被占用"
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
      warn "检测到 80/443 已被占用，Caddy 无法接管 443（避免与现有服务冲突）。占用情况："
      ss -ltnp 2>/dev/null | grep -E ':(80|443) ' | sed 's/^/    /'
      warn "若占用者本身就是反代（nginx/caddy/面板），请把下面片段加进其配置；"
      warn "若是无关服务且可停掉，停掉后重跑本脚本即可全自动完成。"
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

case "$EXPOSE_MODE" in
  caddy)
    if [ -n "$DOMAIN_IN" ]; then
      setup_caddy "$DOMAIN_IN"
    else
      echo "未输入域名，改为打印 Caddy 反代片段（手动添加）："
      print_caddy
    fi
    ;;
  none)
    echo "==> 已跳过对外访问配置（仅本机 127.0.0.1:$PORT 可用）。"
    echo "    之后补对外暴露：重跑 bash <(curl -fsSL $REPO_RAW/deploy.sh) 选 1，或手动加 Caddyfile。"
    ;;
  *)
    echo "（未进入交互菜单：检测不到终端。想交互式请用：bash <(curl -fsSL $REPO_RAW/deploy.sh)）"
    print_caddy
    ;;
esac

echo "==> 完成。TTS 服务运行在 127.0.0.1:${PORT}"
