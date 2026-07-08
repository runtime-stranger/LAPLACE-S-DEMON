use secp256k1::{Secp256k1, SecretKey, PublicKey};
use sha3::{Keccak256, Digest};
use std::collections::BTreeSet;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::Instant;

const MAX_WALLETS: usize = 8;

fn derive_address(key: &[u8; 32]) -> [u8; 20] {
    let secp = Secp256k1::new();
    let sk = SecretKey::from_slice(key).expect("valid key");
    let pk = PublicKey::from_secret_key(&secp, &sk);
    let encoded = pk.serialize_uncompressed();
    let hash = Keccak256::digest(&encoded[1..]);
    let mut addr = [0u8; 20];
    addr.copy_from_slice(&hash[12..]);
    addr
}

struct PerWallet {
    nonce: AtomicU64,
    max_sent: AtomicU64,
    stuck: AtomicBool,
    recovering: AtomicBool,
    in_flight: tokio::sync::RwLock<BTreeSet<u64>>,
    stuck_since: Mutex<Option<Instant>>,
    address: [u8; 20],
    key: [u8; 32],
}

pub struct NonceManager {
    wallets: Vec<PerWallet>,
    round_robin: AtomicU64,
    rpc_url: String,
    client: reqwest::Client,
}

impl NonceManager {
    pub fn new(keys: Vec<[u8; 32]>, rpc_url: &str) -> Self {
        assert!(!keys.is_empty(), "en az bir cüzdan anahtari gerekli");
        assert!(keys.len() <= MAX_WALLETS, "en fazla {}", MAX_WALLETS);

        let wallets = keys.into_iter().map(|key| {
            let address = derive_address(&key);
            PerWallet {
                nonce: AtomicU64::new(0),
                max_sent: AtomicU64::new(0),
                stuck: AtomicBool::new(false),
                recovering: AtomicBool::new(false),
                in_flight: tokio::sync::RwLock::new(BTreeSet::new()),
                stuck_since: Mutex::new(None),
                address,
                key,
            }
        }).collect();

        NonceManager {
            wallets,
            round_robin: AtomicU64::new(0),
            rpc_url: rpc_url.to_string(),
            client: reqwest::Client::new(),
        }
    }

    pub fn wallet_count(&self) -> usize {
        self.wallets.len()
    }

    pub fn address(&self, idx: usize) -> &[u8; 20] {
        &self.wallets[idx].address
    }

    pub fn stuck(&self, idx: usize) -> bool {
        self.wallets[idx].stuck.load(Ordering::Acquire)
    }

    pub fn recovering(&self, idx: usize) -> bool {
        self.wallets[idx].recovering.load(Ordering::Acquire)
    }

    pub async fn next_nonce(&self) -> Option<(usize, u64, [u8; 32])> {
        let n = self.wallets.len();
        let start = self.round_robin.fetch_add(1, Ordering::AcqRel) as usize % n;

        for offset in 0..n {
            let idx = (start + offset) % n;
            let w = &self.wallets[idx];

            if w.stuck.load(Ordering::Acquire) || w.recovering.load(Ordering::Acquire) {
                continue;
            }

            let nonce = w.nonce.fetch_add(1, Ordering::AcqRel);
            w.max_sent.fetch_max(nonce, Ordering::Release);
            w.in_flight.write().await.insert(nonce);

            return Some((idx, nonce, w.key));
        }

        None
    }

    pub async fn mark_confirmed(&self, idx: usize, nonce: u64) {
        self.wallets[idx].in_flight.write().await.remove(&nonce);
    }

    pub async fn recover(&self, idx: usize) {
        let w = &self.wallets[idx];

        if w.recovering.swap(true, Ordering::AcqRel) {
            return;
        }

        let chain_nonce = match self.rpc_pending_nonce(&w.address).await {
            Some(n) => n,
            None => {
                w.recovering.store(false, Ordering::Release);
                return;
            }
        };

        let mut in_flight = w.in_flight.write().await;
        in_flight.retain(|&n| n >= chain_nonce);

        let max_sent = w.max_sent.load(Ordering::Acquire);
        let min_in_flight = in_flight.iter().next().copied();

        // ── Mutabakat Algoritmasi ───────────────────────────────────────────
        // 1) in_flight bos: tum islemler onaylanmis veya mempool'da goruluyor
        //    → local_nonce = chain_nonce, stuck = false
        //
        // 2) in_flight dolu VE chain_nonce > max_sent:
        //    Tum gonderdigimiz nonce'lar zincir tarafindan sayiliyor (mempool)
        //    → local_nonce = chain_nonce, stuck = false
        //
        // 3) in_flight dolu VE chain_nonce <= max_sent:
        //    Zincir, bizim gonderdigimiz nonce'lari GORMUYOR.
        //    En eski in_flight nonce (== min_in_flight) frontier'da takili.
        //    → local_nonce = chain_nonce (takili nonce'i replace et)
        //    → stuck = true (yedek cuzdan devralsin)
        // ─────────────────────────────────────────────────────────────────────

        let stuck = match min_in_flight {
            Some(oldest) if in_flight.len() > 0 && chain_nonce <= max_sent => {
                oldest == chain_nonce
            }
            _ => false,
        };

        if stuck {
            let is_confirmed = {
                let guard = w.stuck_since.lock().unwrap();
                guard
                    .map(|t| t.elapsed() > std::time::Duration::from_secs(12))
                    .unwrap_or(false)
            };

            if is_confirmed {
                w.nonce.store(chain_nonce, Ordering::Release);
                w.stuck.store(true, Ordering::Release);
            } else {
                w.nonce.store(chain_nonce, Ordering::Release);
                w.stuck.store(false, Ordering::Release);
                *w.stuck_since.lock().unwrap() = Some(Instant::now());
            }
        } else {
            w.nonce.store(chain_nonce, Ordering::Release);
            w.stuck.store(false, Ordering::Release);
            *w.stuck_since.lock().unwrap() = None;
        }

        drop(in_flight);
        w.recovering.store(false, Ordering::Release);
    }

    async fn rpc_pending_nonce(&self, addr: &[u8; 20]) -> Option<u64> {
        let addr_hex = format!("0x{}", hex::encode(addr));
        let body = serde_json::json!({
            "jsonrpc": "2.0",
            "method": "eth_getTransactionCount",
            "params": [addr_hex, "pending"],
            "id": 1
        });

        let resp = self
            .client
            .post(&self.rpc_url)
            .json(&body)
            .send()
            .await
            .ok()?;

        let val: serde_json::Value = resp.json().await.ok()?;
        let hex_str = val["result"].as_str()?;
        let stripped = hex_str.strip_prefix("0x").unwrap_or(hex_str);
        u64::from_str_radix(stripped, 16).ok()
    }
}
