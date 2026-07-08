use core_affinity::CoreId;
use memmap2::MmapMut;
use sha3::{Keccak256, Digest};
use rlp::RlpStream;
use secp256k1::{Secp256k1, SecretKey, Message};
use secp256k1::ecdsa::{RecoverableSignature, RecoveryId};
use std::mem;
use std::ptr::{read_volatile, write_volatile};
use std::sync::atomic::{compiler_fence, Ordering};
use std::sync::mpsc;
use std::sync::Arc;
use std::time::Duration;

mod nonce_manager;
mod broadcaster;

use nonce_manager::NonceManager;
use broadcaster::MultiRelayBroadcaster;

// ═══════════════════════════════════════════════════════════════════
// Async Logger — channel-based log collector
//   All log messages are sent through an mpsc channel to a dedicated
//   background thread.  The hot path NEVER calls eprintln! directly.
// ═══════════════════════════════════════════════════════════════════

#[derive(Clone)]
struct Logger {
    tx: mpsc::Sender<String>,
}

impl Logger {
    fn new() -> (Self, std::thread::JoinHandle<()>) {
        let (tx, rx) = mpsc::channel::<String>();
        let handle = std::thread::Builder::new()
            .name("log-writer".into())
            .spawn(move || {
                for msg in rx {
                    eprintln!("{}", msg);
                }
            })
            .expect("log-writer thread");
        (Logger { tx }, handle)
    }

    fn info(&self, msg: impl std::fmt::Display) {
        let _ = self.tx.send(format!("[BİLGİ] {}", msg));
    }

    fn warn(&self, msg: impl std::fmt::Display) {
        let _ = self.tx.send(format!("[UYARI] {}", msg));
    }

    fn error(&self, msg: impl std::fmt::Display) {
        let _ = self.tx.send(format!("[HATA] {}", msg));
    }
}

// Retry helper — exponential backoff (1, 2, 4, 8… s, capped at 30)
async fn retry<F, Fut, T>(log: &Logger, label: &str, max_attempts: u32, f: F) -> Option<T>
where
    F: Fn() -> Fut,
    Fut: std::future::Future<Output = Option<T>>,
{
    for attempt in 1..=max_attempts {
        match f().await {
            Some(val) => return Some(val),
            None => {
                if attempt < max_attempts {
                    let delay = Duration::from_secs(1u64 << (attempt - 1)).min(Duration::from_secs(30));
                    log.warn(format_args!("{} başarısız (deneme {}/{}) {} saniye sonra yeniden...",
                        label, attempt, max_attempts, delay.as_secs()));
                    tokio::time::sleep(delay).await;
                } else {
                    log.error(format_args!("{} tamamen başarısız ({} deneme).", label, max_attempts));
                }
            }
        }
    }
    None
}

// ═══════════════════════════════════════════════════════════════════
// Shared memory protocol (64-byte cache line)
// ═══════════════════════════════════════════════════════════════════
#[repr(C, align(64))]
pub struct MempoolBlock {
    pub data: [u8; 63],
    pub flag: u8,
}

const _: () = assert!(mem::size_of::<MempoolBlock>() == 64);

#[derive(Clone, Debug)]
pub struct Opportunity {
    pub token: [u8; 20],
    pub min_output: [u8; 32],
    pub status: u8,
}

impl Opportunity {
    fn from_mmap(data: &[u8; 63]) -> Self {
        let mut token = [0u8; 20];
        let mut min_output = [0u8; 32];
        token.copy_from_slice(&data[0..20]);
        min_output.copy_from_slice(&data[20..52]);
        Opportunity {
            token,
            min_output,
            status: data[52],
        }
    }
}

// ═══════════════════════════════════════════════════════════════════
// ABI encoding helpers — executeSwap selector + params
// ═══════════════════════════════════════════════════════════════════
fn selector_execute_swap() -> [u8; 4] {
    let hash = Keccak256::digest(b"executeSwap(address,uint256,uint256,uint256,uint256,address,bytes,bytes)");
    let mut sel = [0u8; 4];
    sel.copy_from_slice(&hash[0..4]);
    sel
}

