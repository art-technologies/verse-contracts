#!/usr/bin/env bash
# Deploy the vault to Tezos mainnet.
#
# Usage:
#   scripts/deploy.sh <role-address> [contract-alias]
#
# <role-address> becomes admin + manager + emergency locker (single-address
# deployment, meant for test vaults). For a production deployment with
# separated roles, call scripts/compile.py directly and originate manually.
#
# Requires (all gitignored, never commit):
#   deploy/deployer.key       secret key URI: "unencrypted:edsk..." (chmod 600)
#
# Environment overrides:
#   RPC                  node endpoint   (default https://prod.tcinfra.net/rpc/mainnet)
#   OCTEZ_CLIENT         client binary   (default: octez-client-v25, then octez-client)
#   MAX_TOKENS           rate limit      (default 10)
#   PERIOD_SECONDS       window          (default 600)
#   MAX_ITEMS_PER_BATCH  batch cap       (default 10)
#   BURN_CAP             tez burn cap    (default 4)
#   DRY_RUN=1            simulate the origination, inject nothing
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROLE_ADDR="${1:?usage: scripts/deploy.sh <role-address> [contract-alias]}"
ALIAS="${2:-vault_$(date +%Y%m%d_%H%M%S)}"

export PATH="$HOME/.local/bin:$PATH"
# The repo is shared between macOS and a Linux container; keep each
# platform's venv separate so runs on one OS don't clobber the other's.
export UV_PROJECT_ENVIRONMENT=".venv-deploy-$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m)"
RPC="${RPC:-https://prod.tcinfra.net/rpc/mainnet}"
MAX_TOKENS="${MAX_TOKENS:-10}"
PERIOD_SECONDS="${PERIOD_SECONDS:-600}"
MAX_ITEMS_PER_BATCH="${MAX_ITEMS_PER_BATCH:-10}"
BURN_CAP="${BURN_CAP:-4}"

KEY_FILE="$ROOT/deploy/deployer.key"
BASE_DIR="$ROOT/deploy/.octez-client"
OUT_DIR="$ROOT/deploy/out/$ALIAS"

export TEZOS_CLIENT_UNSAFE_DISABLE_DISCLAIMER=Y

# NB: keep lookups failure-tolerant (|| true) — a failing $(...) inside an
# assignment kills the script under `set -e` BEFORE any error can be printed.
OC="${OCTEZ_CLIENT:-}"
if [ -z "$OC" ]; then
    OC="$(command -v octez-client-v25 || command -v octez-client || true)"
fi
if [ -z "$OC" ]; then
    echo "ERROR: no octez-client found on PATH." >&2
    echo "Need a client that understands the current mainnet protocol" >&2
    echo "(Octez >= 25 for proto PsUshuai). Set OCTEZ_CLIENT=/path/to/it." >&2
    exit 1
fi
command -v uv >/dev/null 2>&1 || { echo "ERROR: uv not found on PATH." >&2; exit 1; }
[ -f "$KEY_FILE" ] || {
    echo "ERROR: $KEY_FILE missing."
    echo "Put the deployer secret key URI there: unencrypted:edsk..."
    echo "and chmod 600 it. The deploy/ directory is gitignored."
    exit 1
}

oc() { "$OC" --base-dir "$BASE_DIR" --endpoint "$RPC" "$@"; }

echo "== 1/4 compile (roles = $ROLE_ADDR, limits = $MAX_TOKENS/$PERIOD_SECONDS/$MAX_ITEMS_PER_BATCH)"
if [ "$(uname -m)" = "aarch64" ]; then
    SMARTPY_PKG=$(cd "$ROOT" && uv run python -c \
        "import importlib.util; print(importlib.util.find_spec('smartpy').submodule_search_locations[0])")
    QEMU="$(command -v qemu-x86_64-static || echo "$HOME/.local/bin/qemu-x86_64-static")"
    export SMARTPY_OASIS="$QEMU $SMARTPY_PKG/smartpy-oasis-linux.exe"
    export SMARTPY_CANOPY="$QEMU $SMARTPY_PKG/smartpy-canopy-linux.exe"
fi
(cd "$ROOT" && uv run python scripts/compile.py \
    --admin "$ROLE_ADDR" --manager "$ROLE_ADDR" --locker "$ROLE_ADDR" \
    --max-tokens "$MAX_TOKENS" --period-seconds "$PERIOD_SECONDS" \
    --max-items-per-batch "$MAX_ITEMS_PER_BATCH" \
    --out "$OUT_DIR")

echo "== 2/4 wallet"
mkdir -p "$BASE_DIR"
if ! oc show address deployer >/dev/null 2>&1; then
    oc import secret key deployer "$(cat "$KEY_FILE")"
fi
DEPLOYER=$(oc show address deployer 2>/dev/null | awk '/Hash:/ {print $2}')
BALANCE=$(oc get balance for deployer)
echo "deployer: $DEPLOYER  balance: $BALANCE  rpc: $RPC"

echo "== 3/4 originate ($ALIAS, burn cap $BURN_CAP tez)"
DRY_ARGS=()
[ "${DRY_RUN:-0}" = "1" ] && DRY_ARGS=(--dry-run) && echo "(DRY RUN — nothing will be injected)"
RECEIPT="$OUT_DIR/origination.log"
oc originate contract "$ALIAS" transferring 0 from deployer \
    running "$OUT_DIR/vault.tz" --init "$(cat "$OUT_DIR/storage.tz")" \
    --burn-cap "$BURN_CAP" "${DRY_ARGS[@]}" | tee "$RECEIPT"

# real injection prints "New contract KT1... originated", dry runs print an
# "Originated contracts:" block — grab the first KT1 either way
KT=$(grep -oE 'KT1[1-9A-HJ-NP-Za-km-z]{33}' "$RECEIPT" | head -1)
[ -n "$KT" ] || { echo "ERROR: no contract address in receipt ($RECEIPT)"; exit 1; }

if [ "${DRY_RUN:-0}" = "1" ]; then
    echo "== dry run OK (would originate $KT-like contract); skipping verification"
    exit 0
fi

echo "== 4/4 verify on-chain"
check() {  # check <what> <expected> <actual>
    if [ "$3" = "$2" ]; then echo "  ok - $1 = $3"; else
        echo "  FAIL - $1: expected $2, got $3"; exit 1; fi
}
check "get_admin"  "\"$ROLE_ADDR\"" "$(oc run view get_admin  on contract "$KT" with input Unit | tail -1 | tr -d ' ')"
check "is_manager" "True"  "$(oc run view is_manager on contract "$KT" with input "\"$ROLE_ADDR\"" | tail -1 | tr -d ' ')"
check "is_emergency_locker" "True" "$(oc run view is_emergency_locker on contract "$KT" with input "\"$ROLE_ADDR\"" | tail -1 | tr -d ' ')"
check "is_locked"  "False" "$(oc run view is_locked  on contract "$KT" with input Unit | tail -1 | tr -d ' ')"

echo
echo "DEPLOYED: $KT"
echo "receipt:  $RECEIPT"
echo "explorer: https://tzkt.io/$KT"
