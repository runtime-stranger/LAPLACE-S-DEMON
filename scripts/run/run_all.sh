#!/usr/bin/env bash
set -euo pipefail
# ═══════════════════════════════════════════════════════════════════════════════
# LAPLACE'S DEMON — Full System Launcher
#   Starts all three components in the background with correct core affinity.
# ═══════════════════════════════════════════════════════════════════════════════
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
echo "[*] LAPLACE'S DEMON — Full system starting..."
sudo taskset -c 2 "${SCRIPT_DIR}/../target/release/executioner" &
PID_RUST=$!
sudo taskset -c 3 python3 "${SCRIPT_DIR}/../brain/brain.py" &
PID_BRAIN=$!
sudo taskset -c 1 python3 "${SCRIPT_DIR}/../watchdog/watchdog.py" &
PID_WATCH=$!
echo "[*] PIDs:  Executioner=${PID_RUST}  Brain=${PID_BRAIN}  Watchdog=${PID_WATCH}"
echo "[*] Stop all: kill ${PID_RUST} ${PID_BRAIN} ${PID_WATCH}"
wait
