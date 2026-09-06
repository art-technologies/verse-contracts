# Operations Runbook — CustodialNFTVault

Applies per deployment on Ethereum Mainnet, Base, Polygon PoS, and Shape.
Vault state is independent per chain; every procedure below must be
considered per chain and, for incidents, executed on **all four chains**.

Key facts operators must know:

- `withdraw` returns `false` (does **not** revert) on an over-limit request:
  the vault auto-locks (pauses), emits `AutoLocked` + the standard `Paused`
  event, transfers nothing, records no consumption.
- "Locked" is the standard OpenZeppelin `Pausable` pause state. `lock()` —
  owner (Safe) or any emergency locker; idempotent and **silent** when
  already paused (the `Paused(account)` event fires only on the actual
  transition). `unlock()` — owner (Safe) only; reverts `ExpectedPause` if the
  vault is not paused; emits `Unpaused(account)`; preserves active history.
  Withdrawing while locked reverts `EnforcedPause`.
- Lock stops NFT withdrawals only. Deposits and owner ERC-20/native rescue
  keep working while locked.
- Role changes (`setManagers`, `setEmergencyLockers`) are **full
  replacements** with 1–10 non-zero, strictly ascending addresses.
- `setLimits` can never change `periodSeconds` (reverts `PeriodIsImmutable`).
  Period changes require the paused-only `resetWindowAndSetPeriod` epoch
  operation, which **erases all window history** — see §6.

---

## 1. Normal withdrawal flow

1. Backend builds the batch (≤ `maxItemsPerBatch`, hard cap 50 items) and
   **sorts items non-decreasingly by `(token, tokenId)`**. Equal keys must
   share the same `standard`; an ERC-721 key may appear only once; ERC-1155
   keys may repeat (count once toward the budget). Unsorted input reverts
   (`ItemsNotSorted`) — sorting is a backend responsibility.
2. Pre-flight (view calls): `isLocked() == false`;
   `getRemainingLimit() >= distinct count of the batch`. If insufficient, hold
   the batch — submitting anyway will auto-lock the vault.
