# Tezos Custodial FA2 Vault

A minimal, security-focused Tezos smart contract that acts as a custodial
vault for FA2 / TZIP-12 tokens — NFTs, editions and other FA2 assets alike
(the vault does not distinguish token kinds) — implementing the
v1 design proposal (an internal document; section references below such as
"proposal §18" point to it — it is not part of this repository).

Written in **SmartPy** (pinned: `smartpy-tezos==0.24.1` via `pyproject.toml`
+ `uv.lock`). Generated Michelson is committed under `build/`.

> ⚠️ **Audit gate:** this contract must receive an external security audit
> before it custodies anything on mainnet. Scenario + integration tests are
> necessary, not sufficient.

## Design at a glance

Deposits **never call this contract** — they are plain FA2 transfers to the
vault address, attributed off-chain by the marketplace indexer. The contract
only controls the *withdrawal* path:

| Property | Mechanism |
|---|---|
| Only the backend can withdraw | `withdraw` requires `SENDER ∈ managers` (1–10 addresses) |
| A stolen manager key can't drain the vault | rolling-window rate limit (`max_tokens` **distinct tokens** per `period_seconds`), shared across all managers |
| Bad initial storage can't weaken the limits | caps validated in the constructor, by `scripts/compile.py`, **and** re-checked fail-closed on every `withdraw` |
| Over-limit withdrawal doesn't fail — it locks | auto-lock path returns **no operations and no failure**, so the lock survives (a `FAILWITH` would revert it) |
| Incidents can be stopped fast | `lock` callable by admin or any lock-only emergency address |
| Emergency responders can't move funds | emergency role can *only* lock — no unlock, no withdraw, no config |
| Recovery requires the multisig | `unlock` and all config changes are admin-only (admin is expected to be a TzSafe multisig) |
| Admin can't rug *unlogged* | every admin path that can move assets is evented. `execute` emits Critical `executed`; rotate-and-withdraw emits the relevant `managers_changed` / `unlocked` / `limits_changed` / `withdraw` events. Do not rely on these events as advance warning against admin compromise: if the admin is a batching contract or operation group, config changes and withdrawals can land in one operation. `execute` grants no authority the admin lacks — the multisig threshold, not the contract, is the boundary against admin compromise. |
| Admin can't be fat-fingered away | two-step transfer: `set_pending_admin` → `accept_admin` |
| Works behind a multisig | all role checks use `SENDER`, never `SOURCE` |

The rate limiter counts **distinct tokens** — unique `(fa2, token_id)` pairs
per withdrawal — never FA2 amounts: withdrawing 1000 editions of one token
costs 1 unit of the window budget (otherwise large edition balances would be
impossible to withdraw). Duplicated pairs within one batch count once; the
same token withdrawn again in a *later* withdrawal inside the window counts
again (per-withdrawal dedup keeps storage bounded). The theft bound is
therefore "at most `max_tokens` distinct tokens per window", not a unit
count — set `max_tokens` with that in mind.

Trust-model note: any manager can deliberately trigger the auto-lock by
submitting an over-limit batch. This is intentional and accepted — fail-safe
beats availability, and a griefing manager could burn the window's budget
with real withdrawals anyway; admin unlock is the remedy. Treat manager keys
as high-trust operational keys and monitor `auto_locked` events.

**Defense in depth:** the on-chain rolling withdrawal limit with auto-lock
is assumed to be the most bulletproof and simplest layer of security — it is
deliberately dumb and cannot be turned off. Deployments should **also** run
off-chain scanners holding the emergency-locker role: they implement any
richer policy (anomaly detection, business rules, allowlists, velocity
heuristics) and lock withdrawals remotely via `lock()`. These are additional
layers *on top of* the on-chain limiter, never a replacement for it.

### Immutable hard caps (compiled in)

| Constant | Value |
|---|---|
| `HARD_MAX_ITEMS_PER_BATCH` | 50 items |
| `MIN_PERIOD_SECONDS` | 1 s |
| `HARD_MAX_PERIOD_SECONDS` | 2 592 000 s (30 days) |
| `HARD_MAX_TOKENS_PER_PERIOD` | 2 000 distinct tokens |
| `HARD_MAX_EMERGENCY_LOCKERS` | 10 addresses |
| `HARD_MAX_MANAGERS` | 10 addresses |

