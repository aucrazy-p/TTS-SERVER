#!/usr/bin/env bash
# TTS-SERVER 一键管理脚本
# 用法:
#   交互菜单:  ./tts-server.sh
#   一键安装:  ./tts-server.sh install   (可用于 curl|bash 非交互)
#   更改端口:  NEW_PORT=9090 ./tts-server.sh change-port   (或菜单选 8)
#   对外访问:  ./tts-server.sh setup-caddy   (或菜单选 9；无人值守: DOMAIN=xx ./tts-server.sh setup-caddy)
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

# 找一个空闲端口：从 $1 起向上扫描（最多 +200），找不到则取 30000-39999 随机高端口
find_free_port(){
  local start="$1" p=$1
  while [ "$p" -le $((start+200)) ]; do
    port_in_use "$p" || { echo "$p"; return 0; }
    p=$((p+1))
  done
  p=$((30000 + (RANDOM % 10000)))
  while port_in_use "$p"; do p=$((30000 + (RANDOM % 10000))); done
  echo "$p"
}

# 端口检查 + 自动分配：
#  - 端口空闲            -> 直接用
#  - 端口被本服务容器占用 -> 复用该容器，继续
#  - 端口被其他服务占用   -> 自动找一个空闲端口，写入 .env 并导出
check_port(){
  local p; p=$(get_port)
  if ! port_in_use "$p"; then
    return 0
  fi
  # 先看是不是本服务自己的容器（重跑安装/启动时常见）
  if command -v docker >/dev/null 2>&1; then
    local ports
    ports=$($DCC ps --format '{{.Ports}}' 2>/dev/null)
    if printf '%s\n' "$ports" | grep -qE "(^|[^0-9])${p}->"; then
      info "端口 $p 由本服务容器占用，将复用该容器，继续..."
      return 0
    fi
  fi
  # 被其他服务占用：自动分配空闲端口
  local np
  np=$(find_free_port "$p")
  if [ -z "$np" ] || [ "$np" = "$p" ]; then
    err "端口 $p 被占用且无法自动分配空闲端口，请手动在 .env 修改 PORT 后重试"
    exit 1
  fi
  info "端口 $p 已被其他服务占用，自动改用空闲端口 $np"
  if [ -f "$ENV_FILE" ]; then
    if grep -q '^PORT=' "$ENV_FILE"; then
      sed -i "s/^PORT=.*/PORT=$np/" "$ENV_FILE"
    else
      printf 'PORT=%s\n' "$np" >> "$ENV_FILE"
    fi
  else
    printf 'TTS_TOKEN=%s\nPORT=%s\n' "$(openssl rand -hex 16)" "$np" > "$ENV_FILE"
  fi
  export PORT="$np"
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
  local tok="" port url
  port=$(get_port)
  [ -f "$ENV_FILE" ] && tok=$(grep '^TTS_TOKEN=' "$ENV_FILE" | cut -d= -f2)
  echo "----------------------------------------"
  info "本地访问: http://127.0.0.1:$port"
  [ -n "$tok" ] && info "TTS_TOKEN: $tok"
  url=$(tts_public_url)
  if [ -n "$url" ]; then
    info "对外服务地址: $url"
  else
    echo "legado_NG 引擎服务地址示例: https://tts.你的域名.com${tok:+?token=$tok}"
    echo "（尚未配置对外访问，可运行 ./tts-server.sh setup-caddy 或菜单选 9）"
  fi
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
  ensure_tts_in_caddy_network || true
  show_url
  # 交互式安装后询问是否立即配置对外访问（无人值守时自动跳过）
  if [ -t 0 ] || [ -c /dev/tty ]; then
    local ans=""
    if [ -t 0 ]; then
      read -rp "是否现在配置对外访问（Caddy 反代，自动装 Caddy + 签 HTTPS 证书）? [y/N]: " ans || true
    else
      read -rp "是否现在配置对外访问（Caddy 反代）? [y/N]: " ans < /dev/tty || true
    fi
    case "$ans" in
      y|Y) setup_caddy || true ;;
    esac
  fi
}

uninstall(){
  info "停止并移除容器与卷..."
  $DCC down -v || true
  if docker image inspect "$IMAGE" >/dev/null 2>&1; then
    docker image rm -f "$IMAGE" || true
  fi
  info "已卸载（容器/镜像已移除，$ENV_FILE 保留以便重装）"
}

start(){ check_port; $DCC up -d; ensure_tts_in_caddy_network || true; info "已启动"; }
stop(){ $DCC stop; info "已停止"; }

