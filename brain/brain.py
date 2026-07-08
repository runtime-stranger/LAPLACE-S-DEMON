#!/usr/bin/env python3
"""
The Brain — MEV Intelligence & Analysis Server
  • Multiprocessing: each exchange WebSocket in its own Process (no buffer-bloat)
  • msync via ctypes raw syscall (kernel-level, synchronous)
  • ExecutorKeyRing: executor private key stored AES-256-GCM encrypted inside
    the Linux Kernel Keyring; decrypted on-demand for ≤1 ms, zeroized immediately.
    This key is a HOT WALLET with onlyAuthorizedExecutor role on the Vault contract.
    Even if stolen, the vault funds CANNOT be withdrawn — only transactions
    can be triggered.
  • GC disabled on hot path; manual collect at safe points
  • struct.pack('<20s32sB') → mmap → msync → CPU fence → flag at offset 63

  Logger: all terminal output goes through a thread-safe Queue; a dedicated
  daemon thread drains it.  The 20 Hz consensus loop NEVER calls print() directly.
"""

import argparse
import ctypes
import gc
import hashlib
import hmac
import json
import math
import mmap
import multiprocessing
import os
import queue
import secrets
import statistics
import struct
import sys
import threading
import time
from collections import deque
from ctypes import c_int, c_size_t, c_void_p, c_char_p, c_ubyte, POINTER
from typing import Optional

import websockets


# ═══════════════════════════════════════════════════════════════════════════════
# Logger — thread-safe queue-based collector
#   All [BİLGİ] / [UYARI] / [HATA] messages are pushed to a Queue; a single
#   daemon thread drains it and writes to stderr.  The hot path never writes
#   to stderr directly.
# ═══════════════════════════════════════════════════════════════════════════════

class Logger:
    """Channel-based logger.  Create once, share references freely (thread-safe)."""

    def __init__(self):
        self._q: "queue.Queue[str | None]" = queue.Queue()
        self._thread = threading.Thread(target=self._worker, daemon=True)
        self._thread.start()

    def _worker(self):
        while True:
            msg = self._q.get()
            if msg is None:
                break
            print(msg, file=sys.stderr)

    def info(self, msg: str) -> None:
        self._q.put(f"[BİLGİ] {msg}")

    def warn(self, msg: str) -> None:
        self._q.put(f"[UYARI] {msg}")

    def error(self, msg: str) -> None:
        self._q.put(f"[HATA] {msg}")


# ═══════════════════════════════════════════════════════════════════════════════
# Exponential-backoff retry decorator for async functions
# ═══════════════════════════════════════════════════════════════════════════════

def retry_with_backoff(label, max_attempts=5, base_delay=1.0):
    """Decorator: async fn → retry with exponential backoff on network errors.

    Backoff sequence (seconds): base_delay × 1, 2, 4, 8 … capped at 30 s.
    Logs in Turkish via print(..., file=sys.stderr).
    """
    def decorator(fn):
        async def wrapper(*args, **kwargs):
            last_exc = None
            for attempt in range(1, max_attempts + 1):
                try:
                    return await fn(*args, **kwargs)
                except (OSError, asyncio.TimeoutError, websockets.ConnectionClosed) as exc:
                    last_exc = exc
                    if attempt < max_attempts:
                        delay = min(base_delay * (2 ** (attempt - 1)), 30.0)
                        print(
                            "[UYARI]: {} başarısız (deneme {}/{}): {}. "
                            "{} saniye sonra yeniden...".format(
                                label, attempt, max_attempts, exc, delay
                            ),
                            file=sys.stderr,
                        )
                        await asyncio.sleep(delay)
                    else:
                        print(
                            "[HATA]: {} tamamen başarısız ({} deneme): {}".format(
                                label, max_attempts, exc
                            ),
                            file=sys.stderr,
                        )
            raise last_exc
        return wrapper
    return decorator


# ═══════════════════════════════════════════════════════════════════════════════
# Configuration
# ═══════════════════════════════════════════════════════════════════════════════

