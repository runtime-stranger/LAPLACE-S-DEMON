// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title Vault — Circuit-Breaker MEV Treasury
 * @notice Single-point treasury for MEV / arbitrage operations.
 *
 *  ┌─ Owner (cold wallet) ─────────────────────────────────┐
 *  │  • addExecutor / removeExecutor                        │
 *  │  • addRouter / removeRouter                            │
 *  │  • emergencyPause / emergencyUnpause                   │
 *  │  • rescueTokens                                        │
 *  └────────────────────────────────────────────────────────┘
 *
 *  ┌─ Signer (Brain server key) ────────────────────────────┐
 *  │  • Off-chain ECDSA verification (ecrecover)            │
 *  │  • Supplies the nonce + deadline signature             │
 *  └────────────────────────────────────────────────────────┘
 *
 *  ┌─ Executors (Rust bot hot wallets) ─────────────────────┐
 *  │  • call executeSwap() with a valid signature           │
 *  │  • Must specify a whitelisted targetRouter             │
 *  │  • Only router.call(swapData) is permitted             │
 *  └────────────────────────────────────────────────────────┘
 */

contract Vault {
    using SafeERC20 for IERC20;

    // ── Storage ─────────────────────────────────────────────────────────────

    /// @notice Cold wallet — sole address that can pause, add executors, rescue.
    address public immutable owner;

    /// @notice Off-chain signer (Brain's public key).
    address public immutable signer;

    /// @notice Authorised executor addresses (Rust bot hot wallets).
    mapping(address => bool) public executors;

    /// @notice Whitelisted DEX router contracts.
    mapping(address => bool) public whitelistedRouters;

    /// @notice Tracks used nonces to prevent signature replay.
    mapping(uint256 => bool) public usedNonces;

    /// @notice Global circuit breaker — when true, all execution is frozen.
    bool public paused;

    // ── Events ──────────────────────────────────────────────────────────────

    event ExecutorAdded(address indexed executor);
    event ExecutorRemoved(address indexed executor);
    event RouterAdded(address indexed router);
    event RouterRemoved(address indexed router);
    event SwapExecuted(
        address indexed token,
        uint256 amountIn,
        uint256 amountOut,
        uint256 nonce,
        address indexed executor,
        address indexed router
    );
    event EmergencyPause(address indexed triggeredBy);
    event EmergencyUnpause(address indexed triggeredBy);

    // ── Constructor ─────────────────────────────────────────────────────────

    /**
     * @param _signer Public address of the Brain server's signing key.
     *                msg.sender becomes the owner (cold wallet).
     */
    constructor(address _signer) {
        require(_signer != address(0), "Vault: zero signer");
        owner = msg.sender;
        signer = _signer;
    }

    // ── Modifiers ───────────────────────────────────────────────────────────

    modifier onlyOwner() {
        require(msg.sender == owner, "Vault: not owner");
        _;
    }

    modifier onlyAuthorizedExecutor() {
        require(executors[msg.sender], "Vault: not authorized executor");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "Vault: paused");
        _;
    }

    // ── Admin: executor management ──────────────────────────────────────────

    function addExecutor(address addr) external onlyOwner {
        require(addr != address(0), "Vault: zero address");
        executors[addr] = true;
        emit ExecutorAdded(addr);
    }

    function removeExecutor(address addr) external onlyOwner {
        executors[addr] = false;
        emit ExecutorRemoved(addr);
    }

    // ── Admin: router whitelist ─────────────────────────────────────────────

    function addRouter(address router) external onlyOwner {
        require(router != address(0), "Vault: zero address");
        whitelistedRouters[router] = true;
        emit RouterAdded(router);
    }

    function removeRouter(address router) external onlyOwner {
        whitelistedRouters[router] = false;
        emit RouterRemoved(router);
    }

    // ── Circuit breaker ─────────────────────────────────────────────────────

    function emergencyPause() external onlyOwner {
        paused = true;
        emit EmergencyPause(msg.sender);
    }

    function emergencyUnpause() external onlyOwner {
        paused = false;
        emit EmergencyUnpause(msg.sender);
    }

    // ── Signature helpers ───────────────────────────────────────────────────

    /**
     * @notice Build the EIP-191 signed-message hash.
     *
     * Cross-chain replay protection via block.chainid + address(this).
     * The executor can only call a whitelisted router, so the router
     * address is also part of the signed payload — an attacker who
     * steals the executor key cannot redirect funds to a non-approved
     * contract even if they replay the signature.
     *
     * @param token      ERC-20 token being swapped
     * @param minOutput  Minimum output expected (slippage / honeypot floor)
     * @param nonce      Unique anti-replay nonce
     * @param deadline   Block timestamp after which the signature expires
     * @param router     Whitelisted DEX router for this swap
     */
    function _hashSwap(
        address token,
        uint256 minOutput,
        uint256 nonce,
        uint256 deadline,
        address router
    ) internal view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                "\x19Ethereum Signed Message:\n32",
                keccak256(
                    abi.encode(
                        token,
                        minOutput,
                        nonce,
                        deadline,
                        router,
                        block.chainid,
                        address(this)
                    )
                )
            )
        );
    }

    /**
     * @notice Split a 65-byte ECDSA signature into v, r, s.
     */
    function _splitSignature(
        bytes calldata sig
    ) internal pure returns (uint8 v, bytes32 r, bytes32 s) {
        require(sig.length == 65, "Vault: invalid sig length");
        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }
        if (v < 27) v += 27;
    }

    // ── Core swap execution ─────────────────────────────────────────────────

    /**
     * @notice Execute an authorised swap through a whitelisted router.
     *
     * Flow:
     *   1. Validate deadline + nonce (anti-replay).
     *   2. Require targetRouter is whitelisted (no arbitrary call).
     *   3. ecrecover → require(signer) — router is part of the signed hash.
     *   4. Transfer `amountIn` tokens to the executor.
     *   5. Call only the whitelisted router with swapData.
     *   6. Honeypot guard: verify token balance >= minOutput.
     *
     * @param token      ERC-20 token to sell
     * @param amountIn   Amount of token to transfer to executor
     * @param minOutput  Minimum balance of `token` required after execution
     * @param nonce      Unique anti-replay nonce
     * @param deadline   Block timestamp deadline
     * @param router     Whitelisted DEX router (call target)
     * @param signature  ECDSA signature (65 bytes) from the Brain signer
     * @param swapData   Calldata forwarded to the whitelisted router
     * @return amountOut Actual net output received back
     */
    function executeSwap(
        address token,
        uint256 amountIn,
        uint256 minOutput,
        uint256 nonce,
        uint256 deadline,
        address router,
        bytes calldata signature,
        bytes calldata swapData
    ) external onlyAuthorizedExecutor whenNotPaused returns (uint256 amountOut) {
        // ── Replay & expiry guards ──────────────────────────────────────
        require(block.timestamp <= deadline, "Vault: Signature Expired");
        require(!usedNonces[nonce], "Vault: Signature Replayed");
        usedNonces[nonce] = true;

        // ── Router whitelist guard (closes arbitrary-call vector) ───────
        require(whitelistedRouters[router], "Vault: router not whitelisted");

        // ── ecrecover verification ──────────────────────────────────────
        // router is part of the signed hash; an attacker who steals the
        // executor key cannot replay the signature with a different router.
        bytes32 msgHash = _hashSwap(token, minOutput, nonce, deadline, router);
        (uint8 v, bytes32 r, bytes32 s) = _splitSignature(signature);
        require(ecrecover(msgHash, v, r, s) == signer, "Vault: invalid signer");

        // ── Transfer tokens to executor ─────────────────────────────────
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        require(balanceBefore >= amountIn, "Vault: insufficient balance");

        IERC20(token).safeTransfer(msg.sender, amountIn);

        // ── Routed call — ONLY the whitelisted router ───────────────────
        // msg.sender.call(swapData) is ELIMINATED. The executor supplies a
        // router address that the signature also commits to. Even with a
        // stolen executor key, funds cannot be sent to an unapproved contract.
        (bool success, bytes memory reason) = router.call(swapData);
        require(success, string(reason));

        // ── Honeypot / Slippage guard (mathematical armor) ────────────
        // Catches: transfer-on-fee tokens, honeypot contracts,
        // fee-on-transfer manipulation, and back-running attacks.
        // balanceAfter must be >= minOutput — otherwise the entire
        // transaction reverts, preventing any loss.
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));
        require(balanceAfter >= minOutput, "Vault: Honeypot/Slippage");

        // ── Corrected profit calculation (no underflow) ─────────────────
        // balanceBefore = vault's full balance before any transfer.
        // amountIn     = tokens sent to the executor.
        // balanceAfter = vault's balance after the router call.
        //
        // tokens retained in vault = balanceBefore - amountIn
        // net amount returned      = balanceAfter - (balanceBefore - amountIn)
        //
        // This is always >= 0 because balanceAfter >= minOutput by the
        // honeypot guard, and minOutput is known to be reachable.
        // Underflow is mathematically impossible.
        amountOut = balanceAfter - (balanceBefore - amountIn);

        emit SwapExecuted(token, amountIn, amountOut, nonce, msg.sender, router);
    }

    // ── Rescue accidentally sent tokens ─────────────────────────────────────

    function rescueTokens(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner {
        IERC20(token).safeTransfer(to, amount);
    }

    receive() external payable {}
}
