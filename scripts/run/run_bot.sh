#!/usr/bin/env bash
set -euo pipefail
# ═══════════════════════════════════════════════════════════════════════════════
# LAPLACE'S DEMON — Execution Engine Launcher
#   Pins the Rust bot to core 2 (isolated via GRUB isolcpus=2,3)
# ═══════════════════════════════════════════════════════════════════════════════
SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
echo "[*] LAPLACE'S DEMON — Execution Engine starting on core 2..."
exec sudo taskset -c 2 "${SCRIPT_DIR}/target/release/executioner"