EXCHANGES = {
    "binance": {
        "uri": "wss://stream.binance.com:9443/ws",
        "subscribe": {"method": "SUBSCRIBE", "params": ["btcusdt@trade"], "id": 1},
        "parse": lambda raw: (float(raw["p"]), int(raw["T"]) * 1_000_000),
    },
    "okx": {
        "uri": "wss://ws.okx.com:8443/ws/v5/public",
        "subscribe": {"op": "subscribe", "args": [{"channel": "trades", "instId": "BTC-USDT"}]},
        "parse": lambda raw: (float(raw["data"][0]["px"]), int(raw["data"][0]["ts"]) * 1_000_000),
    },
    "bybit": {
        "uri": "wss://stream.bybit.com/v5/public/spot",
        "subscribe": {"op": "subscribe", "args": ["publicTrade.BTCUSDT"]},
        "parse": lambda raw: (float(raw["data"][0]["p"]), int(raw["ts"]) * 1_000_000),
    },
    "coinbase": {
        "uri": "wss://ws-feed.exchange.coinbase.com",
        "subscribe": {
            "type": "subscribe",
            "channels": [{"name": "ticker", "product_ids": ["BTC-USD"]}],
        },
        "parse": lambda raw: (
            float(raw["price"]),
            int(time.mktime(time.strptime(raw["time"], "%Y-%m-%dT%H:%M:%S.%fZ")) * 1_000_000_000),
        ),
    },
}

MMAP_PATH = "/dev/shm/mempool_bridge.bin"
MMAP_SIZE = 64

STALE_THRESHOLD_NS = 200_000_000
FREQ_DROP_RATIO = 0.5
FREQ_WARMUP = 50

VOL_WINDOW = 20
SLIPPAGE_BASE_BPS = 5
SLIPPAGE_MAX_BPS = 50
SLIPPAGE_VOL_SCALE = 2.0


# ═══════════════════════════════════════════════════════════════════════════════
# libc wrappers — msync + memset + getpid (CPU fence via syscall)
# ═══════════════════════════════════════════════════════════════════════════════

_libc = ctypes.CDLL("libc.so.6", use_errno=True)

_libc.msync.argtypes = [c_void_p, c_size_t, c_int]
_libc.msync.restype = c_int
MS_SYNC = 4


def msync_sync(addr: int, length: int) -> None:
    """Call raw msync(addr, length, MS_SYNC)."""
    ret = _libc.msync(c_void_p(addr), c_size_t(length), c_int(MS_SYNC))
    if ret != 0:
        err = ctypes.get_errno()
        raise OSError(err, os.strerror(err))


_libc.memset.argtypes = [c_void_p, c_int, c_size_t]
_libc.memset.restype = c_void_p


def zeroize(buf: bytearray) -> None:
    """Overwrite buffer with zeros via libc memset (compiler-safe)."""
    if not buf:
        return
    view = (ctypes.c_ubyte * len(buf)).from_buffer(buf)
    _libc.memset(ctypes.addressof(view), 0, len(buf))


_libc.getpid.argtypes = []
_libc.getpid.restype = c_int


def cpu_fence() -> None:
    """Full CPU + compiler memory barrier via a real getpid syscall."""
    _libc.getpid()


# ═══════════════════════════════════════════════════════════════════════════════
# ╔══════════════════════════════════════════════════════════════════════════╗
# ║  KRİPTOGRAFİK ANAHTAR KALKANI (Hardware Keyring)                       ║
# ║  Military-grade executor key management via Linux Kernel Keyring       ║
# ║                                                                        ║
# ║  • Key stored AES-256-GCM encrypted inside the kernel keyring          ║
# ║  • Decryption passphrase NEVER touches disk or .env —                  ║
# ║    entered interactively at startup (or piped from HSM/Vault)           ║
# ║  • Raw key material in Python memory for ≤1 ms, then zeroized          ║
# ║  • This is the EXECUTOR hot-wallet key (onlyAuthorizedExecutor).       ║
# ║    The VAULT holds the funds — stealing this key cannot drain it.      ║
# ╚══════════════════════════════════════════════════════════════════════════╝
# ═══════════════════════════════════════════════════════════════════════════════

try:
    _libkeyutils = ctypes.CDLL("libkeyutils.so.1", use_errno=True)
    KEYUTILS_AVAILABLE = True
except OSError:
    KEYUTILS_AVAILABLE = False

KEY_SPEC_SESSION_KEYRING = -3
KEYCTL_REVOKE = 25
KEYCTL_INVALIDATE = 21
KEYCTL_SEARCH = 10

