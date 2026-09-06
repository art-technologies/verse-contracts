# Deployment Checklist — CustodialNFTVault

Execute per chain (Ethereum Mainnet, Base, Polygon PoS), mirroring spec §27.
Every box requires an operator initial + date in the release record.
**Hard rule: never attribute marketplace deposits to a deployment whose
bytecode and constructor state do not match the audited, verified manifest.**

---

## Phase 0 — Pre-deployment gates

- [ ] Compiler pinned (`solc 0.8.30`), optimizer settings and EVM target
      identical in local build and CI; dependency versions exact (no floating
      ranges).
- [ ] CI green: `forge fmt --check`, `forge build --sizes`, `forge test -vvv`,
      `forge snapshot --check`, `slither .` — no unjustified high/medium
      findings.
- [ ] Fuzz + invariant suites pass at documented depth (including
      `invariant_windowAccountingConsistent`).
- [ ] Confirm the OpenZeppelin submodule commit equals the `v5.7.0-rc.0` tag
      (`2d59c17d...`) — a **release candidate**, pinned for
      `RateLimiter.SlidingWindow` — and re-review the dependency diff when
      the final `v5.7.0` ships (before the audit gate and any production
      deployment). Single pinned OZ version; no mixing.
- [ ] Deterministic build: two clean-checkout builds produce identical
      creation bytecode; record its hash.
- [ ] Chain config file reviewed: chain ID, production Safe address, manager
      set, locker set, initial limits — all vs. the signed policy document.
      Role arrays non-zero, duplicate-free, strictly ascending (validated
      off-chain before broadcast).
- [ ] Confirm the Safe is deployed on the target chain with the approved
      owner set and threshold, and no modules/guards.

## Phase 1 — Testnet drill (per chain's public test environment)

- [ ] 1. Deploy via `script/DeployVault.s.sol` (direct deployment, no proxy).
- [ ] 2. ERC-721 and ERC-1155 deposit/withdrawal smoke tests pass
      (safe transfers in; manager `withdraw` out; batch ERC-1155 included).
- [ ] 3. Fill the **exact** rolling-window allowance
      (`getRemainingLimit() == 0` after exact fill).
- [ ] 4. Trigger a one-unit-over withdrawal: transaction **succeeds** (does
      not revert), returns `false`, emits `AutoLocked`, `isLocked() == true`.
- [ ] 5. Confirm **no transfer occurred** on auto-lock (token balances
      unchanged, no consumption recorded — `getWindowState()` unchanged by
      that tx).
- [ ] 6. Manual emergency lock exercised from **every** configured locker
      path (and from the Safe); `Paused(account)` observed on the actual
      transition, and repeated locks confirmed as **silent no-ops** (no
      event — verify via `isLocked()`).
- [ ] 7. Safe `unlock()` executed; verify `Unpaused(account)` and that
      active history remains (usage not reset). Also exercise the paused-only
      `resetWindowAndSetPeriod`: verify `WindowEpochReset`, erased usage
      (`getRecentWithdrawn() == 0`), vault still paused, and that `setLimits`
      with a changed period reverts `PeriodIsImmutable`.
- [ ] 8. Rotate one manager and one locker via full-set replacement; verify
      `ManagersChanged`/`EmergencyLockersChanged` hashes and view output.
- [ ] 9. ERC-20 rescue exercised (unlocked and locked).
- [ ] 10. Force native currency into the vault (selfdestruct funder) and
      exercise `rescueNative`; also confirm ordinary sends revert
      (`DirectNativeTransferRejected`).
- [ ] 11. Indexer attribution and monitoring alerts verified end-to-end
      against MONITORING.md (all Critical events fire; anomaly rules fire on
      seeded anomalies).
- [ ] 12. Cross-chain emergency-lock drill: one command locks all testnet
      deployments; verified via independent RPC.

## Phase 2 — Audit gate

- [ ] 13. Independent external security audit completed on the exact commit;
      all accepted findings resolved or formally risk-accepted in writing.
- [ ] Post-audit: if any code changed, rebuild, rerun Phase 0/1, and record
      the new audited bytecode hash. **No material custody before this gate.**

## Phase 3 — Production deployment (per chain)

- [ ] 14. Deploy with `script/DeployVault.s.sol`:
      - correct chain ID validated by the script;
      - `initialOwner` = **production Safe from construction** (never
        deploy-then-transfer);
      - script confirms on-chain `owner() == Safe` and vault starts
        **unpaused** (`isLocked() == false`);
      - script reads back every limit and role from chain;
      - script writes `deployments/<chain>.json` (address, chain ID,
        constructor args, bytecode hash, tx hash, deployment block);
      - explorer source verification submitted.
- [ ] 15. Verify manifest and bytecode **before attributing any deposits**:
      - [ ] `deployments/<chain>.json` reviewed and signed off against the
            policy document (Safe, managers, lockers, limits, chain ID);
      - [ ] run `script/VerifyDeployment.s.sol` independently against the
            manifest — must pass with zero mismatches;
      - [ ] compare runtime bytecode: fetch with `eth_getCode` and hash —
            `cast keccak $(cast code <vaultAddress> --rpc-url <rpc>)` —
            against the audited build's runtime bytecode hash, from **two
            independent RPC providers**;
      - [ ] `pendingOwner() == address(0)`; deployment events match the
            exact constructor baseline at the recorded block — in order:
            `OwnershipTransferred(address(0), owner)`, `ManagersChanged`,
            `EmergencyLockersChanged`, `LimitsChanged((0,0,0), initial)`;
            exactly four events, **no** `Paused` event (vault starts
            unpaused);
      - [ ] monitoring configured and armed for this address (topics pinned
            via `cast sig-event`, drift baselines loaded from the manifest);
            do **not** enable indexer attribution until this box and all of
            step 15 are complete.
- [ ] Deployment cost report recorded at multiple gas-price scenarios (and
      L1 data fee for Base), from live fee data.

## Phase 4 — Production drill and sign-off (per chain)

- [ ] 16. Low-value NFT drill: deposit a low-value ERC-721 and ERC-1155;
      Safe `unlock()`; manager withdrawal round-trip; then repeat the
      operational drill — exact fill + one-over auto-lock, emergency lock
      from every locker, Safe unlock with history preserved, manager+locker
      rotation, ERC-20 and native rescue, cross-chain lock drill — on
      production, with monitoring alerts confirmed firing.
- [ ] Restore approved production limits/roles after the drill;
      `VerifyDeployment` re-run clean; manifest and monitoring baselines
      updated for any drill-time rotations.
- [ ] 17. Formal operational sign-off (security lead + operations lead +
      Safe signers quorum) recorded **before increasing custody value**.
      Sign-off asserts: audit gate passed, all boxes above complete on every
      deployed chain (Ethereum, Base, Polygon, Shape), runbooks
      (OPERATIONS.md) staffed, lock-all-chains tooling live and drilled,
      evidence-retention storage active.

## Standing rules

- Vault contracts are immutable: any fix means a new deployment through this
  entire checklist, including the audit gate for code changes.
- Never reuse testnet keys in production; per-chain KMS manager keys only.
- Any manifest change (roles, limits) requires simultaneous update of
  `deployments/<chain>.json` and monitoring baselines, or drift alerts are
  treated as real incidents.