status(){
  $DCC ps
  echo "---- 当前配置 ----"
  [ -f "$ENV_FILE" ] && grep -E '^(TTS_TOKEN|PORT)=' "$ENV_FILE"
  local url
  url=$(tts_public_url)
  if [ -n "$url" ]; then
    echo "---- 对外服务地址 ----"
    echo "$url"
  else
    echo "（尚未配置对外访问，菜单选 9 或运行 ./tts-server.sh setup-caddy）"
  fi
}

logs(){ $DCC logs -f --tail=50 tts; }

update(){
  info "拉取最新代码并重建镜像..."
  git pull || warn "非 git 目录或 pull 失败，跳过更新源码"
  $DCC up -d --build || $DCC up -d
  ensure_tts_in_caddy_network || true
  info "更新完成"
}

# ---------- 对外访问（Caddy 反代，全自动）----------
print_caddy(){
  local domain="${1:-你的域名}" port tok
  port=$(get_port)
  tok=$(grep '^TTS_TOKEN=' "$ENV_FILE" 2>/dev/null | cut -d= -f2)
  echo "-------------------------------------------"
  echo "请手动在反代配置中加入以下站点（反代到本机 $port）："
  echo
  echo "    $domain {"
  echo "        reverse_proxy 127.0.0.1:$port"
  echo "    }"
  echo
  echo "legado_NG 引擎『服务地址』填： https://$domain${tok:+?token=$tok}"
  echo "-------------------------------------------"
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
      && $SUDO apt-get install -y -qq caddy >/dev/null 2>&1 || true
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
          | grep -oE '"tag_name": *"[^"]+"' | head -1 | sed 's/.*: *"//;s/"//' || true)
    if [ -n "$ver" ] \
       && $SUDO curl -fsSL "https://github.com/caddyserver/caddy/releases/download/${ver}/caddy_${ver#v}_linux_${arch}.tar.gz" -o /tmp/caddy.tar.gz 2>/dev/null \
       && $SUDO tar -xzf /tmp/caddy.tar.gz -C /usr/local/bin caddy 2>/dev/null \
       && $SUDO chmod +x /usr/local/bin/caddy \
       && command -v caddy >/dev/null 2>&1; then
      ok=1
    fi
  fi

  if [ "$ok" -eq 0 ]; then
    err "三种方式均安装失败（检查网络/代理后重试）"
    return 1
  fi
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

# 配置对外访问：优先复用已有 Docker 版 Caddy -> 否则装宿主机 Caddy -> 写反代块 -> reload（幂等）
setup_caddy(){
  local domain="${DOMAIN:-}"
  if [ -z "$domain" ]; then
    read -rp "输入公网域名（需已解析到本机 IP，如 tts.example.com）: " domain || domain=""
  fi
  if [ -z "$domain" ]; then
    warn "未提供域名，跳过对外访问配置"
    return 1
  fi

  local port
  port=$(get_port)

  # --- 路径 1：已有 Docker 版 Caddy 占着 80/443（如 new-api-caddy）→ 直接复用它，不另装 ---
  # 容器版 Caddy 里 127.0.0.1 指它自己，反代目标必须用 TTS 容器名（tts-server），先接入网络
  local dcd="" dname dfile dcfg tgt
  dcd=$(find_docker_caddy || true)
  if [ -n "$dcd" ]; then
    dname="${dcd%%:*}"
    dfile="${dcd#*:}"
    info "检测到已有 Docker 版 Caddy: $dname（Caddyfile: $dfile），直接复用，无需另装 Caddy..."
    ensure_tts_in_caddy_network
    tgt="tts-server:$port"
    cp "$dfile" "${dfile}.bak.$(date +%s)"
    if grep -q "$domain {" "$dfile"; then
      if sed -n '/# >>> Added by TTS-SERVER/,/# >>> end TTS-SERVER/p' "$dfile" | grep -q 'reverse_proxy 127\.0\.0\.1:'; then
        # 旧写法(127.0.0.1)在容器内不可达，迁移为容器名
        awk -v tgt="$tgt" '
          /# >>> Added by TTS-SERVER/ { inblk=1 }
          inblk && /reverse_proxy/ { print "    reverse_proxy " tgt; next }
          /# >>> end TTS-SERVER/ { inblk=0 }
          { print }
        ' "$dfile" > "${dfile}.tmp" && mv "${dfile}.tmp" "$dfile"
        info "已把反代目标从 127.0.0.1:$port 迁移为 $tgt（容器内无法访问宿主机回环地址）"
      else
        info "Caddyfile 已含 $domain 且反代目标正确，跳过写入"
      fi
    else
      cat >> "$dfile" <<EOF

# >>> Added by TTS-SERVER $(date +%F) <<<
$domain {
    reverse_proxy $tgt
}
# >>> end TTS-SERVER <<<
EOF
      info "已向 $dfile 追加 $domain 反代配置（原文件已备份为 ${dfile}.bak.*）"
    fi
    dcfg=$(_docker_caddy_cfg "$dname")
    if docker exec "$dname" caddy reload --config "$dcfg" >/dev/null 2>&1; then
      info "容器内 caddy 已 reload ($dcfg)"
    elif docker restart "$dname" >/dev/null 2>&1; then
      info "reload 失败，已重启容器 $dname 使配置生效"
    else
      warn "容器内 reload/重启均失败，请手动检查: docker exec $dname caddy reload --config $dcfg"
    fi
    _show_caddy_ok "$domain"
    return 0
  fi

  # --- 路径 2：宿主机 Caddy ---
  if ! command -v caddy >/dev/null 2>&1; then
    if port_in_use 80 || port_in_use 443; then
      warn "80/443 已被占用，且未找到可复用的 Docker 版 Caddy。占用情况："
      ss -ltnp 2>/dev/null | grep -E ':(80|443) ' | sed 's/^/    /' || true
      print_caddy "$domain"; return 1
    fi
    install_caddy || { warn "Caddy 安装失败，改为打印片段："; print_caddy "$domain"; return 1; }
  fi

  local cf
  cf=$(find_caddyfile)
  if [ -z "$cf" ]; then
    warn "未找到 Caddyfile，改为打印片段："; print_caddy "$domain"; return 1
  fi
  if head -c1 "$cf" | grep -q '{'; then
    warn "Caddy 使用 JSON 配置，自动写入不适用，改为打印片段："; print_caddy "$domain"; return 1
  fi

  cp "$cf" "${cf}.bak.$(date +%s)"
  if grep -q "$domain {" "$cf"; then
    info "Caddyfile 已含 $domain，跳过重复写入"
  else
    cat >> "$cf" <<EOF

# >>> Added by TTS-SERVER $(date +%F) <<<
$domain {
    reverse_proxy 127.0.0.1:$port
}
# >>> end TTS-SERVER <<<
EOF
    info "已向 $cf 追加 $domain 反代配置（原文件已备份为 ${cf}.bak.*）"
  fi
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet caddy; then
    systemctl reload caddy && info "caddy 已 reload" || warn "caddy reload 失败，请手动: caddy reload"
  else
    caddy reload --config "$cf" >/dev/null 2>&1 && info "caddy 已 reload" || warn "caddy reload 失败，请手动: caddy reload"
  fi

  _show_caddy_ok "$domain"
}

