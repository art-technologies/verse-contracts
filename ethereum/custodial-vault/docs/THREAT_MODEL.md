# Threat Model — CustodialNFTVault

Scope: `src/CustodialNFTVault.sol` (base vault) deployed independently on
Base, Polygon PoS, and Shape; `src/CustodialNFTVaultWithPunks.sol` (an
inheriting extension adding only `withdrawPunks`, selected via the manifest's
`withPunks` flag) on Ethereum Mainnet. Non-upgradeable, deployed directly
(no proxy). Every statement about per-chain limits, monitoring pipelines,
and emergency lock-all procedures applies to ALL deployments of both
variants, including Shape. The extension overrides no base behavior and
builds exclusively on the base's internal withdrawal rails
(`_checkWithdrawalPreconditions` / `_consumeOrAutoLock`), so every claim
about the manager gate, auto-lock, and window budget covers the punk path
by construction.

---

## 1. Assets at risk

| Asset | Location | Exposure |
|---|---|---|
| Custodied ERC-721 NFTs | Vault balance per chain | Primary target; movable only via `withdraw` |
| Custodied ERC-1155 tokens/editions | Vault balance per chain | Primary target; movable only via `withdraw` |
| Custodied CryptoPunks | Punks-variant vault balance (Ethereum Mainnet only) | Primary target; movable only via `withdrawPunks` (same manager gate and shared window); the selector does not exist on base-vault chains |
| Accidentally received ERC-20 tokens | Vault balance | Movable only via owner `rescueERC20` |
| Forced/pre-funded native currency | Vault balance | Movable only via owner `rescueNative` |
| Withdrawal availability | Lock state | Anyone with lock rights can halt withdrawals (accepted) |
| Off-chain deposit attribution | Marketplace indexer | Not an on-chain asset; the vault stores no attribution |

There is no delegatecall and no upgrade mechanism. Every **manager-path**
NFT exit consumes rolling-window budget. The owner additionally holds an
unrestricted arbitrary-call `execute` entrypoint (§5.7) — an accepted design
decision: the owner is treated as root (see §5.7 for the rationale), and the
Safe itself is the security boundary for it. Managers and lockers cannot
call `execute`.

## 2. Trust model

| Actor | Capabilities | Trust assumption |
|---|---|---|
| Owner (dedicated Safe multisig) | `unlock`, `setManagers`, `setEmergencyLockers`, `setLimits` (inside immutable hard caps; cannot change the period), `resetWindowAndSetPeriod` (paused-only; erases window history), `transferOwnership`/`acceptOwnership` (Ownable2Step; transferring to zero cancels a pending transfer), `rescueERC20`, `rescueNative`, `lock` | Ultimate security boundary. Cannot directly move NFTs; can indirectly enable theft (see §3.2). Must be a dedicated Safe, set in the constructor, never renounceable (`renounceOwnership` always reverts `OwnershipRenunciationDisabled`), never zero. |
| Managers (1–10, KMS/HSM EOAs preferred) | `withdraw` only (plus `withdrawPunks` on the Ethereum punks variant), sharing ONE rolling-window allowance per chain across all withdrawal selectors | High-trust operational keys. A compromised manager can steal up to the window budget before auto-lock/limits stop it (§4); splitting the theft across the two selectors buys nothing. |
| Emergency lockers (1–10) | `lock()` only | Low trust required. Can cause availability loss only; cannot unlock, withdraw, or reconfigure. |
| Depositors | Send NFTs to the vault via ordinary (safe) transfers | Untrusted. Receiver callbacks are stateless (no storage writes, no external calls, no attribution). |
| Token contracts | Called only via `safeTransferFrom` during `withdraw`, and `transfer` (SafeERC20) during `rescueERC20` | Untrusted. Reentrancy guard + consume-before-call ordering (limiter storage is updated before any external token call); a token failure atomically reverts the whole withdrawal including the recorded consumption. |
| Recipients | Receive NFTs; safe-transfer callbacks execute on their side | Untrusted. Reentrancy into `withdraw`/rescues blocked by `nonReentrant`; window state is persisted before any external call. |
| Deployer | None after construction | Untrusted post-deployment. Vault starts unlocked; the owner is the Safe from construction. |

