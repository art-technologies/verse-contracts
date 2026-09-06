# Monitoring Specification — CustodialNFTVault

One monitoring pipeline per chain (Ethereum Mainnet, Base, Polygon PoS,
Shape) plus a cross-chain aggregator. Events are detection signals only — they cannot
interrupt later calls inside the same atomic (e.g. Safe) transaction.

---

## 1. Event catalog, topics, and severity

Compute each `topic0` at deployment time from the canonical signature with
Foundry and pin the hashes in the monitoring config — do not hand-compute:

```sh
cast sig-event "WithdrawalExecuted(address,uint256,uint256,uint256,uint256)"
cast sig-event "PunkWithdrawalExecuted(address,uint256,uint256,uint256)"
cast sig-event "AutoLocked(address,uint256,uint256,uint256,uint256)"
cast sig-event "Paused(address)"
cast sig-event "Unpaused(address)"
cast sig-event "WindowEpochReset(uint32,uint32)"
cast sig-event "ManagersChanged(bytes32,bytes32)"
cast sig-event "EmergencyLockersChanged(bytes32,bytes32)"
cast sig-event "LimitsChanged((uint16,uint32,uint8),(uint16,uint32,uint8))"
cast sig-event "OwnershipTransferStarted(address,address)"
cast sig-event "OwnershipTransferred(address,address)"
cast sig-event "ERC20Rescued(address,address,uint256)"
cast sig-event "NativeRescued(address,uint256)"
cast sig-event "Executed(address,uint256,bytes)"
```

Severity per spec §16:

| Event | Indexed topics | Data fields | Severity |
|---|---|---|---|
| `WithdrawalExecuted` | `manager` | `itemCount`, `distinctTokens`, `usedBefore`, `usedAfter` | Informational + anomaly rules (§2) |
| `PunkWithdrawalExecuted` | `manager` | `itemCount`, `usedBefore`, `usedAfter` | Informational + anomaly rules (§2) — CryptoPunks exit via `withdrawPunks` on the `CustodialNFTVaultWithPunks` variant (Ethereum Mainnet only; base-vault chains do not carry this event or selector); consumes the SAME window budget (`distinctTokens == itemCount` by construction) |
| `AutoLocked` | `manager` | `usedInWindow`, `requested`, `maxTokens`, `periodSeconds` | **Critical** (emitted together with `Paused`) |
| `Paused` (OZ Pausable) | — | `account` | **Critical** |
| `Unpaused` (OZ Pausable) | — | `account` | **Critical** |
| `WindowEpochReset` | — | `oldPeriodSeconds`, `newPeriodSeconds` | **Critical** (erases window history; risk-loosening) |
| `ManagersChanged` | `oldHash`, `newHash` (keccak256(abi.encode(array))) | — | **Critical** |
| `EmergencyLockersChanged` | `oldHash`, `newHash` | — | **Critical** |
| `OwnershipTransferStarted` (OZ Ownable2Step) | `previousOwner`, `newOwner` | — | **Critical** |
| `OwnershipTransferred` (OZ Ownable) | `previousOwner`, `newOwner` | — | **Critical** |
| `LimitsChanged` | — | `oldLimits (maxTokens, periodSeconds, maxItemsPerBatch)`, `newLimits (…)` | High; **Critical** if risk-loosening (§5) |
| `ERC20Rescued` | `token`, `recipient` | `amount` | High |
| `NativeRescued` | `recipient` | `amount` | High |
| `Executed` | `target` | `value`, `data` (full calldata) | **Critical** — owner arbitrary call; page immediately |

There is intentionally **no deposit event** on the vault. Deposits are
attributed from canonical token events (ERC-721 `Transfer`, ERC-1155
`TransferSingle`/`TransferBatch`, CryptoPunks `PunkTransfer` — and
`PunkBought`, since a punk bought by the vault emits no `PunkTransfer`) with
`to == vault`, filtered to approved collection contracts only (for punks,
the single canonical mainnet `CryptoPunksMarket`).

Additional Critical rules:

- Any transaction that emits **more than one** owner event (or an owner event
  plus `WithdrawalExecuted`) — atomic combined owner actions are the
  compromised-Safe signature.
- A `lock()` on an already-paused vault is a **silent no-op** — no event is
  emitted. Re-lock attempts are therefore invisible to log ingestion; the
  polling channel (`isLocked()`, §5) is the authoritative lock-state monitor,
  and lock-tooling verification must use views, not events (OPERATIONS.md
  §2).
- `WindowEpochReset` must always reconcile with an approved change ticket
  (OPERATIONS.md §6) — it erases all window usage and can only occur while
  paused.
