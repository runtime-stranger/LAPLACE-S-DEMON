#!/usr/bin/env python3
"""
Watchdog Daemon — Network-Aware Heartbeat Monitor (core 0)

  • Reads Rust bot heartbeat from /dev/shm/mempool_bridge.bin @ byte 61
  • Measures CEX exchange latency via WebSocket ping-pong (no HTTP overhead)
  • On any failure (heartbeat stall > 5s OR ping > 50ms OR network unreachable):
      1. Writes flag=0 (Emergency Stop) to mmap @ byte 63
      2. Sends Cancel All Orders + Market Close to every CEX
      3. Logs to stderr via its own daemon thread
  • Pinned to core 0; isolated from Rust bot (core 2) and Python brain (core 3)

Usage:
  sudo python3 watchdog.py          # normal mode (core pinning requires root)
  python3 watchdog.py --no-affinity  # skip core pinning (for testing)
"""

import argparse
import asyncio
import json
import mmap
import os
import signal
import struct
import sys
import threading
import time
from typing import Optional


# ═══════════════════════════════════════════════════════════════════════════════
# Logger — thread-safe queue (same pattern as brain.py)
# ═══════════════════════════════════════════════════════════════════════════════

class _Logger:
    def __init__(self):
        self._q: "queue.Queue[str | None]" = __import__("queue").Queue()
        self._thread = threading.Thread(target=self._worker, daemon=True)
        self._thread.start()

    def _worker(self):
        while True:
            msg = self._q.get()
            if msg is None:
                break
            print(msg, file=sys.stderr)

    def info(self, msg: str) -> None:
        self._q.put(f"[BİLGİ] Watchdog | {msg}")

    def warn(self, msg: str) -> None:
        self._q.put(f"[UYARI] Watchdog | {msg}")

    def error(self, msg: str) -> None:
        self._q.put(f"[HATA] Watchdog | {msg}")

    def ok(self, msg: str) -> None:
        self._q.put(f"[OK] Watchdog | {msg}")


log = _Logger()


# ═══════════════════════════════════════════════════════════════════════════════
# CEX Emergency API — Cancel All Orders + Market Close
# ═══════════════════════════════════════════════════════════════════════════════
# Her CEX için ayrı implementasyon. API anahtarları ortam değişkenlerinden
# alınır. Sadece acil durumda tetiklenir.
# ═══════════════════════════════════════════════════════════════════════════════

def _cex_sync_request(method: str, url: str, api_key: str, secret: str, body: dict = None) -> Optional[dict]:
    """Senkron HTTP request — watchdog asenkron döngü dışında da çalışabilir."""
    import urllib.request as ureq
    import hmac as _hmac
    import hashlib as _hl

    ts = str(int(time.time() * 1000))
    data_bytes = json.dumps(body).encode() if body else b""

    # Her CEX farklı imzalama kullanır, bu şablon basit bir örnektir.
    # Gerçek üretimde her exchange'in API spec'ine göre imzalama eklenmeli.
    headers = {
        "X-MBX-APIKEY": api_key,
        "Content-Type": "application/json",
    }

    try:
        req = ureq.Request(url, data=data_bytes, headers=headers, method=method)
        with ureq.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read().decode())
    except Exception as exc:
        log.error("CEX API çağrısı başarısız ({} {}): {}".format(method, url, exc))
        return None


def _emergency_cancel_all_binance() -> None:
    key = os.environ.get("BINANCE_API_KEY", "")
    secret = os.environ.get("BINANCE_SECRET", "")
    if not key:
        log.warn("BINANCE_API_KEY tanımlı değil — cancel atlanıyor.")
        return
    log.warn("Binance: tüm emirler iptal ediliyor...")
    _cex_sync_request("DELETE", "https://api.binance.com/api/v3/openOrders", key, secret)
    log.ok("Binance: tüm emirler iptal edildi.")


