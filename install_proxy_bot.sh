#!/usr/bin/env bash
set -Eeuo pipefail

### ================= CONFIG =================
MT_PORT=8443
WA_PORT=443
BOT_DIR="/opt/tg-proxy-bot"
SERVICE_FILE="/etc/systemd/system/tg-proxy-bot.service"
LOG="/var/log/proxy-install.log"
### ==========================================

exec > >(tee -a "$LOG") 2>&1

### ================= UTILS ==================
die() { echo "[ERROR] $*" >&2; exit 1; }

step() { echo -e "\n==== $* ===="; }

require_root() {
  [[ $EUID -eq 0 ]] || die "Run as root"
}

check_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

container_running() {
  docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null | grep -q running
}

rollback() {
  echo "[ROLLBACK] Cleaning up"
  systemctl stop tg-proxy-bot 2>/dev/null || true
  docker rm -f mtproto waproxy 2>/dev/null || true
}
trap rollback ERR
### ==========================================

require_root

### ================= INPUT ==================
echo "=== TELEGRAM SETTINGS ==="
read -rp "BOT TOKEN: " BOT_TOKEN
read -rp "ADMIN TELEGRAM ID: " ADMIN_ID
[[ -n "$BOT_TOKEN" && -n "$ADMIN_ID" ]] || die "Token or admin ID missing"
### ==========================================

### ================= SYSTEM =================
step "Installing system dependencies"
apt update
apt install -y \
  ca-certificates curl python3 python3-pip docker.io

systemctl enable docker
systemctl start docker
systemctl is-active docker >/dev/null || die "Docker not running"

check_cmd docker
check_cmd curl
check_cmd python3
### ==========================================

### ================= PYTHON =================
step "Installing Python dependencies"
pip3 install --no-cache-dir python-telegram-bot==20.7 requests
### ==========================================

### ================= PORTS ==================
step "Freeing port 443 if needed"
systemctl stop nginx apache2 2>/dev/null || true
### ==========================================

### ================= IMAGES =================
step "Pulling Docker images"
docker pull telegrammessenger/proxy:latest
docker pull facebook/whatsapp_proxy:latest
### ==========================================

### ================= MTPROTO =================
step "Starting MTProto proxy"
MT_SECRET="$(openssl rand -hex 16)"

docker rm -f mtproto 2>/dev/null || true
docker run -d \
  --name mtproto \
  --restart unless-stopped \
  -p ${MT_PORT}:443 \
  -e SECRET="${MT_SECRET}" \
  telegrammessenger/proxy:latest

sleep 2
container_running mtproto || die "MTProto failed to start"
### ==========================================

### ================= WHATSAPP =================
step "Starting WhatsApp proxy (official)"
docker rm -f waproxy 2>/dev/null || true
docker run -d \
  --name waproxy \
  --restart unless-stopped \
  -p ${WA_PORT}:443 \
  facebook/whatsapp_proxy:latest

sleep 2
container_running waproxy || die "WhatsApp proxy failed to start"
### ==========================================

### ================= TG MENU =================
step "Setting Telegram chat menu button"
curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/setChatMenuButton" \
  -H "Content-Type: application/json" \
  -d '{"menu_button":{"type":"commands"}}' >/dev/null
### ==========================================

### ================= BOT ====================
step "Installing Telegram bot"
mkdir -p "$BOT_DIR"

cat > "${BOT_DIR}/bot.py" <<PY
import subprocess, time, secrets, requests
from threading import Thread
from telegram import InlineKeyboardButton, InlineKeyboardMarkup, Update
from telegram.ext import ApplicationBuilder, CommandHandler, CallbackQueryHandler, ContextTypes

BOT_TOKEN="${BOT_TOKEN}"
ADMIN_ID=int("${ADMIN_ID}")
MT_PORT=${MT_PORT}
WA_PORT=${WA_PORT}

def sh(cmd): return subprocess.getoutput(cmd)

def notify(msg):
    requests.post(
        f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage",
        json={"chat_id": ADMIN_ID, "text": msg},
        timeout=5
    )

def ip(): return sh("curl -s https://api.ipify.org")

def stats(name):
    return (
        sh(f"docker inspect -f '{{{{.State.Status}}}}' {name}"),
        sh(f"docker inspect -f '{{{{.State.StartedAt}}}}' {name}"),
        sh(f"docker stats {name} --no-stream --format '{{{{.NetIO}}}}'")
    )

def mt_links(secret):
    i = ip()
    return f"tg://proxy?server={i}&port={MT_PORT}&secret={secret}\nhttps://t.me/proxy?server={i}&port={MT_PORT}&secret={secret}"