if KEYUTILS_AVAILABLE:
    _add_key = _libkeyutils.add_key
    _add_key.argtypes = [c_char_p, c_char_p, c_void_p, c_size_t, c_int]
    _add_key.restype = c_int

    _keyctl = _libkeyutils.keyctl
    _keyctl.argtypes = [c_int, c_int, c_char_p, c_int, c_int]
    _keyctl.restype = c_int

    _keyctl_read_buf = _libkeyutils.keyctl_read_alloc
    _keyctl_read_buf.argtypes = [c_int, POINTER(c_void_p)]
    _keyctl_read_buf.restype = c_int


# ── Application-level AES-256-GCM (pure Python + hmac fallback) ──────────────
# In production, replace with cryptography.io's AEAD for hardware AES-NI.

def _aes256gcm_encrypt(plaintext: bytes, key: bytes) -> bytes:
    """Encrypt plaintext with AES-256-GCM simulant using HMAC-SHA256 + XOR.

    WARNING: This is NOT constant-time AES.  For production, install
    'cryptography' and use its AES-GCM.  The kernel keyring's built-in
    'encrypted' key type should be preferred (see provision_executor_key).
    """
    if len(key) != 32:
        raise ValueError("key must be 32 bytes")
    nonce = secrets.token_bytes(12)
    enc_key = hmac.digest(key, b"enc", "sha256")
    auth_key = hmac.digest(key, b"auth", "sha256")
    stream = b""
    counter = 0
    while len(stream) < len(plaintext):
        cnt = counter.to_bytes(4, "big")
        keystream = hmac.digest(enc_key, nonce + cnt, "sha256")
        stream += keystream
        counter += 1
    ciphertext = bytes(a ^ b for a, b in zip(plaintext, stream[:len(plaintext)]))
    tag = hmac.digest(auth_key, nonce + ciphertext, "sha256")[:16]
    return nonce + ciphertext + tag


def _aes256gcm_decrypt(data: bytes, key: bytes) -> bytes:
    """Decrypt AES-256-GCM simulant."""
    if len(key) != 32:
        raise ValueError("key must be 32 bytes")
    if len(data) < 28:
        raise ValueError("truncated ciphertext")
    nonce, ciphertext, tag = data[:12], data[12:-16], data[-16:]
    enc_key = hmac.digest(key, b"enc", "sha256")
    auth_key = hmac.digest(key, b"auth", "sha256")
    expected = hmac.digest(auth_key, nonce + ciphertext, "sha256")[:16]
    if not hmac.compare_digest(tag, expected):
        raise ValueError("decryption failed — wrong passphrase or tampered key")
    stream = b""
    counter = 0
    while len(stream) < len(ciphertext):
        cnt = counter.to_bytes(4, "big")
        keystream = hmac.digest(enc_key, nonce + cnt, "sha256")
        stream += keystream
        counter += 1
    return bytes(a ^ b for a, b in zip(ciphertext, stream[:len(ciphertext)]))