The owner is **not** implicitly a manager. Authorization uses
`msg.sender` only; `tx.origin` is never used.

## 3. Attacker scenarios

### 3.1 Compromised manager key
- Can submit `withdraw` and/or `withdrawPunks` batches until the shared
  rolling window is exhausted;
  one identifier over the remaining allowance auto-locks the vault
  (`AutoLocked` + standard `Paused`, `withdraw` returns `false`, no transfer,
  nothing recorded — `tryConsume` returns false without consuming).
- Cannot unlock, reconfigure, or exceed `maxTokens` distinct identifiers per
  window per chain.
- Can deliberately trigger auto-lock (availability). Accepted: the same key
  could otherwise spend the allowance on real withdrawals.
- Response: emergency lock all chains, `setManagers` to remove the key
  (see OPERATIONS.md).

### 3.2 Compromised owner Safe
The contract blocks a silent direct owner NFT transfer, but a compromised Safe
can: (1) add an attacker manager, (2) raise `maxTokens` up to 2,000 via
`setLimits` and/or — after locking — lower `periodSeconds` toward the
1-second minimum via `resetWindowAndSetPeriod` (which also erases all window
history, itself risk-loosening), (3) `unlock`, then (4) withdraw through the
manager path. All steps emit Critical events, but
monitoring cannot interrupt later calls inside one atomic Safe transaction —
events are detection, not prevention. Mitigations: dedicated Safe, reviewed
owner set/threshold, no unnecessary modules/guards, Safe-config monitoring,
policy forbidding combined risk-loosening + withdrawal transactions, and an
independently scoped configuration-delay module as future hardening.

### 3.3 Malicious token contract
- During `withdraw`: called only after the limiter consumption is recorded
  and state persisted; `nonReentrant` blocks re-entry; a revert atomically
  unwinds the entire withdrawal (no partial withdrawals). It cannot observe
  unconsumed allowance.
- As a "deposit": a contract can emit fake `Transfer`/`TransferSingle`/
  `TransferBatch` events or lie about interface support. The vault does not
  validate collection authenticity — the indexer must recognize approved
  collections only.
- As a hybrid ERC-20/NFT: see accepted limitations (§5).

### 3.4 Malicious recipient
Safe-transfer callbacks on the recipient run mid-batch. Re-entry into
`withdraw`, `rescueERC20`, or `rescueNative` is blocked by the shared
reentrancy guard; all window accounting is already persisted. Worst case: the
recipient reverts, which reverts the whole batch (availability of that batch
only).

### 3.5 Contract-manager outer-revert rollback of auto-lock
If a whitelisted manager is a **contract**, it can call `withdraw`, receive
`false` on an over-limit request (vault now locked in the child frame), and
then revert its own outer call — the EVM rolls back the auto-lock with the
rest of the transaction. Solidity cannot make child-call state survive a
parent revert, and this must not be "fixed" with `tx.origin`. Control is
operational: production managers are direct KMS-backed EOAs; any manager
forwarder must be narrowly scoped and audited (`test/unit` covers
`OuterRevertingManager`). `DeployVault.s.sol` enforces this at deployment:
a manager with code is rejected unless listed in the manifest's
`auditedForwarders` allowlist. Note the attacker still cannot exceed the
window — the rollback only erases the lock, not the limit check.

### 3.6 Emergency-locker compromise / griefing
A locker can only lock (idempotent — a repeated lock is a silent no-op, the
standard `Paused` event fires only on the actual transition). Impact is
availability; recovery is owner `unlock` + `setEmergencyLockers`. Lockers must not also be managers unless
explicitly approved here (default: not approved).

## 4. Theft upper bound

Per chain, per rolling window: at most `maxTokens` **distinct
`(token, tokenId)` identifiers** (hard cap 2,000; operational configuration
should be far lower). The count is derived on-chain from the canonically
ordered batch; a caller-supplied count is never trusted. ERC-1155 amounts do
not add to the budget — one identifier with any edition amount counts once per
withdrawal.

