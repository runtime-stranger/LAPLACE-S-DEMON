#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# 4. ADIM — Askeri Sinif Donanim Izolasyonu
# Hedef: Ubuntu Bare-Metal Dedicated sunucuda tek tikla kurulum
# Calistirma: sudo bash setup.sh
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

# Renkli cikti
B="\e[34m"
G="\e[32m"
Y="\e[33m"
R="\e[31m"
M="\e[35m"
S="\e[0m"

info()  { echo -e "  [${B}*${S}] $1"; }
ok()    { echo -e "  [${G}OK${S}] $1"; }
warn()  { echo -e "  [${Y}!${S}] $1"; }
fail()  { echo -e "  [${R}X${S}] $1"; }
step()  { echo -e "\n${M}[${B}$1/${TOTAL_STEPS}${M}]${S} $2"; }

TOTAL_STEPS=9

# ── Root kontrol ─────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo -e "\n  [${R}HATA${S}] Bu script root yetkisi gerektirir."
    echo -e "  ${Y}sudo bash setup.sh${S}"
    exit 1
fi

# ── Bilgi mesaji ─────────────────────────────────────────────────────────────
echo ""
echo -e "${M}══════════════════════════════════════════════════════════════${S}"
echo -e "${M}  4. ADIM — Askeri Sinif Donanim Izolasyonu${S}"
echo -e "${M}  Ubuntu Bare-Metal Dedicated Sunucu${S}"
echo -e "${M}══════════════════════════════════════════════════════════════${S}"
echo ""
info "Baslangic: $(date)"
echo ""

# =============================================================================
# ADIM 1 — GRUB: isolcpus + nohz_full + rcu_nocbs
# =============================================================================
step 1 "GRUB yapilandirmasi — CPU izolasyonu"

GRUB_CFG="/etc/default/grub"
GRUB_CMDLINE="isolcpus=2,3 nohz_full=2,3 rcu_nocbs=2,3"

LINE=$(grep "^GRUB_CMDLINE_LINUX_DEFAULT=" "$GRUB_CFG" 2>/dev/null || true)

if echo "$LINE" | grep -q "isolcpus"; then
    warn "isolcpus zaten mevcut, kontrol ediliyor..."
    if echo "$LINE" | grep -q "isolcpus=2,3"; then
        ok "isolcpus=2,3 zaten ayarli."
    else
        warn "Mevcut isolcpus farkli. Elle kontrol gerekebilir."
    fi

elif echo "$LINE" | grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=""$'; then
    # Satir bos: dogrudan yaz
    sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=\"\"$/GRUB_CMDLINE_LINUX_DEFAULT=\"${GRUB_CMDLINE}\"/" "$GRUB_CFG"
    ok "GRUB_CMDLINE_LINUX_DEFAULT=\"${GRUB_CMDLINE}\" yazildi."

elif [[ -n "$LINE" ]]; then
    # Satir dolu: sonuna ekle
    sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"$/GRUB_CMDLINE_LINUX_DEFAULT=\"\1 ${GRUB_CMDLINE}\"/" "$GRUB_CFG"
    ok "GRUB_CMDLINE_LINUX_DEFAULT sonuna \" ${GRUB_CMDLINE}\" eklendi."

else
    # Satir hic yok: yeni satir ekle
    echo "GRUB_CMDLINE_LINUX_DEFAULT=\"${GRUB_CMDLINE}\"" >> "$GRUB_CFG"
    ok "GRUB_CMDLINE_LINUX_DEFAULT satiri olusturuldu."
fi

update-grub 2>&1 | tail -1 || true
ok "update-grub tamamlandi."

echo -e "  ${Y}NOT: isolcpus degisiklikleri SUNUCUYI YENIDEN BASLATINCA aktif olur.${S}"
echo -e "  ${Y}      sudo reboot${S}"

# =============================================================================
# ADIM 2 — Hyper-Threading kapat
# =============================================================================
step 2 "Hyper-Threading (SMT) devre disi birakiliyor"

