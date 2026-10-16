FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY server.py .

ENV PORT=8080
ENV TTS_TOKEN=""

# 仅监听容器内部；由 docker-compose 映射到宿主机 127.0.0.1，
# 再由 cloudflared 隧道对外暴露，VPS 防火墙无需开放任何入站端口。
EXPOSE 8080

CMD ["python", "server.py"]