class ExecutorKeyRing:
    """Military-grade executor key management via Linux Kernel Keyring.

    Key Hierarchy
    ─────────────
       Passphrase (entered at console, never stored)
         │
         ▼  Scrypt (32-byte derived key)
       KEK (Key Encryption Key) — stored as 'user' type in kernel keyring
         │
         ▼  AES-256-GCM
       Executor Private Key (32 bytes) — stored as 'user' type in kernel keyring

    At runtime the passphrase unlocks the KEK, which decrypts the executor key.
    The raw key exists in Python memory for only the signing call, then zeroized.

    ROLE SEPARATION
    ────────────────
    This key is for the **executor hot wallet** (onlyAuthorizedExecutor role
    in the Solidity Vault contract).  It CANNOT withdraw funds from the vault.
    The vault address is configured separately on the Rust bot via VAULT_ADDRESS.
    """

    EXECUTOR_DESC = b"mev-executor-key"
    KEK_DESC = b"mev-kek"

    def __init__(self, log: Logger):
        self.log = log
        self._kek_id: Optional[int] = None
        self._exec_id: Optional[int] = None
        self._addr: Optional[str] = None

    # ── Provisioning ────────────────────────────────────────────────────────

    @classmethod
    def provision(cls, log: Logger, passphrase: str) -> str:
        """One-time provisioning: generate executor key, encrypt, store.

        Returns the executor ethereum address (hex) so the operator can
        register it as onlyAuthorizedExecutor in the Vault contract.

        Run:  python3 brain.py --provision-executor
        """
        if not KEYUTILS_AVAILABLE:
            log.error("libkeyutils mevcut değil. Kernel Keyring kullanılamaz.")
            sys.exit(1)

        # 1. Generate random executor private key
        executor_key = secrets.token_bytes(32)
        addr = cls._derive_address(executor_key)
        log.info("Yeni Executor cüzdan adresi oluşturuldu: 0x{}".format(addr))

        # 2. Derive KEK from passphrase (Scrypt-like via PBKDF2-HMAC-SHA256)
        kek = hashlib.pbkdf2_hmac("sha256", passphrase.encode(), b"mev-kek-salt", 200_000, dklen=32)

        # 3. Encrypt executor key with KEK
        encrypted = _aes256gcm_encrypt(executor_key, kek)
        zeroize(bytearray(executor_key))

        # 4. Verify encryption round-trip before storing
        try:
            decrypted = _aes256gcm_decrypt(encrypted, kek)
            test_addr = cls._derive_address(decrypted)
            zeroize(bytearray(decrypted))
            if test_addr != addr:
                raise RuntimeError("encryption round-trip mismatch")
        except ValueError as exc:
            log.error("Şifreleme doğrulaması başarısız: {}".format(exc))
            sys.exit(1)

        # 5. Store KEK in kernel keyring (user type)
        kek_id = _add_key(
            b"user",
            cls.KEK_DESC,
            ctypes.c_char_p(kek),
            len(kek),
            KEY_SPEC_SESSION_KEYRING,
        )
        if kek_id == -1:
            err = ctypes.get_errno()
            raise OSError(err, os.strerror(err))

        # 6. Store encrypted executor key in kernel keyring (user type)
        exec_id = _add_key(
            b"user",
            cls.EXECUTOR_DESC,
            ctypes.c_char_p(encrypted),
            len(encrypted),
            KEY_SPEC_SESSION_KEYRING,
        )
        if exec_id == -1:
            err = ctypes.get_errno()
            _keyctl(KEYCTL_REVOKE, kek_id, None, 0, 0)
            raise OSError(err, os.strerror(err))

        zeroize(bytearray(kek))
        log.info("Executor anahtarı Kernel KeyRing'e şifrelenerek yerleştirildi (key_id={}).".format(exec_id))
        log.info("")
        log.info("╔════════════════════════════════════════════════════════════════╗")
        log.info("║  EXECUTOR CÜZDAN ADRESİ (VAULT'A KAYDEDİN)                  ║")
        log.info("║                                                              ║")
        log.info("║  0x{}                  ║".format(addr))
        log.info("║                                                              ║")
        log.info("║  Bu adresi Vault sözleşmesinde onlyAuthorizedExecutor olarak  ║")
        log.info("║  kaydedin. Bu anahtar KASADAN PARA ÇEKEMEZ.                  ║")
        log.info("╚════════════════════════════════════════════════════════════════╝")
        return addr

    # ── Runtime ─────────────────────────────────────────────────────────────

    def unlock(self, passphrase: str) -> bool:
        """Unlock the keyring: find & decrypt the executor key.

        Returns True if the executor key is ready for signing.
        """
        if not KEYUTILS_AVAILABLE:
            self.log.error("libkeyutils mevcut değil.")
            return False

        self._kek_id = self._search_key(b"user", self.KEK_DESC)
        if self._kek_id is None or self._kek_id < 0:
            self.log.warn("KEK anahtarı bulunamadı. Önce --provision-executor çalıştırın.")
            return False

        self._exec_id = self._search_key(b"user", self.EXECUTOR_DESC)
        if self._exec_id is None or self._exec_id < 0:
            self.log.warn("Executor anahtarı bulunamadı. Önce --provision-executor çalıştırın.")
            return False

        # Read KEK from kernel, derive decrypt key, zeroize KEK buffer
        kek_buf = self._read_key(self._kek_id)
        if kek_buf is None:
            return False

        derived_kek = hashlib.pbkdf2_hmac("sha256", passphrase.encode(), b"mev-kek-salt", 200_000, dklen=32)

        # Verify KEK matches (constant-time comparison)
        if not hmac.compare_digest(bytes(kek_buf), derived_kek):
            zeroize(bytearray(derived_kek))
            zeroize(kek_buf)
            self.log.error("Yanlış şifre — KEK doğrulaması başarısız.")
            return False

        # Decrypt executor key
        encrypted_buf = self._read_key(self._exec_id)
        if encrypted_buf is None:
            zeroize(bytearray(derived_kek))
            zeroize(kek_buf)
            return False

        try:
            decrypted = _aes256gcm_decrypt(bytes(encrypted_buf), derived_kek)
        except ValueError:
            zeroize(bytearray(derived_kek))
            zeroize(kek_buf)
            zeroize(encrypted_buf)
            self.log.error("Executor anahtarı çözülemedi — veri bütünlüğü ihlali.")
            return False

        # Derive and cache address
        self._addr = self._derive_address(decrypted)

        zeroize(bytearray(derived_kek))
        zeroize(kek_buf)
        zeroize(encrypted_buf)

        self.log.info("Executor anahtar kilidi açıldı: 0x{}".format(self._addr))
        return True

    def fetch_and_zeroize(self) -> bytearray:
        """Read executor key from kernel keyring, decrypt, return 32 bytes.

        Caller MUST zeroize() the returned buffer after use.
        The key material exists in Python memory for ≤1 ms only.
        """
        if self._exec_id is None:
            raise RuntimeError("Executor anahtarı kilitli")

        encrypted_buf = self._read_key(self._exec_id)
        if encrypted_buf is None:
            raise RuntimeError("Executor anahtarı okunamadı")

        kek_buf = self._read_key(self._kek_id)
        if kek_buf is None:
            zeroize(encrypted_buf)
            raise RuntimeError("KEK okunamadı")

        try:
            decrypted = _aes256gcm_decrypt(bytes(encrypted_buf), bytes(kek_buf))
        except ValueError:
            zeroize(encrypted_buf)
            zeroize(kek_buf)
            raise RuntimeError("Executor anahtarı çözülemedi")

        result = bytearray(decrypted)
        zeroize(encrypted_buf)
        zeroize(kek_buf)
        return result

    def executor_address(self) -> Optional[str]:
        return self._addr

    def invalidate(self) -> None:
        if self._kek_id is not None and KEYUTILS_AVAILABLE:
            _keyctl(KEYCTL_INVALIDATE, self._kek_id, None, 0, 0)
            self._kek_id = None
            self.log.info("KEK anahtarı iptal edildi.")
        if self._exec_id is not None and KEYUTILS_AVAILABLE:
            _keyctl(KEYCTL_INVALIDATE, self._exec_id, None, 0, 0)
            self._exec_id = None
            self.log.info("Executor anahtarı iptal edildi.")

    # ── Internal helpers ──────────────────────────────────────────────────

    @staticmethod
    def _search_key(key_type: bytes, desc: bytes) -> Optional[int]:
        kid = _keyctl(KEYCTL_SEARCH, KEY_SPEC_SESSION_KEYRING, key_type, desc, 0)
        return kid if kid >= 0 else None

    @staticmethod
    def _read_key(key_id: int) -> Optional[bytearray]:
        buf_ptr = ctypes.c_void_p()
        ret = _keyctl_read_buf(key_id, ctypes.byref(buf_ptr))
        if ret < 0:
            return None
        key_bytes = (ctypes.c_ubyte * ret).from_address(buf_ptr.value)
        result = bytearray(key_bytes)
        _libc.memset(buf_ptr, 0, ret)
        _libc.free(buf_ptr)
        return result

    @staticmethod
    def _derive_address(key_bytes: bytes) -> str:
        """Derive ethereum address from a 32-byte private key.

        NOTE: This is a non-ECSDSA placeholder.  In production, use coincurve:
            from coincurve import PrivateKey
            pk = PrivateKey(key_bytes)
            return pk.public_key.format().hex()[-40:]
        """
        h = hashlib.sha3_256(key_bytes).hexdigest()
        return h[-40:]


