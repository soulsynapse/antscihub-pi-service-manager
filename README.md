# antscihub-pi-service-manager

A single meta-service that monitors and maintains other services on a Raspberry Pi fleet.

## Install

From any Pi (via fleet shell or SSH):

```bash
sudo git clone https://github.com/soulsynapse/antscihub-pi-service-manager.git ~/Desktop/2-SERVICES-MANAGER/antscihub-pi-service-manager
sudo bash ~/Desktop/2-SERVICES-MANAGER/antscihub-pi-service-manager/install.sh
```

During install, module repos listed in `config/modules.conf` are also cloned or updated.

## Agent Instructions for Downstream Services and Repos

---

# antscihub Managed Service Contract

## Overview

A meta service runs on every Pi in the fleet. It is installed at `/opt/antscihub-pi-service-manager/`. Its job is:

1. On every boot, scan `~/Desktop/2-SERVICES-MANAGER/` for managed service folders.
2. `git pull` each one.
3. If code changed, run the service's install command.
4. Continuously (every 30s) ensure each service's systemd unit is running.
5. Restart services that have stopped.
6. Report everything over MQTT via `fleet-publish`.
7. On boot, pull updates for this meta-service itself and reinstall if changed.

You do not need to touch the meta service. You only need to make your repo conform to the contract below.

By default, managed repos are placed under `~/Desktop/2-SERVICES-MANAGER/`.
If you want a different base path, update `SERVICES_DIR` in `/opt/antscihub-pi-service-manager/config/meta.conf` and restart `antscihub-meta`.

Self-update is enabled by default. `install.sh` sets `SELF_REPO_DIR` in `/opt/antscihub-pi-service-manager/config/meta.conf` to the git-backed folder you installed from, and the meta service runs `git pull --ff-only` there on boot.

Module bootstrap is enabled by default. `install.sh` reads `config/modules.conf` and for each `REPO_URL|TARGET_PATH` entry it clones the repo if missing, or runs `git pull --ff-only` if already present.

Default module file example:

```text
https://github.com/soulsynapse/antscihub-pi-wifi-watchdog|~/Desktop/2-SERVICES-MANAGER/wifi-watchdog
```

---

## How to Make Your Repo a Managed Service

### 1. Clone into `~/Desktop/2-SERVICES-MANAGER/<your-folder-name>/`

```bash
git clone https://github.com/org/your-repo.git ~/Desktop/2-SERVICES-MANAGER/your-repo
```

This is the default configured by `install.sh`. You can choose a different base folder by changing `SERVICES_DIR` in `meta.conf`.

### 2. Add `antscihub.manifest` at the repo root

This is the only file the meta service looks for. No manifest means invisible to the meta service.

### 3. Install your own systemd service

The meta service does not create systemd units for you. Your repo's install script is responsible for:

- Copying a `.service` file into `/etc/systemd/system/`
- Running `systemctl daemon-reload`
- Running `systemctl enable <your-service>`
- Installing any dependencies (`pip`, `apt`, etc.)

The meta service only monitors and restarts. It never installs on your behalf.

## `antscihub.manifest`

Plain text, `key=value`, one per line. Lines starting with `#` are comments.

```ini
# REQUIRED
# The systemd unit name the meta service should monitor.
# It checks `systemctl is-active <SERVICE_NAME>` every 30 seconds.
# If your repo doesn't have a long-running service (e.g., it's a library
# or a cron job), set this to "none". The meta service will still
# pull updates but won't monitor anything.
SERVICE_NAME=your-app.service

# REQUIRED
# The git remote URL. The meta service runs `git pull --ff-only` on boot.
GIT_REMOTE=https://github.com/org/your-repo.git

# OPTIONAL
# Command to run from the repo root after git pull detects new commits.
# This is where you install dependencies, copy systemd units, build, etc.
# Runs as root.
# If omitted or "none", the meta service just restarts SERVICE_NAME after a pull.
INSTALL_CMD=sudo bash install.sh

# OPTIONAL
# If "true", the meta service will report that this service is down
# but will NOT attempt to restart it.
# Default: false
NO_AUTO_RESTART=false

# OPTIONAL
# Seconds to wait after restarting before checking health again.
# Set this higher for services that take a while to initialize.
# Default: 10
STARTUP_GRACE=10

# OPTIONAL
# Git branch to track.
# Default: whatever branch is currently checked out
GIT_BRANCH=main
```

## What the Meta Service Does with Your Repo

### On Boot

0. Pull `SELF_REPO_DIR` (meta-service repo) and re-run `install.sh` if changed.
1. Find `~/Desktop/2-SERVICES-MANAGER/your-repo/antscihub.manifest`.
2. Read `GIT_REMOTE`.
3. Run `git pull --ff-only`.
4. If `HEAD` changed:
   1. Run `INSTALL_CMD` (if defined).
   2. Run `systemctl restart SERVICE_NAME` (if not `none`).
5. If `HEAD` is unchanged: do nothing.

### Continuously (Every 30 Seconds)