def wa_link():
    return f"{ip()}:{WA_PORT}"

state = {"mtproto": "running", "waproxy": "running"}

def monitor():
    while True:
        for c in state:
            s = sh(f"docker inspect -f '{{{{.State.Status}}}}' {c} 2>/dev/null")
            if s != "running" and state[c] == "running":
                notify(f"🚨 {c} DOWN")
                state[c] = s
            if s == "running" and state[c] != "running":
                notify(f"✅ {c} UP")
                state[c] = "running"
        time.sleep(15)

async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if update.effective_user.id != ADMIN_ID: return
    kb = [
        [InlineKeyboardButton("🟦 MTProto", callback_data="mt")],
        [InlineKeyboardButton("🟩 WhatsApp Proxy", callback_data="wa")]
    ]
    await update.message.reply_text("Proxy Control Panel", reply_markup=InlineKeyboardMarkup(kb))

async def cb(update: Update, context: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    if q.from_user.id != ADMIN_ID: return

    if q.data == "main":
        return await start(update, context)

    if q.data == "mt":
        kb = [
            [InlineKeyboardButton("📊 Status", callback_data="mt_s")],
            [InlineKeyboardButton("🔗 Links", callback_data="mt_l")],
            [InlineKeyboardButton("🔑 New secret", callback_data="mt_n")],
            [InlineKeyboardButton("🔄 Restart", callback_data="mt_r")],
            [InlineKeyboardButton("⬆️ Update", callback_data="mt_u")],
            [InlineKeyboardButton("⬅️ Back", callback_data="main")]
        ]
        return await q.edit_message_text("MTProto", reply_markup=InlineKeyboardMarkup(kb))

    if q.data == "wa":
        kb = [
            [InlineKeyboardButton("📊 Status", callback_data="wa_s")],
            [InlineKeyboardButton("🔗 Link", callback_data="wa_l")],
            [InlineKeyboardButton("🔄 Restart", callback_data="wa_r")],
            [InlineKeyboardButton("⬆️ Update", callback_data="wa_u")],
            [InlineKeyboardButton("⬅️ Back", callback_data="main")]
        ]
        return await q.edit_message_text("WhatsApp Proxy", reply_markup=InlineKeyboardMarkup(kb))

    if q.data == "mt_s":
        s,a,n = stats("mtproto")
        return await q.edit_message_text(f"MTProto\\n{s}\\n{a}\\n{n}")

    if q.data == "mt_l":
        sec = sh("docker inspect mtproto | grep SECRET | cut -d= -f2 | tr -d '[]\" '")
        return await q.edit_message_text(mt_links(sec))

    if q.data == "mt_n":
        sec = secrets.token_hex(16)
        sh("docker rm -f mtproto")
        sh(f"docker run -d --name mtproto --restart unless-stopped -p {MT_PORT}:443 -e SECRET={sec} telegrammessenger/proxy:latest")
        return await q.edit_message_text(mt_links(sec))

    if q.data == "mt_r":
        sh("docker restart mtproto")
        return await q.edit_message_text("MTProto restarted")

    if q.data == "mt_u":
        sh("docker pull telegrammessenger/proxy:latest && docker restart mtproto")
        return await q.edit_message_text("MTProto updated")

    if q.data == "wa_s":
        s,a,n = stats("waproxy")
        return await q.edit_message_text(f"WhatsApp\\n{s}\\n{a}\\n{n}")

    if q.data == "wa_l":
        return await q.edit_message_text(wa_link())

    if q.data == "wa_r":
        sh("docker restart waproxy")
        return await q.edit_message_text("WhatsApp restarted")

    if q.data == "wa_u":
        sh("docker pull facebook/whatsapp_proxy:latest && docker restart waproxy")
        return await q.edit_message_text("WhatsApp updated")

app = ApplicationBuilder().token(BOT_TOKEN).build()
app.add_handler(CommandHandler("start", start))
app.add_handler(CallbackQueryHandler(cb))
Thread(target=monitor, daemon=True).start()
app.run_polling()
PY
### ==========================================

### ================= SYSTEMD ================
step "Registering systemd service"
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Telegram Proxy Control Bot
After=network.target docker.service

[Service]
ExecStart=/usr/bin/python3 ${BOT_DIR}/bot.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable tg-proxy-bot
systemctl start tg-proxy-bot
systemctl is-active tg-proxy-bot >/dev/null || die "Bot failed to start"
### ==========================================

echo
echo "================ DONE ================"
echo "MTProto port : ${MT_PORT}"
echo "MTProto secret : ${MT_SECRET}"
echo "WhatsApp port : 443"
echo "Install log : ${LOG}"
echo "====================================="
