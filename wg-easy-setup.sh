#!/bin/bash
# ============================================================
#  wg-easy автоустановка — HostKey NL / Ubuntu/Debian
#  Использование: bash wg-easy-setup.sh
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[✓]${NC} $1"; }
info() { echo -e "${CYAN}[i]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# ── Root check ──────────────────────────────────────────────
[[ $EUID -ne 0 ]] && err "Запусти скрипт от root: sudo bash $0"

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║   wg-easy VPN — автоустановка            ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
echo ""

# ── Определяем внешний IP ───────────────────────────────────
info "Определяю внешний IP сервера..."
SERVER_IP=$(curl -s https://api.ipify.org || curl -s https://ifconfig.me)
[[ -z "$SERVER_IP" ]] && err "Не удалось получить внешний IP"
ok "Внешний IP: $SERVER_IP"

# ── Определяем сетевой интерфейс ────────────────────────────
NIC=$(ip route get 8.8.8.8 | awk '{print $5; exit}')
ok "Сетевой интерфейс: $NIC"

# ── Параметры (можно изменить) ───────────────────────────────
WG_PORT=51820
WEB_PORT=51821
WG_SUBNET="10.0.0.0/24"
DNS="1.1.1.1"

# ── Пароль для веб-интерфейса ────────────────────────────────
echo ""
echo -e "${YELLOW}Придумай пароль для веб-интерфейса wg-easy:${NC}"
read -rsp "Пароль: " WEB_PASSWORD
echo ""
[[ -z "$WEB_PASSWORD" ]] && err "Пароль не может быть пустым"

# ── Количество клиентов ──────────────────────────────────────
echo ""
read -rp "Сколько клиентов создать сейчас? (1-5): " CLIENT_COUNT
CLIENT_COUNT=${CLIENT_COUNT:-1}
if ! [[ "$CLIENT_COUNT" =~ ^[0-9]+$ ]] || [ "$CLIENT_COUNT" -lt 1 ] || [ "$CLIENT_COUNT" -gt 5 ]; then
  CLIENT_COUNT=1
fi

# ── Обновление системы ───────────────────────────────────────
echo ""
info "Обновляю систему..."
apt-get update -qq && apt-get upgrade -y -qq
ok "Система обновлена"

# ── IP Forwarding ────────────────────────────────────────────
info "Включаю IP Forwarding..."
grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf \
  || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
grep -q "^net.ipv6.conf.all.forwarding=1" /etc/sysctl.conf \
  || echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
sysctl -p > /dev/null 2>&1
ok "IP Forwarding включён"

# ── Установка зависимостей ───────────────────────────────────
info "Устанавливаю зависимости..."
apt-get install -y -qq curl ufw wireguard-tools qrencode
ok "Зависимости установлены"

# ── Установка Docker ─────────────────────────────────────────
if ! command -v docker &>/dev/null; then
  info "Устанавливаю Docker..."
  curl -fsSL https://get.docker.com | bash -s -- -q
  systemctl enable docker --quiet
  systemctl start docker
  ok "Docker установлен"
else
  ok "Docker уже установлен ($(docker --version | cut -d' ' -f3 | tr -d ','))"
fi

# ── Настройка UFW ─────────────────────────────────────────────
info "Настраиваю файрвол (UFW)..."
ufw --force reset > /dev/null 2>&1
ufw default deny incoming > /dev/null 2>&1
ufw default allow outgoing > /dev/null 2>&1
ufw allow ssh > /dev/null 2>&1
ufw allow "$WG_PORT/udp" comment "WireGuard" > /dev/null 2>&1
ufw allow "$WEB_PORT/tcp" comment "wg-easy UI" > /dev/null 2>&1
ufw --force enable > /dev/null 2>&1
ok "UFW настроен"

# ── Хэш пароля для wg-easy ───────────────────────────────────
info "Генерирую хэш пароля..."
if ! command -v node &>/dev/null; then
  apt-get install -y -qq nodejs > /dev/null 2>&1
fi
PASSWORD_HASH=$(node -e "const {createHash}=require('crypto'); \
  console.log('\$\$'+createHash('sha256').update('$WEB_PASSWORD').digest('hex'))" 2>/dev/null \
  || docker run --rm node:alpine node -e \
    "const {createHash}=require('crypto'); \
    console.log('\$\$'+createHash('sha256').update('$WEB_PASSWORD').digest('hex'))")
ok "Хэш пароля готов"

# ── Запуск wg-easy ────────────────────────────────────────────
info "Запускаю wg-easy контейнер..."

docker rm -f wg-easy 2>/dev/null || true

docker run -d \
  --name wg-easy \
  --restart=unless-stopped \
  --cap-add=NET_ADMIN \
  --cap-add=SYS_MODULE \
  --sysctl="net.ipv4.conf.all.src_valid_mark=1" \
  --sysctl="net.ipv4.ip_forward=1" \
  -v "/etc/wireguard:/etc/wireguard" \
  -p "${WG_PORT}:51820/udp" \
  -p "${WEB_PORT}:51821/tcp" \
  -e LANG=ru \
  -e WG_HOST="$SERVER_IP" \
  -e PASSWORD_HASH="$PASSWORD_HASH" \
  -e WG_PORT="$WG_PORT" \
  -e WG_DEFAULT_ADDRESS="$WG_SUBNET" \
  -e WG_DEFAULT_DNS="$DNS" \
  -e WG_ALLOWED_IPS="0.0.0.0/0" \
  -e WG_PERSISTENT_KEEPALIVE=25 \
  -e UI_TRAFFIC_STATS=true \
  -e UI_CHART_TYPE=1 \
  ghcr.io/wg-easy/wg-easy

ok "wg-easy запущен"

# ── Ждём старта ───────────────────────────────────────────────
info "Жду запуска wg-easy (15 сек)..."
sleep 15

# ── Создаём клиентов через API ────────────────────────────────
echo ""
info "Создаю $CLIENT_COUNT клиента(ов)..."

# Получаем сессионный cookie
SESSION=$(curl -s -c /tmp/wg-cookie.txt -X POST \
  "http://127.0.0.1:$WEB_PORT/api/session" \
  -H "Content-Type: application/json" \
  -d "{\"password\":\"$WEB_PASSWORD\"}" 2>/dev/null)

for i in $(seq 1 "$CLIENT_COUNT"); do
  CLIENT_NAME="client-$i"
  RESULT=$(curl -s -b /tmp/wg-cookie.txt -X POST \
    "http://127.0.0.1:$WEB_PORT/api/wireguard/client" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"$CLIENT_NAME\"}" 2>/dev/null)

  CLIENT_ID=$(echo "$RESULT" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

  if [[ -n "$CLIENT_ID" ]]; then
    # Сохраняем .conf файл
    curl -s -b /tmp/wg-cookie.txt \
      "http://127.0.0.1:$WEB_PORT/api/wireguard/client/$CLIENT_ID/configuration" \
      -o "/root/$CLIENT_NAME.conf" 2>/dev/null

    ok "Клиент $CLIENT_NAME создан → /root/$CLIENT_NAME.conf"

    # QR-код в терминале
    echo ""
    echo -e "${CYAN}QR-код для $CLIENT_NAME:${NC}"
    qrencode -t ansiutf8 < "/root/$CLIENT_NAME.conf" 2>/dev/null || true
    echo ""
  else
    warn "Не удалось создать $CLIENT_NAME через API (добавь вручную в UI)"
  fi
done

rm -f /tmp/wg-cookie.txt

# ── Итог ─────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   Установка завершена успешно!                   ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}  Веб-интерфейс:  http://${SERVER_IP}:${WEB_PORT}         ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  WireGuard порт: UDP ${WG_PORT}                       ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Конфиги клиентов: /root/client-*.conf           ${GREEN}║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}  Управление контейнером:                         ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}    docker restart wg-easy                         ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}    docker logs wg-easy                            ${GREEN}║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
warn "Открой порт $WEB_PORT только для своего IP если используешь в продакшне!"
warn "Пример: ufw allow from <твой_IP> to any port $WEB_PORT"
echo ""
