# Verse contracts

Repository of smart contracts used for [Verse](https://verse.works).

## Contents

| Path | Chain | What |
|---|---|---|
| [`ethereum/contracts/`](ethereum/) | EVM | Payments and Random contracts (Hardhat project) |
| [`ethereum/custodial-vault/`](ethereum/custodial-vault/) | EVM (Ethereum, Base, Polygon PoS, Shape) | `CustodialNFTVault` — custodial vault for ERC-721 / ERC-1155 assets with a rate-limited, auto-locking withdrawal path (Foundry project) |
| [`tezos/payments-capturer/`](tezos/payments-capturer/) | Tezos | `PaymentsCapturer` (Archetype) |
| [`tezos/custodial-vault/`](tezos/custodial-vault/) | Tezos | Custodial vault for FA2 / TZIP-12 assets with a rate-limited, auto-locking withdrawal path (SmartPy project) |
| [`audit/`](audit/) | — | Third-party audit reports |

Each project directory is self-contained: it carries its own README, toolchain
pins, tests and deployment tooling. See the per-project READMEs for build,
test and deployment instructions.

## Custodial vault deployments

The two custodial vaults share one design (deposits are plain token transfers
attributed off-chain; only withdrawals go through the contract, gated by a
manager role, a rolling distinct-token limit, and a non-reverting auto-lock;
admin is a multisig).

| Contract | Network | Address |
|---|---|---|
| `CustodialNFTVault` | Base (8453) | `0x733b0d5a9FC53f35f55754aB5eA58e10004aec11` |
| `CustodialNFTVault` | Shape (360) | `0x733b0d5a9FC53f35f55754aB5eA58e10004aec11` |
| Tezos custodial vault | Tezos mainnet | `KT19WfBM5NVcD8ZDcabdJYG29v4H9g6gZp3n` |

EVM deployment manifests and records (constructor arguments, bytecode hashes,
deployment blocks) live in `ethereum/custodial-vault/deployments/`.

## Cloning

The EVM custodial vault depends on git submodules (OpenZeppelin Contracts and
forge-std):

```sh
git clone --recurse-submodules git@github.com:art-technologies/verse-contracts.git
# or, in an existing clone:
git submodule update --init --recursive
```