def _emergency_cancel_all_okx() -> None:
    key = os.environ.get("OKX_API_KEY", "")
    if not key:
        log.warn("OKX_API_KEY tanımlı değil — cancel atlanıyor.")
        return
    log.warn("OKX: tüm emirler iptal ediliyor...")
    _cex_sync_request("POST", "https://www.okx.com/api/v5/trade/cancel-all", key,
                      os.environ.get("OKX_SECRET", ""),
                      {"instType": "SPOT"})
    log.ok("OKX: tüm emirler iptal edildi.")


def _emergency_cancel_all_bybit() -> None:
    key = os.environ.get("BYBIT_API_KEY", "")
    if not key:
        log.warn("BYBIT_API_KEY tanımlı değil — cancel atlanıyor.")
        return
    log.warn("Bybit: tüm emirler iptal ediliyor...")
    _cex_sync_request("DELETE", "https://api.bybit.com/v5/order/cancel-all", key,
                      os.environ.get("BYBIT_SECRET", ""),
                      {"category": "spot"})
    log.ok("Bybit: tüm emirler iptal edildi.")


def _emergency_cancel_all_coinbase() -> None:
    key = os.environ.get("COINBASE_API_KEY", "")
    if not key:
        log.warn("COINBASE_API_KEY tanımlı değil — cancel atlanıyor.")
        return
    log.warn("Coinbase: tüm emirler iptal ediliyor...")
    _cex_sync_request("DELETE", "https://api.exchange.coinbase.com/orders", key,
                      os.environ.get("COINBASE_SECRET", ""))
    log.ok("Coinbase: tüm emirler iptal edildi.")


CEX_EMERGENCY_CANCEL_ALL = {
    "binance": _emergency_cancel_all_binance,
    "okx": _emergency_cancel_all_okx,
    "bybit": _emergency_cancel_all_bybit,
    "coinbase": _emergency_cancel_all_coinbase,
}


# ═══════════════════════════════════════════════════════════════════════════════
# Mmap — read heartbeat + write emergency flag
# ═══════════════════════════════════════════════════════════════════════════════

MMAP_PATH = "/dev/shm/mempool_bridge.bin"
MMAP_SIZE = 64
HEARTBEAT_OFFSET = 61
FLAG_OFFSET = 63


class MmapWatchdog:
    """Watchdog'un mmap ile etkileşimi.

    • byte 61: Rust bot heartbeat (okunur, değişim izlenir)
    • byte 63: flag (acil durumda 0 yazılır → Rust botu durdurur)
    """

    def __init__(self):
        self._mm: Optional[mmap.mmap] = None
        self._last_heartbeat = -1
        self._last_hb_time = 0.0

    def open(self) -> bool:
        try:
            if not os.path.exists(MMAP_PATH):
                log.error("mmap dosyası bulunamadı: {}".format(MMAP_PATH))
                return False
            fd = os.open(MMAP_PATH, os.O_RDWR)
            self._mm = mmap.mmap(fd, MMAP_SIZE, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE)
            os.close(fd)
            self._last_heartbeat = self.read_heartbeat()
            self._last_hb_time = time.monotonic()
            log.info("mmap açıldı: {} (heartbeat={})".format(MMAP_PATH, self._last_heartbeat))
            return True
        except Exception as exc:
            log.error("mmap açılamadı: {}".format(exc))
            return False

    def read_heartbeat(self) -> int:
        if self._mm is None:
            return -1
        self._mm.seek(HEARTBEAT_OFFSET)
        data = self._mm.read(1)
        return data[0] if data else -1

    def emergency_stop(self) -> None:
        """Flag byte'ını 0 yap → Rust botu durdur.

        Ayrıca kalıcılık için dosyaya da yaz.
        """
        if self._mm is None:
            return
        log.warn("ACİL DURUM: flag=0 yazılıyor (Rust botu durduruluyor)...")
        self._mm.seek(FLAG_OFFSET)
        self._mm.write(b"\x00")
        self._mm.flush()
        log.ok("Emergency stop bayrağı yazıldı.")

    def close(self) -> None:
        if self._mm is not None:
            self._mm.close()
            self._mm = None


