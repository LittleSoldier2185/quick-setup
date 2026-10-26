#!/bin/bash
# ล้างของที่ติดตั้งไว้ เพื่อทดสอบสคริปต์ใหม่ตั้งแต่ต้น
#
# วิธีใช้:
#   sudo bash reset.sh          -> ถามว่าจะล้างระดับไหน
#   sudo bash reset.sh 1        -> ล้าง container + volume + image (เก็บ Docker, Node.js)
#   sudo bash reset.sh 2        -> ล้างทั้งหมด รวมถอน Docker และ Node.js
#
# ไม่แตะ GitLab (ติดตั้งแยกด้วย apt ไม่ได้ใช้ Docker)

if [ "$(id -u)" -ne 0 ]; then
  echo "กรุณารันด้วย root: sudo bash $0"
  exit 1
fi

LEVEL="$1"
if [ -z "$LEVEL" ]; then
  echo "เลือกระดับการล้าง"
  echo "  1) container + volume + image (เก็บ Docker และ Node.js ไว้)  ** ข้อมูลใน volume หายถาวร **"
  echo "  2) ล้างทั้งหมด รวมถอน Docker และ Node.js"
  read -r -p "เลือก (1/2): " LEVEL
fi
case "$LEVEL" in 1|2) ;; *) echo "ยกเลิก"; exit 1 ;; esac

read -r -p "ยืนยันล้างระดับ $LEVEL ? พิมพ์ yes เพื่อดำเนินการ: " OK
[ "$OK" = "yes" ] || { echo "ยกเลิก"; exit 1; }

if command -v docker >/dev/null 2>&1; then
  echo ">> ลบ container, volume, image"
  # ลบเฉพาะของที่สคริปต์ติดตั้งสร้าง ไม่แตะ container/image อื่นในเครื่อง
  docker rm -f emqx mysql nodered 2>/dev/null
  docker volume rm emqx_data emqx_log mysql_data nodered_data 2>/dev/null
  docker rmi -f emqx/emqx mysql:8 nodered/node-red 2>/dev/null
  docker rmi -f $(docker images -q 'emqx/emqx' 'nodered/node-red' 'mysql') 2>/dev/null
fi

if [ "$LEVEL" = "2" ]; then
  echo ">> ถอน Docker"
  systemctl stop docker docker.socket 2>/dev/null
  apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker.io 2>/dev/null
  if dpkg -l 2>/dev/null | grep -Eq '^ii +(docker-ce|docker\.io|containerd\.io) '; then
    echo "!! ถอน Docker ไม่สำเร็จ ไม่ลบ /var/lib/docker เพื่อกันข้อมูลหาย (ดู error ด้วย: apt-get purge docker-ce)"
  else
    rm -rf /var/lib/docker /var/lib/containerd /etc/docker
  fi
  rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc /etc/apt/keyrings/docker.gpg
  rm -rf /etc/systemd/system/docker.service.d
  systemctl daemon-reload

  echo ">> ถอน Node.js"
  apt-get purge -y nodejs 2>/dev/null
  rm -f /etc/apt/sources.list.d/nodesource.list
  rm -rf /usr/local/lib/nodejs /usr/local/bin/node /usr/local/bin/npm /usr/local/bin/npx

  echo ">> ลบค่า proxy และไฟล์ที่เคยสร้างเอง"
  rm -f /etc/apt/apt.conf.d/95proxy
  npm config delete proxy 2>/dev/null
  npm config delete https-proxy 2>/dev/null
  rm -f /root/.npmrc
  rm -rf /opt/iot-stack /root/iot-stack /root/setup.sh /usr/local/bin/go /root/bundle /root/bundle.tar.gz

  apt-get autoremove -y
fi

echo
echo "ล้างเสร็จแล้ว (ระดับ $LEVEL)"
command -v docker >/dev/null 2>&1 && docker ps -a || echo "Docker: ไม่มีในเครื่องแล้ว"
command -v node >/dev/null 2>&1 && node -v || echo "Node.js: ไม่มีในเครื่องแล้ว"
