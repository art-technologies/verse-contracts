# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A custodial vault contract for FA2/TZIP-12 tokens (NFTs, editions and other FA2 assets alike) on Tezos, written in **SmartPy** (pinned `smartpy-tezos==0.24.1` — the committed Michelson in `build/` was produced with exactly this version; bump deliberately and recompile/retest). Implements the internal v1 design proposal (not part of this repository; "proposal §N" references in the README point to it).

## Commands

Dependency management is via [uv](https://docs.astral.sh/uv/); run `uv sync` once to create `.venv`.

```sh
make test          # SmartPy scenario tests (runs tests/test_vault.py as a script)
make compile       # regenerate build/ (contract code + initial storage)
make integration   # 26 checks against a real protocol (octez-client mockup mode)
make fmt           # ruff format + autofix
make lint          # CI-style: ruff format --check && ruff check
```

- There is no per-test selection: SmartPy executes every `@sp.add_test` function when the test file runs. `make test` runs from inside `.scenarios/` because SmartPy writes scenario artifacts to the CWD.
- `make integration` requires `octez-client` on PATH.
- **arm64 Linux:** the SmartPy pip package ships x86_64 compiler binaries. The Makefile auto-detects `aarch64` and exports `SMARTPY_OASIS` / `SMARTPY_CANOPY` pointing at qemu-wrapped binaries (needs `qemu-x86_64-static` in `~/.local/bin`). If you invoke SmartPy outside of make (e.g. `uv run python tests/test_vault.py` or `scripts/compile.py` directly), you must set those env vars yourself — otherwise the compiler fails with an exec error.
- `make compile` deployment parameters (`ADMIN`, `MANAGER`, `LOCKER`, `MAX_TOKENS`, …) are overridable on the make CLI; committed `build/` uses placeholder addresses. Contract *code* output is independent of these parameters — only `storage.tz`/`storage.json` depend on them.

## Architecture

Single contract, three test layers:

- `contracts/vault.py` — the entire contract, one `@sp.module` (`vault_module`). Entrypoints: `withdraw`, `lock`, `unlock`, `set_pending_admin`/`accept_admin`, `set_managers`, `set_emergency_lockers`, `set_limits`, `rescue_fa1_2`, plus on-chain views.
- `tests/test_vault.py` + `tests/mocks.py` — SmartPy scenario tests (16 scenarios) against the official SmartPy FA2/FA1.2 library templates plus purpose-built mocks (`SimpleFA2`, `SimpleFA1_2`, `RejectingFA2`, `RecordingFA2` for grouping/order checks, `AdminProxy` for SENDER-vs-SOURCE checks, `ViewCaller`).
- `integration/run_sandbox_tests.py` — same critical flows executed by `octez-client` on a real protocol (mockup mode); `integration/compile_fixtures.py` builds the FA2 fixtures.
- `scripts/compile.py` — compiles contract + initial storage into `build/` (both `.tz` and `.json` for Taquito). `build/` is committed; regenerate it whenever the contract changes.

## Security invariants (do not break)

The README documents the full design; these are the properties changes must preserve:

- **Deposits never call the contract** — they are plain FA2 transfers to the vault address, attributed off-chain. There is intentionally no deposit entrypoint and no deposit event.
- **Over-limit withdrawal auto-locks without failing**: it returns no operations and no failure. A `FAILWITH` here would revert the lock itself — this is the core trick of the rate limiter.
- **The rate limiter counts distinct `(fa2, token_id)` pairs per withdrawal, never FA2 amounts** — 1000 editions of one token cost 1 unit of the window budget. Duplicates within a batch count once; the same token in a later withdrawal counts again.
- **Roles are strictly separated**: managers (a set of 1–10 addresses) can only withdraw (rate-limited, one window shared across the whole set); emergency lockers can *only* lock; admin (a TzSafe multisig) does unlock/config/rotation plus two direct asset-motion paths — `rescue_fa1_2` (recovers accidentally sent FA1.2 tokens; typed TZIP-7-only, so it cannot call a *standard* TZIP-12 `transfer` — type-mismatch guard, a non-standard contract exposing an FA1.2-shaped `%transfer` could still be called) and `execute` (arbitrary admin lambda, rescue hatch for tokens the typed paths cannot move). Rationale: admin ownership is already effective root; `execute` grants no new authority. If the admin is a batching contract or operation group, rotate/configure-and-withdraw can also land in one operation. Admin theft is never *unlogged* (`execute` emits `executed`; rotate-and-withdraw emits config/unlock/withdraw events), but those events are not advance warning against admin compromise. The multisig threshold is the actual boundary.
- **Hard caps are compiled in, not storage**: `HARD_MAX_ITEMS_PER_BATCH=50`, `MIN_PERIOD_SECONDS=1` (deliberate escape hatch: `period_seconds=1` practically disables the limiter), `HARD_MAX_PERIOD_SECONDS=2_592_000` (30 days), `HARD_MAX_TOKENS_PER_PERIOD=2_000`, `HARD_MAX_EMERGENCY_LOCKERS=10`, `HARD_MAX_MANAGERS=10`. Literals live in `check_limits_`, `set_emergency_lockers` and `set_managers`, mirrored in `__init__` (SmartPy enforces constructor asserts at trace time) and — for limits and manager-set size only, not lockers (no withdrawal authority) — in the `withdraw` fail-closed config guard. A vault originated with hand-crafted *oversized* storage (huge sets/history) may exceed gas on every entrypoint and is **abandoned, not repaired** (see README "Malformed origination"); only out-of-cap *values* are repairable on-chain. The token/period caps exist to bound `withdrawal_history` length and therefore gas.
- **Any manager can deliberately trigger the auto-lock** (over-limit batch). Intentional and accepted: fail-safe beats availability; admin unlock is the remedy.
- **All role checks use `SENDER`, never `SOURCE`** (must work behind a multisig).
- All entrypoints reject non-zero tez; `withdraw` has a documented check *order* (README "Withdraw check order") that tests assert on.
- `unlock` prunes only *expired* withdrawal history — it must never reset the active rate-limit window.
- All FA2 transfer construction lives in one helper, `send_fa2_transfers_` (groups batch items per FA2 contract into single TZIP-12 `transfer` calls, preserving order).

Error codes are `VAULT_*` strings; state changes emit events (see README tables) that off-chain monitoring alerts on — keep both stable unless deliberately versioning.