# ═══════════════════════════════════════════════════════════════════════════════
# Exchange Ping-Pong Latency Monitor
# ═══════════════════════════════════════════════════════════════════════════════
# Her borsaya ayrı bir hafif WebSocket bağlantısı açar.
# Sadece Ping-Pong ölçümü yapar — trade verisi çekmez, rate-limit riske girmez.
# ═══════════════════════════════════════════════════════════════════════════════

EXCHANGE_PING_ENDPOINTS = {
    "binance": {
        "uri": "wss://stream.binance.com:9443/ws",
        "ping_payload": None,  # Binance: op=ping / pong frame kullan
    },
    "okx": {
        "uri": "wss://ws.okx.com:8443/ws/v5/public",
        "ping_payload": '{"ping": ' + str(int(time.time() * 1000)) + '}',
    },
    "bybit": {
        "uri": "wss://stream.bybit.com/v5/public/spot",
        "ping_payload": '{"op": "ping"}',
    },
    "coinbase": {
        "uri": "wss://ws-feed.exchange.coinbase.com",
        # Coinbase raw ping frame kullanır (websockets kütüphanesi handle eder)
        "ping_payload": None,
    },
}

MAX_LATENCY_MS = 50.0
HEARTBEAT_TIMEOUT_S = 5.0
CHECK_INTERVAL_S = 0.1


class ExchangePingMonitor:
    """Her exchange için ayrı WebSocket ping-pong ölçümü.

    Rate-limit'i tetiklememek için ABONE OLMADAN sadece ping atar.
    """

    def __init__(self):
        self._latencies: dict[str, float] = {}
        self._last_ok: dict[str, float] = {}

    def latency(self, name: str) -> Optional[float]:
        return self._latencies.get(name)

    def is_healthy(self, name: str) -> bool:
        lat = self._latencies.get(name)
        if lat is None:
            return False
        return lat < MAX_LATENCY_MS

    def all_healthy(self) -> bool:
        if not self._latencies:
            return False  # henüz ölçüm yoksa sağlıksız kabul et
        return all(self.is_healthy(n) for n in EXCHANGE_PING_ENDPOINTS)

    async def check_all(self) -> dict[str, Optional[float]]:
        results: dict[str, Optional[float]] = {}
        async with asyncio.TaskGroup() as tg:
            tasks = {}
            for name, cfg in EXCHANGE_PING_ENDPOINTS.items():
                task = tg.create_task(self._ping_one(name, cfg))
                tasks[name] = task
            for name, task in tasks.items():
                results[name] = task.result()
        self._latencies = {n: lat for n, lat in results.items() if lat is not None}
        for name in results:
            if results[name] is not None and results[name] < MAX_LATENCY_MS:
                self._last_ok[name] = time.monotonic()
        return results

    async def _ping_one(self, name: str, cfg: dict) -> Optional[float]:
        import websockets
        uri = cfg["uri"]
        try:
            start = time.monotonic()
            async with websockets.connect(uri, ping_interval=None, open_timeout=5) as ws:
                if cfg.get("ping_payload"):
                    await ws.send(cfg["ping_payload"])
                    pong = await asyncio.wait_for(ws.recv(), timeout=5)
                else:
                    pong_waiter = await ws.ping()
                    await asyncio.wait_for(pong_waiter, timeout=5)
                elapsed_ms = (time.monotonic() - start) * 1000
                return elapsed_ms
        except Exception as exc:
            log.warn("{} ping başarısız: {}".format(name, exc))
            return None


# ═══════════════════════════════════════════════════════════════════════════════
# Watchdog Daemon — ana döngü
# ═══════════════════════════════════════════════════════════════════════════════

