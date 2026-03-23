#!/usr/bin/env python3
"""
mqtt_helper.py — Persistent MQTT connection for the service manager.

Reads JSON messages from stdin (one per line) and publishes them encrypted.
Stays connected between publishes. No connect/disconnect churn.

Used as a bash coprocess:
    coproc MQTT { python3 mqtt_helper.py; }
    echo '{"event":"status","managed":["svc1"]}' >&${MQTT[1]}
"""

import glob
import json
import os
import signal
import sys
import time

# Find mqtt_client
mqtt_dir = None
for pattern in ["/home/*/Desktop/1-MQTT", "/home/*/1-MQTT"]:
    for d in glob.glob(pattern):
        if os.path.isfile(os.path.join(d, "mqtt_client.py")):
            mqtt_dir = d
            break
    if mqtt_dir:
        break

if not mqtt_dir:
    print("FATAL: Cannot find MQTT directory", file=sys.stderr)
    sys.exit(1)

sys.path.insert(0, mqtt_dir)
from mqtt_client import FleetMQTT, DEVICE_ID

# Dedicated client ID — won't collide with fleet-shell or fleet-publish
client = FleetMQTT(role="svcmgr")
RESPONSE_TOPIC = f"fleet/response/{DEVICE_ID}"


def publish(payload: dict):
    payload.setdefault("device_id", DEVICE_ID)
    payload.setdefault("timestamp", time.time())
    try:
        info = client.publish(RESPONSE_TOPIC, payload, encrypt=True)
        rc = getattr(info, "rc", 1)
        if rc != 0:
            print(f"publish failed rc={rc}", file=sys.stderr)
    except Exception as e:
        print(f"publish error: {e}", file=sys.stderr)


def shutdown(sig, frame):
    client.loop_stop()
    sys.exit(0)


def main():
    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    client.loop_start()
    if not client.wait_until_connected(timeout=15):
        print("FATAL: MQTT connect timeout", file=sys.stderr)
        sys.exit(1)

    print("CONNECTED", file=sys.stderr)
    sys.stderr.flush()

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            payload = json.loads(line)
            publish(payload)
        except json.JSONDecodeError as e:
            print(f"bad JSON: {e}", file=sys.stderr)
        except Exception as e:
            print(f"error: {e}", file=sys.stderr)

    client.loop_stop()


if __name__ == "__main__":
    main()