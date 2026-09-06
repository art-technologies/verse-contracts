#!/usr/bin/env bash
set -euo pipefail

# Same-address deployment of CustodialNFTVault to Shape (360) and Base (8453)
# mainnets via a FRESH deployer EOA and plain CREATE.
#
# The contract address is keccak256(deployer, nonce), so deploying from the
# same EOA with nonce 0 on both chains yields the identical address —
# constructor args (admin Safe, managers, limits) may differ per chain.
#
# The invariant this script enforces before ANY broadcast:
#   - deployer nonce is 0 on BOTH chains
#   - no code exists at the predicted address on either chain
#   - deployer is funded on both chains
# If the first deploy succeeds and the second fails, DO NOT send any other tx
# from this EOA on the remaining chain — retry the deploy so nonce 0 is
# consumed by the vault, or address parity is lost forever.
#
# Required env:
#   DEPLOYER_PRIVATE_KEY  fresh EOA, never used on Shape or Base
#   SHAPE_RPC_URL         Shape mainnet RPC
#   BASE_RPC_URL          Base mainnet RPC
# Optional:
#   ETHERSCAN_API_KEY     Base source verification (best-effort)
#   SKIP_VERIFY=1         skip explorer verification entirely
#
# Manifests: deployments/shape.json and deployments/base.json must be filled
# in (admin Safe deployed on each chain, managers/lockers set) — DeployVault
# validates them before broadcast.

cd "$(dirname "$0")/.."

if [[ -f .env ]]; then
    set -a
    # shellcheck source=/dev/null
    source .env
    set +a
fi

die() { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARN: $*" >&2; }

[[ -d "$HOME/.foundry/bin" ]] && PATH="$HOME/.foundry/bin:$PATH"
command -v cast >/dev/null || die "cast not found (install foundry: https://getfoundry.sh)"
command -v jq >/dev/null || die "jq not found"
: "${DEPLOYER_PRIVATE_KEY:?set DEPLOYER_PRIVATE_KEY (fresh EOA)}"
: "${SHAPE_RPC_URL:?set SHAPE_RPC_URL}"
: "${BASE_RPC_URL:?set BASE_RPC_URL}"

DEPLOYER=$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY")
PREDICTED=$(cast compute-address "$DEPLOYER" --nonce 0 | awk '{print $NF}')
echo "Deployer:          $DEPLOYER"
echo "Predicted address: $PREDICTED"

# Lowercasing via tr: macOS ships bash 3.2, which lacks ${var,,}.
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Vault code already at the predicted address => that chain is done; the
# script skips it so a partially completed run can be resumed safely.
vault_deployed() {
    local rpc=$1
    [[ "$(cast code "$PREDICTED" --rpc-url "$rpc")" != "0x" ]]
}

preflight() {
    local name=$1 rpc=$2 want_chain_id=$3
    local chain_id nonce balance
    chain_id=$(cast chain-id --rpc-url "$rpc") \
        || die "$name: RPC unreachable"
    [[ "$chain_id" == "$want_chain_id" ]] \
        || die "$name: RPC chain id is $chain_id, expected $want_chain_id"
    if vault_deployed "$rpc"; then
        echo "Preflight: $name already has code at $PREDICTED — deploy will be skipped"
        return 0
    fi
    nonce=$(cast nonce "$DEPLOYER" --rpc-url "$rpc")
    [[ "$nonce" == "0" ]] \
        || die "$name: deployer nonce is $nonce with no vault at $PREDICTED — parity unrecoverable with this EOA"
    balance=$(cast balance "$DEPLOYER" --rpc-url "$rpc")
    [[ "$balance" != "0" ]] \
        || die "$name: deployer has no ETH to pay for gas"
    echo "Preflight OK on $name (chain $chain_id, nonce 0, balance ${balance} wei)"
}

deploy() {
    local name=$1 rpc=$2
    echo
    if vault_deployed "$rpc"; then
        echo "=== $name: already deployed at $PREDICTED, skipping ==="
        return 0
    fi
    echo "=== Deploying to $name ==="
    CHAIN_NAME="$name" forge script script/DeployVault.s.sol:DeployVault \
        --rpc-url "$rpc" --private-key "$DEPLOYER_PRIVATE_KEY" --broadcast -vvv
    local addr
    addr=$(jq -r '.deployment.address' "deployments/$name.json")
    [[ "$(lower "$addr")" == "$(lower "$PREDICTED")" ]] \
        || die "$name: deployed at $addr, expected $PREDICTED — nonce parity broken"
    echo "$name: deployed at $addr"
}

verify_base() {
    local args
    args=$(jq -r '.deployment.constructorArgs' deployments/base.json)
    forge verify-contract --chain-id 8453 --watch \
        --etherscan-api-key "${ETHERSCAN_API_KEY:?set ETHERSCAN_API_KEY or SKIP_VERIFY=1}" \
        --constructor-args "$args" \
        "$PREDICTED" src/CustodialNFTVault.sol:CustodialNFTVault \
        || warn "base: verification failed — retry manually with forge verify-contract"
}

verify_shape() {
    local args
    args=$(jq -r '.deployment.constructorArgs' deployments/shape.json)
    forge verify-contract --chain-id 360 --watch \
        --verifier blockscout --verifier-url "https://shapescan.xyz/api" \
        --constructor-args "$args" \
        "$PREDICTED" src/CustodialNFTVault.sol:CustodialNFTVault \
        || warn "shape: verification failed — retry manually with forge verify-contract"
}

preflight shape "$SHAPE_RPC_URL" 360
preflight base "$BASE_RPC_URL" 8453

deploy shape "$SHAPE_RPC_URL"

# Re-check Base immediately before its broadcast: nothing may have consumed
# nonce 0 while the Shape deploy ran.
if ! vault_deployed "$BASE_RPC_URL"; then
    nonce=$(cast nonce "$DEPLOYER" --rpc-url "$BASE_RPC_URL")
    [[ "$nonce" == "0" ]] || die "base: nonce moved to $nonce during Shape deploy"
fi

deploy base "$BASE_RPC_URL"

if [[ "${SKIP_VERIFY:-0}" != "1" ]]; then
    verify_shape
    verify_base
fi

echo
echo "Done. CustodialNFTVault at $PREDICTED on Shape (360) and Base (8453)."