CryptoPunks exits via `withdrawPunks` consume the same per-chain budget —
one punk is one identifier; the bound above covers both selectors combined.

Deployments are independent, so the global bound is the **sum of the four
per-chain limits** (e.g. 10 tokens / 10 minutes per chain ⇒ up to 40
identifiers can exit across Ethereum + Base + Polygon + Shape before local
limits engage). Off-chain monitoring must enforce a global cross-chain
velocity policy and hold emergency-locker keys for every deployment,
including Shape (MONITORING.md, OPERATIONS.md).

## 5. Accepted limitations

1. **No deposit attribution on-chain.** No deposit entrypoint, no deposit
   event, stateless receiver callbacks. Attribution lives in the indexer,
   which must whitelist collection contracts; the vault cannot detect fake
   collections.
2. **ERC-20 rescue hybrid-token boundary.** `rescueERC20` uses a fixed
   SafeERC20 `transfer(recipient, amount)`; it cannot move a *standard*
   ERC-721/1155 through their normal interfaces. A malicious hybrid token can
   assign arbitrary behavior to the ERC-20 `transfer` selector — this is an
   accepted owner-boundary limitation, not a universal token-type
   proof.
3. **1-second minimum period escape hatch.** `MIN_PERIOD_SECONDS == 1`
   preserves parity with the Tezos design and gives the owner an operational
   escape hatch, but a compromised Safe can shrink the window to ~nothing.
   The only path is the paused-only `resetWindowAndSetPeriod`, which also
   erases all window history and emits `WindowEpochReset` (Critical).
   Monitoring must raise a Critical alert when `periodSeconds` drops below the
   approved operating policy.
4. **Count-based, not value-based, bound.** The limiter counts distinct asset
   identifiers, not economic value. A single high-value NFT costs one budget
   unit. Value-, collection-, and recipient-based policy is enforced by
   off-chain scanners.
5. **Auto-lock rollback by contract managers** (§3.5) — controlled
   operationally, not on-chain.
6. **Lock is availability-only for deposits.** Deposits remain possible while
   locked; ERC-20/native rescue remains available while locked (by design).
7. **Owner arbitrary-call `execute` (accepted risk, design decision
   2026-07-21).** The vault exposes `execute(target, value, data)` — an
   instant, unrestricted, owner-only arbitrary call (plain CALL, never
   delegatecall, reentrancy-guarded, Critical `Executed` event with full
   calldata). Its purpose is recovering assets that follow none of the
   supported standards (ERC-721, ERC-1155, CryptoPunks — punks now have the
   dedicated `withdrawPunks` manager path) and would otherwise be stuck
   forever.

   **Rationale for accepting it without a timelock or veto:** the owner Safe
   already holds effective root over custody. Even without `execute`, a
   compromised Safe can — in roughly ten transactions — replace all managers
   and emergency lockers, raise `maxTokens` to the 2,000 hard cap,
   epoch-reset the window to the 1-second minimum period, and drain the
   vault through its own manager at ~2,000 identifiers per second. `execute`
   therefore grants no fundamentally new capability; it removes the
   multi-transaction friction and the associated on-chain reaction window.

   **Consequences that must be understood and monitored:**
   - A single fraudulently signed Safe transaction can now move custody
     assets atomically (approvals or direct transfers); emergency lockers
     cannot interpose on `execute`, and `Executed` is detection
     after-the-fact, not prevention.
   - The Safe (owner set, threshold, hardware signing, independent calldata
     review before signing) is the sole security boundary for this
     entrypoint; the on-chain rolling window bounds the *manager* path only.
   - The invariant "every NFT exit consumes rolling-window budget" holds for
     the manager path, not for owner `execute` — the indexer/monitoring must
     treat `Executed` as a first-class custody-movement source.

   This entrypoint expands audit scope and must be explicitly reviewed.

## 6. Limiter storage-growth trade-off (replaces the v1 ring-capacity proof)

