#!/bin/bash
# เครื่องมือเดียวจัดการ IoT stack (Docker, Node.js LTS, EMQX, MySQL + phpMyAdmin, Node-RED) บน Ubuntu 22.04
#
# วิธีใช้:
#   sudo bash iot.sh                                   -> ขึ้นเมนูหลัก
#   sudo bash iot.sh install [ชื่อ...]                 -> ติดตั้ง (ไม่ระบุชื่อ = ขึ้นเมนูเลือก)
#   sudo bash iot.sh install --proxy 192.168.10.2 ...  -> ติดตั้งผ่าน proxy ของเซิร์ฟเวอร์หลัก (เครื่องไม่มีเน็ต)
#   sudo bash iot.sh proxy [วงเครือข่าย...]            -> ตั้ง proxy บนเซิร์ฟเวอร์หลัก (มีเน็ต)
#   sudo bash iot.sh bundle                            -> โหลดไฟล์มาเก็บ + แชร์ผ่าน HTTP (เซิร์ฟเวอร์หลัก)
#   sudo bash iot.sh install --from http://IP:8000 ... -> ติดตั้งจาก bundle (ไม่ต้องมีเน็ตเลย)
#   sudo bash iot.sh update [URL]                      -> อัปเดต iot.sh เอง (ไม่ใส่ URL: bundle เดิม หรือ GitHub)
#   sudo bash iot.sh status                            -> ดูสถานะ (exit 1 ถ้ามีอะไรผิดปกติ)
#   sudo bash iot.sh reset [1|2]                       -> ล้างของที่ติดตั้ง
# ชื่อที่ใช้กับ install: docker node emqx mysql nodered apache git all

PORT=8888
NODE_MAJOR=24   # Node.js LTS ที่จะติดตั้ง (26 = Current, ยังไม่ใช่ LTS)
REPO_URL="https://github.com/LittleSoldier2185/quick-setup.git"
BUNDLE_URL_FILE=/etc/iot-bundle.url   # จำ URL ของ bundle ที่ใช้ install --from ไว้ให้ update
DB_PASS="${DB_PASS:-1234}"
NODERED_USER="admin"
NODERED_PASS="1234"   # รหัสเข้า Node-RED (ปล่อยว่าง "" = ไม่ตั้งรหัส)
export DEBIAN_FRONTEND=noninteractive

if [ "$(id -u)" -ne 0 ]; then
  echo "กรุณารันด้วย root: sudo bash $0 $*"
  exit 1
fi

running() { docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"; }

# =====================================================================
#  install
# =====================================================================
cmd_install() {
  PROXY=""
  FROM=""
  while [ "$1" = "--proxy" ] || [ "$1" = "-p" ] || [ "$1" = "--from" ]; do
    OPT="$1"; VAL="$2"
    [ $# -ge 2 ] && shift 2 || shift
    if [ "$OPT" = "--from" ]; then
      [ -z "$VAL" ] && read -r -p "URL ของ bundle (เช่น http://192.168.10.2:8000): " VAL
      echo "$VAL" | grep -Eq "^https?://[A-Za-z0-9.:-]+/?$" || { echo "URL ไม่ถูกต้อง: $VAL"; exit 1; }
      FROM="${VAL%/}"
    else
      SERVER_IP="$VAL"
      [ -z "$SERVER_IP" ] && read -r -p "IP เซิร์ฟเวอร์หลัก (ที่รัน proxy): " SERVER_IP
      if ! echo "$SERVER_IP" | grep -Eq '^[A-Za-z0-9.-]+$'; then
        echo "IP/ชื่อเซิร์ฟเวอร์ไม่ถูกต้อง: $SERVER_IP"
        exit 1
      fi
      PROXY="http://$SERVER_IP:$PORT"
      NOPROXY="localhost,127.0.0.1,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12"
    fi
  done

  # ---------- เลือกสิ่งที่จะติดตั้ง (ตรวจก่อนแก้ค่าระบบ) ----------
  SEL="$*"
  if [ -z "$SEL" ]; then
    echo "เลือกสิ่งที่จะติดตั้ง (พิมพ์เลขคั่นด้วยเว้นวรรค เช่น 1 3 5)"
    echo "  1) Docker"
    echo "  2) Node.js $NODE_MAJOR"
    echo "  3) EMQX (MQTT)"
    echo "  4) MySQL + phpMyAdmin"
    echo "  5) Node-RED"
    echo "  6) Apache"
    echo "  7) Git"
    echo "  8) ทั้งหมด"
    read -r -p "เลือก: " CHOICE
    for n in $CHOICE; do
      case "$n" in
        1) SEL="$SEL docker" ;;
        2) SEL="$SEL node" ;;
        3) SEL="$SEL emqx" ;;
        4) SEL="$SEL mysql" ;;
        5) SEL="$SEL nodered" ;;
        6) SEL="$SEL apache" ;;
        7) SEL="$SEL git" ;;
        8) SEL="all" ;;
      esac
    done
  fi
  case " $SEL " in *" all "*) SEL="docker node emqx mysql nodered apache git" ;; esac
  for w in $SEL; do
    case "$w" in
      docker|node|emqx|mysql|nodered|apache|git) ;;
      *) echo "ไม่รู้จัก: $w (ใช้ได้: docker node emqx mysql nodered apache git all)"; exit 1 ;;
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

  # ---------- proxy (เฉพาะเมื่อใช้ --proxy) ----------
  PX_ENV=()
  if [ -n "$PROXY" ]; then
    echo "ทดสอบ proxy $PROXY ..."
    CODE=$(curl -sS -m 10 -x "$PROXY" -o /dev/null -w "%{http_code}" https://deb.nodesource.com 2>/dev/null)
    case "$CODE" in
      000|""|403|407|502|503|504)
        echo "!! ใช้ proxy ไม่ได้ (HTTP ${CODE:-000}) เช็ก: ping $SERVER_IP, รัน 'iot.sh proxy' บนเซิร์ฟเวอร์หลักแล้วหรือยัง, วงเครือข่ายนี้ถูก Allow หรือยัง"
        exit 1
        ;;
    esac
    echo "proxy ใช้ได้ (HTTP $CODE)"

    export http_proxy="$PROXY" https_proxy="$PROXY" HTTP_PROXY="$PROXY" HTTPS_PROXY="$PROXY"
    export no_proxy="$NOPROXY" NO_PROXY="$NOPROXY"
    PX_ENV=(-e HTTP_PROXY="$PROXY" -e HTTPS_PROXY="$PROXY" -e NO_PROXY="$NOPROXY")

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
  fi

  if [ -n "$FROM" ]; then
    # โหมด bundle: ใช้ apt repo ที่เซิร์ฟเวอร์หลักแชร์ไว้ ไม่ออกเน็ต
    command -v curl >/dev/null 2>&1 || { echo "ต้องมี curl ในเครื่อง"; exit 1; }
    curl -fsS -m 10 -o /dev/null "$FROM/debs/Release" || { echo "!! โหลด $FROM/debs/Release ไม่ได้ เช็กว่า 'iot.sh bundle' รันแล้วและเข้าถึงเครื่องนั้นได้"; exit 1; }
    BL=/etc/apt/sources.list.d/iot-bundle.list
    echo "$FROM" > "$BUNDLE_URL_FILE"
    echo "deb [trusted=yes] $FROM/debs ./" > $BL
    apt-get update -y -o Dir::Etc::sourcelist=$BL -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0
  else
    apt-get update -y
    apt-get install -y curl ca-certificates gnupg
  fi

  if want docker; then
    echo "===== Docker ====="
    if ! command -v docker >/dev/null 2>&1; then
      if [ -n "$FROM" ]; then
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      else
        curl -fsSL https://get.docker.com | sh
      fi
    fi
    systemctl enable --now docker
    docker --version
  fi

  if want node; then
    echo "===== Node.js $NODE_MAJOR ====="
    [ -n "$FROM" ] || curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash -
    apt-get install -y nodejs
    node -v
    npm -v
    if [ -n "$PROXY" ]; then
      npm config set proxy "$PROXY"
      npm config set https-proxy "$PROXY"
    fi
  fi

  if want apache; then
    echo "===== Apache ====="
    apt-get install -y apache2
    systemctl enable --now apache2
    apache2 -v | head -n 1
  fi

  if want git; then
    echo "===== Git ====="
    apt-get install -y git
    git --version
  fi

  # โหมด bundle: โหลด image จากเซิร์ฟเวอร์หลักเข้า Docker (ไม่ต้อง pull)
  NR_IMAGE=nodered/node-red:latest
  if [ -n "$FROM" ]; then
    NR_IMAGE=nodered-iot:latest
    for pair in emqx:emqx mysql:mysql mysql:phpmyadmin nodered:nodered; do
      want "${pair%%:*}" || continue
      echo "โหลด image ${pair##*:} ..."
      curl -fsS "$FROM/images/${pair##*:}.tar" | docker load || echo "!!! โหลด image ${pair##*:} ไม่สำเร็จ"
    done
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
    DB_NAME=mysql; DB_IMAGE=mysql:8; DB_ENV=MYSQL; DB_OTHER=mariadb   # DB_OTHER = ของเก่าที่เคยลงไว้ (ชนพอร์ต 3306)
    echo "===== $DB_NAME + phpMyAdmin ====="
    docker network create iot-net 2>/dev/null

    # ตรวจของเดิม (container / volume ของ mysql และ mariadb / phpmyadmin)
    EXISTING=""
    KEEP=""
    for n in mysql mariadb phpmyadmin; do
      docker container inspect "$n" >/dev/null 2>&1 && EXISTING="$EXISTING container:$n"
    done
    for n in mysql mariadb; do
      docker container inspect "$n" >/dev/null 2>&1 && KEEP="${KEEP:-$n}"
      docker volume inspect "${n}_data" >/dev/null 2>&1 && EXISTING="$EXISTING volume:${n}_data"
    done
    [ -n "$KEEP" ] && docker container inspect "$DB_NAME" >/dev/null 2>&1 && KEEP="$DB_NAME"

    ANS=1
    if [ -n "$EXISTING" ]; then
      echo "พบของเดิม:$EXISTING"
      echo "  1) ข้าม  — เก็บฐานข้อมูลเดิมไว้ ติดตั้งเฉพาะ phpMyAdmin"
      echo "  2) ล้าง  — ลบของเดิม (รวมข้อมูลในฐานข้อมูลถาวร) แล้วติดตั้งใหม่"
      read -r -p "เลือก (1/2) [1]: " ANS </dev/tty 2>/dev/null || ANS=1
      case "$ANS" in 2) ;; *) ANS=1 ;; esac
    fi

    if [ "$ANS" = "2" ]; then
      echo "ล้างของเดิม..."
      docker rm -f mysql mariadb phpmyadmin 2>/dev/null
      docker volume rm mysql_data mariadb_data 2>/dev/null
      KEEP=""
    fi

    if [ -n "$KEEP" ]; then
      # ใช้ฐานข้อมูลเดิมที่มีอยู่ (ชื่ออาจไม่ตรงกับที่เลือก เพราะพอร์ต 3306 ชนกัน)
      [ "$KEEP" != "$DB_NAME" ] && echo "ใช้ $KEEP เดิมที่มีอยู่ (ไม่ใช่ $DB_NAME ที่เลือก)"
      DB_NAME="$KEEP"
      docker start "$DB_NAME" >/dev/null 2>&1
      docker network connect iot-net "$DB_NAME" 2>/dev/null
      docker rm -f phpmyadmin 2>/dev/null
    else
      # ตัวที่ไม่ได้เลือกชนพอร์ต 3306 จึงลบ container ทิ้ง (volume ยังอยู่)
      docker rm -f "$DB_OTHER" "$DB_NAME" phpmyadmin 2>/dev/null
      docker run -d --name "$DB_NAME" --restart always \
        --network iot-net \
        -p 3306:3306 \
        -e ${DB_ENV}_ROOT_PASSWORD="$DB_PASS" \
        -e ${DB_ENV}_DATABASE=iotdb \
        -v ${DB_NAME}_data:/var/lib/mysql \
        "$DB_IMAGE" \
        || echo "!!! $DB_NAME ติดตั้งไม่สำเร็จ ดู error ด้านบน"
    fi
    docker run -d --name phpmyadmin --restart always \
      --network iot-net \
      -p 8080:80 \
      -e PMA_HOST="$DB_NAME" \
      phpmyadmin:latest \
      || echo "!!! phpMyAdmin ติดตั้งไม่สำเร็จ ดู error ด้านบน"
  fi

  if want nodered; then
    echo "===== Node-RED ====="
    docker rm -f nodered 2>/dev/null
    docker run -d --name nodered --restart always \
      -p 1880:1880 \
      -v nodered_data:/data \
      "$NR_IMAGE" \
      || echo "!!! Node-RED ติดตั้งไม่สำเร็จ ดู error ด้านบน"
    # รอให้ Node-RED สร้างไฟล์ settings.js ก่อน (แทน sleep ตายตัว)
    for i in $(seq 1 30); do
      docker exec nodered test -f /data/settings.js 2>/dev/null && break
      sleep 2
    done
    # image จาก bundle มี node-red-node-mysql อยู่แล้ว
    if [ -z "$FROM" ]; then
      docker exec "${PX_ENV[@]}" nodered npm install --prefix /data node-red-node-mysql \
        || echo "!!! ติดตั้ง node-red-node-mysql ไม่สำเร็จ (Node-RED ยังไม่มีโหนด MySQL)"
    fi

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
    for p in 80 1880 1883 8080 8083 8084 8883 18083 3306; do ufw allow ${p}/tcp; done
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
    if running "$DB_NAME"; then
      echo "$DB_NAME : $IP:3306  (root / $DB_PASS)"
      running phpmyadmin && echo "phpMyAdmin: http://$IP:8080  (root / $DB_PASS)"
    else
      echo "$DB_NAME : ไม่ได้รัน"
    fi
  fi
  if want apache; then
    systemctl is-active --quiet apache2 && echo "Apache   : http://$IP:80" || echo "Apache   : ไม่ได้รัน"
  fi
  if want git; then
    command -v git >/dev/null 2>&1 && git --version || echo "Git      : ติดตั้งไม่สำเร็จ"
  fi
  exit 0
}