_show_caddy_ok(){
  local domain="$1" tok
  tok=$(grep '^TTS_TOKEN=' "$ENV_FILE" 2>/dev/null | cut -d= -f2)
  echo "-------------------------------------------"
  echo "✓ 对外暴露已配置： https://$domain${tok:+?token=$tok}"
  echo "  （HTTPS 证书由 Caddy 自动向 Let's Encrypt 申请并续期）"
  echo "  到 legado_NG 导入 self-hosted-edge-tts.json，服务地址填上面的 URL"
  echo "-------------------------------------------"
}

# 查找绑定了 80/443 的 Docker 版 Caddy 容器，返回 "容器名:Caddyfile宿主机路径"，无则返回非零
find_docker_caddy(){
  command -v docker >/dev/null 2>&1 || return 1
  local cid name mounts src
  for cid in $(docker ps --format '{{.ID}}' 2>/dev/null); do
    docker port "$cid" 2>/dev/null | grep -qE ':443' || continue
    name=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||')
    case "$name" in *caddy*) ;; *) continue ;; esac
    mounts=$(docker inspect -f '{{range .Mounts}}{{println .Source .Destination}}{{end}}' "$cid" 2>/dev/null)
    src=$(printf '%s\n' "$mounts" | awk '{
      sub(/\/$/, "", $2)
      if ($2 ~ /Caddyfile$/) { print $1; exit }
      if ($2 == "/etc/caddy") { print $1 "/Caddyfile"; exit }
    }')
    [ -n "$src" ] && [ -f "$src" ] || continue
    echo "$name:$src"
    return 0
  done
  return 1
}

# 取容器内 caddy 实际使用的配置路径（从启动命令解析，兜底 /etc/caddy/Caddyfile）
_docker_caddy_cfg(){
  local name="$1" cfg
  cfg=$(docker inspect -f '{{join .Config.Cmd " "}}' "$name" 2>/dev/null \
        | grep -oE '(^|[= ])--config[= ][^ ]+' | head -1 | awk '{print $NF}' | tr -d '"' || true)
  [ -n "$cfg" ] && { echo "$cfg"; return 0; }
  echo "/etc/caddy/Caddyfile"
}

