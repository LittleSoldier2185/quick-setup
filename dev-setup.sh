#!/bin/bash
# รันบน "เครื่อง dev/IoT (ไม่มีเน็ต)" โดยออกเน็ตผ่าน proxy ของเซิร์ฟเวอร์หลัก
# ต้องรัน server-proxy.sh บนเซิร์ฟเวอร์หลักก่อน
#
# วิธีใช้:
#   sudo bash dev-setup.sh                 -> ถาม IP เซิร์ฟเวอร์ แล้วขึ้นเมนู
#   sudo bash dev-setup.sh 192.168.10.2    -> ระบุ IP ตรงๆ แล้วขึ้นเมนู
#   sudo bash dev-setup.sh 192.168.10.2 docker node   -> ระบุสิ่งที่จะลงเลย
# ชื่อที่ใช้ได้: docker node emqx mysql nodered all

PORT=8888
MYSQL_PASS="1234"
export DEBIAN_FRONTEND=noninteractive

if [ "$(id -u)" -ne 0 ]; then
  echo "กรุณารันด้วย root: sudo bash $0"
  exit 1
fi

# ---------- ตั้ง proxy ----------
SERVER_IP="$1"
[ $# -gt 0 ] && shift
if [ -z "$SERVER_IP" ]; then
  read -r -p "IP เซิร์ฟเวอร์หลัก (ที่รัน proxy): " SERVER_IP
fi
if ! echo "$SERVER_IP" | grep -Eq '^[A-Za-z0-9.-]+$'; then
  echo "IP/ชื่อเซิร์ฟเวอร์ไม่ถูกต้อง: $SERVER_IP"
  exit 1
fi
PROXY="http://$SERVER_IP:$PORT"
NOPROXY="localhost,127.0.0.1,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12"

# ---------- เลือกสิ่งที่จะติดตั้ง (ตรวจก่อนแก้ค่าระบบ) ----------
SEL="$*"
if [ -z "$SEL" ]; then
  echo "เลือกสิ่งที่จะติดตั้ง (พิมพ์เลขคั่นด้วยเว้นวรรค เช่น 1 3 5)"
  echo "  1) Docker"
  echo "  2) Node.js 22"
  echo "  3) EMQX (MQTT)"
  echo "  4) MySQL"
  echo "  5) Node-RED"
  echo "  6) ทั้งหมด"
  read -r -p "เลือก: " CHOICE
  for n in $CHOICE; do
    case "$n" in
      1) SEL="$SEL docker" ;;
      2) SEL="$SEL node" ;;
      3) SEL="$SEL emqx" ;;
      4) SEL="$SEL mysql" ;;
      5) SEL="$SEL nodered" ;;
      6) SEL="all" ;;
    esac
  done
fi
case " $SEL " in *" all "*) SEL="docker node emqx mysql nodered" ;; esac
for w in $SEL; do
  case "$w" in
    docker|node|emqx|mysql|nodered) ;;
    *) echo "ไม่รู้จัก: $w (ใช้ได้: docker node emqx mysql nodered all)"; exit 1 ;;
  esac
done
if [ -z "$(echo $SEL)" ]; then
  echo "ไม่ได้เลือกอะไร"
  exit 1
fi

want() { echo " $SEL " | grep -q " $1 "; }

if want emqx || want mysql || want nodered; then
  want docker || SEL="$SEL docker"
fi

echo "ทดสอบ proxy $PROXY ..."
CODE=$(curl -sS -m 10 -x "$PROXY" -o /dev/null -w "%{http_code}" https://deb.nodesource.com 2>/dev/null)
case "$CODE" in
  000|""|403|407|502|503|504)
    echo "!! ใช้ proxy ไม่ได้ (HTTP ${CODE:-000}) เช็ก: ping $SERVER_IP, server-proxy.sh รันแล้วหรือยัง, วงเครือข่ายนี้ถูก Allow หรือยัง"
    exit 1
    ;;
esac
echo "proxy ใช้ได้ (HTTP $CODE)"

export http_proxy="$PROXY" https_proxy="$PROXY" HTTP_PROXY="$PROXY" HTTPS_PROXY="$PROXY"
export no_proxy="$NOPROXY" NO_PROXY="$NOPROXY"

