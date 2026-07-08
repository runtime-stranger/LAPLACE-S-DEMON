# ⚡ LAPLACE'S DEMON
### Ultra-Low-Latency MEV Execution Engine — Kernel-Bypass, Memory-Mapped, Military-Grade

> *"A sufficient knowledge of the state of the universe at a given instant would reveal all future motions."*
> — Pierre-Simon Laplace

---

## ⚠️ TİCARİ KULLANIM YASAĞI — BUSINESS SOURCE LICENSE 1.1

Bu proje **BSL 1.1 (Business Source License)** ile korunmaktadır.
**Kesinlikle ticari amaçla kullanılamaz, kopyalanıp çalıştırılarak para kazanılamaz.**

| İzin Durumu | Açıklama |
|-------------|----------|
| ✅ **Eğitim/İnceleme** | Kaynak kod görüntülenebilir, fork edilebilir, incelenebilir |
| ❌ **Ticari Kullanım** | MEV çıkarma, arbitraj, market making, HFT — KESİNLİKLE YASAK |
| ❌ **SaaS / Bulut** | Herhangi bir ticari servis olarak sunulamaz |
| ❌ **Finans Kurumları** | Hedge fonlar, prop trading firmaları kullanamaz |

İhlal durumunda yasal haklar saklıdır. Detay: [LICENSE](./LICENSE)

---

## 📖 Operational Playbook (Kullanım Kılavuzu)

Bu kılavuz, sistemi **bare-metal (fiziki) sunucunuzda sıfır hata ile ayağa kaldırmanız** için tasarlanmış kurumsal operasyon adımlarıdır. **Sıralamaya mutlak suretle uyunuz.**

---

### 🛑 ÖNEMLİ UYARI: Fiziksel Konsol / IPMI Erişimi

> **KRİTİK NOT:** `Adım 2` (Ağ Kalkanı) çalıştırıldığı an sunucunun dış dünyaya bakan tüm standart portları (klasik SSH dahil) kapatılacaktır. Bu nedenle, adımları uygularken sunucu sağlayıcınızın (Örn: Hetzner, OVH, Dell iDRAC) size sunduğu **IPMI / KVM Over IP** (Fiziksel ekran simülasyonu) konsolunun açık ve elinizin altında olduğundan **emin olun**.

---

### Adım 1: Sunucu Çekirdek İzolasyonu

İlk adım, sunucunun işlemci çekirdeklerini (Core 2 ve Core 3) sadece bota rezerve etmek ve arka plan donanım kesmelerini temizlemektir.

```bash
# Root yetkisine geç
sudo su

# Betiği çalıştırılabilir yap ve ateşle
chmod +x scripts/setup.sh
sudo bash scripts/setup.sh
```

Ekranda `[OK]` 9 adımın da tamamlandığını gördükten sonra, Linux çekirdeğinin (GRUB) izolasyon parametrelerini devreye alması için sunucuyu **yeniden başlatın**:

```bash
sudo reboot
```

Sunucu açıldıktan sonra çekirdeklerin izole edildiğini doğrulayın:

```bash
cat /sys/devices/system/cpu/isolated
```

> **Beklenen çıktı:** `2-3`
>
> Bu, işlemcinin en hızlı iki kalbinin artık tamamen bota adandığı anlamına gelir. Core 0 ve Core 1 ise işletim sistemi, ağ kesmeleri (IRQ) ve Watchdog için rezerve edilmiştir.

---

### Adım 2: Kriptografik Tünel ve Ağ Kalkanı

Bu adımda sunucu dış dünyaya tamamen sağırlaştırılacak ve RPC düğümünüze özel şifreli bir WireGuard otobanı (`wg0`) kurulacaktır.

**Ön hazırlık:** RPC düğümünüzü (Node) sağlayan şirketten veya kendi yerel düğümünüzden şu iki veriyi alın:

| Parametre | Örnek |
|-----------|-------|
| RPC WireGuard IP/Port (Endpoint) | `185.12.34.56:51820` |
| RPC WireGuard Public Key | `abc1234...base64_kod...` |

Bu verileri aşağıdaki komutun içine yerleştirerek çalıştırın:

```bash
chmod +x scripts/network_defense.sh

sudo WG_ENDPOINT="185.12.34.56:51820" \
     WG_PEER_PUBKEY="abc1234...base64_kod..." \
     bash scripts/network_defense.sh install
```

Komut bittiğinde ekrana **bu sunucunun Yerel Genel Anahtarı (Local Public Key)** basılacaktır. O anahtarı kopyalayın ve RPC düğümünüzün ayarlarına (Peer kısmına) ekleyin. Tünel kriptografik olarak el sıkışacaktır.

**Doğrulama:**

```bash
sudo bash scripts/network_defense.sh status
```

> Beklenen: Tüm portlar `DROP`, `wg0` tüneli `Active`, `txqueuelen 10000`

---

### Adım 3: Askeri Sınıf Anahtar Kalkanı (Keyring)

Botun Ethereum işlemlerini tetikleyeceği **boş geçici sıcak cüzdan (Hot Wallet)** anahtarı, diske yazılmadan doğrudan Linux çekirdeğinin güvenli hafızasına şifrelenerek enjekte edilecektir.

```bash
# Anahtar enjeksiyon sihirbazını başlat
python3 brain/brain.py --provision-executor
```

Sistem sizden **en az 12 karakterli, güçlü bir koruma parolası** isteyecektir. Bu parolayı girin ve **güvenli bir yere not edin** (kaybederseniz anahtar kurtarılamaz).

Sihirbaz, çekirdek hafızasında (Kernel Keyring) anahtarı AES-256-GCM ile şifreleyecek ve size `0x...` ile başlayan bir **Executor Cüzdan Adresi** üretecektir.

#### 🧩 Zincir Üstü Kayıt (ZORUNLU)

1. Üretilen cüzdan adresini kopyalayın.
2. Kendi ana **soğuk cüzdanınızdan** (Ledger / Trezor / MetaMask) Remix IDE'ye bağlanın.
3. `contracts/Vault.sol` akıllı sözleşmesini dağıtın (eğer daha önce dağıtmadıysanız).
4. `addExecutor(address)` fonksiyonunu çağırın ve üretilen adresi `true` olarak yetkilendirin.

> Artık **paranızın durduğu ana kasa**, bu izole robota sadece takas emri tetikleme yetkisi vermiş oldu. Executor cüzdanı **KASADAN PARA ÇEKEMEZ.**

---

### Adım 4: Ortam Değişkenlerinin Yapılandırılması

```bash
cp config/executioner.env.example .env
# .env dosyasını bir metin editörüyle açın ve aşağıdaki alanları doldurun:
```

| Değişken | Zorunlu | Açıklama |
|----------|---------|----------|
| `VAULT_ADDRESS` | ✅ | Adım 3'te dağıttığınız Vault sözleşme adresi |
| `CHAIN_ID` | ✅ | Zincir numarası (Ethereum=1, Sepolia=11155111) |
| `RPC_URL` | ✅ | Ethereum düğümünüzün RPC adresi |
| `PRIVATE_KEY_1` | ✅ | Executor hot wallet özel anahtarı |
| `SEARCHER_KEY` | ⬜ | Flashbots imzalayıcı anahtarı (opsiyonel) |

> **GÜVENLİK:** `.env` dosyasını **ASLA** GitHub'a göndermeyin. `.gitignore` zaten bunu engeller.

---

### Adım 5: Hayaleti Ateşlemek (Full Execution)

Tüm altyapı zırhlandı, tüneller kuruldu ve anahtarlar kilitlendi. Artık otonom sistemi başlatma zamanı.

```bash
chmod +x scripts/run/run_all.sh
sudo bash scripts/run/run_all.sh
```

Script sizden Adım 3'te belirlediğiniz **Koruma Parolasını** isteyecektir. Parolanızı girdiğiniz an:

1. Anahtar **1 milisaniyeliğine** çözülür
2. Rust ve Python süreçleri kendi izole çekirdeklerine (`taskset -c 2` ve `-c 3`) fırlatılır
3. Parolanın bulunduğu bellek alanı RAM'den **kalıcı olarak silinir (Zeroize)**

#### Canlı İzleme