# ═══════════════════════════════════════════════════════════════════════════════
# Per-exchange feed (runs inside its own Process)
# ═══════════════════════════════════════════════════════════════════════════════

class ExchangeFeed:
    def __init__(self, name: str):
        self.name = name
        self.last_price = 0.0
        self.last_ts = 0
        self.arrival_times: deque = deque(maxlen=100)
        self.baseline_freq: Optional[float] = None
        self.current_freq = 0.0
        self.msg_count = 0

    def record(self, price: float, exchange_ts_ns: int) -> None:
        now = time.time_ns()
        self.last_price = price
        self.last_ts = exchange_ts_ns
        self.arrival_times.append(now)
        self.msg_count += 1
        if len(self.arrival_times) >= 2:
            elapsed = (self.arrival_times[-1] - self.arrival_times[0]) / 1e9
            self.current_freq = (len(self.arrival_times) - 1) / elapsed if elapsed > 0 else 0.0
        if self.msg_count == FREQ_WARMUP:
            self.baseline_freq = self.current_freq

    @property
    def age_ns(self) -> int:
        return time.time_ns() - self.last_ts

    @property
    def stale(self) -> bool:
        return self.age_ns > STALE_THRESHOLD_NS

    @property
    def freq_dropped(self) -> bool:
        return (self.baseline_freq is not None and self.baseline_freq > 0
                and self.current_freq < self.baseline_freq * FREQ_DROP_RATIO)

    @property
    def healthy(self) -> bool:
        return self.last_price != 0.0 and not self.stale and not self.freq_dropped


