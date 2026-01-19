#!/bin/bash
set -Eeuo pipefail

LOG="/var/log/proxy-install.log"
exec > >(tee -a "$LOG") 2>&1

rollback() {
  echo "[ROLLBACK] Откат"
  systemctl stop tg-proxy-bot 2>/dev/null || true
  docker rm -f mtproto waproxy 2>/dev/null || true
}
trap rollback ERR

echo "=== НАСТРОЙКА ==="
read -p "Telegram BOT TOKEN: " BOT_TOKEN
read -p "Telegram ADMIN ID: " ADMIN_ID

MT_PORT=8443
WA_PORT=443

step() { echo -e "\n==== $1 ===="; }

check_container() {
  docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null | grep -q running
}

step "Установка зависимостей"
apt update
apt install -y curl ca-certificates python3 python3-pip docker.io

systemctl enable docker
systemctl start docker
systemctl is-active docker

pip3 install --no-cache-dir python-telegram-bot==20.7 requests

step "Освобождение порта 443"
systemctl stop nginx apache2 2>/dev/null || true

step "Загрузка Docker образов"
docker pull telegrammessenger/proxy:latest
docker pull facebook/whatsapp_proxy:latest

step "Запуск MTProto"
MT_SECRET=$(openssl rand -hex 16)
docker rm -f mtproto 2>/dev/null || true
docker run -d \
  --name mtproto \
  --restart unless-stopped \
  -p ${MT_PORT}:443 \
  -e SECRET=${MT_SECRET} \
  telegrammessenger/proxy:latest

sleep 3
check_container mtproto || { echo "MTPROTO НЕ ЗАПУСТИЛСЯ"; docker logs mtproto; exit 1; }

step "Запуск WhatsApp Proxy"
docker rm -f waproxy 2>/dev/null || true
docker run -d \
  --name waproxy \
  --restart unless-stopped \
  -p ${WA_PORT}:443 \
  facebook/whatsapp_proxy:latest

sleep 3
check_container waproxy || { echo "WHATSAPP НЕ ЗАПУСТИЛСЯ"; docker logs waproxy; exit 1; }

step "Настройка Telegram Menu Button"
curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/setChatMenuButton" \
  -H "Content-Type: application/json" \
  -d '{"menu_button":{"type":"commands"}}' >/dev/null

step "Установка Telegram-бота"
mkdir -p /opt/tg-proxy-bot

cat <<EOF >/opt/tg-proxy-bot/bot.py
import subprocess, time, secrets, requests
from threading import Thread
from telegram import InlineKeyboardButton, InlineKeyboardMarkup, Update
from telegram.ext import ApplicationBuilder, CommandHandler, CallbackQueryHandler, ContextTypes

BOT_TOKEN="${BOT_TOKEN}"
ADMIN_ID=int("${ADMIN_ID}")
MT_PORT=${MT_PORT}
WA_PORT=${WA_PORT}

def sh(c): return subprocess.getoutput(c)

def notify(t):
    requests.post(
        f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage",
        json={"chat_id":ADMIN_ID,"text":t}
    )

def ip(): return sh("curl -s https://api.ipify.org")

def stats(name):
    return (
        sh(f"docker inspect -f '{{{{.State.Status}}}}' {name}"),
        sh(f"docker inspect -f '{{{{.State.StartedAt}}}}' {name}"),
        sh(f"docker stats {name} --no-stream --format '{{{{.NetIO}}}}'")
    )

def mt_links(secret):
    i=ip()
    return (
        f"tg://proxy?server={i}&port={MT_PORT}&secret={secret}\n"
        f"https://t.me/proxy?server={i}&port={MT_PORT}&secret={secret}"
    )

def wa_link():
    return f"{ip()}:{WA_PORT}"

last={"mtproto":"running","waproxy":"running"}

def monitor():
    while True:
        for c in last:
            s=sh(f"docker inspect -f '{{{{.State.Status}}}}' {c} 2>/dev/null")
            if s!="running" and last[c]=="running":
                notify(f"🚨 {c} УПАЛ")
                last[c]=s
            if s=="running" and last[c]!="running":
                notify(f"✅ {c} ВОССТАНОВЛЕН")
                last[c]="running"
        time.sleep(15)

