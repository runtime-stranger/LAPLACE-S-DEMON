# ⚡ LAPLACE'S DEMON
### Ultra-Low-Latency MEV Execution Engine — Kernel-Bypass, Memory-Mapped, Military-Grade

> *"A sufficient knowledge of the state of the universe at a given instant would reveal all future motions."*
> — Pierre-Simon Laplace

---

## ⚠️ COMMERCIAL USE PROHIBITED — Business Source License 1.1

**EN:** This project is protected under **BSL 1.1 (Business Source License) — PERPETUAL**. Commercial use, copying for profit, or running as a commercial service is **STRICTLY PROHIBITED**.

**TR:** Bu proje **BSL 1.1 (Business Source License) — KALICI** lisans ile korunmaktadır. Ticari kullanım, kopyalayarak para kazanma, ticari servis olarak çalıştırma **KESİNLİKLE YASAKTIR**.

| Status / Durum | Description / Açıklama |
|----------------|------------------------|
| ✅ **Education/Research** (Eğitim/İnceleme) | Source code may be viewed, forked, studied |
| ❌ **Commercial Use** (Ticari Kullanım) | MEV extraction, arbitrage, market making, HFT — **FORBIDDEN** |
| ❌ **SaaS / Cloud** | Cannot be offered as a commercial service |
| ❌ **Financial Institutions** | Hedge funds, prop trading firms may NOT use |

Legal rights reserved in case of violation. Details: [LICENSE](./LICENSE)

---

## 📖 Operational Playbook (Kullanım Kılavuzu)

**EN:** This guide provides enterprise-grade operational steps to deploy the system on **bare-metal servers with zero error**. Follow the sequence strictly.

**TR:** Bu kılavuz, sistemi **bare-metal (fiziki) sunucunuzda sıfır hata ile ayağa kaldırmanız** için tasarlanmış kurumsal operasyon adımlarıdır. **Sıralamaya mutlak suretle uyunuz.**

---

### 🛑 WARNING / ÖNEMLİ UYARI: IPMI / Physical Console Required

**EN:** After `Step 2` (Network Shield) executes, all standard ports including SSH will be **dropped**. Ensure your provider's **IPMI / KVM Over IP** console is open and accessible before proceeding.

**TR:** `Adım 2` (Ağ Kalkanı) çalıştırıldığı an sunucunun dış dünyaya bakan tüm standart portları (klasik SSH dahil) kapatılacaktır. Sunucu sağlayıcınızın size sunduğu **IPMI / KVM Over IP** konsolunun açık ve elinizin altında olduğundan **emin olun**.

---

### Step 1 / Adım 1: CPU Core Isolation (Çekirdek İzolasyonu)

**EN:** Reserve Core 2 and Core 3 exclusively for the bot. Isolate hardware interrupts away from these cores.

**TR:** İşlemci çekirdeklerini (Core 2 ve Core 3) sadece bota rezerve etmek ve arka plan donanım kesmelerini temizlemek.

```bash
sudo su
chmod +x scripts/setup.sh
sudo bash scripts/setup.sh
```

Reboot when all 9 steps show `[OK]`:
```bash
sudo reboot
```

Verify isolation:
```bash
cat /sys/devices/system/cpu/isolated
```

> **Expected / Beklenen:** `2-3`
>
> **EN:** The two fastest cores are now fully dedicated to the bot. Core 0 and Core 1 are reserved for OS, network IRQs, and Watchdog.
>
> **TR:** İşlemcinin en hızlı iki kalbi artık tamamen bota adanmıştır. Core 0 ve Core 1 işletim sistemi, ağ kesmeleri (IRQ) ve Watchdog için rezerve edilmiştir.

---

### Step 2 / Adım 2: Encrypted Tunnel & Network Shield (Kriptografik Tünel ve Ağ Kalkanı)

**EN:** The server will be deafened to the outside world. All traffic flows through an encrypted WireGuard highway (`wg0`) to your RPC node.

