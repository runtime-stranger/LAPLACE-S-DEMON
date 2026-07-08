#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# network_defense.sh — Ağ Kalkanı (v2)
#   • WireGuard üzerinden SSH izni + fiziksel arayüzde DROP-ALL
#   • WireGuard VPN tüneli (RPC düğümü ile şifreli iletişim)
#   • RPS (Receive Packet Steering) + RFS: IRQ'ları core 0-1'e sabitle
#     (core 2 = Rust bot, core 3 = Python beyni korunur)
#
# Kullanım:
#   sudo ./network_defense.sh install           → İlk kurulum
#   sudo ./network_defense.sh status            → Durum raporu
#   sudo ./network_defense.sh teardown          → Tüm yapılandırmayı geri al
#   sudo ./network_defense.sh logs              → WireGuard logları
#
# Ortam Değişkenleri (install):
#   WG_ENDPOINT=<ip:port>          RPC düğümü adresi (gerekli)
#   WG_PEER_PUBKEY=<base64>        RPC düğümü genel anahtarı (gerekli)
#   WG_LISTEN_PORT=<port>          Yerel WireGuard portu (varsayılan: 51820)
#   WG_ADDRESS=<cidr>              Tünel IP'si (varsayılan: 10.0.0.2/24)
#   WG_PEER_ALLOWED_IPS=<cidr>     RPC ağı (varsayılan: 10.0.0.0/24)
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

# ── Renkler ──────────────────────────────────────────────────────────────────
KIRMIZI='\033[0;31m'
YESIL='\033[0;32m'
SARI='\033[1;33m'
MAVI='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${MAVI}[BİLGİ]${NC} $*"; }
ok()    { echo -e "${YESIL}[OK]${NC} $*"; }
warn()  { echo -e "${SARI}[UYARI]${NC} $*"; }
error() { echo -e "${KIRMIZI}[HATA]${NC} $*"; }
die()   { error "$*"; exit 1; }

# ── Varsayılanlar ────────────────────────────────────────────────────────────
WG_INTERFACE="wg0"
WG_LISTEN_PORT="${WG_LISTEN_PORT:-51820}"
WG_PEER_ALLOWED_IPS="${WG_PEER_ALLOWED_IPS:-10.0.0.0/24}"
WG_CONFIG_DIR="/etc/wireguard"
WG_CONFIG="${WG_CONFIG_DIR}/${WG_INTERFACE}.conf"
WG_PRIVKEY="${WG_CONFIG_DIR}/${WG_INTERFACE}.key"
WG_PUBKEY="${WG_CONFIG_DIR}/${WG_INTERFACE}.pub"

# ── Root kontrolü ────────────────────────────────────────────────────────────
require_root() {
    [[ $EUID -eq 0 ]] || die "Root yetkisi gerekli. sudo ile çalıştırın."
}

# ── Fiziksel ağ arayüzünü tespit et (loopback/wg0 hariç) ────────────────────
detect_iface() {
    local candidates
    candidates=$(ip -o link show | awk -F': ' '{print $2}' \
        | grep -v lo | grep -v "${WG_INTERFACE}" | grep -v "^[[:space:]]*$" \
        | head -n1)
    if [[ -z "$candidates" ]]; then
        die "Fiziksel ağ arayüzü tespit edilemedi."
    fi
    echo "$candidates"
}