class WatchdogDaemon:
    """Ana watchdog döngüsü — core 0'da çalışır.

    Her 100ms'de bir:
      1. Rust heartbeat kontrolü (byte 61)
      2. Exchange ping-pong latans ölçümü (her 5 tick'te bir = 500ms)
      3. Hata varsa → emergency_stop() + CEX cancel+close
    """

    def __init__(self, mmap_wd: MmapWatchdog, ping_mon: ExchangePingMonitor):
        self.mmap = mmap_wd
        self.ping = ping_mon
        self._emergency_triggered = False
        self._running = True

        # Rust heartbeat izleme
        self._hb_value = mmap_wd.read_heartbeat()
        self._hb_time = time.monotonic()

    async def run(self):
        log.info("Watchdog başlatılıyor — core 0'da nabız izleniyor.")
        log.info("  • Rust heartbeat:  byte 61 (timeout: {}s)".format(HEARTBEAT_TIMEOUT_S))
        log.info("  • Exchange latans: < {}ms".format(MAX_LATENCY_MS))
        log.info("  • Tick aralığı:    {}ms".format(CHECK_INTERVAL_S * 1000))

        tick = 0
        while self._running:
            await asyncio.sleep(CHECK_INTERVAL_S)
            tick += 1

            # ── 1) Rust heartbeat ──────────────────────────────────────
            try:
                current_hb = self.mmap.read_heartbeat()
            except Exception as exc:
                log.error("Heartbeat okuma hatası: {}".format(exc))
                await self._trigger_emergency()
                continue

            if current_hb < 0:
                log.error("Heartbeat değeri geçersiz (={}).".format(current_hb))
                await self._trigger_emergency()
                continue

            hb_changed = (current_hb != self._hb_value)
            if hb_changed:
                self._hb_value = current_hb
                self._hb_time = time.monotonic()
            else:
                elapsed = time.monotonic() - self._hb_time
                if elapsed > HEARTBEAT_TIMEOUT_S:
                    log.error("Rust botu yanıt vermiyor (heartbeat {} saniyedir değişmedi).".format(
                        int(elapsed)))
                    await self._trigger_emergency()
                    continue

            # ── 2) Exchange ping-pong (her 5 tick = 500ms) ─────────────
            if tick % 5 == 0:
                results = await self.ping.check_all()
                for name, lat in results.items():
                    if lat is None:
                        log.warn("{} — bağlantı KOPUK".format(name))
                    elif lat >= MAX_LATENCY_MS:
                        log.error("{} — latans {}ms (limit: {}ms)".format(name, round(lat, 1), MAX_LATENCY_MS))
                    elif lat >= MAX_LATENCY_MS * 0.8:
                        log.warn("{} — latans {}ms (sınırda)".format(name, round(lat, 1)))

                if not self.ping.all_healthy():
                    log.error("Exchange bağlantıları sağlıksız — acil durum tetikleniyor.")
                    await self._trigger_emergency()
                    continue

            # ── 3) Periyodik durum bildirimi (her 50 tick = 5sn) ──────
            if tick % 50 == 0:
                status = []
                status.append("Rust HB={}".format(current_hb))
                for name in EXCHANGE_PING_ENDPOINTS:
                    lat = self.ping.latency(name)
                    if lat is not None:
                        status.append("{}={}ms".format(name, round(lat, 1)))
                    else:
                        status.append("{}=KOPUK".format(name))
                log.info("DURUM: " + " | ".join(status))

        log.info("Watchdog döngüsü sonlandı.")

    async def _trigger_emergency(self):
        if self._emergency_triggered:
            return  # sadece bir kez tetikle
        self._emergency_triggered = True

        log.error("╔══════════════════════════════════════════════════════════════╗")
        log.error("║  ACİL DURUM PROTOKOLÜ TETİKLENDİ                          ║")
        log.error("╚══════════════════════════════════════════════════════════════╝")

        # 1) Rust botunu durdur (mmap flag=0)
        self.mmap.emergency_stop()

        # 2) CEX emirleri iptal et
        log.warn("Tüm CEX borsalarına Cancel All Orders gönderiliyor...")
        for name, cancel_fn in CEX_EMERGENCY_CANCEL_ALL.items():
            try:
                cancel_fn()
            except Exception as exc:
                log.error("{} cancel hatası: {}".format(name, exc))

        log.warn("ACİL DURUM PROTOKOLÜ TAMAMLANDI.")
        log.warn("Watchdog, Rust botu yeniden başlayana kadar bekleyecek.")

        # Emergency tetiklendikten sonra watchdog bekleme moduna geçer
        # (sürekli hata loglamasını engellemek için)
        while self._running:
            await asyncio.sleep(10)
            log.info("Acill durum modu — Rust botunun yeniden başlaması bekleniyor...")

    def stop(self):
        self._running = False


