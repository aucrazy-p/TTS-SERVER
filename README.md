# TTS-SERVER

为 legado_NG 提供自托管 Edge TTS 服务（文本只过你自己的服务器，不过第三方中转）。

## 一、VPS 一键部署

**前提**：VPS 已装 Caddy，且你的域名已解析到 VPS 公网 IP。

在 VPS 上执行：

```bash
DOMAIN=你的域名 curl -fsSL https://raw.githubusercontent.com/aucrazy-p/TTS-SERVER/main/deploy.sh | bash
```

脚本自动完成：装 docker → 生成随机 `TTS_TOKEN` → 构建并启动服务（监听 `127.0.0.1:8080`）→ 把你的域名反代写进 Caddyfile 并 `reload`。结束会输出 legado_NG 要填的「服务地址」（含 `?token=...`）。

- 改端口（如 8080 被占用）：`PORT=9090 DOMAIN=你的域名 curl ... | bash`
- 用 Cloudflare 隧道（零开放端口）：`TUNNEL=1 DOMAIN=你的域名 curl ... | bash`

## 二、legado_NG 配置

1. 导入 `self-hosted-edge-tts.json`（朗读设置 → TTS 引擎 → 导入）
2. 「服务地址」填部署输出的地址（`https://你的域名?token=...`，没开 token 就不带 `?token`）
3. 重新拉取发音人，多角色 + 情绪自动映射即生效

## 三、管理

```bash
./tts-server.sh status      # 查看状态
./tts-server.sh logs        # 看日志
./tts-server.sh update      # 更新并重建
./tts-server.sh uninstall   # 卸载（保留 .env）
```

## 说明

- 服务只监听 `127.0.0.1`，VPS 防火墙无需开放 8080 端口。
- 对外暴露后建议保留 `TTS_TOKEN`，避免他人白嫖。
- 共 39 个中文音色（与 legado_NG 内置默认一致）。
