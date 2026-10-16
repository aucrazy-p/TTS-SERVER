#!/usr/bin/env bash
# TTS-SERVER 一键部署（菜单式）
#
# 用法（仓库已设为 public，可直接拉取）:
#   交互安装（推荐，直接进入管理菜单）:
#     bash <(curl -fsSL https://raw.githubusercontent.com/aucrazy-p/TTS-SERVER/main/deploy.sh)
#   ⚠️ 不要写成 `curl ... | bash` 跑交互：那样 bash 的 stdin 是管道、不是终端，菜单读不到输入。
#   无人值守（无终端时自动：安装 + 配 Caddy 反代）:
#     curl -fsSL https://raw.githubusercontent.com/aucrazy-p/TTS-SERVER/main/deploy.sh | DOMAIN=tts.example.com bash
#     curl -fsSL .../deploy.sh | DOMAIN=tts.example.com PORT=9090 bash
#
# 交互菜单项（进入后与 /opt/tts-server/tts-server.sh 相同）:
#   1) 安装  2) 卸载  3) 启动  4) 停止  5) 状态  6) 日志  7) 更新  8) 更改端口  9) 对外访问配置(Caddy 反代)
#   「安装」完成后会询问是否立即配置对外访问（输入域名即全自动：装 Caddy -> 写 Caddyfile -> 签证书 -> reload）。
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

err(){ echo "[ERROR] $*"; }

echo "==> TTS-SERVER 一键部署"
echo "    安装目录: $INSTALL_DIR"

# ---------- 获取项目文件 ----------
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
  cd "$INSTALL_DIR" || exit 1
  for f in server.py requirements.txt Dockerfile docker-compose.yml tts-server.sh .env.example .gitignore README.md; do
    curl -fsSL "$REPO_RAW/$f" -o "$f" || { err "下载 $f 失败"; exit 1; }
  done
fi

cd "$INSTALL_DIR" || exit 1

# ---------- 进入管理菜单 / 无人值守分支 ----------
if [ -t 0 ] || [ -c /dev/tty ]; then
  # 交互：直接进入管理菜单
  exec bash ./tts-server.sh
elif [ -n "${DOMAIN:-}" ]; then
  # 无人值守 + 指定域名：自动安装并配置 Caddy 反代
  bash ./tts-server.sh install
  DOMAIN="${DOMAIN:-}" bash ./tts-server.sh setup-caddy
else
  # 无人值守但未给域名：仅安装，打印反代片段
  bash ./tts-server.sh install
  bash ./tts-server.sh caddy-snippet
  echo "==> 完成。如需对外暴露，登录服务器运行: bash $INSTALL_DIR/tts-server.sh 然后选 9"
fi
