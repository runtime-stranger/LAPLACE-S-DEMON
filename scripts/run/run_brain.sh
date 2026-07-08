#!/usr/bin/env bash
set -euo pipefail
# ═══════════════════════════════════════════════════════════════════════════════
# LAPLACE'S DEMON — Brain Server Launcher
#   Pins the Python analysis engine to core 3 (isolated via GRUB isolcpus=2,3)
# ═══════════════════════════════════════════════════════════════════════════════
SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
echo "[*] LAPLACE'S DEMON — Brain Server starting on core 3..."
exec sudo taskset -c 3 python3 "${SCRIPT_DIR}/brain/brain.py"