`HARD_MAX_TOKENS_PER_PERIOD` and `HARD_MAX_PERIOD_SECONDS` exist to bound
`withdrawal_history` (see Storage below) and therefore per-operation gas; a
compromised admin could always drain the vault eventually (rotate managers,
unlock at will), so the caps are a gas/robustness bound, not a theft bound —
the multisig itself is the security boundary for limits.

`MIN_PERIOD_SECONDS = 1` is a deliberate escape hatch: the admin (multisig)
can set `period_seconds=1`, which makes every history record expire almost
immediately and practically disables the rate limiter when operationally
needed. `limits_changed` events make this visible to monitoring — alert on
suspiciously low periods.

The literals live in `check_limits_` / `set_emergency_lockers` /
`set_managers`, mirrored in `__init__` (initial storage bypasses the
setters). The `withdraw` fail-closed guard re-checks the *limits* and the
manager-set size only — not the locker set, which has no withdrawal
authority (third-party vault copies with arbitrary storage are out of scope
anyway: deposits are only ever attributed to the vault we deploy through
`scripts/compile.py`). Change the caps *before* deployment if needed — the
admin cannot change them after origination.

## Repository layout

```
contracts/vault.py             the vault (single SmartPy contract, auditable)
tests/test_vault.py            scenario tests (16 scenarios, SmartPy harness)
tests/mocks.py                 SimpleFA2 / RejectingFA2 / RecordingFA2 / AdminProxy / ViewCaller
integration/run_sandbox_tests.py  26 checks on a real protocol (octez mockup)
integration/compile_fixtures.py   FA2 fixtures for the integration run
scripts/compile.py             compiles contract + initial storage to build/
build/vault.tz|.json           committed generated Michelson (annotated / JSON)
build/storage.tz|.json         initial storage (placeholder addresses)
pyproject.toml + uv.lock       pinned compiler + locked environment (uv)
Makefile                       compile / test / integration targets
```

## Storage

```python
storage_type = sp.record(
    admin=sp.address,                      # TzSafe multisig
    pending_admin=sp.option[sp.address],   # two-step transfer target
    managers=sp.set[sp.address],           # KMS-backed withdrawal signers (1–10)
    emergency_lockers=sp.set[sp.address],  # lock-only addresses
    locked=sp.bool,
    limits=sp.record(max_tokens=sp.nat, period_seconds=sp.nat,
                     max_items_per_batch=sp.nat),
    withdrawal_history=sp.list[sp.record(timestamp=sp.timestamp, tokens=sp.nat)],
    metadata=sp.big_map[sp.string, sp.bytes],   # TZIP-16
)
```

`withdrawal_history` is bounded: every active record has `tokens ≥ 1` (the
distinct-token count of that withdrawal) and records only enter while the
active total is within the `max_tokens` *in force at that time*. Note that
lowering `max_tokens` via `set_limits` keeps still-active records, so the
active total can sit above the *new* `max_tokens` until those records expire
(further withdrawals auto-lock meanwhile) — the guaranteed bound is
therefore `HARD_MAX_TOKENS_PER_PERIOD = 2000` records, not the current
`max_tokens`. Expired records are pruned on every withdrawal, unlock and
limit change — pruning always uses the *current* `period_seconds`, so
*raising* the period can re-activate stored-but-expired records
("resurrection"). This is intended and conservative: it can only shrink the
available budget, never grow it. Every `withdraw` iterates the list once, so the hard cap also
bounds per-operation gas. Keep `max_tokens` proportionate to real traffic
anyway — the cap is a ceiling, not a target.

## Entrypoints

| Entrypoint | Caller | Effect |
|---|---|---|
| `withdraw(list of {fa2, token_id, amount, recipient})` | manager | Emits grouped FA2 `transfer` calls (vault → recipient). Over-limit ⇒ auto-lock, **no transfers, no failure**. |
| `lock()` | admin or emergency locker | Pause withdrawals. Idempotent: re-locking while locked succeeds. |
| `unlock()` | admin | Resume withdrawals. Prunes only *expired* history — never resets the active window. |
| `set_pending_admin(address)` | admin | Start two-step admin transfer. |
| `accept_admin()` | pending admin | Complete admin transfer. |
| `set_managers(set of address)` | admin | Replace the withdrawal manager set (1–10). |
| `set_emergency_lockers(set of address)` | admin | Replace lock-only addresses (1–10). |
| `set_limits({max_tokens, period_seconds, max_items_per_batch})` | admin | Change limits within hard caps. |
| `rescue_fa1_2({token, recipient, value})` | admin | Recover FA1.2 tokens accidentally sent to the vault (TZIP-7 `transfer`, vault → recipient). Works while locked; not rate-limited. |
| `execute(lambda)` | admin | Run an arbitrary lambda as the vault (rescue hatch for tokens the typed paths cannot move). Emits Critical `executed` in the same transaction. Works while locked; not rate-limited. |