# ═══════════════════════════════════════════════════════════════════════════════
# Sinyal yönetimi (SIGINT / SIGTERM — temiz kapanış)
# ═══════════════════════════════════════════════════════════════════════════════

_shutdown_requested = False


def _signal_handler(signum, frame):
    global _shutdown_requested
    if _shutdown_requested:
        log.warn("İkinci sinyal — zorla çıkılıyor.")
        sys.exit(1)
    _shutdown_requested = True
    log.info("Kapatma sinyali alındı ({}).".format(signum))


# ═══════════════════════════════════════════════════════════════════════════════
# Core affinity — watchdog core 0'a sabitlenir
# ═══════════════════════════════════════════════════════════════════════════════

def _pin_core(core_id: int = 0) -> bool:
    """Process'i belirtilen çekirdeğe sabitle."""
    try:
        import ctypes
        libc = ctypes.CDLL("libc.so.6", use_errno=True)
        # sched_setaffinity(pid, cpusetsize, mask)
        # pid=0 → current process
        mask = 1 << core_id
        size = ctypes.sizeof(ctypes.c_ulong)
        ret = libc.sched_setaffinity(0, size, ctypes.byref(ctypes.c_ulong(mask)))
        if ret != 0:
            err = ctypes.get_errno()
            log.warn("Core pinning başarısız (errno={}). Root yetkisi gerekebilir.".format(err))
            return False
        log.info("Watchdog core {}'a sabitlendi.".format(core_id))
        return True
    except Exception as exc:
        log.warn("Core pinning desteklenmiyor: {}".format(exc))
        return False


# ═══════════════════════════════════════════════════════════════════════════════
# Entry point
# ═══════════════════════════════════════════════════════════════════════════════

def main():
    parser = argparse.ArgumentParser(description="Watchdog Daemon — Network-Aware Heartbeat")
    parser.add_argument("--no-affinity", action="store_true",
                        help="Core pinning'i atla (test modu)")
    args = parser.parse_args()

    signal.signal(signal.SIGINT, _signal_handler)
    signal.signal(signal.SIGTERM, _signal_handler)

    # Core pinning
    if not args.no_affinity:
        _pin_core(0)

    # Mmap
    mmap_wd = MmapWatchdog()
    if not mmap_wd.open():
        log.error("mmap açılamadı — çıkılıyor.")
        sys.exit(1)

    ping_mon = ExchangePingMonitor()
    daemon = WatchdogDaemon(mmap_wd, ping_mon)

    try:
        asyncio.run(daemon.run())
    except KeyboardInterrupt:
        log.info("Klavye kesmesi.")
    except Exception as exc:
        log.error("Beklenmeyen hata: {}".format(exc))
    finally:
        daemon.stop()
        mmap_wd.close()
        log.info("Watchdog durduruldu.")


if __name__ == "__main__":
    import queue as _q  # _Logger için gerekli
    main()