```bash
# 1. Terminal — Rust Executioner logları
journalctl -u executioner -f

# 2. Terminal — Python Brain logları
journalctl -u executioner-brain -f

# 3. Terminal — Watchdog durum raporu
journalctl -u executioner-watchdog -f
```

> Ekranda `[BİLGİ]: Tetikçi core 1'e (2. CPU) çivilendi.` ve `[BİLGİ]: The Brain başlatılıyor...` mesajlarını görüyorsanız, operasyon başlamış demektir.

---

## 🛡️ Acil Durum Tahliye ve Bakım Komutları

Sistem üretim ortamındayken ağ parametrelerini anlık kontrol etmek veya acil bir durumda sistemi tamamen durdurup tüm kilitleri açmak için şu komut seti ayrılmıştır:

| Komut | Açıklama |
|-------|----------|
| `sudo bash scripts/network_defense.sh status` | Firewall, RPS/RFS ve Sysctl kuyruk sağlığını raporlar |
| `sudo bash scripts/network_defense.sh logs` | WireGuard tünelindeki kriptografik el sıkışma sağlığını gösterir |
| `sudo bash scripts/network_defense.sh teardown` | **ACİL DURUM STOP** (aşağıya bakın) |

### ACİL DURUM TASFİYESİ

Olası bir küresel ağ bölünmesinde veya sunucu fiziksel ihlal şüphesinde:

```bash
sudo bash scripts/network_defense.sh teardown
```

Bu komut **tek tıkla**:
- WireGuard tünelini düşürür
- Şifreli anahtarları çekirdekten `shred` ile kazır (kurtarılamaz)
- `iptables` kurallarını sıfırlayarak tüm standart SSH portlarını dış dünyaya yeniden açar
- Kernel sysctl tamponlarını orijinal Linux ayarlarına geri döndürür

---

## 🏗️ Sistem Mimarisi

```
                           ┌─────────────────────────────────────┐
                           │         BARE-METAL DEDICATED        │
                           │       GRUB: isolcpus=2,3            │
                           │       SMT: OFF · /dev/shm: 128MB    │
                           └──────────────┬──────────────────────┘
                                          │
              ┌───────────────────────────────────────────────┐
              │          FİZİKSEL AĞ ARAYÜZÜ (NIC)           │
              │   RPS mask=3 (core 0-1) · RFS=32768/4096     │
              │       ICMP DROP · Tüm Portlar DROP            │
              └──────────────────────┬────────────────────────┘
                                     │
              ┌──────────────────────┴────────────────────────┐
              │           WIREGUARD TÜNELİ (wg0)              │
              │  txqueuelen=10000 · PersistentKeepalive=25    │
              │  netdev_max_backlog=100000 · rmem=16MB        │
              └──────────────────────┬────────────────────────┘
                                     │
         ┌───────────────────────────┼───────────────────────────┐
         │                           │                           │
         ▼                           ▼                           ▼
   ┌───────────┐             ┌──────────────┐          ┌──────────────┐
   │ CORE 1    │             │  CORE 2       │          │  CORE 3      │
   │ Watchdog  │◄───────────►│  Executioner  │◄────────►│  Brain       │
   │ (Python)  │  mmap@61    │  (Rust)       │  mmap@63 │  (Python)    │
   │           │  heartbeat  │               │  flag    │              │
   │ • Ping    │  monitoring│  • spin-loop  │  write   │ • WS feeds   │
   │ • Latency │             │  • ECDSA      │          │ • consensus  │
   │ • Cancel  │             │  • broadcast  │          │ • slippage   │
   └─────┬─────┘             └───────┬───────┘          └──────┬───────┘
         │                           │                         │
         ▼                           ▼                         ▼
   ┌──────────────────────────────────────────────────────────────────┐
   │                      DIŞ AĞ (EXTERNAL)                          │
   │                                                                  │
   │  Borsalar (WSS) ───► Brain ──► mmap ──► Executioner ──► Relays  │
   │  Watchdog ──► Ping/ Pong ölçümü ──► Emergency Stop              │
   └──────────────────────────────────────────────────────────────────┘
```

---

## 📁 Proje Yapısı

