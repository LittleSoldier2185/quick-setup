#!/bin/bash
# ดูสถานะ stack ที่ติดตั้งไว้ (EMQX, MySQL, phpMyAdmin, Node-RED) ในคำสั่งเดียว
#
# วิธีใช้:
#   sudo bash status.sh                 -> ตรวจครั้งเดียว
#   sudo watch -n 5 bash status.sh      -> รีเฟรชทุก 5 วินาที
#   DB_PASS=xxxx sudo -E bash status.sh -> ถ้าเปลี่ยนรหัส MySQL (ค่าเริ่มต้น 1234)
# คืนค่า exit 1 ถ้ามีอะไรผิดปกติ (เอาไปใช้กับ cron / สคริปต์อื่นได้)

DB_PASS="${DB_PASS:-1234}"
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
  echo "เรียก Docker ไม่ได้ ลองรันด้วย sudo: sudo bash $0"
  exit 1
fi

exists()  { docker container inspect "$1" >/dev/null 2>&1; }
listen()  { ss -tln 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$1\$"; }
http()    { curl -s -o /dev/null -m 5 -w "%{http_code}" "$1" 2>/dev/null; }

echo "===== $(hostname)  $(date '+%Y-%m-%d %H:%M:%S') ====="

# ---------- Containers ----------
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

# ---------- Ports ----------
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

# ---------- Services ----------
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
if exists emqx; then
  if docker exec emqx emqx ctl status >/dev/null 2>&1; then
    clients=$(docker exec emqx emqx ctl clients list 2>/dev/null | grep -c '^Client')
    ok "EMQX ทำงานอยู่  อุปกรณ์ที่เชื่อมต่อ=$clients"
  else
    bad "EMQX ตอบ ctl status ไม่ได้"
  fi
fi

# ---------- Resources ----------
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