# ═══════════════════════════════════════════════════════════════════════════════
# 1. GÜVENLİK DUVARI — WireGuard SSH izni + fiziksel IF DROP-ALL
# ═══════════════════════════════════════════════════════════════════════════════
# Sıra kritiktir:
#   1) wg0 arayüzü oluşturulmalı (WireGuard ayakta olmalı)
#   2) wg0 üzerinden SSH (tcp/22) ALLOW
#   3) wg0 üzerinden her şey ALLOW (tünel içi serbest)
#   4) loopback ALLOW
#   5) ESTABLISHED,RELATED ALLOW
#   6) WireGuard UDP portuna ALLOW (tünel kurulumu için)
#   7) fiziksel arayüzde ICMP DROP
#   8) fiziksel arayüzde tüm INPUT DROP
#   9) ancak DEFAULT POLICY DROP yap
# ═══════════════════════════════════════════════════════════════════════════════
setup_firewall() {
    local iface
    iface=$(detect_iface)

    echo ""
    info "╔════════════════════════════════════════════════════════════════════╗"
    info "║  1. Güvenlik Duvarı — WireGuard SSH izni + ${iface} DROP-ALL  ║"
    info "╚════════════════════════════════════════════════════════════════════╝"

    command -v iptables &>/dev/null || die "iptables bulunamadı."

    # Önce tüm zincirleri ve kuralları temizle (temiz sayfa)
    iptables -F
    iptables -X
    iptables -t nat -F
    iptables -t mangle -F

    # ── 1) WireGuard arayüzü (wg0) üzerinden SSH izni ──────────────────
    # Bu kural DEFAULT POLICY DROP'tan ÖNCE eklenmelidir.
    # Operatör, VPN tüneli içinden ssh ile bağlanabilir.
    info "wg0 üzerinden SSH (tcp/22) izni veriliyor..."
    iptables -A INPUT -i "${WG_INTERFACE}" -p tcp --dport 22 -j ACCEPT

    # ── 2) wg0 arayüzünden gelen tüm trafiğe izin ─────────────────────
    iptables -A INPUT -i "${WG_INTERFACE}" -j ACCEPT

    # ── 3) loopback ────────────────────────────────────────────────────
    iptables -A INPUT -i lo -j ACCEPT

    # ── 4) Mevcut bağlantılar ──────────────────────────────────────────
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

    # ── 5) WireGuard UDP portu (tünel kurulumu için) ──────────────────
    iptables -A INPUT -p udp --dport "${WG_LISTEN_PORT}" -j ACCEPT

    # ── 6) Fiziksel arayüzde ICMP'yi tamamen engelle (ping) ──────────
    info "Fiziksel arayüzde (${iface}) ICMP engelleniyor..."
    iptables -A INPUT -i "${iface}" -p icmp -j DROP

    # ── 7) Fiziksel arayüzde tüm port girişlerini engelle ────────────
    info "Fiziksel arayüzde (${iface}) tüm portlar kapatılıyor..."
    iptables -A INPUT -i "${iface}" -j DROP

    # ── 8) Default policy DROP ────────────────────────────────────────
    # ANCAK wg0 SSH kuralı bundan önce eklendiği için wg0 içinden SSH
    # çalışmaya devam eder. Fiziksel arayüze gelen her şey düşer.
    info "Varsayılan poliçe: TÜM GİREN PAKETLER DÜŞÜRÜLÜYOR..."
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT ACCEPT

    # ── Kalıcı hale getir ─────────────────────────────────────────────
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save
        netfilter-persistent reload
        ok "iptables kuralları kalıcı hale getirildi."
    elif command -v iptables-save &>/dev/null; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || \
        iptables-save > /etc/iptables/rules 2>/dev/null || \
        warn "iptables kuralları kaydedilemedi. 'apt install iptables-persistent' önerilir."
    fi

    echo ""
    ok "Güvenlik duvarı aktif."
    info "  • wg0 SSH (22):        İZİN VERİLDİ  (VPN içinden bağlanabilirsiniz)"
    info "  • wg0 tüm trafik:      İZİN VERİLDİ"
    info "  • ${iface} ICMP:          ENGELLENDİ"
    info "  • ${iface} tüm portlar:   ENGELLENDİ (DROP-ALL)"
    info "  • Default INPUT:       DROP"
    echo ""
    iptables -L -n -v 2>/dev/null | head -25
}