fn abi_encode(sel: &[u8; 4], token: &[u8; 20], amount_in: &[u8; 32],
              min_output: &[u8; 32], nonce: u64, deadline: u64,
              router: &[u8; 20], signature: &[u8], swap_data: &[u8]) -> Vec<u8>
{
    let head_size: u64 = 4 + 8 * 32;

    let sig_offset: u64 = head_size;
    let swap_data_offset: u64 = head_size + 32 + pad_len(signature.len()) as u64;

    let cap = head_size as usize + 64 + swap_data.len() + signature.len();
    let mut out = Vec::with_capacity(cap);
    out.extend_from_slice(&sel[..]);

    abi_push_addr(&mut out, token);
    abi_push_u256(&mut out, amount_in);
    abi_push_u256(&mut out, min_output);
    abi_push_u64(&mut out, nonce);
    abi_push_u64(&mut out, deadline);
    abi_push_addr(&mut out, router);
    abi_push_u64(&mut out, sig_offset);
    abi_push_u64(&mut out, swap_data_offset);
    abi_push_bytes(&mut out, signature);
    abi_push_bytes(&mut out, swap_data);
    out
}

fn pad_len(len: usize) -> usize {
    if len % 32 == 0 { len } else { ((len / 32) + 1) * 32 }
}

fn abi_push_addr(buf: &mut Vec<u8>, addr: &[u8; 20]) {
    buf.extend_from_slice(&[0u8; 12]);
    buf.extend_from_slice(addr);
}

fn abi_push_u256(buf: &mut Vec<u8>, val: &[u8; 32]) {
    buf.extend_from_slice(val);
}

fn abi_push_u64(buf: &mut Vec<u8>, val: u64) {
    let mut be = [0u8; 32];
    be[24..].copy_from_slice(&val.to_be_bytes());
    buf.extend_from_slice(&be);
}

fn abi_push_bytes(buf: &mut Vec<u8>, data: &[u8]) {
    let mut len_be = [0u8; 32];
    len_be[24..].copy_from_slice(&(data.len() as u64).to_be_bytes());
    buf.extend_from_slice(&len_be);
    buf.extend_from_slice(data);
    let rem = pad_len(data.len()) - data.len();
    buf.extend_from_slice(&vec![0u8; rem]);
}

// ═══════════════════════════════════════════════════════════════════
// ECDSA signing + RLP encoding → signed raw tx hex
// ═══════════════════════════════════════════════════════════════════
fn build_and_sign(vault: &[u8; 20], calldata: &[u8],
                  nonce: u64, gas_price: u64, gas_limit: u64,
                  chain_id: u64, key: &[u8; 32]) -> Result<String, String>
{
    let secp = Secp256k1::new();
    let secret_key = SecretKey::from_slice(key)
        .map_err(|_| "[HATA] Geçersiz gizli anahtar (32 bayt bekleniyor).".to_string())?;

    let mut stream = RlpStream::new_list(9);
    stream.append(&nonce);
    stream.append(&gas_price);
    stream.append(&gas_limit);
    stream.append(&vault[..]);
    stream.append(&0u64);
    stream.append(&calldata[..]);
    stream.append(&chain_id);
    stream.append(&0u64);
    stream.append(&0u64);

    let unsigned_rlp = stream.out().to_vec();

    let hash = Keccak256::digest(&unsigned_rlp);
    let msg = Message::from_slice(&hash)
        .map_err(|_| "[HATA] Mesaj hash'i geçersiz.".to_string())?;
    let (sig, rec_id): (RecoverableSignature, RecoveryId) =
        secp.sign_ecdsa_recoverable(&msg, &secret_key);
    let compact = sig.serialize_compact();
    let rec_byte = rec_id.to_i32() as u8;

    let v = chain_id * 2 + 35 + rec_byte as u64;
    let mut r = [0u8; 32];
    let mut s = [0u8; 32];
    r.copy_from_slice(&compact[..32]);
    s.copy_from_slice(&compact[32..]);

    let mut signed = RlpStream::new_list(9);
    signed.append(&nonce);
    signed.append(&gas_price);
    signed.append(&gas_limit);
    signed.append(&vault[..]);
    signed.append(&0u64);
    signed.append(&calldata[..]);
    signed.append(&v);
    signed.append(&r[..]);
    signed.append(&s[..]);

    Ok(format!("0x{}", hex::encode(signed.out().to_vec())))
}

