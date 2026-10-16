# TTS-SERVER

自托管的 Edge TTS 服务，配合 [legado_NG](https://github.com/joestar817/legado_NG) 实现**多角色 AI 朗读 + 情绪风格**，文本只经过你自己的服务器，不经过任何第三方中转。

## 特性

- 后端基于微软 **Edge TTS**（免费、免 API Key、中文神经嗓音质量极佳）
- 支持 **情绪/风格自动映射**（沿用 legado_NG 的 AI 分镜产出，自动选 Edge 说话风格）
- 输出 **MP3**，带宽友好；服务端只依赖 `edge-tts` + `flask`，镜像轻量
- 经 **Cloudflare Tunnel** 暴露，VPS 防火墙**零入站端口**
- 提供菜单式一键管理脚本（安装 / 卸载 / 状态 / 日志 / 更新）

> 路线图：后端设计为可插拔，后续可加入 Piper（离线）、Kokoro、CosyVoice（顶级中文）等免费引擎。

## 目录结构

```
tts-server/
├── server.py                    # Flask 服务：/voices 发音人目录 + /tts SSML 合成
├── self-hosted-edge-tts.json   # 导入 legado_NG 的 TTS 引擎脚本
├── Dockerfile
├── docker-compose.yml          # 仅映射 127.0.0.1:8080
├── tts-server.sh               # 菜单式一键管理脚本
├── requirements.txt
├── .env.example
└── README.md
```

## 快速开始（VPS 上）

```bash
# 方式一：菜单交互
./tts-server.sh          # 选 1 安装

# 方式二：一键非交互（适合 curl|bash）
./tts-server.sh install
```

脚本会自动：检测/安装 docker → 生成随机 `TTS_TOKEN` → 构建并启动服务。

## 暴露到公网（Cloudflare Tunnel，零开放端口）

```bash
cloudflared tunnel login
cloudflared tunnel create tts
cloudflared tunnel route dns tts tts.你的域名.com
cloudflared tunnel run --url http://localhost:8080 tts
```

## legado_NG 配置

1. 把 `self-hosted-edge-tts.json` 导入 legado_NG（朗读设置 → TTS 引擎 → 导入）；
2. 把"服务地址"改成你的域名，例如 `https://tts.你的域名.com`（设了 `TTS_TOKEN` 就填 `https://tts.你的域名.com?token=...`）；
3. 重新拉取发音人即可，多角色 AI 路由自动生效。

## 管理命令

| 命令 | 作用 |
|---|---|
| `./tts-server.sh install` | 安装并启动 |
| `./tts-server.sh uninstall` | 卸载（移除容器/镜像，保留 .env） |
| `./tts-server.sh status` | 查看运行状态与配置 |
| `./tts-server.sh logs` | 跟踪日志 |
| `./tts-server.sh update` | 拉取最新并重建 |

## 说明

- 情绪仅对**支持该风格**的音色生效（音色清单里的 `styles` 即白名单）。
- Edge TTS 为联网服务；若需离线可后续切换 Piper 等后端。
