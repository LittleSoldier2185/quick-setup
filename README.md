# quick-setup

Scripts to set up an IoT stack on Ubuntu: Docker, Node.js 22, EMQX (MQTT), MySQL + phpMyAdmin, and Node-RED.
All scripts must run as root (`sudo`).

## Scripts

| Script | Run on | Purpose |
|---|---|---|
| `setup-online.sh` | machine with internet | Install the stack |
| `server-proxy.sh` | main server with internet | Start a proxy (tinyproxy) for machines without internet |
| `dev-setup.sh` | machine without internet | Install the stack through the proxy of the main server |
| `status.sh` | any installed machine | Check status from the terminal |
| `reset.sh` | any installed machine | Remove what was installed |

## Install (with internet)

```bash
sudo bash setup-online.sh                 # menu, type numbers e.g. 1 3 5
sudo bash setup-online.sh docker node     # or give names
sudo bash setup-online.sh all             # everything
```

Names: `docker` `node` `emqx` `mysql` `nodered` `all`.
EMQX, MySQL and Node-RED need Docker, so it is added automatically.

If an old MySQL / phpMyAdmin install is found, the script asks:
1. **skip**: keep the database and its data, install phpMyAdmin only (default)
2. **clean**: delete the old containers and volumes (data is lost), then install again

## Install (no internet, through a proxy)

On the main server (has internet):

```bash
sudo bash server-proxy.sh 192.168.20.0/24     # subnet(s) of the dev machines
```

On the dev machine:

```bash
sudo bash dev-setup.sh 192.168.10.2                 # IP of the main server, then menu
sudo bash dev-setup.sh 192.168.10.2 docker node     # or give names
```

The proxy listens on port 8888 and only allows ports 80 and 443.

## Services

| Service | URL / port | Login |
|---|---|---|
| Node-RED | `http://<IP>:1880` | `admin` / `1234` (`setup-online.sh` only) |
| EMQX dashboard | `http://<IP>:18083` | `admin` / `public` |
| MQTT | `<IP>:1883` | no auth by default |
| MySQL | `<IP>:3306` | `root` / `1234`, database `iotdb` |
| phpMyAdmin | `http://<IP>:8080` | `root` / `1234` |

**Change the default passwords before using this outside a lab.** Docker published ports bypass `ufw`,
so open ports are reachable from the network even if `ufw` blocks them.

## Check status

```bash
sudo bash status.sh                # check once
sudo watch -n 5 bash status.sh     # refresh every 5 seconds
```

Shows containers (state, restarts), listening ports, service checks (MySQL, Node-RED, phpMyAdmin, EMQX clients),
and CPU / RAM / disk. Exits with code 1 if something is wrong.

## Update

```bash
git pull
sudo bash setup-online.sh nodered     # re-run to recreate a service, data in volumes is kept
```

## Remove

```bash
sudo bash reset.sh 1    # containers + volumes + images (keeps Docker and Node.js). DATA IS DELETED
sudo bash reset.sh 2    # also uninstall Docker, Node.js and proxy settings
```

Both ask you to type `yes`. Only the stack's own containers, volumes and images are removed.
Back up first if you need the data:

```bash
docker exec -e MYSQL_PWD=1234 mysql mysqldump -uroot --all-databases > backup.sql
```
