#!/usr/bin/env bash
set -euo pipefail
# ═══════════════════════════════════════════════════════════════════════════════
# LAPLACE'S DEMON — Watchdog Daemon Launcher
#   Pins the network watchdog to core 1 (reserved for OS/IRQ isolation)
# ═══════════════════════════════════════════════════════════════════════════════
SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
echo "[*] LAPLACE'S DEMON — Watchdog Daemon starting on core 1..."
exec sudo taskset -c 1 python3 "${SCRIPT_DIR}/watchdog/watchdog.py"
