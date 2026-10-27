# quick-setup

Scripts to set up an IoT stack on Ubuntu: Docker, Node.js 22, EMQX (MQTT), MySQL + phpMyAdmin, and Node-RED.
All scripts must run as root (`sudo`).

## Usage

One script, `iot.sh`, with sub-commands:

| Command | Run on | Purpose |
|---|---|---|
| `install` | machine with internet | Install the stack |
| `install --proxy <IP>` | machine without internet | Install through the proxy of the main server |
| `proxy` | main server with internet | Start a proxy (tinyproxy) for machines without internet |
| `bundle` | main server with internet | Download everything once and share it over HTTP for other machines |
| `install --from <URL>` | machine without internet | Install from the main server's bundle (no internet at all) |
| `update` | any machine | Update `iot.sh` itself (from the bundle if one was used, otherwise from GitHub) |
| `status` | any installed machine | Check status from the terminal |
| `reset` | any installed machine | Remove what was installed |

Run `sudo bash iot.sh` with no arguments for a menu.

## Install (with internet)

```bash
sudo bash iot.sh install                # menu, type numbers e.g. 1 3 5
sudo bash iot.sh install docker node     # or give names
sudo bash iot.sh install all             # everything
```

Names: `docker` `node` `emqx` `mysql` `nodered` `all`.
EMQX, MySQL and Node-RED need Docker, so it is added automatically.

If an old MySQL / phpMyAdmin install is found, the script asks:
1. **skip**: keep the database and its data, install phpMyAdmin only (default)
2. **clean**: delete the old containers and volumes (data is lost), then install again

## Install (no internet, through a proxy)

On the main server (has internet):

```bash
sudo bash iot.sh proxy 192.168.20.0/24     # subnet(s) of the dev machines
```

On the dev machine:

```bash
sudo bash iot.sh install --proxy 192.168.10.2                 # IP of the main server, then menu
sudo bash iot.sh install --proxy 192.168.10.2 docker node     # or give names
```

The proxy listens on port 8888 and only allows ports 80 and 443.

## Install (no internet, from a bundle)

Alternative to the proxy: the main server downloads everything once (apt packages for Docker and Node.js,
Docker images for EMQX, MySQL, phpMyAdmin and Node-RED with `node-red-node-mysql` built in) and serves it on port 8000.

On the main server (has internet):

```bash
sudo bash iot.sh bundle            # files go to /srv/iot-bundle, served by the iot-bundle service
```

On the other server (needs only a network path to the main server):

```bash
curl -fO http://192.168.10.2:8000/iot.sh
sudo bash iot.sh install --from http://192.168.10.2:8000              # menu
sudo bash iot.sh install --from http://192.168.10.2:8000 docker emqx  # or give names
```

Run `bundle` again to refresh the files. To update `iot.sh` on a machine without internet, run `sudo bash iot.sh update` (it reuses the bundle URL from `install --from`; or pass a URL: `iot.sh update http://192.168.10.2:8000`). On the main server, `update` pulls from GitHub and refreshes the shared copy too. The bundle is plain HTTP without authentication, so keep it on a trusted network.

## Services

| Service | URL / port | Login |
|---|---|---|
| Node-RED | `http://<IP>:1880` | `admin` / `1234` (`install` without `--proxy`) |
| EMQX dashboard | `http://<IP>:18083` | `admin` / `public` |
| MQTT | `<IP>:1883` | no auth by default |
| MySQL | `<IP>:3306` | `root` / `1234`, database `iotdb` |
| phpMyAdmin | `http://<IP>:8080` | `root` / `1234` |

**Change the default passwords before using this outside a lab.** Docker published ports bypass `ufw`,
so open ports are reachable from the network even if `ufw` blocks them.

## Check status

```bash
sudo bash iot.sh status                # check once
sudo watch -n 5 bash iot.sh status     # refresh every 5 seconds
```

Shows containers (state, restarts), listening ports, service checks (MySQL, Node-RED, phpMyAdmin, EMQX clients),
and CPU / RAM / disk. Exits with code 1 if something is wrong.

## Update

```bash
git pull
sudo bash iot.sh install nodered     # re-run to recreate a service, data in volumes is kept
```

## Remove

```bash
sudo bash iot.sh reset 1    # containers + volumes + images (keeps Docker and Node.js). DATA IS DELETED
sudo bash iot.sh reset 2    # also uninstall Docker, Node.js and proxy settings
```

Both ask you to type `yes`. Only the stack's own containers, volumes and images are removed.
Back up first if you need the data:

```bash
docker exec -e MYSQL_PWD=1234 mysql mysqldump -uroot --all-databases > backup.sql
```