**TR:** Sunucu dış dünyaya tamamen sağırlaştırılacak ve RPC düğümünüze özel şifreli bir WireGuard otobanı (`wg0`) kurulacaktır.

**Prerequisites / Ön hazırlık:** Obtain from your RPC node provider:

| Parameter / Parametre | Example / Örnek |
|-----------------------|-----------------|
| RPC WireGuard IP/Port (Endpoint) | `185.12.34.56:51820` |
| RPC WireGuard Public Key | `abc1234...base64...` |

```bash
chmod +x scripts/network_defense.sh

sudo WG_ENDPOINT="185.12.34.56:51820" \
     WG_PEER_PUBKEY="abc1234...base64..." \
     bash scripts/network_defense.sh install
```

**EN:** Copy the displayed **Local Public Key** and add it to your RPC node's Peer configuration.

**TR:** Ekrana basılan **Yerel Genel Anahtarı** kopyalayın ve RPC düğümünüzün ayarlarına (Peer kısmına) ekleyin.

**Verify / Doğrulama:**
```bash
sudo bash scripts/network_defense.sh status
```

> **Expected / Beklenen:** All ports `DROP`, `wg0` tunnel `Active`, `txqueuelen 10000`

---

### Step 3 / Adım 3: Military-Grade Key Shield (Askeri Sınıf Anahtar Kalkanı)

**EN:** The bot's hot wallet private key is encrypted directly into the Linux Kernel Keyring — never written to disk.

**TR:** Botun Ethereum işlemlerini tetikleyeceği **sıcak cüzdan (Hot Wallet)** anahtarı, diske yazılmadan doğrudan Linux çekirdeğinin güvenli hafızasına şifrelenerek enjekte edilecektir.

```bash
python3 brain/brain.py --provision-executor
```

**EN:** You will be prompted for a **strong master password (min 12 chars)**. Save it securely — loss means unrecoverable key. The key is encrypted with AES-256-GCM in kernel memory. An `0x...` **Executor Wallet Address** will be generated.

**TR:** Sistem sizden **en az 12 karakterli, güçlü bir koruma parolası** isteyecektir. Bu parolayı girin ve **güvenli bir yere not edin** (kaybederseniz anahtar kurtarılamaz). Sihirbaz, çekirdek hafızasında (Kernel Keyring) anahtarı AES-256-GCM ile şifreleyecek ve size `0x...` ile başlayan bir **Executor Cüzdan Adresi** üretecektir.

#### 🧩 On-Chain Registration / Zincir Üstü Kayıt (MANDATORY / ZORUNLU)

1. Copy the generated wallet address.
2. Connect your **cold wallet** (Ledger / Trezor / MetaMask) to Remix IDE.
3. Deploy `contracts/Vault.sol` (if not already deployed).
4. Call `addExecutor(address)` with the generated address set to `true`.

> **EN:** Your main vault now authorizes only this isolated bot to trigger swaps. The executor wallet **CANNOT WITHDRAW** from the vault.
>
> **TR:** Artık **paranızın durduğu ana kasa**, bu izole robota sadece takas emri tetikleme yetkisi vermiş oldu. Executor cüzdanı **KASADAN PARA ÇEKEMEZ.**

---

### Step 4 / Adım 4: Environment Configuration (Ortam Değişkenleri)

```bash
cp config/executioner.env.example .env
```

| Variable / Değişken | Required / Zorunlu | Description / Açıklama |
|---------------------|--------------------|------------------------|
| `VAULT_ADDRESS` | ✅ | Vault contract address from Step 3 |
| `CHAIN_ID` | ✅ | Chain ID (Ethereum=1, Sepolia=11155111) |
| `RPC_URL` | ✅ | Your Ethereum node RPC URL |
| `PRIVATE_KEY_1` | ✅ | Executor hot wallet private key |
| `SEARCHER_KEY` | ⬜ | Flashbots signing key (optional) |

> **EN:** **NEVER** commit `.env` to GitHub. `.gitignore` already blocks it.
>
> **TR:** `.env` dosyasını **ASLA** GitHub'a göndermeyin. `.gitignore` zaten bunu engeller.

