# TTS-SERVER

自托管的 Edge TTS 服务，配合 [legado_NG](https://github.com/joestar817/legado_NG) 实现**多角色 AI 朗读 + 情绪风格**。文本只经过你自己的服务器，不经过任何第三方中转（内置「Next Edge TTS」会把小说发往写死的第三方 IP，本方案规避这一点）。

## 特性

- 后端基于微软 **Edge TTS**（免费、免 API Key、中文神经嗓音质量极佳）
- **39 个中文友好音色**（与 legado_NG 内置默认一致：晓晓/晓亦/云希/云野…含 HD/FHD 高清与多角色切换）
- 支持 **情绪/风格自动映射**（沿用 legado_NG 的 AI 分镜产出，自动选 Edge 说话风格）
- 输出 **MP3**，带宽友好；服务端只依赖 `edge-tts` + `flask`，镜像轻量（约 120–250MB 内存，1G VPS 可跑）
- 对外暴露**默认走 Caddy 反代，一键自动配置**：脚本自动定位 Caddyfile → 备份 → 写入域名反代块 → reload
- 可选 **Cloudflare 隧道**（零开放端口）
- `TTS_TOKEN` 鉴权：对外暴露后建议开启，防止他人白嫖
- 提供菜单式管理脚本（安装 / 卸载 / 启动 / 停止 / 状态 / 日志 / 更新）

> 路线图：后端设计为可插拔，后续可加入 Piper（离线）、Kokoro、CosyVoice（顶级中文）等免费引擎。

## 目录结构

```
tts-server/
├── deploy.sh                   # 一键部署脚本（curl|bash 直接拉取运行，自动配置 Caddy 反代）
├── server.py                    # Flask 服务：/voices 发音人目录 + /tts SSML 合成（39 音色在此定义）
├── self-hosted-edge-tts.json   # 导入 legado_NG 的 TTS 引擎脚本
├── Dockerfile
├── docker-compose.yml          # 仅映射 127.0.0.1:${PORT}（默认 8080，可改）
├── tts-server.sh               # 菜单式一键管理脚本
├── requirements.txt
├── .env.example
└── README.md
```

## 一键部署（推荐）

仓库为 **public**，直接在 VPS 上执行（**安装时填入你的域名**，脚本会自动把反代写进 Caddyfile 并 reload）：

```bash
DOMAIN=你的域名 curl -fsSL https://raw.githubusercontent.com/aucrazy-p/TTS-SERVER/main/deploy.sh | bash
```

脚本自动完成：

1. 获取项目文件（有 git 则 clone，无则逐文件下载）
2. 安装 docker / 生成随机 `TTS_TOKEN` / 构建镜像 / 启动服务（监听 `127.0.0.1:${PORT}`）
3. **自动配置 Caddy 反代**：定位 Caddyfile → 备份（`Caddyfile.bak.<时间戳>`）→ 追加 `你的域名 { reverse_proxy 127.0.0.1:${PORT} }` → `caddy reload`
4. 输出 legado_NG 要填的「服务地址」（含 `?token=...`）

> 前缀条件：VPS 上需**已安装 Caddy**（`caddy` 命令可用）且**你的域名已解析到 VPS 公网 IP**。若脚本找不到 Caddyfile 或 Caddy 用 JSON 配置，会回退为打印反代片段让你手动加。

### 完全交互式（不记命令）

```bash
curl -fsSL https://raw.githubusercontent.com/aucrazy-p/TTS-SERVER/main/deploy.sh | bash
```

脚本会依次询问：是否装 docker、你的公网域名，然后全自动装好并暴露。

### 自定义端口

默认监听 `127.0.0.1:8080`。若 8080 已被 s-ui / new-api / 其他服务占用，部署时指定 `PORT`（脚本启动前会检测占用并提示）：

```bash
PORT=9090 DOMAIN=你的域名 curl -fsSL https://raw.githubusercontent.com/aucrazy-p/TTS-SERVER/main/deploy.sh | bash
```

已安装后改端口：把 `.env` 的 `PORT` 改成空闲端口后重装/重启：

```bash
sed -i 's/^PORT=.*/PORT=9090/' .env && bash ./tts-server.sh install
```

### 备选：Cloudflare 隧道（零开放端口）

不想开防火墙端口时用，但需 Cloudflare 账号 + 域名 + **浏览器一次性登录授权**（无法全自动）：

```bash
TUNNEL=1 DOMAIN=你的域名 curl -fsSL https://raw.githubusercontent.com/aucrazy-p/TTS-SERVER/main/deploy.sh | bash
```

## 备选：手动 / 菜单管理

```bash
# 方式一：菜单交互
./tts-server.sh          # 选 1 安装 / 选 8 看隧道指引

# 方式二：一键非交互
./tts-server.sh install  # 仅装服务（不含对外暴露，需另行配置 Caddy/隧道）
```

## legado_NG 配置

1. 把 `self-hosted-edge-tts.json` 导入 legado_NG（朗读设置 → TTS 引擎 → 导入）；
2. 把「服务地址」改成部署脚本输出的地址，形如 `https://你的域名?token=<自动生成的TTS_TOKEN>`（没开 token 就填 `https://你的域名`）；
3. 重新拉取发音人即可，多角色 AI 路由 + 情绪自动映射生效。

## 管理命令

| 命令 | 作用 |
|---|---|
| `./tts-server.sh install` | 安装并启动服务（重装时保留 `.env`） |
| `./tts-server.sh uninstall` | 卸载（移除容器/镜像，保留 `.env`） |
| `./tts-server.sh status` | 查看运行状态与配置 |
| `./tts-server.sh logs` | 跟踪日志 |
| `./tts-server.sh update` | 拉取最新代码并重建镜像 |
| `./tts-server.sh stop` / `start` | 停止 / 启动 |

## 安全说明

- 服务**只监听本机 `127.0.0.1`**，对外必须经 Caddy 反代或 Cloudflare 隧道；VPS 防火墙**无需开放 `${PORT}` 端口**。
- 对外暴露后强烈建议保留 `TTS_TOKEN`（默认随机生成），legado_NG 引擎地址里带 `?token=...`，否则他人拿到地址即可白嫖你的 TTS。

## 其他说明

- 情绪风格仅对**支持该风格**的音色生效（音色清单 `styles` 即白名单）。
- Edge TTS 为联网服务；若需离线可后续切换 Piper 等后端。
- 镜像名 `tts-server-tts`，容器 `restart: unless-stopped`，VPS 重启后自动恢复（Caddy 同理由 systemd 自启）。