// ═══════════════════════════════════════════════════════════════════
// Processing pipeline (runs inside tokio runtime on separate thread)
// ═══════════════════════════════════════════════════════════════════
async fn process_opportunity(
    opp: Opportunity,
    nonce_mgr: &NonceManager,
    broadcaster: &MultiRelayBroadcaster,
    vault: &[u8; 20],
    chain_id: u64,
    gas_price: u64,
    target_block: u64,
    log: &Logger,
) {
    let (wallet_idx, nonce, key) = match nonce_mgr.next_nonce().await {
        Some(v) => v,
        None => {
            log.warn("Tüm cüzdanlar meşgul, fırsat kaçırıldı.");
            return;
        }
    };

    let deadline = 1_800_000_000u64 + 30;
    let mut amount_in = [0u8; 32];
    amount_in[31] = 1;

    let swap_data = Vec::new();
    let signature = Vec::new();

    let calldata = abi_encode(
        &selector_execute_swap(),
        &opp.token,
        &amount_in,
        &opp.min_output,
        nonce,
        deadline,
        &[0u8; 20],
        &signature,
        &swap_data,
    );

    let signed_tx = match build_and_sign(
        vault, &calldata, nonce, gas_price, 300_000, chain_id, &key,
    ) {
        Ok(tx) => tx,
        Err(e) => {
            log.error(format_args!("{} İmzalama başarısız, fırsat kaçırıldı.", e));
            return;
        }
    };

    let max_retries = 3;
    let mut any_ok = false;
    for attempt in 1..=max_retries {
        let results = broadcaster.broadcast(&signed_tx, target_block, target_block + 5).await;
        any_ok = results.iter().any(|r| r.success);

        if any_ok {
            log.info(format_args!("Fırsat başarıyla yayınlandı (deneme {}).", attempt));
            nonce_mgr.mark_confirmed(wallet_idx, nonce).await;
            break;
        }

        if attempt < max_retries {
            let delay = 2u64.pow(attempt - 1);
            let fail_details: Vec<&str> = results.iter()
                .filter_map(|r| r.error.as_deref())
                .collect();
            log.warn(format_args!("Yayın başarısız (deneme {}/{}): {}. {} saniye sonra yeniden...",
                attempt, max_retries, fail_details.join(", "), delay));
            tokio::time::sleep(Duration::from_secs(delay)).await;
        } else {
            log.error(format_args!("Yayın {} denemede de başarısız. İşlem atlanıyor.", max_retries));
        }
    }

    tokio::time::sleep(Duration::from_secs(12)).await;
    nonce_mgr.recover(wallet_idx).await;
}

fn load_keys(log: &Logger) -> Vec<[u8; 32]> {
    let mut keys = Vec::new();
    for i in 1..=8 {
        let var = format!("PRIVATE_KEY_{}", i);
        if let Ok(hex_str) = std::env::var(&var) {
            let hex_str = hex_str.strip_prefix("0x").unwrap_or(&hex_str);
            if let Ok(bytes) = hex::decode(hex_str) {
                if bytes.len() == 32 {
                    let mut key = [0u8; 32];
                    key.copy_from_slice(&bytes);
                    keys.push(key);
                    log.info(format_args!("Cüzdan {} yüklendi: 0x{}..{}",
                        i, &hex_str[..4], &hex_str[hex_str.len()-4..]));
                }
            }
        }
    }
    if keys.is_empty() {
        log.error("En az bir PRIVATE_KEY_N ortam değişkeni gerekli");
        std::process::exit(1);
    }
    keys
}

