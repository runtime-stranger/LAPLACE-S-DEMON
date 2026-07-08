use futures::future::join_all;
use serde::Serialize;
use secp256k1::{Secp256k1, SecretKey, Message};
use sha3::{Keccak256, Digest};
use std::time::Duration;

#[derive(Clone, Debug)]
pub struct RelayEndpoint {
    pub name: &'static str,
    pub url: String,
}

#[derive(Serialize)]
struct BundleParams {
    txs: Vec<String>,
    #[serde(rename = "blockNumber")]
    block_number: String,
    #[serde(rename = "maxBlock", skip_serializing_if = "Option::is_none")]
    max_block: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    minTimestamp: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    maxTimestamp: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    revertingTxHashes: Option<Vec<String>>,
}

#[derive(Serialize)]
struct JsonRpcRequest {
    jsonrpc: String,
    method: String,
    id: u64,
    params: Vec<BundleParams>,
}

#[derive(Debug)]
pub struct BroadcastResult {
    pub relay: String,
    pub success: bool,
    pub latency_ms: u64,
    pub error: Option<String>,
}

#[derive(Clone)]
pub struct FlashbotsSigner {
    pub address: [u8; 20],
    key: [u8; 32],
}

impl FlashbotsSigner {
    pub fn from_key(key: [u8; 32]) -> Self {
        let secp = Secp256k1::new();
        let sk = SecretKey::from_slice(&key).expect("valid key");
        let pk = secp256k1::PublicKey::from_secret_key(&secp, &sk);
        let encoded = pk.serialize_uncompressed();
        let hash = Keccak256::digest(&encoded[1..]);
        let mut address = [0u8; 20];
        address.copy_from_slice(&hash[12..]);
        FlashbotsSigner { address, key }
    }

    fn sign(&self, body: &[u8]) -> String {
        let secp = Secp256k1::new();
        let hash = Keccak256::digest(body);
        let msg = Message::from_slice(&hash).expect("32 bytes");
        let sk = SecretKey::from_slice(&self.key).expect("valid key");
        let (sig, rec_id) = secp.sign_ecdsa_recoverable(&msg, &sk);
        let compact = sig.serialize_compact();
        let rec_byte = rec_id.to_i32() as u8;
        let v = 27 + rec_byte;

        let mut raw = Vec::with_capacity(65);
        raw.extend_from_slice(&compact[..32]);
        raw.extend_from_slice(&compact[32..]);
        raw.push(v);
        hex::encode(raw)
    }

    pub fn auth_header(&self, body: &[u8]) -> String {
        let sig = self.sign(body);
        format!("0x{}:0x{}", hex::encode(self.address), sig)
    }
}

pub struct MultiRelayBroadcaster {
    relays: Vec<RelayEndpoint>,
    client: reqwest::Client,
    timeout: Duration,
    signer: Option<FlashbotsSigner>,
}

impl MultiRelayBroadcaster {
    pub fn new(relays: Vec<RelayEndpoint>) -> Self {
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(10))
            .build()
            .expect("reqwest Client");

        MultiRelayBroadcaster {
            relays,
            client,
            timeout: Duration::from_secs(5),
            signer: None,
        }
    }

    pub fn with_signer(mut self, signer: FlashbotsSigner) -> Self {
        self.signer = Some(signer);
        self
    }

    pub fn relay_count(&self) -> usize {
        self.relays.len()
    }

    pub async fn broadcast(
        &self,
        signed_tx_hex: &str,
        target_block: u64,
        max_block: u64,
    ) -> Vec<BroadcastResult> {
        let bundle = BundleParams {
            txs: vec![signed_tx_hex.to_string()],
            block_number: format!("0x{:x}", target_block),
            max_block: Some(format!("0x{:x}", max_block)),
            minTimestamp: None,
            maxTimestamp: None,
            revertingTxHashes: Some(Vec::new()),
        };

        let tasks: Vec<_> = self
            .relays
            .iter()
            .map(|relay| {
                let client = self.client.clone();
                let url = relay.url.clone();
                let name = relay.name;
                let body = JsonRpcRequest {
                    jsonrpc: "2.0".into(),
                    method: "eth_sendBundle".into(),
                    id: 1,
                    params: vec![BundleParams {
                        txs: bundle.txs.clone(),
                        block_number: bundle.block_number.clone(),
                        max_block: bundle.max_block.clone(),
                        minTimestamp: None,
                        maxTimestamp: None,
                        revertingTxHashes: Some(Vec::new()),
                    }],
                };
                let body_bytes = serde_json::to_vec(&body).expect("JSON");
                let timeout = self.timeout;
                let auth = self.signer.as_ref().map(|s| s.auth_header(&body_bytes));

                tokio::spawn(async move {
                    let start = std::time::Instant::now();

                    let mut req = client.post(&url).body(body_bytes.clone());
                    if let Some(hdr) = &auth {
                        req = req.header("X-Flashbots-Signature", hdr);
                    }

                    let result = tokio::time::timeout(timeout, async {
                        req.send().await
                    })
                    .await;

                    let elapsed = start.elapsed().as_millis() as u64;

                    match result {
                        Ok(Ok(resp)) => {
                            let status = resp.status();
                            if status.is_success() {
                                BroadcastResult {
                                    relay: name.to_string(),
                                    success: true,
                                    latency_ms: elapsed,
                                    error: None,
                                }
                            } else {
                                BroadcastResult {
                                    relay: name.to_string(),
                                    success: false,
                                    latency_ms: elapsed,
                                    error: Some(format!("HTTP {}", status)),
                                }
                            }
                        }
                        Ok(Err(e)) => BroadcastResult {
                            relay: name.to_string(),
                            success: false,
                            latency_ms: elapsed,
                            error: Some(e.to_string()),
                        },
                        Err(_) => BroadcastResult {
                            relay: name.to_string(),
                            success: false,
                            latency_ms: elapsed,
                            error: Some("timeout".into()),
                        },
                    }
                })
            })
            .collect();

        join_all(tasks)
            .await
            .into_iter()
            .map(|r| r.unwrap_or_else(|_| BroadcastResult {
                relay: "unknown".into(),
                success: false,
                latency_ms: 0,
                error: Some("task panic".into()),
            }))
            .collect()
    }

    pub fn default_relays() -> Vec<RelayEndpoint> {
        vec![
            RelayEndpoint {
                name: "Flashbots",
                url: "https://relay.flashbots.net".into(),
            },
            RelayEndpoint {
                name: "Builder0x69",
                url: "https://builder0x69.io".into(),
            },
            RelayEndpoint {
                name: "BeaverBuild",
                url: "https://rpc.beaverbuild.org".into(),
            },
            RelayEndpoint {
                name: "Titan",
                url: "https://rpc.titanbuilder.xyz".into(),
            },
            RelayEndpoint {
                name: "Eden",
                url: "https://rpc.edennetwork.io".into(),
            },
            RelayEndpoint {
                name: "Rsync",
                url: "https://rsync-builder.xyz".into(),
            },
        ]
    }
}