```
laplaces-demon/
├── src/                           # Rust execution engine
│   ├── main.rs                    # Zero-jitter spin-loop, mmap protocol
│   ├── nonce_manager.rs           # Lock-free nonce tracking (RwLock)
│   └── broadcaster.rs             # Flashbots v2 multi-relay broadcaster
├── contracts/                     # Solidity smart contracts
│   └── Vault.sol                  # Guardrail Vault — honeypot filter
├── brain/                         # Python analysis engine
│   ├── brain.py                   # Exchange feeds, consensus, keyring
│   └── requirements.txt
├── watchdog/                      # Python watchdog daemon
│   ├── watchdog.py                # Heartbeat, ping-pong, emergency stop
│   └── requirements.txt
├── scripts/                       # Infrastructure & deployment
│   ├── setup.sh                   # 9-step bare-metal provisioning
│   ├── network_defense.sh         # Firewall + WireGuard + RPS/RFS
│   └── run/                       # Launcher scripts
│       ├── run_bot.sh             # Core 2: Rust executioner
│       ├── run_brain.sh           # Core 3: Python brain
│       ├── run_watchdog.sh        # Core 1: Python watchdog
│       └── run_all.sh             # All components simultaneously
├── config/
│   └── executioner.env.example    # Environment variables template
├── Cargo.toml                     # Rust dependencies
├── README.md                      # This file
├── LICENSE                        # Business Source License 1.1
└── .gitignore                     # Military-grade secret filtering
```

---

## 🛡️ OPSEC & Anti-Insider Tedbirleri

| Tedbir | Açıklama |
|--------|----------|
| **PTRACE Kalkanı** | `kernel.yama.ptrace_scope=1` — root saldırgan bile canlı RAM dökümü alamaz |
| **Anahtar Şifreleme** | AES-256-GCM KEK; özel anahtar RAM'de ≤1 ms bulunur, sonra `libc.memset` ile kazınır |
| **API Kısıtlaması** | CEX API anahtarlarında **Para Çekme (Withdrawal) KAPALI** olmalıdır |
| **Ağ İzolasyonu** | WireGuard tüneli; fiziksel NIC tüm portları ve ICMP'yi düşürür |
| **Çekirdek İzolasyonu** | GRUB `isolcpus=2,3`; RPS/RFS ile IRQ'lar core 0-1'e yönlendirilir |
| **Devre Kesici** | Watchdog, heartbeat durması veya borsa gecikmesi >50ms'de sistemi durdurur |

---

## ⚙️ Donanım Gereksinimleri

| Bileşen | Minimum | Önerilen |
|---------|---------|----------|
| **CPU** | 4 fiziksel çekirdek (8+ thread) | 8+ fiziksel çekirdek |
| **RAM** | 32 GB ECC | 64 GB+ ECC |
| **Depolama** | 512 GB NVMe SSD | 1 TB+ NVMe Gen4 |
| **Ağ** | 1 Gbps dedicated | 10 Gbps dedicated |
| **SLA** | — | %99.99 donanım garantisi |
| **Uzaktan Yönetim** | — | IPMI / KVM Over IP |

---

## ⚖️ Lisans — Business Source License 1.1

Copyright © 2026 runtime-stranger. All rights reserved.

| Parametre | Değer |
|-----------|-------|
| **Lisans Türü** | Business Source License 1.1 (Kalıcı) |
| **Ek Kullanım İzni** | Yalnızca eğitim/araştırma amaçlı |
| **Süre** | **SÜRESİZ / PERPETUAL** — dönüşüm yok |

**Ticari kullanım, kopyalayarak para kazanma, fork ederek ticari sisteme dönüştürme KESİNLİKLE YASAKTIR.** Bu lisans kalıcıdır (perpetual), hiçbir açık kaynak lisansa dönüşmez. Detaylı metin için [LICENSE](./LICENSE) dosyasını inceleyiniz.

---

<p align="center">
  <sub>Business Source License 1.1 · © 2026 runtime-stranger</sub>
  <br>
  <sub>Rust · Python · Solidity · Linux Kernel · secp256k1 · Flashbots</sub>
  <br>
  <sub>Ultra-Low-Latency · Memory-Mapped · Kernel-Bypass · Military-Grade</sub>
</p>