- **Standing rule for `Executed`:** the owner `execute` entrypoint is
  instant and unrestricted (accepted design decision: the owner Safe already
  holds effective root — it can replace all roles, max the limits,
  epoch-reset the window, and drain in ~10 transactions; `execute` removes
  friction, not a boundary). Consequently there is NO on-chain reaction
  window: every `Executed` must reconcile with a pre-approved rescue ticket
  (target, decoded calldata, recipient). Decode `data` and alert-highlight
  calls whose `target` is an approved custody collection — that is a drain
  signature, and by the time the event is seen the transfer has happened, so
  the response is the Safe-compromise procedure (OPERATIONS §4), not a veto.
  Because detection is after-the-fact, Safe transaction review BEFORE
  signing is the real control for this entrypoint.
- Deployment baseline: the constructor emits exactly **four** events, in
  order — `OwnershipTransferred(address(0), owner)`,
  `ManagersChanged(hash(empty), hash(initial))`,
  `EmergencyLockersChanged(hash(empty), hash(initial))`, and
  `LimitsChanged((0,0,0), initial)` — once, at the manifest deployment
  block (asserted by `test_constructorEmitsExactBaselineEvents`). It emits
  **no** `Paused` event and the vault starts **unpaused**, so every
  `Paused`/`AutoLocked`/`Unpaused` occurrence after deployment is
  operational and must map to a known drill or incident.

Route Critical → paging (24/7); High → paging during business hours + ticket;
Informational → dashboard + anomaly engine.

## 2. `WithdrawalExecuted` / `PunkWithdrawalExecuted` anomaly rules

Every rule below applies to BOTH manager withdrawal events —
`PunkWithdrawalExecuted` is a first-class withdrawal signal, not a separate
category, and must feed the same shadow window model, velocity counters, and
backend-order reconciliation. For punk events read `distinctTokens :=
itemCount` (each punk is one distinct identifier by construction).

Fire High (or Critical where marked) when:

- withdrawal has no matching backend withdrawal order (reconcile by tx hash) —
  **Critical**;
- recipient is not in the expected-recipient set for the matched order —
  **Critical**;
- token contract is not an approved collection — **Critical**;
- `usedAfter / maxTokens` crosses 80% of the window budget;
- per-manager rate exceeds baseline (e.g. > N withdrawals or > M distinct
  tokens per hour, tuned per chain);
- withdrawals outside approved operating hours;
- `distinctTokens` at or near `maxItemsPerBatch` repeatedly (draining
  pattern);