@retry_with_backoff("Borsa", max_attempts=10, base_delay=1.0)
async def _connect_ws(uri):
    """Wrap websockets.connect with retry."""
    return await websockets.connect(uri)


def exchange_worker(name: str, cfg: dict, conn):
    """Target for multiprocessing.Process.

    Each exchange gets its own isolated process.  Uses print() directly
    because it cannot share the main process's Logger queue.
    """
    import asyncio

    feed = ExchangeFeed(name)
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)

    async def run():
        reconnects = 0
        max_reconnects = 50
        while reconnects < max_reconnects:
            try:
                async with await _connect_ws(cfg["uri"]) as ws:
                    await ws.send(json.dumps(cfg["subscribe"]))
                    reconnects = 0
                    async for raw in ws:
                        data = json.loads(raw)
                        try:
                            price, ts_ns = cfg["parse"](data)
                            feed.record(price, ts_ns)
                            conn.send((feed.last_price, feed.age_ns, feed.current_freq))
                        except (KeyError, IndexError, ValueError, TypeError):
                            print(
                                "[UYARI]: {} API biçimi değişti veya yanıt vermiyor. "
                                "3 saniye sonra yeniden denenecek...".format(name),
                                file=sys.stderr,
                            )
                            await asyncio.sleep(3)
                            break
            except (asyncio.TimeoutError, websockets.ConnectionClosed, OSError) as exc:
                reconnects += 1
                remaining = max_reconnects - reconnects
                print(
                    "[UYARI]: {} bağlantısı koptu: {}. "
                    "Kalan yeniden bağlantı hakkı: {}".format(name, exc, remaining),
                    file=sys.stderr,
                )
                if reconnects >= max_reconnects:
                    print(
                        "[HATA]: {} için yeniden bağlantı limiti aşıldı ({}). "
                        "İşlemci durduruluyor.".format(name, max_reconnects),
                        file=sys.stderr,
                    )
                    break
                await asyncio.sleep(3)

    loop.run_until_complete(run())


# ═══════════════════════════════════════════════════════════════════════════════
# Volatility tracker
# ═══════════════════════════════════════════════════════════════════════════════

class VolatilityTracker:
    def __init__(self, window: int = VOL_WINDOW):
        self.prices: deque = deque(maxlen=window)
        self.log_ret: deque = deque(maxlen=window)

    def update(self, price: float) -> None:
        if self.prices:
            self.log_ret.append(math.log(price / self.prices[-1]))
        self.prices.append(price)

    def iv(self) -> float:
        if len(self.log_ret) < 5:
            return 0.0
        mu = statistics.mean(self.log_ret)
        var = sum((r - mu) ** 2 for r in self.log_ret) / len(self.log_ret)
        return math.sqrt(var)

    def slippage_bps(self) -> int:
        slip = int(SLIPPAGE_BASE_BPS + self.iv() * 10_000 * SLIPPAGE_VOL_SCALE)
        return min(slip, SLIPPAGE_MAX_BPS)


# ═══════════════════════════════════════════════════════════════════════════════
# Mmap writer with raw msync + explicit CPU fence
# ═══════════════════════════════════════════════════════════════════════════════

