#!/bin/bash
set -e

echo "=== Telegram Bot настройки ==="
read -p "Введи Telegram BOT TOKEN: " BOT_TOKEN
read -p "Введи ADMIN Telegram ID: " ADMIN_ID

MT_PORT=8443
WA_PORT=443

echo "[+] Установка зависимостей"
apt update
apt install -y \
  ca-certificates curl gnupg lsb-release \
  python3 python3-pip \
  docker.io docker-compose

systemctl enable docker
systemctl start docker

pip3 install python-telegram-bot==20.7 requests

### === MTProto ===
echo "[+] Запуск MTProto"
MT_SECRET=$(openssl rand -hex 16)

docker rm -f mtproto 2>/dev/null || true
docker run -d \
  --name mtproto \
  --restart unless-stopped \
  -p ${MT_PORT}:443 \
  -e SECRET=$MT_SECRET \
  telegrammessenger/proxy:latest

### === WhatsApp TLS Proxy (443, оригинальный) ===
echo "[+] Запуск WhatsApp Proxy"

docker rm -f waproxy 2>/dev/null || true
docker run -d \
  --name waproxy \
  --restart unless-stopped \
  -p ${WA_PORT}:443 \
  ghcr.io/alkalinelab/waproxy:latest

### === Telegram Bot ===
mkdir -p /opt/tg-docker-bot

cat <<EOF >/opt/tg-docker-bot/bot.py
import subprocess
import time
import requests
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import ApplicationBuilder, CommandHandler, CallbackQueryHandler, ContextTypes
from threading import Thread

BOT_TOKEN = "${BOT_TOKEN}"
ADMIN_ID = int("${ADMIN_ID}")
TG_API = f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage"

containers = ["mtproto", "waproxy"]
last_state = {c: "running" for c in containers}

def sh(cmd):
    return subprocess.getoutput(cmd)

def notify(text):
    requests.post(TG_API, json={"chat_id": ADMIN_ID, "text": text})

def container_info(name):
    status = sh(f"docker inspect -f '{{{{.State.Status}}}}' {name} 2>/dev/null")
    started = sh(f"docker inspect -f '{{{{.State.StartedAt}}}}' {name} 2>/dev/null")
    net = sh(f"docker stats {name} --no-stream --format '{{{{.NetIO}}}}' 2>/dev/null")
    return status, started, net

def monitor():
    global last_state
    while True:
        for c in containers:
            state = sh(f"docker inspect -f '{{{{.State.Status}}}}' {c} 2>/dev/null")
            if state != "running" and last_state[c] == "running":
                notify(f"🚨 ALERT: {c} УПАЛ (state={state})")
                last_state[c] = state
            if state == "running" and last_state[c] != "running":
                notify(f"✅ {c} ВОССТАНОВЛЕН")
                last_state[c] = "running"
        time.sleep(15)

async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if update.effective_user.id != ADMIN_ID:
        return
    kb = [
        [InlineKeyboardButton("📊 Статус", callback_data="status")],
        [InlineKeyboardButton("🔄 Рестарт MTProto", callback_data="r_mt"),
         InlineKeyboardButton("🔄 Рестарт WA", callback_data="r_wa")],
        [InlineKeyboardButton("⬆️ Обновить MTProto", callback_data="u_mt"),
         InlineKeyboardButton("⬆️ Обновить WA", callback_data="u_wa")]
    ]
    await update.message.reply_text("Docker Proxy Control", reply_markup=InlineKeyboardMarkup(kb))

async def buttons(update: Update, context: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    if q.from_user.id != ADMIN_ID:
        return

    if q.data == "status":
        mt = container_info("mtproto")
        wa = container_info("waproxy")
        await q.edit_message_text(
            f"🟦 MTProto\nСтатус: {mt[0]}\nАптайм: {mt[1]}\nТрафик: {mt[2]}\n\n"
            f"🟩 WhatsApp Proxy (443)\nСтатус: {wa[0]}\nАптайм: {wa[1]}\nТрафик: {wa[2]}"
        )

    if q.data == "r_mt":
        sh("docker restart mtproto")
        await q.edit_message_text("MTProto перезапущен")

    if q.data == "r_wa":
        sh("docker restart waproxy")
        await q.edit_message_text("WhatsApp Proxy перезапущен")

    if q.data == "u_mt":
        sh("docker pull telegrammessenger/proxy:latest && docker restart mtproto")
        await q.edit_message_text("MTProto обновлён")

    if q.data == "u_wa":
        sh("docker pull ghcr.io/alkalinelab/waproxy:latest && docker restart waproxy")
        await q.edit_message_text("WhatsApp Proxy обновлён")

app = ApplicationBuilder().token(BOT_TOKEN).build()
app.add_handler(CommandHandler("start", start))
app.add_handler(CallbackQueryHandler(buttons))

Thread(target=monitor, daemon=True).start()
app.run_polling()
EOF

### === systemd ===
cat <<EOF >/etc/systemd/system/tg-docker-bot.service
[Unit]
Description=Telegram Docker Control Bot
After=network.target docker.service

[Service]
ExecStart=/usr/bin/python3 /opt/tg-docker-bot/bot.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable tg-docker-bot
systemctl start tg-docker-bot

echo "=================================="
echo "ГОТОВО"
echo "MTProto порт: ${MT_PORT}"
echo "MTProto secret: ${MT_SECRET}"
echo "WhatsApp proxy порт: 443"
echo "Алерты включены"
echo "=================================="