# =====================================================================
#  proxy  (รันบนเซิร์ฟเวอร์หลักที่มีเน็ต)
# =====================================================================
cmd_proxy() {
  EXTRA="$*"
  if [ -z "$EXTRA" ]; then
    read -r -p "วงเครือข่ายของ dev/IoT (เช่น 192.168.20.0/24 คั่นด้วยเว้นวรรค): " EXTRA
  fi

  apt-get update -y
  apt-get install -y tinyproxy curl

  # วงเครือข่ายของเครื่องนี้ (เช่น 192.168.10.0/24) อนุญาตให้อัตโนมัติ
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
  echo "แล้วรัน: sudo bash iot.sh install --proxy $IP"
  echo "================================================"
}

# เก็บสำเนา git repo ไว้ใน bundle (ให้ GitLab ในวงที่ไม่มีเน็ตตั้ง pull mirror มาดึงจากเครื่องนี้ได้)
mirror_repo() {
  command -v git >/dev/null 2>&1 || apt-get install -y git || return 1
  R=/srv/iot-bundle/repo.git
  if [ -d "$R" ]; then
    git -C "$R" remote update --prune || return 1
  else
    git clone --mirror "$REPO_URL" "$R" || return 1
  fi
  git -C "$R" update-server-info
}

# =====================================================================
#  bundle  (รันบนเซิร์ฟเวอร์หลักที่มีเน็ต: โหลดไฟล์ทั้งหมดมาเก็บ แล้วแชร์ผ่าน HTTP)
# =====================================================================
cmd_bundle() {
  SELF=$(readlink -f "${BASH_SOURCE[0]}")   # path จริงของสคริปต์ (ก่อน cd ไปที่อื่น)
  BUNDLE=/srv/iot-bundle
  BPORT=8000
  mkdir -p "$BUNDLE/debs" "$BUNDLE/images"

  # ต้องมี Docker + repo ของ Docker/NodeSource บนเครื่องนี้ก่อน
  if ! command -v docker >/dev/null 2>&1; then
    echo "ติดตั้ง Docker บนเครื่องนี้ก่อน..."
    (cmd_install docker) || exit 1
  fi
  apt-get update -y
  apt-get install -y curl ca-certificates gnupg apt-utils python3
  # ตั้ง repo ใหม่ทุกครั้ง เพื่อไม่ค้างเวอร์ชันเก่าถ้าเคยลง repo ของ Node รุ่นอื่นไว้
  curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash -

  echo "===== โหลดแพ็กเกจ apt (Docker, Node.js) ====="
  cd "$BUNDLE/debs" || exit 1
  rm -f ./*.deb
  PKGS="docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin nodejs apache2 git"
  # รวม dependency ทั้งหมด (รวมที่เครื่องนี้ลงไว้แล้ว) เพื่อให้เครื่องปลายทางเลือกเอาเฉพาะที่ขาด
  DEPS=$(apt-cache depends --recurse --no-recommends --no-suggests --no-conflicts --no-breaks --no-replaces --no-enhances $PKGS \
    | grep '^\w' | sort -u)
  apt-get download $DEPS || echo "!! บางแพ็กเกจโหลดไม่สำเร็จ (ข้ามได้ถ้าเป็นแพ็กเกจเสมือน)"
  apt-ftparchive packages . > Packages
  gzip -kf Packages
  apt-ftparchive release . > Release

  echo "===== โหลด Docker image ====="
  cd "$BUNDLE/images" || exit 1
  # Node-RED: ใส่ node-red-node-mysql ไว้ใน image เลย เครื่องปลายทางจะได้ไม่ต้องใช้ npm
  BD=$(mktemp -d)
  printf 'FROM nodered/node-red:latest\nRUN npm install --no-fund --no-audit node-red-node-mysql\n' > "$BD/Dockerfile"
  docker pull nodered/node-red:latest && docker build -t nodered-iot:latest "$BD"
  rm -rf "$BD"
  for pair in emqx:emqx/emqx:latest mysql:mysql:8 phpmyadmin:phpmyadmin:latest nodered:nodered-iot:latest; do
    name=${pair%%:*}; img=${pair#*:}
    [ "$name" = nodered ] || docker pull "$img" || { echo "!!! pull $img ไม่สำเร็จ"; continue; }
    docker save "$img" -o "$name.tar.new" && mv "$name.tar.new" "$name.tar"
  done

  cp -f "$SELF" "$BUNDLE/iot.sh" || { echo "!! ก๊อปปี้ iot.sh เข้า bundle ไม่สำเร็จ"; exit 1; }
  mirror_repo && REPO_OK=1 || echo "!! เก็บ git repo ไม่สำเร็จ (ข้ามได้ ไม่กระทบการติดตั้ง)"

  echo "===== เปิดแชร์ผ่าน HTTP พอร์ต $BPORT ====="
  cat > /etc/systemd/system/iot-bundle.service <<EOF_SVC
[Unit]
Description=IoT bundle file server
After=network.target

[Service]
ExecStart=/usr/bin/python3 -m http.server $BPORT --directory $BUNDLE
Restart=always

[Install]
WantedBy=multi-user.target
EOF_SVC
  systemctl daemon-reload
  systemctl enable iot-bundle
  systemctl restart iot-bundle
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    ufw allow ${BPORT}/tcp
  fi

  IP=$(hostname -I | awk '{print $1}')
  echo
  du -sh "$BUNDLE"/* 2>/dev/null
  echo
  echo "================================================"
  echo "Bundle พร้อมแล้วที่ http://$IP:$BPORT"
  echo "บนอีกเครื่อง (ไม่ต้องมีเน็ต):"
  echo "  curl -fO http://$IP:$BPORT/iot.sh"
  echo "  sudo bash iot.sh install --from http://$IP:$BPORT"
  [ -n "$REPO_OK" ] && echo "GitLab pull mirror URL: http://$IP:$BPORT/repo.git"
  echo "================================================"
}

# =====================================================================
#  update  (อัปเดต iot.sh เอง: เครื่องไม่มีเน็ตดึงจาก bundle, เครื่องมีเน็ตดึงจาก GitHub)
# =====================================================================
cmd_update() {
  SELF=$(readlink -f "${BASH_SOURCE[0]}")
  URL="$1"
  if [ -z "$URL" ]; then
    if [ -s "$BUNDLE_URL_FILE" ]; then
      URL="$(cat "$BUNDLE_URL_FILE")"            # เคย install --from ไว้ -> ใช้ bundle เดิม
    else
      URL="https://raw.githubusercontent.com/LittleSoldier2185/quick-setup/main/iot.sh"
    fi
  fi
  case "$URL" in *.sh) ;; *) URL="${URL%/}/iot.sh" ;; esac
  echo "ดึง $URL ..."

  TMP=$(mktemp)
  if ! curl -fsSL -m 30 "$URL" -o "$TMP"; then
    echo "!! โหลดไม่สำเร็จ (เช็กว่าเซิร์ฟเวอร์หลักรัน 'iot.sh bundle' แล้วและเข้าถึงได้)"
    rm -f "$TMP"; exit 1
  fi
  sed -i 's/\r$//' "$TMP"
  if ! head -n 1 "$TMP" | grep -q '^#!/bin/bash' || ! bash -n "$TMP" 2>/dev/null; then
    echo "!! ไฟล์ที่ได้ไม่ใช่สคริปต์ที่ใช้ได้ ไม่เปลี่ยนอะไร"
    rm -f "$TMP"; exit 1
  fi
  if cmp -s "$TMP" "$SELF"; then
    echo "เป็นเวอร์ชันล่าสุดแล้ว"
    rm -f "$TMP"; exit 0
  fi
  cp -f "$SELF" "$SELF.bak"
  chmod 755 "$TMP"
  mv -f "$TMP" "$SELF"                           # แทนที่ทั้งไฟล์ ไม่แก้ไฟล์ที่กำลังรันอยู่
  # เซิร์ฟเวอร์หลัก: อัปเดตตัวที่แชร์ใน bundle ด้วย
  [ -f /srv/iot-bundle/iot.sh ] && cp -f "$SELF" /srv/iot-bundle/iot.sh && echo "อัปเดต /srv/iot-bundle/iot.sh แล้ว"
  [ -d /srv/iot-bundle/repo.git ] && mirror_repo && echo "อัปเดต /srv/iot-bundle/repo.git แล้ว"
  echo "อัปเดตเรียบร้อย (ของเดิมเก็บไว้ที่ $SELF.bak)"
  exit 0
}

# =====================================================================
#  status
# =====================================================================
cmd_status() {
  FAILS=0
  if [ -t 1 ]; then
    G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; D=$'\e[2m'; N=$'\e[0m'
  else
    G=""; R=""; Y=""; D=""; N=""
  fi
  ok()   { echo "  ${G}OK${N}    $*"; }
  bad()  { echo "  ${R}FAIL${N}  $*"; FAILS=$((FAILS + 1)); }
  warn() { echo "  ${Y}WARN${N}  $*"; }
  skip() { echo "  ${D}--    $*${N}"; }

  if ! command -v docker >/dev/null 2>&1; then
    echo "ไม่พบ Docker ในเครื่องนี้"
    exit 1
  fi
  if ! docker info >/dev/null 2>&1; then
    echo "เรียก Docker ไม่ได้ (docker daemon ไม่ทำงาน?)"
    exit 1
  fi

  exists()  { docker container inspect "$1" >/dev/null 2>&1; }
  listen()  { ss -tln 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$1\$"; }
  http()    { curl -s -o /dev/null -m 5 -w "%{http_code}" "$1" 2>/dev/null; }

  echo "===== $(hostname)  $(date '+%Y-%m-%d %H:%M:%S') ====="

  echo
  echo "[Containers]"
  for n in emqx mysql phpmyadmin nodered; do
    if ! exists "$n"; then skip "$n  (ไม่ได้ติดตั้ง)"; continue; fi
    state=$(docker inspect -f '{{.State.Status}}' "$n")
    restarts=$(docker inspect -f '{{.RestartCount}}' "$n")
    health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$n")
    up=$(docker inspect -f '{{.State.StartedAt}}' "$n" | cut -c1-19 | tr 'T' ' ')
    info="$n  $state  restarts=$restarts  since=$up${health:+  health=$health}"
    if [ "$state" != "running" ] || [ "$health" = "unhealthy" ]; then
      bad "$info"
    elif [ "$restarts" -gt 0 ]; then
      warn "$info  (เคยรีสตาร์ท อาจ crash)"
    else
      ok "$info"
    fi
  done

  echo
  echo "[Ports]"
  check_port() {   # ชื่อ container, พอร์ต, คำอธิบาย
    exists "$1" || return
    if listen "$2"; then ok "$2  $3"; else bad "$2  $3  (ไม่มีใครฟังพอร์ตนี้)"; fi
  }
  check_port nodered    1880  "Node-RED"
  check_port emqx       1883  "MQTT"
  check_port emqx       18083 "EMQX dashboard"
  check_port mysql      3306  "MySQL"
  check_port phpmyadmin 8080  "phpMyAdmin"

  echo
  echo "[Services]"
  if exists mysql; then
    if out=$(docker exec -e MYSQL_PWD="$DB_PASS" mysql mysqladmin -uroot ping 2>&1); then
      ok "MySQL ตอบสนอง ($out)"
    else
      bad "MySQL ไม่ตอบ: $(echo "$out" | tail -n 1)"
    fi
  fi
  if exists nodered; then
    code=$(http http://localhost:1880)
    case "$code" in
      2*|3*|401) ok "Node-RED HTTP $code" ;;
      *)         bad "Node-RED HTTP ${code:-000}" ;;
    esac
  fi
  if exists phpmyadmin; then
    code=$(http http://localhost:8080)
    case "$code" in
      2*|3*) ok "phpMyAdmin HTTP $code" ;;
      *)     bad "phpMyAdmin HTTP ${code:-000}" ;;
    esac
  fi
  if command -v apache2 >/dev/null 2>&1; then
    if systemctl is-active --quiet apache2; then
      code=$(http http://localhost:80)
      case "$code" in
        2*|3*|401|403) ok "Apache HTTP $code" ;;
        *)             bad "Apache HTTP ${code:-000}" ;;
      esac
    else
      bad "Apache ไม่ได้รัน (systemctl status apache2)"
    fi
  fi
  if exists emqx; then
    if docker exec emqx emqx ctl status >/dev/null 2>&1; then
      clients=$(docker exec emqx emqx ctl clients list 2>/dev/null | grep -c '^Client')
      ok "EMQX ทำงานอยู่  อุปกรณ์ที่เชื่อมต่อ=$clients"
    else
      bad "EMQX ตอบ ctl status ไม่ได้"
    fi
  fi

  echo
  echo "[Resources]"
  if [ -n "$(docker ps -q)" ]; then
    docker stats --no-stream --format "  {{.Name}}\tCPU {{.CPUPerc}}\tRAM {{.MemUsage}}" | column -t -s $'\t'
  else
    skip "ไม่มี container ที่รันอยู่"
  fi
  echo
  free -h | awk 'NR==1 || /^Mem/ {print "  " $0}'
  disk=$(df -h / | awk 'NR==2 {print $5 " ใช้ไป (" $3 " / " $2 ")"}')
  pct=$(df / | awk 'NR==2 {gsub("%","",$5); print $5}')
  if [ "$pct" -ge 90 ]; then bad "ดิสก์ /  $disk"; elif [ "$pct" -ge 80 ]; then warn "ดิสก์ /  $disk"; else ok "ดิสก์ /  $disk"; fi
  echo "  Docker: $(docker system df --format '{{.Type}} {{.Size}}' | paste -sd ' ' -)"

  echo
  if [ "$FAILS" -eq 0 ]; then
    echo "${G}ทุกอย่างปกติ${N}"
  else
    echo "${R}พบปัญหา $FAILS รายการ${N}  (ดู log: docker logs --tail 50 <ชื่อ container>)"
    exit 1
  fi
}

# =====================================================================
#  reset
# =====================================================================
cmd_reset() {
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
    docker rm -f emqx mariadb phpmyadmin mysql nodered 2>/dev/null
    docker volume rm emqx_data emqx_log mariadb_data mysql_data nodered_data 2>/dev/null
    docker network rm iot-net 2>/dev/null
    docker rmi -f emqx/emqx mariadb phpmyadmin mysql:8 nodered/node-red 2>/dev/null
    docker rmi -f $(docker images -q 'emqx/emqx' 'nodered/node-red' 'mysql' 'mariadb' 'phpmyadmin') 2>/dev/null
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

    echo ">> ถอน Apache"
    apt-get purge -y apache2 apache2-utils 2>/dev/null

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
}

# =====================================================================
#  main
# =====================================================================
CMD="$1"
if [ -z "$CMD" ]; then
  echo "เลือกงาน"
  echo "  -- เครื่องที่มีเน็ต / เซิร์ฟเวอร์หลัก --"
  echo "  1) install  ติดตั้ง stack (มีเน็ต)"
  echo "  2) proxy    ตั้ง proxy ให้เครื่องอื่นออกเน็ต"
  echo "  3) bundle   โหลดไฟล์ทั้งหมดมาเก็บและแชร์ให้เครื่องอื่น"
  echo "  -- เครื่องที่ไม่มีเน็ต --"
  echo "  4) install  ติดตั้งผ่าน proxy ของเซิร์ฟเวอร์หลัก"
  echo "  5) install  ติดตั้งจาก bundle ของเซิร์ฟเวอร์หลัก"
  echo "  -- ทั่วไป --"
  echo "  6) status   ดูสถานะ"
  echo "  7) reset    ล้างของที่ติดตั้ง"
  echo "  8) update   อัปเดต iot.sh เอง"
  read -r -p "เลือก: " M
  case "$M" in
    1) CMD=install ;;
    2) CMD=proxy ;;
    3) CMD=bundle ;;
    4) CMD=install; set -- install --proxy ;;
    5) CMD=install; set -- install --from ;;
    6) CMD=status ;;
    7) CMD=reset ;;
    8) CMD=update ;;
    *) echo "ยกเลิก"; exit 1 ;;
  esac
fi
shift

case "$CMD" in
  install) cmd_install "$@" ;;
  proxy)   cmd_proxy "$@" ;;
  bundle)  cmd_bundle ;;
  update)  cmd_update "$@" ;;
  status)  cmd_status ;;
  reset)   cmd_reset "$@" ;;
  *) echo "ไม่รู้จักคำสั่ง: $CMD (ใช้ได้: install proxy bundle update status reset)"; exit 1 ;;
esac