# ═══════════════════════════════════════════════════════════════════════════════
# 2. WIREGUARD VPN TÜNELİ — RPC düğümü ile şifreli bağlantı
# ═══════════════════════════════════════════════════════════════════════════════
setup_wireguard() {
    echo ""
    info "╔════════════════════════════════════════════════════════════════════╗"
    info "║  2. WireGuard VPN Tüneli — RPC düğümü ile şifreli iletişim      ║"
    info "╚════════════════════════════════════════════════════════════════════╝"

    command -v wg &>/dev/null || die "WireGuard kurulu değil. 'apt install wireguard' çalıştırın."

    [[ -n "${WG_ENDPOINT:-}" ]]   || die "WG_ENDPOINT gerekli (örn: WG_ENDPOINT=185.12.34.56:51820)"
    [[ -n "${WG_PEER_PUBKEY:-}" ]] || die "WG_PEER_PUBKEY gerekli (RPC düğümü genel anahtarı)"

    mkdir -p "${WG_CONFIG_DIR}"
    chmod 700 "${WG_CONFIG_DIR}"

    # Anahtar çifti (daha önce yoksa oluştur)
    if [[ ! -f "${WG_PRIVKEY}" ]]; then
        info "Yerel WireGuard anahtar çifti oluşturuluyor..."
        wg genkey | tee "${WG_PRIVKEY}" | wg pubkey > "${WG_PUBKEY}"
        chmod 600 "${WG_PRIVKEY}" "${WG_PUBKEY}"
        ok "Anahtar çifti oluşturuldu."
    else
        info "Mevcut anahtar çifti kullanılıyor."
    fi

    local private_key public_key wg_address
    private_key=$(cat "${WG_PRIVKEY}")
    public_key=$(cat "${WG_PUBKEY}")
    wg_address="${WG_ADDRESS:-10.0.0.2/24}"

    # WireGuard konfigürasyonu — PersistentKeepalive = 25 ZORUNLU
    # Bu parametre, stateful güvenlik duvarlarının (NAT/firewall)
    # tüneli düşürmesini engeller. Her 25 saniyede bir keepalive paketi
    # gönderilir, böylece durum tablosu taze kalır.
    info "WireGuard konfigürasyonu yazılıyor: ${WG_CONFIG}"
    cat > "${WG_CONFIG}" <<EOF
# ═══════════════════════════════════════════════════════════════════════════════
# WireGuard: ${WG_INTERFACE}
# Oluşturma: $(date -I)
# Yerel genel anahtar: ${public_key}
# ═══════════════════════════════════════════════════════════════════════════════
[Interface]
PrivateKey = ${private_key}
Address    = ${wg_address}
ListenPort = ${WG_LISTEN_PORT}

# ── RPC düğümü ──────────────────────────────────────────────────────────────
# PersistentKeepalive = 25  →  Stateful firewall/NAT'ın tüneli düşürmesini
#                              önler. Her 25 saniyede bir keepalive atılır.
[Peer]
PublicKey  = ${WG_PEER_PUBKEY}
Endpoint   = ${WG_ENDPOINT}
AllowedIPs = ${WG_PEER_ALLOWED_IPS}
PersistentKeepalive = 25
EOF
    chmod 600 "${WG_CONFIG}"
    ok "WireGuard konfigürasyonu yazıldı (PersistentKeepalive=25 aktif)."

    # Arayüzü başlat (önce varsa durdur, temiz başlangıç)
    wg-quick down "${WG_INTERFACE}" 2>/dev/null || true
    wg-quick up "${WG_INTERFACE}" || die "WireGuard arayüzü başlatılamadı."

    # Sistem başlangıcında otomatik başlat
    if command -v systemctl &>/dev/null; then
        systemctl enable "wg-quick@${WG_INTERFACE}" 2>/dev/null || true
        ok "WireGuard systemd servisi etkinleştirildi."
    fi

    echo ""
    ok "WireGuard tüneli aktif."
    info "╔════════════════════════════════════════════════════════════════════╗"
    info "║  Bu sunucunun genel anahtarı (RPC düğümüne ekleyin):             ║"
    info "║                                                                ║"
    info "║  ${public_key}  ║"
    info "║                                                                ║"
    info "║  RPC düğümünde şu komutla ekleyin:                             ║"
    info "║    wg set wg0 peer ${public_key} allowed-ips 10.0.0.2/32 ║"
    info "╚════════════════════════════════════════════════════════════════════╝"

    # Varsayılan rotayı WireGuard üzerinden yönlendir
    info "Tüm IPv4 trafiği WireGuard üzerinden yönlendiriliyor..."
    ip route del default 2>/dev/null || true
    ip route add default dev "${WG_INTERFACE}" metric 50 || \
        warn "Varsayılan rota değiştirilemedi. Var olan rotalar korunuyor."
    ok "Tüm çıkan trafik ${WG_INTERFACE} üzerinden yönlendiriliyor."
}