- unusually high ERC-1155 `amount` values vs. collection baseline (amounts
  don't consume budget — value policy is off-chain by design);
- `usedBefore`/`usedAfter` from events disagree with a shadow rolling-window
  model or `getWindowState()` — **Critical** (indexer or contract-model bug).

Additional punk-specific rules:

- token contract is not the canonical `CryptoPunksMarket` — **Critical**
  (`withdrawPunks` accepts any address; only the canonical contract is
  approved custody);
- any `PunkWithdrawalExecuted` on a chain whose manifest lists no punk
  custody (punks exist on Ethereum Mainnet only) — **Critical**.

Sanity invariant per event: `usedAfter - usedBefore == distinctTokens` and
`distinctTokens <= itemCount <= 50` (for `PunkWithdrawalExecuted`:
`usedAfter - usedBefore == itemCount <= 50`).

## 3. Cross-chain aggregate withdrawal velocity

On-chain limits are per chain; total exposure is the sum across chains
(e.g. 10 tokens/10 min locally ⇒ up to 40 identifiers across the four
chains). The aggregator must:

- maintain a global rolling count of distinct identifiers withdrawn across
  Ethereum + Base + Polygon + Shape, counting BOTH `WithdrawalExecuted` and
  `PunkWithdrawalExecuted` events;
- enforce a **global policy threshold below the sum of local limits**
  (recommended start: ≤ 50% of the summed local budgets per window) — breach
  is Critical and triggers the lock-all-chains runbook (OPERATIONS.md §2);
- alert on correlated patterns: same recipient or collection on multiple
  chains within one window; `AutoLocked` on one chain while withdrawals
  continue on others (auto-lock does **not** propagate — lockers must);
- hold an emergency-locker key for every deployment and support one-command
  lock submission to all chains.

## 4. Finality / reorg policy per chain

| Chain | Confirmation for alert triage | Confirmation for settlement/attribution |
|---|---|---|
| Ethereum Mainnet | 1 block (fast alerting; may reorg) | Finalized (~2 epochs ≈ 64 slots ≈ 13 min); use the `finalized` tag |
| Base | L2 inclusion (seconds; sequencer trust) | Alert triage on `safe` (batch on L1); attribute on L1-finalized (`finalized` tag, L1 finality + batch posting, ~15–30 min) |
| Polygon PoS | ~30 blocks heuristic for alerting | Checkpoint finality: block included in a Bor→Ethereum checkpoint (typically ~10–30 min); use `finalized` tag / checkpoint API |
| Shape | L2 inclusion (seconds; sequencer trust; OP-stack like Base) | Alert triage on `safe` (batch on L1); attribute on L1-finalized (`finalized` tag, ~15–30 min) |

Rules:

- Security alerts (Critical events) fire at **first sight** (even pre-final) —
  false positives from reorgs are acceptable, missed locks are not.
- Marketplace deposit attribution and withdrawal settlement use the
  settlement column only.
- Lock decisions never wait for finality.

## 5. Configuration drift and policy alerts

Poll every N minutes (≤ 5) per chain and compare against the **approved
deployment manifest** (`deployments/<chain>.json` + signed policy doc):

- `getLimits()` vs. manifest: any mismatch = Critical. Specifically:
  - `periodSeconds` **below** approved operating policy (contract minimum is
    1 second — an owner escape hatch): **Critical**. Any `periodSeconds`
    change at all implies a `WindowEpochReset` occurred (`setLimits` cannot
    change the period) — correlate with that Critical event;
  - `maxTokens` or `maxItemsPerBatch` **above** approved policy: **Critical**
    (risk-loosening);
  - tightening changes: High until reconciled with a change ticket.
- `getManagers()` / `getEmergencyLockers()` vs. manifest: any drift =
  Critical. Cross-check `ManagersChanged`/`EmergencyLockersChanged` hashes:
  `newHash` must equal `keccak256(abi.encode(expectedArray))`.
- `owner()` / `pendingOwner()`: `owner` ≠ manifest Safe = Critical;
  `pendingOwner` ≠ 0 without an approved transfer ticket = Critical.
- `isLocked()` state change without a corresponding processed event =
  Critical (missed event = indexer gap).
- Runtime bytecode hash (`cast keccak $(cast code <vault>)`) vs. manifest —
  daily; mismatch = Critical (should be impossible; detects wrong-address
  configuration). The expected hash is per-variant: manifests record
  `contractName` (`CustodialNFTVault`, or `CustodialNFTVaultWithPunks` when
  `withPunks: true` — Ethereum Mainnet only). A punks-variant hash on a
  base-vault chain (or vice versa) is the wrong contract = Critical.

## 6. Safe owner-set monitoring

The vault cannot see Safe-internal changes; monitor the Safe contract
directly on each chain:

- `AddedOwner`, `RemovedOwner`, `ChangedThreshold`, `EnabledModule`,
  `DisabledModule`, `ChangedGuard`, `SafeSetup` — all **Critical** vs. the
  approved owner/threshold manifest (modules and guards should be absent).
- Poll `getOwners()` / `getThreshold()` as drift backstop (same cadence as
  §5).
- Alert on any Safe transaction that bundles vault owner calls with other
  calls (MultiSend to the vault + anything else) — Critical.

## 7. Manager nonce and failed-transaction monitoring

Per manager key, per chain:

- track expected nonce; a nonce consumed by a transaction **not** originated
  by the backend = Critical (key used elsewhere — possible compromise);
- any manager transaction to an address other than the vault, or with a
  selector other than `withdraw(...)` — or, on the Ethereum punks variant,
  `withdrawPunks(...)` — = Critical. The `withdrawPunks` selector exists
  ONLY on `CustodialNFTVaultWithPunks` (Ethereum Mainnet); on base-vault
  chains such a call reverts `UnknownCall` and is Critical key-misuse
  regardless, matching §2;
- failed/reverted manager transactions: decode the custom error
  (`ItemsNotSorted`, `BatchTooLarge`, `EnforcedPause`, …) — repeated
  reverts = High (backend bug or probing);
- remember: an over-limit request does **not** revert — it appears as a
  successful transaction with `AutoLocked` and no `WithdrawalExecuted`;
- gas balance below the funding floor (≥ 20 lock-scale transactions at 10×
  typical gas): High. Same rule for emergency-locker keys — an unfunded
  locker is a broken kill switch.

## 8. Indexer rollback / reorg handling

- Ingest with block hash + parent hash; on parent-hash mismatch, roll back
  all derived state (attributions, window shadow model, alert state) to the
  common ancestor and re-ingest.
- Keep pre-finality attributions in a `pending` state (per §4 settlement
  column); only finalized events become `settled`.
- If a previously alerted event disappears in a reorg, do **not** auto-close
  the alert — flag "reorged-out" for human review (reorg-hiding is itself an
  attack signal).
- Persist per-chain cursors (block number + hash); on restart, re-verify the
  cursor hash before resuming. Alert High if the indexer head lags chain head
  by more than 5 minutes on any chain — a blind window on one chain while
  others withdraw defeats the cross-chain policy (§3).
- Log-based ingestion must also poll views (§5) as an independent channel so
  a dropped subscription cannot silently blind lock-state monitoring.
