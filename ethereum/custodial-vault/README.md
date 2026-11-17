# EVM Custodial NFT Vault

Minimal, security-focused custodial vault for **ERC-721** and **ERC-1155**
assets on Ethereum Mainnet, Base, Polygon PoS, and Shape. On Ethereum
Mainnet the deployed contract is the **`CustodialNFTVaultWithPunks`**
extension, which inherits the base vault unchanged and adds a dedicated
**CryptoPunks** withdrawal path.

## Design summary

- Deposits are ordinary (safe) token transfers; receiver callbacks are
  stateless and there is **no on-chain deposit attribution**. The marketplace
  indexer attributes deposits from canonical token events.
- Withdrawals are restricted to 1–10 **manager** accounts sharing a rolling
  window measured in **distinct `(token, tokenId)` pairs** (never ERC-1155
  units).
- **CryptoPunks** (pre-ERC-721) are supported by the
  `CustodialNFTVaultWithPunks` variant only (Ethereum Mainnet — the punks
  contract exists nowhere else). Its `withdrawPunks` entrypoint reuses the
  `WithdrawalItem` shape (`token` = punks contract, `tokenId` = punk index,
  `amount` = 1, `standard` = the canonical `ERC721` placeholder), transfers
  via `transferPunk`, and is built exclusively on the base vault's internal
  rails, so it shares the manager gate, pause state, batch cap, and the
  SAME window budget — one punk = one distinct identifier. Base-vault
  chains do not carry the selector.
- An over-limit request **auto-locks** the vault: it returns `false`, emits
  `AutoLocked` (alongside the standard `Paused` event), transfers nothing,
  records no consumption, and does **not** revert (a revert would roll the
  lock back).
- **Emergency lockers** can only `lock()`. Only the **owner** (a dedicated
  Safe multisig, set in the constructor via `Ownable2Step`) can `unlock()`,
  reconfigure, or rescue ERC-20/native funds. Unlock never erases active
  history. "Locked" is the standard `Pausable` pause state.
- Built on OpenZeppelin primitives: `Ownable2Step` (renunciation disabled),
  `Pausable`, `ERC721Holder`/`ERC1155Holder`, `ReentrancyGuard`, `SafeERC20`,
  `EnumerableSet`, and `RateLimiter.SlidingWindow`. Custom code is limited to
  the batch validators / distinct-token counter, the transfer dispatch, and
  the auto-lock policy, with the shared withdrawal rails exposed to the punks
  extension as two internal hooks (`_checkWithdrawalPreconditions`,
  `_consumeOrAutoLock`).
- Rolling-window accounting is OpenZeppelin `RateLimiter.SlidingWindow` under
  a single global key: a consumption expires exactly when the full period has
  elapsed. `periodSeconds` is immutable via `setLimits`; the only way to
  change it is the explicit paused-only `resetWindowAndSetPeriod`, which
  erases all window history and emits `WindowEpochReset`. Limiter checkpoint
  storage is **not** permanently bounded — see the storage-growth trade-off
  in `docs/THREAT_MODEL.md` and the benchmarks in `test/gas/VaultGas.t.sol`.
- No delegatecall, no proxy/upgrade path, no ownership renunciation. The
  vault starts **unlocked**.
- The owner has an unrestricted **`execute(target, value, data)`** (plain
  call, Critical `Executed` event) for recovering assets that follow none of
  the supported standards (future-unknown standards). Accepted-risk
  design decision: the owner Safe already holds effective root over custody
  (it can replace all roles, max limits, epoch-reset the window, and drain
  in ~10 transactions), so `execute` removes friction rather than granting
  new capability — the Safe itself is the security boundary
  (`docs/THREAT_MODEL.md` §5.7).

## Repository layout