All entrypoints reject non-zero tez.

### Non-FA2 assets sent to the vault

Native tez cannot get stuck: there is no `default` entrypoint, every
entrypoint rejects non-zero tez, and Tezos has no force-send, so the vault's
tez balance is provably always 0. FA1.2 tokens *can* land in the vault's
ledger entry (the token contract is the one called, so the vault can't
refuse); `rescue_fa1_2` exists to recover them. Its parameter is
TZIP-7-typed, so it cannot call a *standard* TZIP-12 `transfer` entrypoint —
targeting a standard FA2 contract fails with `VAULT_NO_FA12_TRANSFER` — and
therefore cannot be used as an FA2 withdrawal bypass against standard
collections. A non-standard contract exposing an FA1.2-shaped `%transfer`
could still be called: this is a type-mismatch guard, not a universal proof.
Tokens of any other standard (or FA2/FA1.2 contracts with broken `transfer`
entrypoints) are recoverable only via the admin-only `execute` lambda.

### Withdraw check order

1. `AMOUNT == 0` else `VAULT_TEZ_REJECTED`
2. stored config within hard caps (fail-closed guard against hand-crafted
   initial storage) else `VAULT_BAD_LIMITS` / `VAULT_TOO_MANY_MANAGERS`
3. `SENDER ∈ managers` else `VAULT_NOT_MANAGER`
4. `locked == false` else `VAULT_LOCKED`
5. every `item.amount > 0` else `VAULT_ZERO_AMOUNT`
6. batch not empty else `VAULT_EMPTY_BATCH`
7. batch length ≤ `max_items_per_batch` else `VAULT_BATCH_TOO_LARGE`
8. `used_in_window + requested ≤ max_tokens` — where `requested` is the
   number of **distinct `(fa2, token_id)` pairs** in the batch, not the sum
   of amounts — otherwise the contract **succeeds while doing nothing
   except**: `locked := true`, emit `%auto_locked`.

Batch items are grouped per FA2 contract into a single TZIP-12 `transfer`
call each (`send_fa2_transfers_` — all FA2 transfer construction lives in
that one helper), preserving item order. If any FA2 transfer fails, Tezos
reverts the entire operation — including the vault's history update (no
partial withdrawals).

**Malformed origination — repair vs. abandon.** The step-2 guard makes a
vault originated with hand-crafted out-of-cap storage unable to withdraw.
Whether it can be *repaired* on-chain depends on what is malformed:
out-of-cap **values** (a wrong number in `limits`, an 11-address manager
set) are cheaply fixable via `set_limits` / `set_managers`. Oversized
**structures** (thousands of managers/lockers/history records) are not:
the setters `PACK` the old sets for event hashes, `unlock`/`set_limits`
iterate the whole history, and — since none of these fields is a big_map —
the entire storage is (de)serialized on every call, so a sufficiently large
storage makes *every* entrypoint exceed gas, including `lock`. Such a vault
must be **abandoned**, which is safe by construction: it holds nothing at
origination, and deposits are attributed off-chain — never attribute
deposits to a vault whose initial storage was not produced by the audited
pipeline (`scripts/compile.py`).

## Errors

`VAULT_TEZ_REJECTED`, `VAULT_NOT_MANAGER`, `VAULT_LOCKED`, `VAULT_NOT_LOCKED`,
`VAULT_EMPTY_BATCH`, `VAULT_BATCH_TOO_LARGE`, `VAULT_ZERO_AMOUNT`,
`VAULT_NOT_ADMIN`, `VAULT_NOT_ADMIN_OR_LOCKER`, `VAULT_NO_PENDING_ADMIN`,
`VAULT_NOT_PENDING_ADMIN`, `VAULT_NO_LOCKERS`, `VAULT_TOO_MANY_LOCKERS`,
`VAULT_NO_MANAGERS`, `VAULT_TOO_MANY_MANAGERS`, `VAULT_BAD_LIMITS`,
`VAULT_NO_FA2_TRANSFER`, `VAULT_NO_FA12_TRANSFER`.

