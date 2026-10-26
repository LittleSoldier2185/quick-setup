#!/bin/bash
# ติดตั้งแบบ "มีเน็ต" เลือกได้ทีละส่วน (Ubuntu 22.04)
#
# วิธีใช้:
#   sudo bash setup-online.sh                  -> ขึ้นเมนู พิมพ์เลข เช่น 1 3 5
#   sudo bash setup-online.sh docker node      -> ระบุชื่อตรงๆ
#   sudo bash setup-online.sh all              -> ลงทั้งหมด
# ชื่อที่ใช้ได้: docker node emqx mysql nodered all

MYSQL_PASS="1234"
NODERED_USER="admin"
NODERED_PASS="1234"   # รหัสเข้า Node-RED (ปล่อยว่าง "" = ไม่ตั้งรหัส)
export DEBIAN_FRONTEND=noninteractive

if [ "$(id -u)" -ne 0 ]; then
  echo "กรุณารันด้วย root: sudo bash $0"
  exit 1
fi

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
running() { docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"; }

if want emqx || want mysql || want nodered; then
  want docker || SEL="$SEL docker"
fi

apt-get update -y
apt-get install -y curl ca-certificates gnupg

if want docker; then
  echo "===== Docker ====="
  if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sh
  fi
  systemctl enable --now docker
  docker --version
fi

if want node; then
  echo "===== Node.js 22 ====="
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y nodejs
  node -v
  npm -v
fi

if want emqx; then
  echo "===== EMQX ====="
  docker rm -f emqx 2>/dev/null
  # หมายเหตุ: emqx/emqx:5 ไม่มีบน Docker Hub ต้องใช้ latest หรือเลขเต็ม เช่น 5.8.0
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
  # รอให้ Node-RED สร้างไฟล์ settings.js ก่อน (แทน sleep ตายตัว)
  for i in $(seq 1 30); do
    docker exec nodered test -f /data/settings.js 2>/dev/null && break
    sleep 2
  done
  docker exec nodered npm install --prefix /data node-red-node-mysql \
    || echo "!!! ติดตั้ง node-red-node-mysql ไม่สำเร็จ (Node-RED ยังไม่มีโหนด MySQL)"

  if [ -n "$NODERED_PASS" ]; then
    echo "ตั้งรหัสผ่าน Node-RED..."
    if ! docker exec -e NR_USER="$NODERED_USER" -e NR_PASS="$NODERED_PASS" nodered node -e '
      const fs = require("fs"), bcrypt = require("bcryptjs");
      const f = "/data/settings.js";
      let s = fs.readFileSync(f, "utf8");
      s = s.replace(/^.*\/\* setup-online \*\/.*\n/m, "");
      if (/^\s*adminAuth\s*:/m.test(s)) { console.log("มี adminAuth ของคุณอยู่แล้ว ข้าม (รหัสที่แสดงท้ายสคริปต์อาจไม่ตรง)"); process.exit(0); }
      const hash = bcrypt.hashSync(process.env.NR_PASS, 8);
      const line = "\n    /* setup-online */ adminAuth: { type: \"credentials\", users: [{ username: " + JSON.stringify(process.env.NR_USER) + ", password: " + JSON.stringify(hash) + ", permissions: \"*\" }] },";
      const out = s.replace(/module\.exports\s*=\s*\{/, (m) => m + line);
      if (out === s) { console.error("หา module.exports ใน settings.js ไม่เจอ"); process.exit(1); }
      fs.writeFileSync(f, out);
      console.log("ตั้งรหัส Node-RED เรียบร้อย");
    '; then
      echo "!!! ตั้งรหัส Node-RED ไม่สำเร็จ — Node-RED เปิดโดยไม่มีรหัสผ่าน"
      NODERED_PASS=""
    fi
  fi
  docker restart nodered
fi

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  for p in 1880 1883 8083 8084 8883 18083 3306; do ufw allow ${p}/tcp; done
fi

echo
command -v docker >/dev/null 2>&1 && docker ps
IP=$(hostname -I | awk '{print $1}')
echo
# แสดงที่อยู่เฉพาะตัวที่รันอยู่จริง
if want nodered; then
  if running nodered; then
    if [ -n "$NODERED_PASS" ]; then
      echo "Node-RED : http://$IP:1880  ($NODERED_USER / $NODERED_PASS)"
    else
      echo "Node-RED : http://$IP:1880  (ไม่มีรหัส)"
    fi
  else
    echo "Node-RED : ไม่ได้รัน"
  fi
fi
if want emqx; then
  running emqx && echo "EMQX     : http://$IP:18083  (admin / public)  MQTT: $IP:1883" || echo "EMQX     : ไม่ได้รัน"
fi
if want mysql; then
  running mysql && echo "MySQL    : $IP:3306  (root / $MYSQL_PASS)" || echo "MySQL    : ไม่ได้รัน"
fi
exit 0