```text
src/CustodialNFTVault.sol            Base vault (direct deployment, no proxy)
src/CustodialNFTVaultWithPunks.sol   CryptoPunks extension (Ethereum Mainnet)
src/interfaces/ICustodialNFTVault.sol
src/interfaces/ICustodialNFTVaultWithPunks.sol
src/interfaces/ICryptoPunks.sol      Minimal pre-ERC-721 punks interface
test/unit/                           Caller matrix, deposits, withdrawals
                                     (incl. punks), rolling window, locking,
                                     configuration, rescue, events/views
test/fuzz/                           Property tests (batches, limits, roles)
test/invariant/                      Stateful invariants + handler
test/gas/                            Gas benchmarks (snapshot-checked in CI)
test/fork/                           Ethereum/Base/Polygon fork smoke tests
test/mocks/                          Hostile and standard token mocks
script/DeployVault.s.sol             Manifest-driven deployment (`withPunks`
                                     manifest flag selects the variant)
script/VerifyDeployment.s.sol        Independent on-chain state verification
script/OperationalDrill.s.sol        Testnet rollout drill (spec §27)
script/deploy-shape-base.sh          Same-address (nonce-0) Shape+Base deploy
deployments/<chain>.json             Approved manifests + deployment records
docs/                                Threat model, operations, monitoring,
                                     deployment checklist
```

## Toolchain (pinned)

| Component | Version |
|---|---|
| Solidity | `0.8.30` (exact, `foundry.toml`) |
| EVM target | `cancun` (supported on all four target chains) |
| Optimizer | enabled, `optimizer_runs = 200` |
| OpenZeppelin Contracts | `v5.7.0-rc.0` (git submodule, non-upgradeable package only, single pinned version — no mixing) |
| forge-std | `v1.11.0` (git submodule, tests only) |
| Foundry | `1.7.1` (CI-pinned) |
| Slither | static analysis gate |

> **Release-candidate warning:** `v5.7.0-rc.0` is a **release candidate**,
> pinned because `RateLimiter.SlidingWindow` first ships in it. The pinned
> submodule commit (`2d59c17d…`) must be independently reviewed, and the diff
> re-reviewed against the final `v5.7.0` release before any production
> deployment.

Clone with submodules:

```sh
git clone --recurse-submodules <repo>
```

## Build and test

```sh
forge build --sizes         # compile + bytecode size report
forge test -vvv             # unit + fuzz + invariant + gas suites
forge snapshot --check      # gas regression gate
forge fmt --check           # formatting gate
slither .                   # static analysis gate
make ci                     # all of the above
```

Fork tests are skipped unless the corresponding RPC env var is set:

```sh
ETHEREUM_RPC_URL=... BASE_RPC_URL=... POLYGON_RPC_URL=... forge test --match-path "test/fork/*"
```

## Deployment

1. Edit the approved manifest `deployments/<chain>.json` (Safe owner,
   strictly ascending manager/locker arrays, limits inside the immutable hard
   caps; `"withPunks": true` on Ethereum Mainnet only selects the
   `CustodialNFTVaultWithPunks` variant). See `docs/DEPLOYMENT_CHECKLIST.md`
   for the full rollout procedure, including the mandatory testnet drill.
   Shape + Base share one address via the nonce-0 script:
   `make deploy-shape-base`.
2. Deploy and verify sources on the explorer:

   ```sh
   export ETHEREUM_RPC_URL=... ETHERSCAN_API_KEY=...
   make deploy-ethereum     # CHAIN_NAME=ethereum forge script ... --broadcast --verify
   ```

3. Independently verify on-chain state and runtime bytecode against the
   manifest (also run this before attributing any deposits):

   ```sh
   make verify-ethereum
   ```

4. Run the operational drill against a public test environment:

   ```sh
   forge script script/OperationalDrill.s.sol:OperationalDrill \
       --rpc-url $TESTNET_RPC_URL --broadcast -vvvv
   ```

All deployments run from an operator machine via the Make targets above —
there is intentionally **no deployment workflow in CI** (the only GitHub
Actions workflow is `.github/workflows/evm-custodial-vault.yml` at the
repository root, the test/lint gate). Base and Shape must be
deployed together through `make deploy-shape-base` (nonce-0 address parity).

## Hard caps (immutable)

| Cap | Value |
|---|---|
| Distinct tokens per window | 2,000 |
| Window length | 30 days (min 1 s) |
| Items per batch | 50 |
| Managers | 10 |
| Emergency lockers | 10 |

## Reference standards

- [ERC-165: Standard Interface Detection](https://eips.ethereum.org/EIPS/eip-165)
- [ERC-20: Fungible Token Standard](https://eips.ethereum.org/EIPS/eip-20)
- [ERC-721: Non-Fungible Token Standard](https://eips.ethereum.org/EIPS/eip-721)
- [ERC-1155: Multi Token Standard](https://eips.ethereum.org/EIPS/eip-1155)
- [EIP-2929/2200 storage and cold-access gas rules](https://eips.ethereum.org/EIPS/eip-2929)