## Events

| Tag | Payload | Alert severity (proposal §18) |
|---|---|---|
| `withdraw` | manager, item_count, distinct_tokens | — |
| `auto_locked` | used_in_window, requested, max_tokens, period_seconds | Critical |
| `locked` | by | Critical |
| `unlocked` | by | Critical |
| `managers_changed` | old_hash, new_hash (blake2b of packed set) | Critical |
| `emergency_lockers_changed` | old_hash, new_hash (blake2b of packed set) | Critical |
| `limits_changed` | old_limits, new_limits | High |
| `pending_admin_set` | old_pending_admin, new_pending_admin | Critical |
| `admin_accepted` | old_admin, new_admin | Critical |
| `fa1_2_rescued` | token, recipient, value | High |
| `executed` | lambda_hash (blake2b of packed lambda) | Critical |

There is intentionally no `deposit` event: deposits don't call the vault.

## Views

`get_admin`, `get_pending_admin`, `is_manager(address)`,
`is_emergency_locker(address)`, `is_locked`, `get_limits`,
`get_recent_withdrawn` (distinct tokens withdrawn in the current window),
`get_remaining_limit`.

## Building and testing

Dependencies and tooling are managed with [uv](https://docs.astral.sh/uv/)
(`smartpy-tezos==0.24.1` pinned in `pyproject.toml`, exact environment in
`uv.lock`).

```sh
uv sync            # create .venv with locked dependencies

make test          # SmartPy scenario tests (16 scenarios)
make compile       # regenerate build/ (contract code + initial storage)
make integration   # 26 checks on a real protocol via octez-client mockup
make fmt           # format + autofix (ruff)
make lint          # CI-style check: ruff format --check && ruff check
```

> **arm64 note:** the SmartPy pip package ships x86_64 compiler binaries; on
> arm64 Linux they run under qemu user emulation. The Makefile detects
> aarch64 and sets `SMARTPY_OASIS` / `SMARTPY_CANOPY` to the qemu-wrapped
> binaries automatically (requires `qemu-x86_64-static` in `~/.local/bin`).

### Test coverage

**Scenario tests** (`tests/test_vault.py`, against the *official* SmartPy FA2
library contracts plus purpose-built mocks): deposit by plain FA2 transfer;
single/batch/edition withdrawals with per-FA2 grouping; full access-control
matrix; input validation; rate limit exact-fill and **auto-lock without
failure** (with `_now`-controlled window expiry and pruning, and the window
shared across managers); unlock never resetting the active window; lock role
matrix and re-lock semantics; two-step admin transfer with all negative
paths; manager-set/locker rotation and both hard caps; limit validation
against hard caps; `SENDER`-not-`SOURCE`
authorization via a multisig stand-in proxy; whole-operation rollback on a
failing FA2; on-chain views through a real caller contract; FA1.2 rescue
against the official SmartPy TZIP-7 template (role matrix, FA2-target
rejection, works-while-locked).

**Integration tests** (`integration/`): the same critical flows executed by
`octez-client` against a real protocol (mockup mode) using the committed
compilation pipeline — see [integration/README.md](integration/README.md),
which also documents the Ghostnet rollout drill.

## Deployment

1. `uv sync`
2. Compile with production parameters (conservative limits; proposal §21):

   ```sh
   uv run python scripts/compile.py \
     --admin KT1...tzsafe \
     --manager tz2...signer1 --manager tz2...signer2 \
     --locker tz1...emergency1 --locker tz1...emergency2 \
     --max-tokens 10 --period-seconds 600 --max-items-per-batch 10 \
     --metadata-uri 'ipfs://...'   # optional TZIP-16 pointer
   ```

3. Originate:

   ```sh
   octez-client originate contract nft_vault \
     transferring 0 from <deployer> \
     running build/vault.tz --init "$(cat build/storage.tz)" --burn-cap 2
   ```

4. Follow the proposal's rollout: Ghostnet first (§20.1), then mainnet with
   the production TzSafe as admin **from origination** (§20.2), a small-value
   NFT smoke test, an emergency lock/unlock drill — and the **external audit
   before any mainnet custody**.

## Out of scope (per proposal §3)

No deposit entrypoint, no on-chain balances or attribution, no collection
allowlist/blocklist, no royalties or order logic, no `authorizer_sig`, no
upgradeability. TzSafe itself and the AWS KMS signer service are external
components and not part of this repository.