SMT_CTRL="/sys/devices/system/cpu/smt/control"
if [[ -f "$SMT_CTRL" ]]; then
    echo "off" > "$SMT_CTRL"
    ok "SMT devre disi (echo off > ${SMT_CTRL})."
else
    warn "SMT kontrol dosyasi bulunamadi. Kernel destegi yok mu?"
fi

# Kalici hale getirmek icin systemd servisi
cat > /etc/systemd/system/disable-smt.service <<'SERV'
[Unit]
Description=Disable SMT (Hyper-Threading) Early At Boot
DefaultDependencies=no
After=sysinit.target
RequiresMountsFor=/sys
Before=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo off > /sys/devices/system/cpu/smt/control'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERV

systemctl daemon-reload 2>/dev/null || true
systemctl enable disable-smt.service 2>/dev/null || true
ok "SMT kapatma servisi olusturuldu ve etkinlestirildi (disable-smt.service)."

# =============================================================================
# ADIM 3 — irqbalance durdur + NIC IRQ affinitesi
# =============================================================================
step 3 "IRQ izolasyonu — irqbalance durduruluyor, NIC kesmeleri core 0-1'e"

systemctl stop irqbalance 2>/dev/null || true
systemctl disable irqbalance 2>/dev/null || true
ok "irqbalance durduruldu ve devre disi birakildi."