# ═══════════════════════════════════════════════════════════════════════════════
# 3. RPS (Receive Packet Steering) + RFS (Receive Flow Steering)
#    Amaç: NIC soft IRQ'larını yalnızca core 0-1'e dağıt.
#          Core 2 (Rust bot) ve core 3 (Python beyni) korunsun.
# ═══════════════════════════════════════════════════════════════════════════════
setup_rps_rfs() {
    local iface
    iface=$(detect_iface)

    echo ""
    info "╔════════════════════════════════════════════════════════════════════╗"
    info "║  3. RPS + RFS — IRQ'ları core 0-1'e sabitle                     ║"
    info "║     Core 2 (Rust bot) ve core 3 (Python beyni) korunuyor        ║"
    info "╚════════════════════════════════════════════════════════════════════╝"
    info "Fiziksel arayüz: ${iface}"

    # ── RPS: Receive Packet Steering ────────────────────────────────────────
    # Bitmask = 3  →  binary 0011  →  yalnızca core 0 ve core 1
    # NOT: Bit 0 = core 0, Bit 1 = core 1 (bit sırası LSB = CPU 0)
    local rps_cpus="3"
    local queues_found=0

    info "RPS cpu maskesi: ${rps_cpus} (core 0-1, yani 0011)"
    for rx_queue in /sys/class/net/"${iface}"/queues/RX-*; do
        local rps_path="${rx_queue}/rps_cpus"
        if [[ -f "$rps_path" ]]; then
            echo "$rps_cpus" > "$rps_path" 2>/dev/null || warn "RPS yazılamadı: ${rps_path}"
            queues_found=$((queues_found + 1))
        fi
    done

    if [[ $queues_found -gt 0 ]]; then
        ok "RPS: ${queues_found} RX kuyruğu core 0-1'e yönlendirildi (mask=3)."
    else
        warn "RX kuyruğu bulunamadı. RPS desteklenmiyor olabilir."
    fi

    # ── RFS: Receive Flow Steering (önbellek kaçırmalarını önler) ──────────
    # rps_sock_flow_entries: Global RFS tablosu boyutu = 32768
    # rps_flow_cnt: Her RX kuyruğu için akış sayısı = 4096
    info "RFS yapılandırılıyor..."
    echo 32768 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || \
        warn "rps_sock_flow_entries yazılamadı."

    for rx_queue in /sys/class/net/"${iface}"/queues/RX-*; do
        local rfs_path="${rx_queue}/rps_flow_cnt"
        if [[ -f "$rfs_path" ]]; then
            echo 4096 > "$rfs_path" 2>/dev/null || warn "rps_flow_cnt yazılamadı: ${rfs_path}"
        fi
    done
    ok "RFS: rps_sock_flow_entries=32768, her kuyruk için rps_flow_cnt=4096."

    # ── IRQ smp_affinity (doğrudan IRQ yönlendirme) ────────────────────────
    local smp_mask="00000003"  # Aynı mask: core 0-1
    local irqs
    irqs=$(grep -E "eth|eno|ens|enp" /proc/interrupts 2>/dev/null \
           | awk -F: '{print $1}' | tr -d ' ' || true)
    if [[ -n "$irqs" ]]; then
        for irq in $irqs; do
            local smp_path="/proc/irq/${irq}/smp_affinity"
            [[ -f "$smp_path" ]] && echo "$smp_mask" > "$smp_path" 2>/dev/null || true
        done
        ok "IRQ smp_affinity core 0-1'e yönlendirildi."
    fi

    # ── RPS/RFS'yi kalıcı hale getir (systemd oneshot servisi) ────────────
    if command -v systemctl &>/dev/null; then
        local rps_service="/etc/systemd/system/rps-rfs.service"
        cat > "$rps_service" <<'RPSRFSEOF'
[Unit]
Description=RPS+RFS — NIC IRQ steering to cores 0-1 (protect cores 2-3)
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c '\
  echo 32768 > /proc/sys/net/core/rps_sock_flow_entries; \
  for q in /sys/class/net/*/queues/RX-*/rps_cpus; do \
    echo 3 > "$q" 2>/dev/null || true; \
  done; \
  for q in /sys/class/net/*/queues/RX-*/rps_flow_cnt; do \
    echo 4096 > "$q" 2>/dev/null || true; \
  done; \
  for irq in $(grep -E "eth|eno|ens|enp" /proc/interrupts | awk -F: "{print \$1}" | tr -d " "); do \
    [ -f "/proc/irq/$irq/smp_affinity" ] && echo 00000003 > "/proc/irq/$irq/smp_affinity" 2>/dev/null || true; \
  done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
RPSRFSEOF
        systemctl daemon-reload
        systemctl enable rps-rfs.service
        ok "RPS/RFS systemd servisi kuruldu ve etkinleştirildi (rps-rfs.service)."
    fi

    echo ""
    ok "Ağ IRQ yükü core 0-1'e sabitlendi."
    info "  • RPS mask:         3 (core 0-1)"
    info "  • rps_sock_flow:   32768"
    info "  • rps_flow_cnt:     4096 / kuyruk"
    info "  • smp_affinity:     00000003"
    info "  • Core 2 (Rust):    Korunuyor"
    info "  • Core 3 (Python):  Korunuyor"
}