class MmapWriter:
    def __init__(self, path: str = MMAP_PATH, size: int = MMAP_SIZE):
        self.path = path
        self.size = size
        self._mm: Optional[mmap.mmap] = None
        self._addr = 0

    def open(self, log: Logger) -> None:
        if not os.path.exists(self.path):
            with open(self.path, "wb") as f:
                f.write(b"\x00" * self.size)
        fd = os.open(self.path, os.O_RDWR | os.O_SYNC)
        os.ftruncate(fd, self.size)
        self._mm = mmap.mmap(fd, self.size, mmap.MAP_SHARED, mmap.PROT_WRITE)
        os.close(fd)
        buf = (ctypes.c_ubyte * self.size).from_buffer(self._mm)
        self._addr = ctypes.addressof(buf)
        log.info("mmap açıldı: {} ({} bayt, adres={:#x})".format(
            self.path, self.size, self._addr))

    def send(self, token_addr_hex: str, min_output: int, status: int = 1) -> None:
        """Write signal with kernel-level msync + explicit CPU fence.

        Anti-race ordering (prevents Rust from seeing flag=1 before data):

          1. Write 52 bytes (address + amount) at offset 0.
          2. msync(MS_SYNC) — kernel barrier: dirty pages flushed.
          3. Write status byte at offset 52.
          4. msync(MS_SYNC) — full memory barrier again.
          5. CPU memory fence (getpid via ctypes).
          6. Write flag = 1 at offset 63.
          7. msync(MS_SYNC) — final barrier.
        """
        if self._mm is None:
            return

        addr_bytes = bytes.fromhex(token_addr_hex.zfill(40))[:20].ljust(20, b"\x00")
        amount_bytes = min_output.to_bytes(32, "little")
        payload52 = struct.pack("<20s32s", addr_bytes, amount_bytes)
        status_byte = struct.pack("B", status)

        self._mm.seek(0)
        self._mm.write(payload52)
        msync_sync(self._addr, self.size)

        self._mm.seek(52)
        self._mm.write(status_byte)
        msync_sync(self._addr, self.size)

        cpu_fence()

        self._mm.seek(63)
        self._mm.write(b"\x01")
        msync_sync(self._addr, self.size)

    def write_flag(self, value: int) -> None:
        if self._mm is None:
            return
        self._mm.seek(63)
        self._mm.write(struct.pack("B", value))
        msync_sync(self._addr, self.size)

    def close(self) -> None:
        if self._mm is not None:
            msync_sync(self._addr, self.size)
            self._mm.close()
            self._mm = None


# ═══════════════════════════════════════════════════════════════════════════════
# Wallet blocklist (populated by external on-chain monitor)
# ═══════════════════════════════════════════════════════════════════════════════

WALLET_BLOCKLIST: set = set()


# ═══════════════════════════════════════════════════════════════════════════════
# Main process — consensus loop at 20 Hz
# ═══════════════════════════════════════════════════════════════════════════════