---

### Step 5 / Adım 5: Ignite the Phantom (Hayaleti Ateşlemek)

**EN:** All infrastructure is armored, tunnels established, keys locked. Time to launch the autonomous system.

**TR:** Tüm altyapı zırhlandı, tüneller kuruldu ve anahtarlar kilitlendi. Artık otonom sistemi başlatma zamanı.

```bash
chmod +x scripts/run/run_all.sh
sudo bash scripts/run/run_all.sh
```

**EN:** You will be prompted for the **Master Password** from Step 3. Upon entry:

**TR:** Script sizden Adım 3'te belirlediğiniz **Koruma Parolasını** isteyecektir. Parolanızı girdiğiniz an:

1. Key is decrypted for **≤1 ms**
2. Rust and Python processes are pinned to isolated cores (`taskset -c 2` and `-c 3`)
3. Password memory is **permanently zeroized** from RAM

#### Live Monitoring / Canlı İzleme

```bash
# Terminal 1 — Rust Executioner logs
journalctl -u executioner -f

# Terminal 2 — Python Brain logs
journalctl -u executioner-brain -f

# Terminal 3 — Watchdog status
journalctl -u executioner-watchdog -f
```

> **EN:** You should see `[INFO]: Executioner pinned to core 2.` and `[INFO]: Brain starting...` — operation is live.
>
> **TR:** Ekranda `[BİLGİ]: Tetikçi core 2'ye çivilendi.` ve `[BİLGİ]: The Brain başlatılıyor...` mesajlarını görüyorsanız, operasyon başlamış demektir.

---

## 🛡️ Emergency Evacuation & Maintenance / Acil Durum Tahliye ve Bakım

| Command / Komut | Description / Açıklama |
|-----------------|------------------------|
| `sudo bash scripts/network_defense.sh status` | Firewall, RPS/RFS, sysctl queue health |
| `sudo bash scripts/network_defense.sh logs` | WireGuard cryptographic handshake health |
| `sudo bash scripts/network_defense.sh teardown` | **EMERGENCY STOP** (see below) |

### EMERGENCY SHUTDOWN / ACİL DURUM TASFİYESİ

**EN:** In case of global network partition or physical breach suspicion:

**TR:** Olası bir küresel ağ bölünmesinde veya sunucu fiziksel ihlal şüphesinde:

```bash
sudo bash scripts/network_defense.sh teardown
```

This command **in a single click** / Bu komut **tek tıkla**:
- Drops WireGuard tunnel
- `shred`s encrypted keys from kernel (unrecoverable)
- Resets `iptables`, reopens all standard ports
- Restores kernel sysctl buffers to Linux defaults

---

## 🏗️ System Architecture / Sistem Mimarisi

```
                           ┌─────────────────────────────────────┐
                           │         BARE-METAL DEDICATED        │
                           │       GRUB: isolcpus=2,3            │
                           │       SMT: OFF · /dev/shm: 128MB    │
                           └──────────────┬──────────────────────┘
                                           │
              ┌───────────────────────────────────────────────┐
              │          PHYSICAL NIC (FİZİKSEL AĞ)          │
              │   RPS mask=3 (core 0-1) · RFS=32768/4096     │
              │       ICMP DROP · All Ports DROP              │
              └──────────────────────┬────────────────────────┘
                                     │
              ┌──────────────────────┴────────────────────────┐
              │           WIREGUARD TUNNEL (wg0)              │
              │  txqueuelen=10000 · PersistentKeepalive=25    │
              │  netdev_max_backlog=100000 · rmem=16MB        │
              └──────────────────────┬────────────────────────┘
                                     │
         ┌───────────────────────────┼───────────────────────────┐
         │                           │                           │
         ▼                           ▼                           ▼
   ┌───────────┐             ┌──────────────┐          ┌──────────────┐
   │ CORE 0    │             │  CORE 2       │          │  CORE 3      │
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
   │                      EXTERNAL NETWORK (DIŞ AĞ)                  │
   │                                                                  │
   │  Exchanges (WSS) ──► Brain ──► mmap ──► Executioner ──► Relays  │
   │  Watchdog ──► Ping/Pong ──► Emergency Stop                      │
   └──────────────────────────────────────────────────────────────────┘
```