# ═══════════════════════════════════════════════════════════════════════════════
# 4. EVM LINUX SYSCTL NETWORK OPTIMIZER — Ağ Kuyruğu Aşım Kalkanı
#    Hedef: WireGuard tünelinin (wg0) yoğun mempool/blok trafiği altında
#           Buffer Bloat yaşamasını engellemek.
# ═══════════════════════════════════════════════════════════════════════════════
# Ayarlar:
#   • wg0 txqueuelen 10000    — iletim kuyruğu derinliği (Buffer Bloat önler)
#   • net.core.netdev_max_backlog  = 100000   — kernel ağ kuyruğu bütçesi
#   • net.core.rmem_max             = 16777216 — max UDP/TCP alma tamponu
#   • net.core.wmem_max             = 16777216 — max UDP/TCP gönderme tamponu
#   • net.ipv4.tcp_rmem             = 4096 87380 16777216 — TCP alma 3'lüsü
#   • net.ipv4.tcp_wmem             = 4096 65536 16777216 — TCP gönderme 3'lüsü
# ═══════════════════════════════════════════════════════════════════════════════

SYSCTL_BACKUP="/etc/sysctl.d/99-executioner.conf"

setup_sysctl_network() {
    echo ""
    info "╔════════════════════════════════════════════════════════════════════╗"
    info "║  4. EVM Sysctl Optimizer — Ağ Kuyruğu Aşım Kalkanı              ║"
    info "╚════════════════════════════════════════════════════════════════════╝"

    # ── 4a) WireGuard txqueuelen ──────────────────────────────────────────────
    info "wg0 txqueuelen 10000 ayarlanıyor (Buffer Bloat koruması)..."
    ip link set dev "${WG_INTERFACE}" txqueuelen 10000 2>/dev/null || \
        warn "txqueuelen ayarlanamadı — wg0 henüz hazır olmayabilir."

    local actual_txq
    actual_txq=$(ip link show "${WG_INTERFACE}" 2>/dev/null \
        | grep -oP 'qlen \K\d+' || echo "?")
    ok "wg0 txqueuelen: ${actual_txq} (hedef: 10000)"

    # ── 4b) /etc/sysctl.d/99-executioner.conf — kalıcı kernel ayarları ──────
    info "Kernel ağ parametreleri yazılıyor: ${SYSCTL_BACKUP}"
    cat > "${SYSCTL_BACKUP}" <<EOF
# ═══════════════════════════════════════════════════════════════════════════════
# executioner — EVM Linux Network Optimizer
# Oluşturma: $(date -I)
#
# Amaç: WireGuard (wg0) üzerinden akan yoğun mempool ve blok şifre çözme
#       trafiği altında Buffer Bloat'u ve aşırı kuyruk gecikmesini önlemek.
# ═══════════════════════════════════════════════════════════════════════════════

# Kernel ağ kuyruğu maksimum uzunluğu (gelen paketler için)
# Varsayılan: 1000  →  100000 (100× artış)
net.core.netdev_max_backlog = 100000

# Maksimum UDP/TCP alma tamponu (byte)
# Varsayılan: 212992 (~208 KB)  →  16777216 (16 MB)
net.core.rmem_max = 16777216

# Maksimum UDP/TCP gönderme tamponu (byte)
# Varsayılan: 212992 (~208 KB)  →  16777216 (16 MB)
net.core.wmem_max = 16777216

# TCP alma tamponu 3'lüsü (min / default / max)
# Varsayılan: 4096 131072 6291456  →  4096 87380 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216

# TCP gönderme tamponu 3'lüsü (min / default / max)
# Varsayılan: 4096 16384 4194304  →  4096 65536 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
EOF
    chmod 644 "${SYSCTL_BACKUP}"
    ok "Yapılandırma dosyası yazıldı: ${SYSCTL_BACKUP}"

    # ── 4c) Sysctl'leri uygula ──────────────────────────────────────────────
    info "sysctl ayarları uygulanıyor..."
    sysctl -p "${SYSCTL_BACKUP}" 2>/dev/null || {
        warn "sysctl -p başarısız oldu, tek tek uygulanıyor..."
        sysctl -w net.core.netdev_max_backlog=100000
        sysctl -w net.core.rmem_max=16777216
        sysctl -w net.core.wmem_max=16777216
        sysctl -w net.ipv4.tcp_rmem="4096 87380 16777216"
        sysctl -w net.ipv4.tcp_wmem="4096 65536 16777216"
    }

    ok "EVM Sysctl Network Optimizer aktif."
    echo ""
    info "  • wg0 txqueuelen:       10000"
    info "  • netdev_max_backlog:   100000"
    info "  • rmem_max / wmem_max:  16777216 (16 MB)"
    info "  • tcp_rmem:             4096 87380 16777216"
    info "  • tcp_wmem:             4096 65536 16777216"
}