async def start(update:Update,context:ContextTypes.DEFAULT_TYPE):
    if update.effective_user.id!=ADMIN_ID: return
    kb=[
        [InlineKeyboardButton("🟦 MTProto",callback_data="mt")],
        [InlineKeyboardButton("🟩 WhatsApp Proxy",callback_data="wa")]
    ]
    await update.message.reply_text("Proxy Control Panel",reply_markup=InlineKeyboardMarkup(kb))

async def cb(update:Update,context:ContextTypes.DEFAULT_TYPE):
    q=update.callback_query
    await q.answer()
    if q.from_user.id!=ADMIN_ID: return

    if q.data=="main":
        await start(update,context)

    elif q.data=="mt":
        kb=[
            [InlineKeyboardButton("📊 Статус",callback_data="mt_s")],
            [InlineKeyboardButton("🔗 Ссылки",callback_data="mt_l")],
            [InlineKeyboardButton("🔑 Новый SECRET",callback_data="mt_n")],
            [InlineKeyboardButton("🔄 Перезапуск",callback_data="mt_r")],
            [InlineKeyboardButton("⬆️ Обновить",callback_data="mt_u")],
            [InlineKeyboardButton("⬅️ Назад",callback_data="main")]
        ]
        await q.edit_message_text("🟦 MTProto",reply_markup=InlineKeyboardMarkup(kb))

    elif q.data=="wa":
        kb=[
            [InlineKeyboardButton("📊 Статус",callback_data="wa_s")],
            [InlineKeyboardButton("🔗 Ссылка",callback_data="wa_l")],
            [InlineKeyboardButton("🔄 Перезапуск",callback_data="wa_r")],
            [InlineKeyboardButton("⬆️ Обновить",callback_data="wa_u")],
            [InlineKeyboardButton("⬅️ Назад",callback_data="main")]
        ]
        await q.edit_message_text("🟩 WhatsApp Proxy",reply_markup=InlineKeyboardMarkup(kb))

    elif q.data=="mt_s":
        s,a,n=stats("mtproto")
        await q.edit_message_text(f"MTProto\\nСтатус:{s}\\nАптайм:{a}\\nТрафик:{n}")

    elif q.data=="mt_l":
        sec=sh("docker inspect mtproto | grep SECRET | head -1 | cut -d= -f2 | tr -d '\"[] '")
        await q.edit_message_text(mt_links(sec))

    elif q.data=="mt_n":
        sec=secrets.token_hex(16)
        sh("docker rm -f mtproto")
        sh(f"docker run -d --name mtproto --restart unless-stopped -p {MT_PORT}:443 -e SECRET={sec} telegrammessenger/proxy:latest")
        await q.edit_message_text(mt_links(sec))

    elif q.data=="mt_r":
        sh("docker restart mtproto")
        await q.edit_message_text("MTProto перезапущен")

    elif q.data=="mt_u":
        sh("docker pull telegrammessenger/proxy:latest && docker restart mtproto")
        await q.edit_message_text("MTProto обновлён")

    elif q.data=="wa_s":
        s,a,n=stats("waproxy")
        await q.edit_message_text(f"WhatsApp\\nСтатус:{s}\\nАптайм:{a}\\nТрафик:{n}")

    elif q.data=="wa_l":
        await q.edit_message_text(wa_link())

    elif q.data=="wa_r":
        sh("docker restart waproxy")
        await q.edit_message_text("WhatsApp перезапущен")

    elif q.data=="wa_u":
        sh("docker pull facebook/whatsapp_proxy:latest && docker restart waproxy")
        await q.edit_message_text("WhatsApp обновлён")

app=ApplicationBuilder().token(BOT_TOKEN).build()
app.add_handler(CommandHandler("start",start))
app.add_handler(CallbackQueryHandler(cb))
Thread(target=monitor,daemon=True).start()
app.run_polling()
EOF

cat <<EOF >/etc/systemd/system/tg-proxy-bot.service
[Unit]
Description=Telegram Proxy Control Bot
After=network.target docker.service

[Service]
ExecStart=/usr/bin/python3 /opt/tg-proxy-bot/bot.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable tg-proxy-bot
systemctl start tg-proxy-bot
systemctl is-active tg-proxy-bot

echo "================================="
echo "ГОТОВО"
echo "MTProto порт: ${MT_PORT}"
echo "WhatsApp порт: 443"
echo "MTProto SECRET: ${MT_SECRET}"
echo "Логи установки: ${LOG}"
echo "================================="