fn hex_to_bytes(s: &str) -> Result<[u8; 20], String> {
    let s = s.strip_prefix("0x").unwrap_or(s);
    let bytes = hex::decode(s).map_err(|_| format!("[HATA] Geçersiz hex: {}", s))?;
    if bytes.len() != 20 {
        return Err(format!("[HATA] Hex 20 bayt olmalı, {} bayt var.", bytes.len()));
    }
    let mut out = [u8; 20];
    out.copy_from_slice(&bytes);
    Ok(out)
}

// ═══════════════════════════════════════════════════════════════════
// Entry point — HOT PATH on core 1, async pipeline on separate thread
// ═══════════════════════════════════════════════════════════════════
fn main() -> Result<(), Box<dyn std::error::Error>> {
    // ── Panic hook: replace raw panic output with clean Turkish message ───
    std::panic::set_hook(Box::new(|_info| {
        use std::io::Write;
        let _ = writeln!(
            std::io::stderr(),
            "[HATA]: Sistem beklenmeyen bir iç hata aldı, otomatik kurtarma döngüsü başlatılıyor..."
        );
    }));

    // ── Logger init (BEFORE any other operation) ─────────────────────────
    let (logger, _log_handle) = Logger::new();

    // ── Core pinning (Core ID 1 = 2nd CPU) ──────────────────────────────────
    let core = CoreId { id: 1 };
    if !core_affinity::set_for_current(core) {
        logger.error("2. çekirdeğe çivilenemedi.");
        std::process::exit(1);
    }
    logger.info("Tetikçi core 1'e (2. CPU) çivilendi.");

    // ── Config ──────────────────────────────────────────────────────────────
    let vault_addr_str = std::env::var("VAULT_ADDRESS")
        .unwrap_or_else(|_| {
            logger.error("VAULT_ADDRESS ortam değişkeni gerekli");
            std::process::exit(1);
        });
    let vault: [u8; 20] = match hex_to_bytes(&vault_addr_str) {
        Ok(v) => v,
        Err(e) => {
            logger.error(e);
            std::process::exit(1);
        }
    };
    let chain_id: u64 = std::env::var("CHAIN_ID")
        .unwrap_or_else(|_| "1".into())
        .parse()
        .unwrap_or_else(|e| {
            logger.error(format_args!("Geçersiz CHAIN_ID: {}", e));
            std::process::exit(1);
        });
    let rpc_url: String = std::env::var("RPC_URL")
        .unwrap_or_else(|_| "http://localhost:8545".into());
    let gas_price: u64 = std::env::var("GAS_PRICE")
        .unwrap_or_else(|_| "42000000000".into())
        .parse()
        .unwrap_or_else(|e| {
            logger.error(format_args!("Geçersiz GAS_PRICE: {}", e));
            std::process::exit(1);
        });
    let relay_urls: Vec<String> = std::env::var("MEV_RELAYS")
        .unwrap_or_default()
        .split(',')
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string())
        .collect();
    let searcher_key_hex: Option<String> = std::env::var("SEARCHER_KEY").ok();

    // ── Channel: hot path → async pipeline ─────────────────────────────────
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<Opportunity>();

    // ── Async pipeline thread ───────────────────────────────────────────────
    let keys = load_keys(&logger);
    let pipeline_logger = logger.clone();
    std::thread::spawn(move || {
        let rt = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .unwrap_or_else(|e| {
                pipeline_logger.error(format_args!("Tokio runtime başlatılamadı: {}", e));
                std::process::exit(1);
            });

        rt.block_on(async {
            let nonce_mgr = Arc::new(NonceManager::new(keys, &rpc_url));
            let mut broadcaster = if relay_urls.is_empty() {
                MultiRelayBroadcaster::new(MultiRelayBroadcaster::default_relays())
            } else {
                let relays = relay_urls.into_iter().map(|url| {
                    broadcaster::RelayEndpoint { name: "custom", url }
                }).collect();
                MultiRelayBroadcaster::new(relays)
            };

            if let Some(ref hex_key) = searcher_key_hex {
                let stripped = hex_key.strip_prefix("0x").unwrap_or(hex_key);
                if let Ok(bytes) = hex::decode(stripped) {
                    if bytes.len() == 32 {
                        let mut key = [0u8; 32];
                        key.copy_from_slice(&bytes);
                        let signer = broadcaster::FlashbotsSigner::from_key(key);
                        broadcaster = broadcaster.with_signer(signer);
                        pipeline_logger.info(format_args!("Flashbots imzalayıcı aktif: 0x{}..{}",
                            &hex::encode(&signer.address[..4]),
                            &hex::encode(&signer.address[16..])));
                    }
                }
            }

            let broadcaster = Arc::new(broadcaster);

            for i in 0..nonce_mgr.wallet_count() {
                nonce_mgr.recover(i).await;
                pipeline_logger.info(format_args!("Cüzdan {} başlangıç nonce: {:?}",
                    i + 1, nonce_mgr.address(i)));
            }

            let current_block: u64 = 0;

            while let Some(opp) = rx.recv().await {
                let nm = nonce_mgr.clone();
                let bc = broadcaster.clone();
                let log = pipeline_logger.clone();
                tokio::spawn(async move {
                    process_opportunity(opp, &nm, &bc, &vault, chain_id, gas_price, current_block + 1, &log).await;
                });
            }
        });
    });

    // ── mmap setup ──────────────────────────────────────────────────────────
    let mmap_path = "/dev/shm/mempool_bridge.bin";
    let file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .open(mmap_path)?;
    file.set_len(64)?;

    let mmap = MmapMut::map(&file)?;
    let base_mut: *mut u8 = mmap.as_mut_ptr();
    let base_const: *const u8 = mmap.as_ptr();
    let flag_read: *const u8 = unsafe { base_const.add(63) };
    let flag_write: *mut u8 = unsafe { base_mut.add(63) };
    let heartbeat: *mut u8 = unsafe { base_mut.add(61) };
    unsafe { write_volatile(heartbeat, 0); }

    logger.info(format_args!("mmap: {:p}, flag@63, heartbeat@61, bekleniyor...", base_const));

    // ── HOT PATH (NO DIRECT I/O) ────────────────────────────────────────────
    loop {
        // Symmetric compiler barriers prevent the compiler from hoisting
        // read_volatile/write_volatile outside the loop (zero-jitter guarantee).
        compiler_fence(Ordering::SeqCst);
        let flag: u8 = unsafe { read_volatile(flag_read) };

        #[cfg(target_arch = "x86_64")]
        unsafe { std::arch::asm!("lfence", options(nostack, preserves_flags)); }

        compiler_fence(Ordering::SeqCst);

        if flag != 0 {
            let block: &MempoolBlock = unsafe { &*(base_const as *const MempoolBlock) };
            let opp = Opportunity::from_mmap(&block.data);

            if tx.send(opp).is_err() {
                break;
            }

            unsafe { write_volatile(flag_write, 0); }
            compiler_fence(Ordering::SeqCst);
        }

        // Heartbeat — tell the watchdog we're alive (volatile, zero-jitter)
        unsafe {
            let hb = read_volatile(heartbeat);
            write_volatile(heartbeat, hb.wrapping_add(1));
        }

        std::hint::spin_loop();
    }

    Ok(())
}