# NIC IRQ'larini 0. ve 1. cekirdege yonlendir (bitmask 0x03 = 3)
IRQ_COUNT=0
for irq_path in /proc/irq/*/smp_affinity_list; do
    [[ -f "$irq_path" ]] || continue
    irq_num=$(basename "$(dirname "$irq_path")")
    echo "0-1" > "$irq_path" 2>/dev/null || true
    ((IRQ_COUNT++))
done
ok "${IRQ_COUNT} IRQ kesmesi core 0-1'e yonlendirildi."

# Kalici IRQ affinite kurallari (udev ile)
mkdir -p /etc/udev/rules.d
cat > /etc/udev/rules.d/40-irq-affinity.rules <<'UDEV'
# NIC IRQ'larini core 0-1'de topla
SUBSYSTEM=="net", ACTION=="add", RUN+="/bin/bash -c 'for f in /sys/class/net/%k/device/msi_irqs/*; do echo 1 > /proc/irq/$(cat $f)/smp_affinity_list 2>/dev/null; done'"
UDEV
ok "Udev IRQ kurali olusturuldu."

# =============================================================================
# ADIM 4 — Bagimliliklari yukle
# =============================================================================
step 4 "Sistem bagimliliklari yukleniyor"

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    build-essential \
    pkg-config \
    libssl-dev \
    linux-tools-common \
    linux-tools-generic \
    curl \
    wget \
    git \
    wireguard \
    iptables \
    python3 \
    python3-pip \
    python3-mmap \
    keyutils \
    ufw \
    htop \
    iotop \
    sysstat \
    net-tools \
    ethtool \
    2>&1 | tail -2 || true
ok "Paketler yuklendi."

# Rust kurulumu (cargo)
if ! command -v cargo &>/dev/null; then
    info "Rust yukleniyor..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --quiet
    source "$HOME/.cargo/env"
    rustup default stable 2>/dev/null || true
    ok "Rust kuruldu: $(rustc --version 2>/dev/null || echo '?')"
else
    ok "Rust zaten mevcut: $(cargo --version 2>/dev/null || echo '?')"
fi

# Python websockets
pip3 install -q websockets 2>/dev/null || pip3 install websockets 2>/dev/null || true
ok "Python websockets kuruldu."

# =============================================================================
# ADIM 5 — /dev/shm tmpfs boyutu
# =============================================================================
step 5 "/dev/shm tmpfs genisletiliyor"

mount -o remount,size=128M /dev/shm 2>/dev/null || true
ok "/dev/shm boyutu 128 MB olarak ayarlandi."

# Kalici mount
if ! grep -q "/dev/shm" /etc/fstab 2>/dev/null; then
    echo "tmpfs /dev/shm tmpfs defaults,noexec,nosuid,size=128M 0 0" >> /etc/fstab
    ok "/dev/shm fstab'a eklendi."
else
    ok "/dev/shm zaten fstab'da."
fi

# =============================================================================
# ADIM 6 — Sistem limitleri (real-time oncelik)
# =============================================================================
step 6 "Sistem limitleri ayarlaniyor"

# PAM limit modülünün aktif olduğundan emin ol
if ! grep -qs "pam_limits.so" /etc/pam.d/common-session 2>/dev/null; then
    echo "session required pam_limits.so" >> /etc/pam.d/common-session
    ok "pam_limits.so eklendi: /etc/pam.d/common-session"
else
    ok "pam_limits.so zaten aktif."
fi

LIMITS_FILE="/etc/security/limits.d/99-mev.conf"
cat > "$LIMITS_FILE" <<'LIMITS'
# MEV Executioner — gercek zamanli oncelik ve bellek kilidi
*               hard    nice            -20
*               soft    nice            -20
*               hard    rtprio          99
*               soft    rtprio          99
*               hard    memlock         unlimited
*               soft    memlock         unlimited
LIMITS
ok "Limitler yazildi: ${LIMITS_FILE}"

# =============================================================================
# ADIM 7 — Rust projesini derle
# =============================================================================
step 7 "Rust botu derleniyor"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

if [[ -f "Cargo.toml" ]]; then
    cargo build --release 2>&1 | tail -3 || warn "Derleme sirasinda uyari olabilir."
    if [[ -f "target/release/executioner" ]]; then
        ok "Rust bot basariyla derlendi: target/release/executioner"
    else
        fail "Derleme sonucu binary bulunamadi."
    fi
else
    warn "Cargo.toml bulunamadi. Derleme atlaniyor."
fi

cd "$SCRIPT_DIR"

# =============================================================================
# ADIM 8 — Calistirma komutlari
# =============================================================================
step 8 "Calistirma komutlari hazirlaniyor"

cat > run_bot.sh <<'RUN'
#!/usr/bin/env bash
set -euo pipefail
# Rust Executioner — 2. cekirdekte baslat
echo "[*] Tetikci baslatiliyor (core 2)..."
exec sudo taskset -c 2 ./target/release/executioner
RUN

cat > run_brain.sh <<'RUN'
#!/usr/bin/env bash
set -euo pipefail
# Python Brain — 3. cekirdekte baslat
echo "[*] Beyin baslatiliyor (core 3)..."
exec sudo taskset -c 3 python3 brain.py
RUN

cat > run_watchdog.sh <<'RUN'
#!/usr/bin/env bash
set -euo pipefail
# Watchdog — 1. cekirdekte baslat
echo "[*] Watchdog baslatiliyor (core 1)..."
exec sudo taskset -c 1 python3 watchdog.py
RUN

cat > run_all.sh <<'RUN'
#!/usr/bin/env bash
set -euo pipefail
# Tum bilesenleri arka planda baslat
echo "[*] Tum sistem baslatiliyor..."
sudo taskset -c 2 ./target/release/executioner &
PID_RUST=$!
sudo taskset -c 3 python3 brain.py &
PID_BRAIN=$!
sudo taskset -c 1 python3 watchdog.py &
PID_WATCH=$!
echo "[*] PID'ler: Rust=${PID_RUST}  Brain=${PID_BRAIN}  Watchdog=${PID_WATCH}"
echo "[*] Durdurmak icin: kill ${PID_RUST} ${PID_BRAIN} ${PID_WATCH}"
wait
RUN

chmod +x run_bot.sh run_brain.sh run_watchdog.sh run_all.sh
ok "Calistirma scriptleri olusturuldu."

# =============================================================================
# ADIM 9 — RAM Koruma Kalkani (PTRACE Engeli)
# =============================================================================
step 9 "RAM Koruma Kalkani — PTRACE engelleniyor"

echo "kernel.yama.ptrace_scope = 1" > /etc/sysctl.d/99-ptrace.conf
sysctl -w kernel.yama.ptrace_scope=1 2>/dev/null || true
ok "PTRACE kapsami kapatildi (kernel.yama.ptrace_scope=1). Root saldirgan bile canli bellek dokumu alamaz."

# =============================================================================
# OZET
# =============================================================================
echo ""
echo -e "${M}══════════════════════════════════════════════════════════════${S}"
echo -e "${M}  4. ADIM — KURULUM TAMAMLANDI${S}"
echo -e "${M}══════════════════════════════════════════════════════════════${S}"
echo ""
echo -e "  ${G}✓${S} CPU izolasyonu:     isolcpus=2,3 (GRUB)"
echo -e "  ${G}✓${S} Hyper-Threading:    KAPALI (SMT off)"
echo -e "  ${G}✓${S} IRQ kesmeleri:      Core 0-1 (NIC)"
echo -e "  ${G}✓${S} Bagimliliklar:      build-essential, cargo, python3, ..."
echo -e "  ${G}✓${S} /dev/shm:           128 MB tmpfs"
echo -e "  ${G}✓${S} Rust bot:           Derlendi"
echo -e "  ${G}✓${S} Calistirma scriptleri hazir"
echo -e "  ${G}✓${S} RAM Kalkani:       PTRACE kapali (kernel.yama.ptrace_scope=1)"
echo ""
echo -e "  ${Y}╔══════════════════════════════════════════════════════════╗${S}"
echo -e "  ${Y}║${S}  KULLANIM KOMUTLARI:                                  ${Y}║${S}"
echo -e "  ${Y}║${S}                                                       ${Y}║${S}"
echo -e "  ${Y}║${S}  1. SUNUCUYU YENIDEN BASLATIN:                       ${Y}║${S}"
echo -e "  ${Y}║${S}     sudo reboot                                      ${Y}║${S}"
echo -e "  ${Y}║${S}                                                       ${Y}║${S}"
echo -e "  ${Y}║${S}  2. Terminal 1 — Rust Executioner (core 2):          ${Y}║${S}"
echo -e "  ${Y}║${S}     sudo taskset -c 2 ./target/release/executioner   ${Y}║${S}"
echo -e "  ${Y}║${S}                                                       ${Y}║${S}"
echo -e "  ${Y}║${S}  3. Terminal 2 — Python Brain (core 3):              ${Y}║${S}"
echo -e "  ${Y}║${S}     sudo taskset -c 3 python3 brain.py               ${Y}║${S}"
echo -e "  ${Y}║${S}                                                       ${Y}║${S}"
echo -e "  ${Y}║${S}  4. Terminal 3 — Watchdog (core 1):                  ${Y}║${S}"
echo -e "  ${Y}║${S}     sudo taskset -c 1 python3 watchdog.py            ${Y}║${S}"
echo -e "  ${Y}║${S}                                                       ${Y}║${S}"
echo -e "  ${Y}║${S}  Tek komutla hepsini baslatmak icin:                 ${Y}║${S}"
echo -e "  ${Y}║${S}     sudo ./run_all.sh                                ${Y}║${S}"
echo -e "  ${Y}╚══════════════════════════════════════════════════════════╝${S}"
echo ""
echo -e "  ${B}Islemci dagilimi:${S}"
echo -e "    Core 0  →  OS / IRQ / NIC kesmeleri"
echo -e "    Core 1  →  Watchdog (Python)"
echo -e "    Core 2  →  Rust Executioner (Tetikci)"
echo -e "    Core 3  →  Python Brain (Analiz)"
echo ""
info "Bitis: $(date)"
echo ""