v1's custom fixed-capacity packed checkpoint ring (2,000 entries, provably
never overwriting an active record) was **deleted** in v2. Rolling-window
accounting is now OpenZeppelin `RateLimiter.SlidingWindow` under a single
global key, with the same externally observable semantics: a consumption
expires exactly when the full period has elapsed, and an over-limit
`tryConsume` returns false while recording nothing (the vault then pauses,
emits `AutoLocked`, and returns false without reverting).

The trade-off that must be understood in place of the old proof:

- Checkpoint storage is a dynamic OpenZeppelin `Checkpoints.Trace208` array.
  Each successful consumption at a **unique timestamp** pushes one new
  checkpoint (one storage slot); the array length is **not** permanently
  bounded the way the v1 ring was.
- Consumptions within the same timestamp (same block) coalesce into the
  latest checkpoint — no new slot.
- History truncates: on the first consumption after the vault has been idle
  for a full window, the limiter rewinds and reuses existing slots, so the
  array does not grow monotonically under normal duty cycles.
- Gas and storage behavior at 1 / 100 / 2,000 / 10,000-checkpoint histories
  is benchmarked in `test/gas/VaultGas.t.sol` (withdrawal and view paths);
  the gas snapshot gate tracks regressions. Reads are `O(log n)` binary
  lookups inside the OZ library.
- `resetWindowAndSetPeriod` (owner, paused-only) fully erases the history and
  serves as the operational recovery path if growth ever became a concern.

Window-accounting correctness is covered by
`test/invariant/VaultInvariants.t.sol::invariant_windowAccountingConsistent`
(a shadow model of the sliding window) plus the rolling-window unit suite.

Overflow note: the cumulative consumption value is a `uint208` inside
`Trace208`, growing by ≤ 2,000 per window; it cannot overflow within any
realistic contract lifetime, and `resetWindowAndSetPeriod` exists as a
recovery mechanism regardless.

### 6.1 Release-candidate dependency risk

`RateLimiter` ships first in OpenZeppelin Contracts **v5.7.0-rc.0**, so the
repository pins that release-candidate tag (submodule commit `2d59c17d…`) as
its **single** OpenZeppelin version — no mixing of OZ versions. Accepted
risks and required actions:

- An RC is not a final release: the pinned commit must be **independently
  reviewed** as part of the audit scope, or the dependency **re-diffed
  against the final `v5.7.0`** release (and re-pinned) before the audit
  concludes and before any production deployment.
- Any upstream change to `RateLimiter`/`Checkpoints` between the RC and the
  final tag invalidates the gas benchmarks and must re-trigger Phase 0/1 of
  the deployment checklist.

## 7. Spec §30 review-checklist answers