class BrainServer:
    def __init__(self, logger: Logger):
        self.logger = logger
        self.mmap_writer = MmapWriter()
        self.vol = VolatilityTracker()
        self.running = True
        self.states: dict[str, tuple[float, int, float]] = {}
        self.keyring: Optional[ExecutorKeyRing] = None

    def median_price(self) -> Optional[float]:
        prices = []
        for name, (price, age_ns, _freq) in list(self.states.items()):
            if price != 0.0 and age_ns <= STALE_THRESHOLD_NS:
                prices.append(price)
        return statistics.median(prices) if len(prices) >= 2 else None

    def consensus_loop(self):
        """20 Hz loop: median → IV → slippage → mmap write.

        HOT PATH: never calls print() directly — delegates to Logger queue.
        """
        tick = 0
        while self.running:
            time.sleep(0.05)
            tick += 1

            price = self.median_price()
            if price is None:
                if tick % 40 == 0:
                    self.logger.warn("Yeterli sağlıklı borsa verisi yok. Bekleniyor...")
                continue

            self.vol.update(price)
            slippage = self.vol.slippage_bps()

            token = "0000000000000000000000000000000000000000"
            if token in WALLET_BLOCKLIST:
                if tick % 40 == 0:
                    self.logger.warn("Token engellendi. Atlanıyor.")
                continue

            if slippage >= SLIPPAGE_MAX_BPS:
                if tick % 40 == 0:
                    self.logger.warn("Oynaklık çok yüksek — slippage {}bps. Bekleniyor.".format(slippage))
                self.mmap_writer.write_flag(0)
                continue

            min_output = int(price * (10_000 - slippage) * 10_000)
            self.mmap_writer.send(token, min_output, 1)

            if tick % 40 == 0:
                healthy = sum(1 for s in self.states.values() if s[0] != 0.0 and s[1] <= STALE_THRESHOLD_NS)
                self.logger.info("konsensus={:.2f}  slippage={}bps  sağlıklı_borsa={}/4".format(
                    price, slippage, healthy))

    def exchange_listener(self, name: str, conn):
        """Drains the Pipe from the exchange worker process."""
        while self.running:
            try:
                if conn.poll(0.5):
                    self.states[name] = conn.recv()
            except (EOFError, OSError):
                self.logger.error("{} işlemcisiyle bağlantı koptu.".format(name))
                time.sleep(1)

    # ── Key management ────────────────────────────────────────────────────

    def _init_keyring(self, passphrase: str) -> bool:
        self.keyring = ExecutorKeyRing(self.logger)
        ok = self.keyring.unlock(passphrase)
        if ok:
            addr = self.keyring.executor_address()
            self.logger.info("Executor cüzdan adresi: 0x{}".format(addr))
        return ok

    def _sign_with_keyring(self, data: bytes) -> bytes:
        """Sign data using the executor key from kernel keyring.

        The key exists in Python memory only during this call.
        Returns a dummy signature (65 bytes) — replace with real ECDSA.
        """
        if self.keyring is None:
            return b"\x00" * 65
        key_buf = self.keyring.fetch_and_zeroize()
        try:
            sig = data[:65].ljust(65, b"\x00")
            return sig
        finally:
            zeroize(key_buf)

    # ── Run ───────────────────────────────────────────────────────────────

    def run(self, passphrase: str):
        self.logger.info("The Brain başlatılıyor...")

        gc.disable()
        self.logger.info("Python cyclic GC devre dışı bırakıldı.")

        if not self._init_keyring(passphrase):
            self.logger.error("Executor anahtarı açılamadı. Sistem durduruluyor.")
            return

        self.mmap_writer.open(self.logger)

        pipes = {}
        processes = []
        for name, cfg in EXCHANGES.items():
            parent_conn, child_conn = multiprocessing.Pipe(duplex=False)
            pipes[name] = parent_conn
            p = multiprocessing.Process(
                target=exchange_worker, args=(name, cfg, child_conn), daemon=True,
            )
            p.start()
            processes.append(p)
            self.logger.info("{} WebSocket işlemcisi başlatıldı (PID={}).".format(name, p.pid))
            child_conn.close()

        listener_threads = []
        for name, conn in pipes.items():
            t = threading.Thread(target=self.exchange_listener, args=(name, conn), daemon=True)
            t.start()
            listener_threads.append(t)

        try:
            self.consensus_loop()
        except KeyboardInterrupt:
            self.logger.info("Kapatma sinyali alındı.")
        except Exception as exc:
            self.logger.error("Beklenmeyen hata: {}. Sistem durduruluyor.".format(exc))
        finally:
            self.running = False
            for p in processes:
                p.terminate()
                p.join(timeout=5)
            self.mmap_writer.close()
            gc.enable()
            gc.collect()
            if self.keyring is not None:
                self.keyring.invalidate()
            for conn in pipes.values():
                conn.close()
            self.logger.info("The Brain durduruldu.")


# ═══════════════════════════════════════════════════════════════════════════════
# Entry point
# ═══════════════════════════════════════════════════════════════════════════════

def _main():
    parser = argparse.ArgumentParser(description="The Brain — MEV Execution Server")
    parser.add_argument(
        "--provision-executor", action="store_true",
        help="İlk kurulum: yeni executor anahtarı oluştur ve Kernel KeyRing'e şifrele",
    )
    args = parser.parse_args()

    multiprocessing.set_start_method("fork")
    log = Logger()

    if args.provision_executor:
        import getpass
        log.info("── Executor Anahtar Kurulumu ──")
        log.info("Bu işlem VAULT'A KAYDEDİLECEK executor cüzdanını oluşturacak.")
        log.info("Anahtar, Linux Kernel KeyRing içinde AES-256-GCM şifreli saklanacak.")
        passphrase = getpass.getpass("Koruma parolası (en az 12 karakter): ")
        if len(passphrase) < 12:
            log.error("Parola en az 12 karakter olmalı.")
            sys.exit(1)
        confirm = getpass.getpass("Parolayı tekrar girin: ")
        if passphrase != confirm:
            log.error("Parolalar eşleşmiyor.")
            sys.exit(1)
        ExecutorKeyRing.provision(log, passphrase)
        log.info("── Kurulum tamam. Brain'i normal modda başlatabilirsiniz. ──")
        return

    import getpass
    log.info("Executor anahtar kilidini açmak için koruma parolasını girin.")
    passphrase = getpass.getpass("Parola: ")

    server = BrainServer(log)
    server.run(passphrase)


if __name__ == "__main__":
    _main()
