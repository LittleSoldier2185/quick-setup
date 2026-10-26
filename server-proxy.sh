#!/bin/bash
# รันบน "เซิร์ฟเวอร์หลัก (มีเน็ต)" เพื่อให้เครื่อง dev/IoT ออกเน็ตผ่านเครื่องนี้
#
# วิธีใช้:
#   sudo bash server-proxy.sh 192.168.20.0/24        -> อนุญาตวงของ dev (VLAN20) เพิ่ม
#   sudo bash server-proxy.sh 192.168.20.0/24 192.168.30.0/24   -> หลายวงได้
#   sudo bash server-proxy.sh                        -> ไม่ใส่ จะถามให้พิมพ์
# วงของเครื่องนี้เองจะถูกอนุญาตให้อัตโนมัติ

PORT=8888
export DEBIAN_FRONTEND=noninteractive

if [ "$(id -u)" -ne 0 ]; then
  echo "กรุณารันด้วย root: sudo bash $0"
  exit 1
fi

EXTRA="$*"
if [ -z "$EXTRA" ]; then
  read -r -p "วงเครือข่ายของ dev/IoT (เช่น 192.168.20.0/24 คั่นด้วยเว้นวรรค): " EXTRA
fi

apt-get update -y
apt-get install -y tinyproxy curl

# วงเครือข่ายของเครื่องนี้ (เช่น 192.168.10.0/24)
DEV=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n 1)
OWN=$(ip -o -4 route show dev "$DEV" scope link 2>/dev/null | awk '{print $1}' | head -n 1)
SUBNETS="$OWN $EXTRA"
if [ -z "$(echo $SUBNETS)" ]; then
  echo "!! ไม่มีวงเครือข่ายให้อนุญาต (หาวงของเครื่องนี้ไม่เจอ และไม่ได้ระบุเพิ่ม) -> proxy จะปฏิเสธทุกเครื่อง"
  exit 1
fi
for s in $SUBNETS; do
  echo "$s" | grep -Eq '^[0-9a-fA-F:.]+(/[0-9]+)?$' || { echo "รูปแบบวงเครือข่ายไม่ถูกต้อง: $s"; exit 1; }
done
echo "อนุญาตวง: $SUBNETS"

CONF=/etc/tinyproxy/tinyproxy.conf
cp -n "$CONF" "$CONF.bak"
if grep -Eq '^#?\s*Port ' "$CONF"; then
  sed -i -E "s/^#?\s*Port .*/Port $PORT/" "$CONF"
else
  echo "Port $PORT" >> "$CONF"
fi
for s in $SUBNETS; do
  grep -qxF "Allow $s" "$CONF" || echo "Allow $s" >> "$CONF"
done
# จำกัดพอร์ตปลายทางที่ CONNECT ได้ ไม่ให้ใช้เซิร์ฟเวอร์เป็นทางผ่านไปพอร์ตอื่น
for p in 80 443; do
  grep -qxF "ConnectPort $p" "$CONF" || echo "ConnectPort $p" >> "$CONF"
done

systemctl enable tinyproxy
systemctl restart tinyproxy

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  for s in $SUBNETS; do
    ufw allow from "$s" to any port "$PORT" proto tcp
  done
fi

IP=$(hostname -I | awk '{print $1}')
echo
echo "ทดสอบ proxy เครื่องนี้:"
curl -sS -m 8 -x "http://127.0.0.1:$PORT" -o /dev/null -w "  https://deb.nodesource.com -> HTTP %{http_code}\n" https://deb.nodesource.com
echo
echo "================================================"
echo "Proxy พร้อมแล้วที่ http://$IP:$PORT"
echo "บนเครื่อง dev ทดสอบก่อนว่าพอร์ตถึง:"
echo "  curl -x http://$IP:$PORT -I https://deb.nodesource.com"
echo "แล้วรัน: sudo bash dev-setup.sh $IP"
echo "================================================"