1. Find `~/Desktop/2-SERVICES-MANAGER/your-repo/antscihub.manifest`.
2. Read `SERVICE_NAME`.
3. Run `systemctl is-active SERVICE_NAME`.
4. If active: move on.
5. If not active:
   1. Count consecutive failures.
   2. After 3 consecutive failures: attempt restart.
   3. Wait `STARTUP_GRACE` seconds, then check again.
   4. After 5 failed restart attempts: give up and report only.

## MQTT Reporting

The meta service publishes to `fleet/managed-services/<DEVICE_ID>/meta` via `fleet-publish`.

Events relevant to your service:

- `repo_updated`: Your repo had new commits; pull succeeded.
- `install_ok`: Your `INSTALL_CMD` ran successfully.
- `install_failed`: Your `INSTALL_CMD` exited non-zero.
- `pull_failed`: `git pull` failed (auth, network, merge conflict).
- `service_restarting`: Your service was down; meta is restarting it.
- `service_recovered`: Restart worked.
- `service_restart_failed`: Restart did not help.
- `service_gave_up`: 5 failed restarts; meta stopped trying until next boot.
- `status`: Periodic summary listing all healthy/unhealthy services.

## Your Repo's `install.sh` Responsibilities

Your `INSTALL_CMD` script must be idempotent (safe to run repeatedly). It runs as root from your repo root directory.

It should:

- Install system dependencies (if any).
- Install Python/Node/etc. dependencies (if any).
- Copy your `.service` file to `/etc/systemd/system/`.
- Run `systemctl daemon-reload`.
- Run `systemctl enable your-app.service`.
- Not run `systemctl start` (the meta service handles that).

Example:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Install dependencies
apt-get install -y -qq python3-pip > /dev/null 2>&1
pip3 install -q -r requirements.txt

# Install systemd unit
cp your-app.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable your-app.service
```

## Your `.service` File

Standard systemd unit. Requirements:

- It must match `SERVICE_NAME` in your manifest.
- It should use `Restart=always` or `Restart=on-failure` so systemd also tries to keep it alive.
- Use absolute paths.

Example:

```ini
[Unit]
Description=Your App
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /home/pi/Desktop/your-repo/main.py
WorkingDirectory=/home/pi/Desktop/your-repo
Restart=on-failure
RestartSec=5
User=pi
Environment=PATH=/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=multi-user.target
```

## Publishing from Your Service

Your service can publish to MQTT using `fleet-publish` (already installed on every Pi):

```bash
# Simple text message to default topic (fleet/report/<DEVICE_ID>)
fleet-publish --text "sensor reading: 24.1C"

# JSON payload to default topic
fleet-publish --json '{"temp_c": 24.1, "humidity": 62}'

# JSON to a custom topic
fleet-publish --topic "fleet/sensors/temperature" --json '{"temp_c": 24.1}'
```

Notes:

- Payloads are encrypted by default.
- `device_id` and `timestamp` are auto-added when missing.
- Use `--no-encrypt` only if your consumer expects plaintext.

## Minimal Complete Example

A repo called `my-sensor` that reads a sensor and publishes every 10 seconds.

```text
my-sensor/
├── antscihub.manifest
├── install.sh
├── my-sensor.service
├── requirements.txt
└── main.py
```

`antscihub.manifest`

```ini
SERVICE_NAME=my-sensor.service
GIT_REMOTE=https://github.com/org/my-sensor.git
INSTALL_CMD=sudo bash install.sh
STARTUP_GRACE=5
```

`install.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
pip3 install -q -r requirements.txt
cp my-sensor.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable my-sensor.service
```

`my-sensor.service`

```ini
[Unit]
Description=My Sensor Reader
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /home/pi/Desktop/my-sensor/main.py
WorkingDirectory=/home/pi/Desktop/my-sensor
Restart=on-failure
RestartSec=5
User=pi

[Install]
WantedBy=multi-user.target
```

`main.py`

```python
import json
import subprocess
import time

while True:
    reading = {"temp_c": 24.1}  # replace with real sensor read
    subprocess.run([
        "fleet-publish",
        "--json", json.dumps(reading),
        "--topic", "fleet/sensors/my-sensor",
    ])
    time.sleep(10)
```

## Checklist for a New Managed Service Repo

- [ ] `antscihub.manifest` exists at repo root.
- [ ] `SERVICE_NAME` matches your `.service` filename exactly.
- [ ] `GIT_REMOTE` is set and the Pi has access (public repo or SSH key).
- [ ] `INSTALL_CMD` is set if you need dependency installation or systemd unit setup.
- [ ] Your install script copies the `.service` file to `/etc/systemd/system/`.
- [ ] Your install script runs `systemctl daemon-reload` and `systemctl enable`.
- [ ] Your install script does not run `systemctl start`.
- [ ] Your install script is idempotent.
- [ ] Your `.service` file uses absolute paths.
- [ ] Your `.service` file has `Restart=on-failure` or `Restart=always`.
- [ ] Repo is cloned to `~/Desktop/<folder-name>/`.

