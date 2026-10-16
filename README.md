# TTS-SERVER

为 legado_NG 提供自托管 Edge TTS 服务（文本只过你自己的服务器，不过第三方中转）。

## 一、VPS 一键部署

在 VPS 上执行（**菜单式**：运行后直接进入管理菜单）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/aucrazy-p/TTS-SERVER/main/deploy.sh)
```

> ⚠️ 不要写成 `curl ... | bash`：那样 stdin 是管道，菜单读不到输入。无人值守才用管道并带变量。

菜单项：

```
1) 安装  2) 卸载  3) 启动  4) 停止  5) 状态
6) 日志  7) 更新  8) 更改端口  9) 对外访问配置(Caddy 反代)  0) 退出
```

选 `1` 安装：自动装 docker → 生成随机 `TTS_TOKEN` → 构建并启动（默认 `127.0.0.1:8080`，**被占用会自动分配空闲端口**）→ 结束时询问是否配置对外访问，回答 `y` 并输入域名即全自动（自动装 Caddy → 写 Caddyfile → 自动签 HTTPS 证书并续期 → reload）。之后随时可从菜单选 `9` 补配或改配。

**前提**：配置反代时，域名需已解析到本机公网 IP；且 80/443 未被其他服务占用（若被占用脚本会列出占用进程/容器）。

无人值守 / 非交互（变量必须写在 `bash` 这一侧）：
- 自动安装 + 自动配 Caddy 反代：`curl -fsSL .../deploy.sh | DOMAIN=你的域名 bash`
- 指定端口：`curl -fsSL .../deploy.sh | DOMAIN=你的域名 PORT=9090 bash`

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
./tts-server.sh change-port # 更改端口（菜单选 8 亦可），自动同步 Caddy 反代端口
./tts-server.sh setup-caddy # 对外访问配置（菜单选 9 亦可）：装 Caddy + 写反代 + 签证书，幂等可重复执行
# 非交互：NEW_PORT=9090 ./tts-server.sh change-port ；DOMAIN=你的域名 ./tts-server.sh setup-caddy
```

## 说明

- 服务只监听 `127.0.0.1`，VPS 防火墙无需开放服务端口。若默认 8080 被占用，安装时自动改用其他空闲端口（见脚本输出）。
- 对外暴露后建议保留 `TTS_TOKEN`，避免他人白嫖。
- 共 39 个中文音色（与 legado_NG 内置默认一致）。