# ═══════════════════════════════════════════════════════════════════════════════
# DURUM KONTROLÜ
# ═══════════════════════════════════════════════════════════════════════════════
show_status() {
    echo ""
    info "╔════════════════════════════════════════════════════════════════════╗"
    info "║  Ağ Kalkanı — Durum Raporu (v3)                                 ║"
    info "╚════════════════════════════════════════════════════════════════════╝"

    echo ""
    info "── Güvenlik Duvarı (iptables) ──"
    iptables -L -n -v 2>/dev/null | head -40

    echo ""
    info "── WireGuard ──"
    if command -v wg &>/dev/null; then
        wg show 2>/dev/null || warn "WireGuard aktif değil."
    else
        warn "WireGuard kurulu değil."
    fi

    echo ""
    info "── RPS CPU Maskeleri ──"
    local iface
    iface=$(detect_iface)
    for rx_q in /sys/class/net/"${iface}"/queues/RX-*/rps_cpus; do
        [[ -f "$rx_q" ]] && echo "  ${rx_q}: $(cat "$rx_q" 2>/dev/null)"
    done

    echo ""
    info "── RFS Yapılandırması ──"
    echo "  rps_sock_flow_entries: $(cat /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || echo 'N/A')"
    for rx_q in /sys/class/net/"${iface}"/queues/RX-*/rps_flow_cnt; do
        [[ -f "$rx_q" ]] && echo "  ${rx_q}: $(cat "$rx_q" 2>/dev/null)"
    done

    echo ""
    info "── EVM Sysctl Network Optimizer ──"
    echo "  wg0 txqueuelen: $(ip link show "${WG_INTERFACE}" 2>/dev/null | grep -oP 'qlen \K\d+' || echo 'N/A')"
    for key in net.core.netdev_max_backlog net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem; do
        local val
        val=$(sysctl -n "$key" 2>/dev/null || echo 'N/A')
        echo "  ${key}: ${val}"
    done

    echo ""
    info "── IRQ Yönlendirme (smp_affinity) ──"
    local irqs
    irqs=$(grep -E "eth|eno|ens|enp" /proc/interrupts 2>/dev/null \
           | awk -F: '{print $1}' | tr -d ' ' || true)
    for irq in $irqs; do
        local smp_path="/proc/irq/${irq}/smp_affinity"
        [[ -f "$smp_path" ]] && echo "  IRQ ${irq}: $(cat "$smp_path" 2>/dev/null)"
    done
}

