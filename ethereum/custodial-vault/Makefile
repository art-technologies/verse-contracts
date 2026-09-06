.PHONY: build test fmt fmt-check snapshot snapshot-check slither coverage clean \
        deploy-ethereum deploy-base deploy-polygon deploy-shape-base \
        verify-ethereum verify-base verify-polygon verify-shape ci

build:
	forge build --sizes

test:
	forge test -vvv

fmt:
	forge fmt

fmt-check:
	forge fmt --check

# Snapshot only the deterministic gas suite; fuzz/invariant gas is not stable.
snapshot:
	forge snapshot --match-path "test/gas/*"

snapshot-check:
	forge snapshot --match-path "test/gas/*" --check

slither:
	slither .

coverage:
	forge coverage --report summary

clean:
	forge clean

ci: fmt-check build test snapshot-check slither

# Deployment. Requires per-chain env:
#   <CHAIN>_RPC_URL, ETHERSCAN_API_KEY and a broadcaster
#   (either DEPLOYER_PRIVATE_KEY or --account / hardware wallet flags).
deploy-ethereum:
	CHAIN_NAME=ethereum forge script script/DeployVault.s.sol:DeployVault \
		--rpc-url ethereum --broadcast --verify -vvvv

deploy-base:
	CHAIN_NAME=base forge script script/DeployVault.s.sol:DeployVault \
		--rpc-url base --broadcast --verify -vvvv

deploy-polygon:
	CHAIN_NAME=polygon forge script script/DeployVault.s.sol:DeployVault \
		--rpc-url polygon --broadcast --verify -vvvv

# Same-address deployment to Shape + Base mainnet from a fresh EOA (nonce 0).
# Requires DEPLOYER_PRIVATE_KEY, SHAPE_RPC_URL, BASE_RPC_URL.
deploy-shape-base:
	./script/deploy-shape-base.sh

verify-ethereum:
	CHAIN_NAME=ethereum forge script script/VerifyDeployment.s.sol:VerifyDeployment \
		--rpc-url ethereum -vvvv

verify-base:
	CHAIN_NAME=base forge script script/VerifyDeployment.s.sol:VerifyDeployment \
		--rpc-url base -vvvv

verify-polygon:
	CHAIN_NAME=polygon forge script script/VerifyDeployment.s.sol:VerifyDeployment \
		--rpc-url polygon -vvvv

verify-shape:
	CHAIN_NAME=shape forge script script/VerifyDeployment.s.sol:VerifyDeployment \
		--rpc-url shape -vvvv