3. Manager (KMS-backed EOA, correct chain's key) signs and submits
   `withdraw(items)`.
4. Confirm outcome:
   - `true` + `WithdrawalExecuted(manager, itemCount, distinctTokens,
     usedBefore, usedAfter)` → success; reconcile token `Transfer` /
     `TransferSingle`/`TransferBatch` events against the batch.
   - `false` + `AutoLocked` → no transfer happened; go to §5.
   - Revert → decode the custom error; fix input; no state changed.
5. Wait for chain finality (MONITORING.md §4) before marking the withdrawal
   settled in the marketplace.

CryptoPunks (Ethereum Mainnet only, where the deployed contract is the
`CustodialNFTVaultWithPunks` variant) follow the same flow through the
separate `withdrawPunks(items)` selector, reusing the `WithdrawalItem`
shape: `token` = the canonical `CryptoPunksMarket`, `tokenId` = punk index,
`amount` = 1, `standard` = the `ERC721` placeholder. Items must be
**strictly** ascending by `(token, tokenId)` (duplicates revert). Success
emits `PunkWithdrawalExecuted(manager, itemCount, usedBefore, usedAfter)`;
reconcile the punks contract's `PunkTransfer` events. Punks consume the same
window budget — pre-flight `getRemainingLimit()` covers both selectors
combined.

## 2. Lock-all-chains procedure (emergency)

Trigger: suspected manager/Safe compromise, `AutoLocked`, anomalous
withdrawals, indexer/monitoring alarm, or any doubt.

1. Run the one-command lock tool: submits `lock()` from the emergency-locker
   key on **Ethereum, Base, Polygon, and Shape** simultaneously. Locker
   infrastructure is separate from manager infrastructure.
2. `lock()` is idempotent — always send to all four chains even if some
   already show locked. A lock on an already-locked vault is a **silent
   no-op** (no event), so verification must use the view, not events.
3. Verify `isLocked() == true` on every chain via two independent RPC
   providers; on chains that actually transitioned, also confirm the standard
   `Paused(account)` event.
4. If a locker key fails (nonce, gas, RPC), fall back to: another configured
   locker → the owner Safe (`lock()` is owner-callable) → §7 fallbacks.
5. Open an incident record (§8) before any unlock discussion.

Drill this quarterly and during every rollout (spec §27 step 12).

## 3. Manager removal / rotation

1. If compromise is suspected: lock all chains first (§2). For routine
   rotation, locking is optional but recommended.
2. Provision the new key in KMS/HSM (§9 requirements) and fund it minimally
   for gas.
3. Owner Safe executes `setManagers(newSet)` — the **complete** new set,
   strictly ascending, 1–10 addresses, old key omitted. There is no
   incremental grant/revoke.
4. Verify: `getManagers()` matches the approved manifest;
   `ManagersChanged(oldHash, newHash)` emitted where
   `newHash == keccak256(abi.encode(newSet))`; `isManager(oldKey) == false`.
5. Update the deployment manifest and the monitoring role-drift baseline
   **in the same change**, or monitoring will (correctly) page.
6. Repeat per chain — keys are per-chain, so each chain's set is rotated
   independently.
7. Locker rotation: identical procedure with `setEmergencyLockers` /
   `EmergencyLockersChanged`.

## 4. Safe compromise procedure

Assume the worst: a compromised Safe can add a manager, raise limits, lock
and reset the window with a shorter period (`resetWindowAndSetPeriod`),
unlock, and withdraw — possibly in **one atomic transaction** (monitoring
detects, cannot prevent).

1. Lock all chains from emergency lockers immediately (§2). Note: the
   compromised Safe can re-unlock, so locking buys time, not safety —
   iterate locks while executing the following.
2. Freeze marketplace operations: stop attributing deposits, stop directing
   users to deposit to the vault on all chains.
3. Attempt Safe recovery: if honest owners still hold threshold, rotate Safe
   owners and cancel pending transactions; then `transferOwnership(newSafe)`
   from the old Safe and `acceptOwnership()` from the new one
   (`OwnershipTransferStarted` → `OwnershipTransferred`). Note:
   `transferOwnership(address(0))` **cancels** a pending transfer (it never
   renounces — renunciation is disabled).
4. If threshold is attacker-controlled: the vault owner cannot be forcibly
   recovered (no timelock). Race to minimize loss: keep the vault
   locked from lockers as often as the attacker unlocks, alert
   users/collections, coordinate with recipients/marketplaces on the stolen
   identifiers, and prepare migration of remaining assets — a legitimate
   manager (if uncompromised) can withdraw remaining NFTs to a new vault
   within window limits during any unlocked interval you control.
5. Preserve all evidence (§8). Post-incident: rebuild Safe (owners,
   threshold, no unneeded modules), redeploy or re-verify the vault, repeat
   the operational drill before resuming custody.

Prevention policy (must be enforced organizationally): dedicated Safe;
reviewed owner set/threshold; tested recovery; no combined risk-loosening +
withdrawal transactions; Safe owner-set monitoring (MONITORING.md §6).

## 5. Auto-lock investigation and unlock approval

An `AutoLocked` event means a manager requested more than the remaining
allowance. It is either a backend accounting bug, an operational spike, or a
compromised/misbehaving manager.

Investigation checklist (complete **all** before proposing unlock):

- [ ] Pull the `AutoLocked` event: `manager`, `usedInWindow`, `requested`,
      `maxTokens`, `periodSeconds`.
- [ ] Reconstruct the triggering batch from the transaction calldata; confirm
      **no transfer occurred** in that transaction and no consumption was
      recorded (`getWindowState()` unchanged by it).
- [ ] Reconcile all `WithdrawalExecuted` events in the current window against
      backend withdrawal orders — every event maps to a legitimate order,
      recipients and collections match.
- [ ] Reconcile vault NFT balances on-chain vs. indexer expectations.
- [ ] Check the manager key: expected host/KMS logs for the transaction,
      nonce continuity, no unknown transactions from the key on any chain.
- [ ] Check the other two chains for correlated `AutoLocked` /
      `WithdrawalExecuted` anomalies.
- [ ] Root cause written down: backend under-check of `getRemainingLimit()`,
      legitimate demand spike, or compromise.

Unlock approval (owner Safe signers):

- [ ] Investigation above complete and reviewed by a second person.
- [ ] If compromise: manager rotated (§3) **before** unlock.
- [ ] Limits (`getLimits()`) confirmed appropriate; loosening limits to
      "make room" requires separate explicit approval — never bundle
      `setLimits` (or `resetWindowAndSetPeriod`, §6) risk-loosening with
      pending withdrawals.
- [ ] Safe executes `unlock()`; verify the standard `Unpaused(account)` event
      and that `getWindowState()` usage matches expectation — unlock never
      resets active history, so remaining allowance may still be near zero
      until consumptions expire.
- [ ] Monitoring re-armed; incident record closed with evidence (§8).

## 6. Period change / window reset (`resetWindowAndSetPeriod`) — Critical

`setLimits` can never change `periodSeconds` (it reverts `PeriodIsImmutable`).
The **only** way to change the period is `resetWindowAndSetPeriod(newPeriod)`
— an owner-only, paused-only epoch operation that **erases all window
history** (current usage drops to zero) and emits
`WindowEpochReset(oldPeriod, newPeriod)`. The vault **stays paused** after
the call; unlocking is a separate `unlock()` with its own approval (§5).

This is a **risk-loosening operation regardless of the new period value**
(it forgives all recent usage), so treat it as **Critical** and require
incident-level approval:

1. Written change request stating the old period, new period, current
   `getWindowState()` usage that will be erased, and why erasure is
   acceptable now. Approval by security lead + owner-Safe signers quorum —
   the same bar as an incident unlock (§5).
2. Confirm no pending/withheld withdrawals are waiting to exploit the
   forgiven allowance; reconcile the current window's `WithdrawalExecuted`
   events first.
3. Lock the vault (`lock()`, §2) if not already locked — the call reverts
   (`ExpectedPause`) otherwise.
4. Owner Safe executes `resetWindowAndSetPeriod(newPeriod)`. Never bundle it
   with `unlock`, `setLimits`, or role changes in one Safe transaction
   (monitoring treats bundling as a compromise signature).
5. Verify `WindowEpochReset(oldPeriod, newPeriod)` (Critical alert expected —
   reconcile it with the change ticket), `getLimits().periodSeconds ==
   newPeriod`, `getRecentWithdrawn() == 0`, and `isLocked() == true`.
6. Update the deployment manifest and monitoring drift baseline **in the same
   change**, then proceed to the separate unlock approval (§5).

## 6a. Non-standard asset rescue (`execute`) — Critical

Recovery path for assets that follow neither ERC-721 nor ERC-1155 (e.g.
CryptoPunks-style contracts) and cannot leave through `withdraw` or the
fixed-shape rescues: the owner-only `execute(target, value, data)` — an
**instant, unrestricted arbitrary call** (plain CALL, never delegatecall).

**Accepted-risk note (design decision, 2026-07-21):** the owner Safe already
holds effective root over custody even without `execute` — a compromised
Safe can replace all managers and emergency lockers, max the limits,
epoch-reset the window to the 1-second minimum, and drain the vault in
roughly ten transactions. `execute` therefore grants no fundamentally new
capability; it removes the multi-transaction friction. The consequence
operators must internalize: **there is no on-chain reaction window for
`execute`** — no delay, no locker veto, and lockers cannot interpose. The
Safe itself (owner set, threshold, hardware signing, independent
transaction review before signing) is the sole control for this entrypoint.

Legitimate rescue procedure:

1. Written rescue ticket: stuck asset, target contract, exact calldata
   (decoded and raw), recipient, and why no standard path applies. Approval:
   security lead + owner-Safe quorum.
2. Every Safe signer independently decodes and verifies the calldata against
   the ticket **before signing** — this step replaces the removed timelock
   and veto and is mandatory.
3. Owner Safe submits `execute(target, value, data)`. Monitoring pages
   Critical on `Executed` — reconcile with the ticket immediately.
4. Verify the asset's arrival at the recipient. Never bundle `execute` with
   any other owner action in one Safe transaction.

Hostile-`Executed` response: an `Executed` event that does not match a
pre-approved ticket means the transfer has ALREADY happened — go directly to
§4 (Safe compromise procedure) and §2 (lock-all-chains); there is nothing to
veto after the fact.

## 7. RPC failure / chain congestion fallback

- Maintain ≥ 2 independent RPC providers per chain plus a self-hosted node
  for Ethereum where practical. Lock tooling tries providers in order and
  broadcasts through all of them.
- Emergency `lock()` must be submittable with an aggressive fee: pre-agreed
  bumped `maxFeePerGas`/`maxPriorityFeePerGas` (e.g. 5–10× current base fee)
  — a lock transaction is cheap (≤ ~45k gas) and must never be stuck. Use
  same-nonce fee-bump replacement if pending too long.
- Base and Shape (both OP-stack): L2 gas is cheap but include L1 data-fee
  headroom; if the sequencer is down, lock via the L1 force-inclusion path is
  slow — treat an unreachable L2 as an incident and pause that chain's
  attribution/withdrawals operationally.
- Polygon: expect gas-price spikes; keep the locker funded for ≥ 20 lock
  transactions at 10× typical gas price on every chain.
- If a manager transaction is stuck during congestion, do **not** blind-retry
  from another manager — recompute `getRemainingLimit()` first to avoid an
  accidental auto-lock.
- If all RPC paths fail on a chain: escalate to incident, halt marketplace
  activity for that chain; a chain nobody can read must not be attributed.

## 8. Evidence retention

For every incident (auto-lock, manual emergency lock, rotation under
suspicion, Safe event) retain for ≥ 24 months:

- transaction hashes, raw calldata, and decoded events for all vault
  transactions in the affected window on all chains;
- `getWindowState()`, `getLimits()`, `getManagers()`,
  `getEmergencyLockers()`, `isLocked()` snapshots at detection and at
  resolution;
- monitoring alerts with timestamps, indexer state/rollback logs, RPC
  provider logs;
- KMS/HSM signing logs and host access logs for implicated manager keys;
- Safe transaction history and owner-set snapshots;
- the written investigation and unlock-approval checklist (§5) with
  approver identities.

Store in an append-only bucket outside the operational AWS account boundary
used by manager/locker infrastructure.

## 9. Manager-key requirements (spec §20)

- Separate manager keys **per chain** whenever operationally possible.
- KMS- or HSM-backed signing; no raw private keys on application hosts.
- **Direct EOA managers are required by default**: if a manager is a
  contract, its outer revert rolls back the vault's auto-lock (EVM frame
  semantics — see THREAT_MODEL.md §3.5). Any forwarding contract must be
  narrowly scoped and independently audited. **Enforced at deployment:**
  `DeployVault.s.sol` rejects any manager with code unless it is listed in
  the manifest's `auditedForwarders` allowlist.
- Transaction allowlisting to the vault address and the `withdraw` selector
  where the signing platform supports it.
- Fee and nonce monitoring per key (MONITORING.md §7).
- On suspected compromise: immediate lock-all-chains (§2) then rotation (§3).
- A manager must not also be an emergency locker unless explicitly approved
  in the threat model (default: not approved). **Enforced at deployment:**
  `DeployVault.s.sol` requires disjoint manager/locker sets unless the
  manifest sets `allowManagerLockerOverlap: true`.
- Emergency-locker infrastructure lives on separate hosts/accounts from
  manager infrastructure.