# ═══════════════════════════════════════════════════════════════════════════════
# GERİ ALMA (Teardown)
# ═══════════════════════════════════════════════════════════════════════════════
teardown() {
    echo ""
    warn "╔════════════════════════════════════════════════════════════════════╗"
    warn "║  Ağ Kalkanı kaldırılıyor — tüm yapılandırma sıfırlanıyor        ║"
    warn "╚════════════════════════════════════════════════════════════════════╝"

    # WireGuard durdur
    if command -v wg-quick &>/dev/null; then
        wg-quick down "${WG_INTERFACE}" 2>/dev/null || true
        systemctl disable "wg-quick@${WG_INTERFACE}" 2>/dev/null || true
        info "WireGuard durduruldu."
    fi

    # Anahtarları güvenle sil
    [[ -f "${WG_PRIVKEY}" ]] && { shred -u "${WG_PRIVKEY}" 2>/dev/null || rm -f "${WG_PRIVKEY}"; info "Özel anahtar silindi."; }
    rm -f "${WG_CONFIG}" "${WG_PUBKEY}" 2>/dev/null || true

    # Firewall'u sıfırla (TÜM PORTLARI AÇ)
    info "Güvenlik duvarı sıfırlanıyor — tüm portlar açılıyor..."
    iptables -F
    iptables -X
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT

    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save
    fi

    # RPS/RFS servisini kaldır
    systemctl disable rps-rfs.service 2>/dev/null || true
    rm -f /etc/systemd/system/rps-rfs.service 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true

    # RFS sysctl'lerini sıfırla
    echo 0 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || true

    # EVM Sysctl Network Optimizer kaldır
    info "EVM Sysctl Network Optimizer kaldırılıyor..."
    rm -f "${SYSCTL_BACKUP}" 2>/dev/null || true
    # Kernel parametrelerini varsayılana döndür
    sysctl -w net.core.netdev_max_backlog=1000 2>/dev/null || true
    sysctl -w net.core.rmem_max=212992 2>/dev/null || true
    sysctl -w net.core.wmem_max=212992 2>/dev/null || true
    sysctl -w net.ipv4.tcp_rmem="4096 131072 6291456" 2>/dev/null || true
    sysctl -w net.ipv4.tcp_wmem="4096 16384 4194304" 2>/dev/null || true
    # txqueuelen sıfırla (Linux varsayılanı)
    ip link set dev "${WG_INTERFACE}" txqueuelen 1000 2>/dev/null || true
    ok "EVM Sysctl Network Optimizer kaldırıldı (kernel varsayılanlarına dönüldü)."

    ok "Ağ Kalkanı kaldırıldı. Tüm portlar AÇIK."
    warn "SSH (tcp/22) artık her arayüzden erişilebilir."
}