---

## 📁 Project Structure / Proje Yapısı

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
│       ├── run_watchdog.sh        # Core 0: Python watchdog
│       └── run_all.sh             # All components simultaneously
├── config/
│   └── executioner.env.example    # Environment variables template
├── Cargo.toml                     # Rust dependencies
├── README.md                      # This file
├── LICENSE                        # Business Source License 1.1 (Perpetual)
└── .gitignore                     # Military-grade secret filtering
```

---

## 🛡️ OPSEC & Anti-Insider Measures / Tedbirler

| Measure / Tedbir | Description / Açıklama |
|------------------|------------------------|
| **PTRACE Shield** (PTRACE Kalkanı) | `kernel.yama.ptrace_scope=1` — even root attacker cannot dump live RAM |
| **Key Encryption** (Anahtar Şifreleme) | AES-256-GCM KEK; private key in RAM ≤1 ms, then zeroized via `libc.memset` |
| **API Restriction** (API Kısıtlaması) | CEX API keys must have **Withdrawal = OFF** |
| **Network Isolation** (Ağ İzolasyonu) | WireGuard tunnel; physical NIC drops all ports and ICMP |
| **Core Isolation** (Çekirdek İzolasyonu) | GRUB `isolcpus=2,3`; RPS/RFS steers IRQs to core 0-1 |
| **Circuit Breaker** (Devre Kesici) | Watchdog halts system on heartbeat stall or exchange latency >50ms |

---

## ⚙️ Hardware Requirements / Donanım Gereksinimleri

| Component / Bileşen | Minimum | Recommended / Önerilen |
|---------------------|---------|------------------------|
| **CPU** | 4 physical cores (8+ threads) | 8+ physical cores |
| **RAM** | 32 GB ECC | 64 GB+ ECC |
| **Storage / Depolama** | 512 GB NVMe SSD | 1 TB+ NVMe Gen4 |
| **Network / Ağ** | 1 Gbps dedicated | 10 Gbps dedicated |
| **SLA** | — | %99.99 hardware guarantee |
| **Remote Management / Uzaktan Yönetim** | — | IPMI / KVM Over IP |

---

## ⚖️ License — Business Source License 1.1 (Perpetual)

Copyright © 2026 runtime-stranger. All rights reserved.

| Parameter / Parametre | Value / Değer |
|-----------------------|---------------|
| **License Type / Lisans Türü** | Business Source License 1.1 (Perpetual / Kalıcı) |
| **Additional Use Grant / Ek Kullanım İzni** | Educational / research only (Yalnızca eğitim/araştırma amaçlı) |
| **Duration / Süre** | **PERPETUAL / SÜRESİZ** — no conversion, no expiry (dönüşüm yok, süre sınırı yok) |

**EN:** Commercial use, copying for profit, forking into commercial systems is **STRICTLY PROHIBITED**. This license is **perpetual** — it never converts to any open-source license. See [LICENSE](./LICENSE) for full text.

**TR:** Ticari kullanım, kopyalayarak para kazanma, fork ederek ticari sisteme dönüştürme **KESİNLİKLE YASAKTIR**. Bu lisans **kalıcıdır (perpetual)**, hiçbir açık kaynak lisansa dönüşmez. Detaylı metin için [LICENSE](./LICENSE) dosyasını inceleyiniz.

---

<p align="center">
  <sub>Business Source License 1.1 (Perpetual) · © 2026 runtime-stranger</sub>
  <br>
  <sub>Rust · Python · Solidity · Linux Kernel · secp256k1 · Flashbots</sub>
  <br>
  <sub>Ultra-Low-Latency · Memory-Mapped · Kernel-Bypass · Military-Grade</sub>
</p>