# 把 TTS 容器接入 Docker 版 Caddy 所在网络（别名 tts-server），使 Caddy 能按容器名反代。
# 注意：compose 重建容器后会脱离该网络，install/start/update/change-port 后都要调一次。
ensure_tts_in_caddy_network(){
  command -v docker >/dev/null 2>&1 || return 0
  local dcd dname tts_cid net nets
  dcd=$(find_docker_caddy || true)
  [ -n "$dcd" ] || return 0
  dname="${dcd%%:*}"
  tts_cid=$($DCC ps -q tts 2>/dev/null | head -1)
  [ -n "$tts_cid" ] || return 0
  net=$(docker inspect -f '{{range $k,$_ := .NetworkSettings.Networks}}{{$k}} {{end}}' "$dname" 2>/dev/null | cut -d' ' -f1)
  [ -n "$net" ] || return 0
  nets=$(docker inspect -f '{{range $k,$_ := .NetworkSettings.Networks}}{{$k}} {{end}}' "$tts_cid" 2>/dev/null)
  if printf '%s' "$nets" | tr ' ' '\n' | grep -qx "$net"; then
    return 0
  fi
  if docker network connect --alias tts-server "$net" "$tts_cid" >/dev/null 2>&1; then
    info "已将 TTS 容器接入 Caddy 网络 $net（别名 tts-server）"
  else
    warn "TTS 容器接入网络 $net 失败，容器版 Caddy 将无法反代（127.0.0.1 在容器内指 Caddy 自己）"
  fi
}

# 从 Caddyfile 的 TTS-SERVER 标记块提取已配置的对外域名（无则返回空）
get_tts_domain(){
  local cf=""
  cf=$(find_caddyfile)
  if [ -z "$cf" ] || ! grep -q '# >>> Added by TTS-SERVER' "$cf" 2>/dev/null; then
    local dcd
    dcd=$(find_docker_caddy || true)
    [ -n "$dcd" ] && cf="${dcd#*:}"
  fi
  [ -n "$cf" ] || return 0
  sed -n '/# >>> Added by TTS-SERVER/,/# >>> end TTS-SERVER/p' "$cf" 2>/dev/null \
    | grep -oE '^[A-Za-z0-9._-]+ \{' | head -1 | tr -d ' {'
}

# 拼对外服务地址（域名+token）
tts_public_url(){
  local domain tok
  domain=$(get_tts_domain)
  [ -n "$domain" ] || return 0
  tok=$(grep '^TTS_TOKEN=' "$ENV_FILE" 2>/dev/null | cut -d= -f2)
  echo "https://$domain${tok:+?token=$tok}"
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

# 在 TTS 标记块内把反代端口改为 new，并 reload caddy（支持宿主机 Caddy 与 Docker 版 Caddy）
update_caddy_port(){
  local old="$1" new="$2" cf="" scope="host" dcd dcfg
  cf=$(find_caddyfile)
  if [ -n "$cf" ] && grep -q '# >>> Added by TTS-SERVER' "$cf" 2>/dev/null; then
    scope="host"
  else
    # 宿主机 Caddyfile 无标记块时，尝试 Docker 版 Caddy
    dcd=$(find_docker_caddy || true)
    if [ -n "$dcd" ]; then
      scope="${dcd%%:*}"
      cf="${dcd#*:}"
    fi
  fi
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
  local tgt
  if [ "$scope" = "host" ]; then tgt="127.0.0.1:$new"; else tgt="tts-server:$new"; fi
  awk -v tgt="$tgt" '
    /# >>> Added by TTS-SERVER/ { inblk=1 }
    inblk && /reverse_proxy/ { print "    reverse_proxy " tgt; next }
    /# >>> end TTS-SERVER/ { inblk=0 }
    { print }
  ' "$cf" > "${cf}.tmp" && mv "${cf}.tmp" "$cf"
  if [ "$scope" = "host" ]; then
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet caddy; then
      systemctl reload caddy && info "caddy 已 reload" || warn "caddy reload 失败，请手动: caddy reload"
    else
      caddy reload --config "$cf" >/dev/null 2>&1 && info "caddy 已 reload" || warn "caddy reload 失败，请手动: caddy reload"
    fi
  else
    dcfg=$(_docker_caddy_cfg "$scope")
    ensure_tts_in_caddy_network
    if docker exec "$scope" caddy reload --config "$dcfg" >/dev/null 2>&1; then
      info "容器 $scope 内 caddy 已 reload"
    elif docker restart "$scope" >/dev/null 2>&1; then
      info "已重启容器 $scope 使新端口生效"
    else
      warn "reload 失败，请手动: docker exec $scope caddy reload --config $dcfg"
    fi
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
  ensure_tts_in_caddy_network || true
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
    echo " 9) 对外访问配置 setup-caddy"
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
      9) setup_caddy || true ;;
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
  setup-caddy) setup_caddy; exit 0 ;;
  caddy-snippet) print_caddy "${DOMAIN:-}"; exit 0 ;;
esac

menu