# ═══════════════════════════════════════════════════════════════════════════════
# ANA KUMANDA
# ═══════════════════════════════════════════════════════════════════════════════
main() {
    local cmd="${1:-help}"

    case "$cmd" in
        install)
            require_root
            echo ""
            info "╔════════════════════════════════════════════════════════════════════╗"
            info "║  Ağ Kalkanı Kurulumu v3                                        ║"
            info "║                                                                 ║"
            info "║  Sıra:                                                          ║"
            info "║    1. WireGuard tüneli kurulur (wg0)                            ║"
            info "║    2. Güvenlik duvarı: wg0 SSH izni + fiziksel IF DROP-ALL      ║"
            info "║    3. RPS+RFS: IRQ'lar core 0-1'e sabitlenir                    ║"
            info "║    4. EVM Sysctl Optimizer: ağ kuyruğu bütçesi genişletilir     ║"
            info "╚════════════════════════════════════════════════════════════════════╝"

            # ÖNCE WireGuard (wg0 arayüzü firewall kurallarından önce ayakta olmalı)
            info "Adım 1/3: WireGuard tüneli kuruluyor..."
            setup_wireguard

            # SONRA firewall (wg0 arayüzü hazır olduğu için SSH kuralı çalışır)
            info ""
            info "Adım 2/3: Güvenlik duvarı yapılandırılıyor..."
            setup_firewall

            # EN SON RPS/RFS
            info ""
            info "Adım 3/3: RPS + RFS yapılandırılıyor..."
            setup_rps_rfs

            # EVM Sysctl Network Optimizer
            info ""
            info "Adım 4/4: EVM Sysctl Network Optimizer uygulanıyor..."
            setup_sysctl_network

            echo ""
            ok "══════════════════════════════════════════════════════════════════════"
            ok "  Ağ Kalkanı kurulumu TAMAMLANDI."
            ok "══════════════════════════════════════════════════════════════════════"
            echo ""
            info "Özet:"
            info "  • WireGuard tüneli:  ${WG_INTERFACE} (PersistentKeepalive=25)"
            info "  • wg0 SSH (22):      İZİN VERİLDİ — VPN içinden bağlanabilirsiniz"
            info "  • Fiziksel IF:       Tüm portlar + ICMP DROP"
            info "  • RPS mask:          3 (core 0-1)"
            info "  • RFS entries:       32768 global, 4096/kuyruk"
            info "  • wg0 txqueuelen:    10000"
            info "  • netdev_max_backlog: 100000"
            info "  • rmem/wmem:          16 MB"
            info "  • Core 2 (Rust):     Korunuyor"
            info "  • Core 3 (Python):   Korunuyor"
            echo ""
            warn "SSH yalnızca WireGuard tüneli (wg0) üzerinden çalışır."
            warn "Fiziksel arayüzden SSH, ping ve tüm portlar KAPALI."
            ;;
        status)
            require_root
            show_status
            ;;
        teardown|kaldir|reset)
            require_root
            teardown
            ;;
        logs)
            if command -v journalctl &>/dev/null; then
                journalctl -u "wg-quick@${WG_INTERFACE}" -n 50 --no-pager
            else
                warn "journalctl bulunamadı."
                dmesg 2>/dev/null | grep -i wireguard | tail -20 || true
            fi
            ;;
        help|--help|-h)
            echo "Kullanım: $0 <komut>"
            echo ""
            echo "Komutlar:"
            echo "  install          İlk kurulum (wireguard → firewall → rps+rfs → sysctl)"
            echo "  status           Durum raporu"
            echo "  teardown         Tüm yapılandırmayı geri al"
            echo "  logs             WireGuard logları"
            echo ""
            echo "Ortam değişkenleri (install):"
            echo "  WG_ENDPOINT=<ip:port>          RPC düğümü adresi (gerekli)"
            echo "  WG_PEER_PUBKEY=<base64>        RPC düğümü genel anahtarı (gerekli)"
            echo "  WG_LISTEN_PORT=<port>          Yerel WireGuard portu (varsayılan: 51820)"
            echo "  WG_ADDRESS=<cidr>              Tünel IP'si (varsayılan: 10.0.0.2/24)"
            echo "  WG_PEER_ALLOWED_IPS=<cidr>     RPC ağı (varsayılan: 10.0.0.0/24)"
            echo ""
            echo "Örnek:"
            echo "  WG_ENDPOINT=95.12.34.56:51820 WG_PEER_PUBKEY=<key> sudo $0 install"
            ;;
        *)
            die "Bilinmeyen komut: ${cmd}. Kullanım: $0 {install|status|teardown|logs|help}"
            ;;
    esac
}

main "$@"