# apt
cat > /etc/apt/apt.conf.d/95proxy <<EOF_APT
Acquire::http::Proxy "$PROXY";
Acquire::https::Proxy "$PROXY";
EOF_APT

# Docker daemon (ใช้ตอน docker pull)
mkdir -p /etc/systemd/system/docker.service.d
DK_CONF=/etc/systemd/system/docker.service.d/http-proxy.conf
cat > "$DK_CONF.new" <<EOF_DK
[Service]
Environment="HTTP_PROXY=$PROXY"
Environment="HTTPS_PROXY=$PROXY"
Environment="NO_PROXY=$NOPROXY"
EOF_DK
if ! cmp -s "$DK_CONF.new" "$DK_CONF"; then
  mv "$DK_CONF.new" "$DK_CONF"
  systemctl daemon-reload
  # restart เฉพาะเมื่อค่า proxy เปลี่ยนจริง (กัน container ที่รันอยู่ดับโดยไม่จำเป็น)
  systemctl is-active --quiet docker && systemctl restart docker
else
  rm -f "$DK_CONF.new"
fi

apt-get update -y
apt-get install -y curl ca-certificates gnupg

if want docker; then
  echo "===== Docker ====="
  if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sh
  fi
  systemctl daemon-reload
  systemctl enable docker
  systemctl restart docker
  docker --version
fi

if want node; then
  echo "===== Node.js 22 ====="
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y nodejs
  node -v
  npm -v
  npm config set proxy "$PROXY"
  npm config set https-proxy "$PROXY"
fi

if want emqx; then
  echo "===== EMQX ====="
  docker rm -f emqx 2>/dev/null
  docker run -d --name emqx --restart always \
    -p 1883:1883 -p 8083:8083 -p 8084:8084 -p 8883:8883 -p 18083:18083 \
    -v emqx_data:/opt/emqx/data \
    emqx/emqx:latest \
    || echo "!!! EMQX ติดตั้งไม่สำเร็จ ดู error ด้านบน"
fi

if want mysql; then
  echo "===== MySQL ====="
  docker rm -f mysql 2>/dev/null
  docker run -d --name mysql --restart always \
    -p 3306:3306 \
    -e MYSQL_ROOT_PASSWORD="$MYSQL_PASS" \
    -e MYSQL_DATABASE=iotdb \
    -v mysql_data:/var/lib/mysql \
    mysql:8 \
    || echo "!!! MySQL ติดตั้งไม่สำเร็จ ดู error ด้านบน"
fi

if want nodered; then
  echo "===== Node-RED ====="
  docker rm -f nodered 2>/dev/null
  docker run -d --name nodered --restart always \
    -p 1880:1880 \
    -v nodered_data:/data \
    nodered/node-red:latest \
    || echo "!!! Node-RED ติดตั้งไม่สำเร็จ ดู error ด้านบน"
  # รอให้ container พร้อมแทน sleep ตายตัว
  for i in $(seq 1 30); do
    docker exec nodered test -f /data/settings.js 2>/dev/null && break
    sleep 2
  done
  if docker exec -e HTTP_PROXY="$PROXY" -e HTTPS_PROXY="$PROXY" -e NO_PROXY="$NOPROXY" \
      nodered npm install --prefix /data node-red-node-mysql; then
    docker restart nodered
  else
    echo "!!! ติดตั้ง node-red-node-mysql ไม่สำเร็จ (Node-RED ยังไม่มีโหนด MySQL)"
  fi
fi

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  for p in 1880 1883 8083 8084 8883 18083 3306; do ufw allow ${p}/tcp; done
fi

echo
command -v docker >/dev/null 2>&1 && docker ps
IP=$(hostname -I | awk '{print $1}')
echo
running() { docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"; }
if want nodered; then
  running nodered && echo "Node-RED : http://$IP:1880" || echo "Node-RED : ไม่ได้รัน"
fi
if want emqx; then
  running emqx && echo "EMQX     : http://$IP:18083  (admin / public)  MQTT: $IP:1883" || echo "EMQX     : ไม่ได้รัน"
fi
if want mysql; then
  running mysql && echo "MySQL    : $IP:3306  (root / $MYSQL_PASS)" || echo "MySQL    : ไม่ได้รัน"
fi
exit 0