| Question | Answer |
|---|---|
| Can any role other than a manager move a standard NFT? | No. `withdraw` (ERC-721/1155) and — on the Ethereum punks variant only — `withdrawPunks` (CryptoPunks) are the only NFT exits and both require manager membership (`isManager(msg.sender)`). No NFT rescue or approval path exists. |
| Can any external calldata be executed arbitrarily? | Yes — by the owner only, via `execute` (plain CALL, no `delegatecall`, Critical `Executed` event). Accepted design decision per §5.7: the owner already holds effective root over custody, so `execute` removes friction, not a boundary. No other role can execute arbitrary calldata; `fallback` reverts `UnknownCall()`. |
| Can a rescue selector move a standard ERC-721 or ERC-1155? | No for standard tokens: `rescueERC20` calls fixed `transfer(address,uint256)`; standard 721/1155 do not move via that interface. Hybrid tokens are the accepted boundary (§5.2). |
| Can a token callback re-enter before budget consumption? | No. The limiter consumption (`tryConsume`) is persisted before any external token call, and `withdraw`/rescues share `nonReentrant`. |
| Can an active checkpoint be overwritten? | N/A in v2 — there is no custom ring or slot-reuse scheme. Checkpoint storage is OpenZeppelin `Checkpoints.Trace208` inside `RateLimiter.SlidingWindow`; the library appends/coalesces per its own audited semantics (§6). |
| Can a limit change reset active history? | No. `setLimits` preserves the window history, cannot change the period (`PeriodIsImmutable`), and never changes lock state. Only `resetWindowAndSetPeriod` erases history — paused-only, owner-only, and emits the Critical `WindowEpochReset` event. |
| Can unlock reset active history? | No. `unlock` is a plain `Pausable` `_unpause` — window history is untouched (expiry is purely time-based inside the limiter). It reverts `ExpectedPause` when not paused. |
| Can an over-limit path revert after setting the lock? | Not inside the vault: the auto-lock branch pauses (`_pause`), emits `AutoLocked` (alongside `Paused`), and returns `false` with no external calls and no revert path after the pause. Nothing is recorded by the failed `tryConsume`. |
| Can the owner renounce ownership? | No. `renounceOwnership` is overridden to always revert `OwnershipRenunciationDisabled`; the vault can never become ownerless. |
| Can `setLimits` change the period? | No — it reverts `PeriodIsImmutable`. The only period-change path is `resetWindowAndSetPeriod` while paused, which erases all window history, emits the Critical `WindowEpochReset`, and leaves the vault paused. |
| Is limiter storage bounded? | No — this is the documented v2 trade-off (§6): the `Trace208` array grows one slot per successful consumption at a unique timestamp, coalesces same-timestamp consumptions, and truncates (reuses slots) on the first consumption after a full-window idle. Benchmarked at 1/100/2,000/10,000-checkpoint histories in `test/gas/VaultGas.t.sol`; `resetWindowAndSetPeriod` is the recovery path. |
| Can a contract manager's outer revert roll back auto-lock, and is that operationally controlled? | Yes it can (EVM frame semantics), and yes it is controlled: EOA managers required in production, forwarders must be audited; documented in §3.5 and tested. |
| Can duplicate or unsorted inputs undercount distinct tokens? | No. One-pass canonical-order verification reverts on unsorted input (`ItemsNotSorted`), duplicate ERC-721 (`DuplicateERC721`), and standard mismatch (`TokenStandardMismatch`); repeated ERC-1155 keys legitimately count once. `withdrawPunks` requires strictly ascending `(token, tokenId)`, so duplicates are impossible and every item counts once. |
| Can packed checkpoint writes corrupt a neighboring record? | N/A in v2 — there is no custom bit-packing; checkpoint layout is OpenZeppelin `Checkpoints.Trace208`. |
| Can cumulative counters overflow within a realistic lifetime? | No. The cumulative `Trace208` value is `uint208` — effectively unbounded for any realistic lifetime (≤ 2,000 per window) — and the limiter's `reset` (via `resetWindowAndSetPeriod`) exists as recovery. |
| Can forced native currency become permanently stuck? | No. `receive`/`fallback` reject ordinary sends; `rescueNative` (owner, works while locked) recovers forced/pre-funded balances via `Address.sendValue`, bubbling the recipient's revert data (or `Errors.FailedCall`) on failure. |
| Can the owner be accidentally set to zero or renounced? | No. The `Ownable` constructor rejects zero; `Ownable2Step` requires the pending owner to `acceptOwnership()`; `transferOwnership(address(0))` merely **cancels** a pending transfer (never renounces); `renounceOwnership` always reverts `OwnershipRenunciationDisabled`. |
| Can malformed role arrays desynchronize mappings and enumeration? | No. Full replacement requires 1–10 non-zero, strictly ascending (hence unique) addresses; old mapping entries are cleared before repopulation; array and mapping mirror exactly (invariant-tested). |
| Can any loop exceed an immutable bound? | No loop in vault code does: loops iterate batch items (≤ 50) or role arrays (≤ 10, including `EnumerableSet.clear` and output sorting). Limiter reads are OZ `Checkpoints` `O(log n)` binary lookups over a dynamic history whose growth/truncation behavior is documented and benchmarked in §6. |
| Are Base L1 data fees and cross-chain aggregate exposure handled by operations rather than assumed away on-chain? | Yes. Fee interpretation and the ×4-chain aggregate bound are operational concerns covered in MONITORING.md/OPERATIONS.md; on-chain cross-chain sync is explicitly out of scope. |
