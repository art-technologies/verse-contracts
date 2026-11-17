# Verse ERC721-C collections (`LondonTokenC`)

A second Studio deploy option next to the existing London ERC-721: the same artist contract as an
**ERC721-C** creator token (Limit Break Creator Token Standard). It lets **OpenSea enforce creator
earnings**. A Verse **custody exemption** keeps custody withdrawals working whatever transfer
policy is applied to the collection later. Target chain: **Ethereum Mainnet**.

> **Audit gate:** the custody exemption is royalty-bypass logic. Get an independent review
> before mainnet deployment.

## Components

| Contract | Role |
|---|---|
| `src/erc721c/CustodyRegistry.sol` | One per chain, owned by the Verse Safe. Lists custody accounts (Venly custody EOA now; a vault later). `isCustody(address)`. |
| `src/erc721c/LondonTokenCFactory.sol` | Same `createCollection(uri, minter, gatewayManager, name, royaltyBps, owner)` and `NewCollection(address)` as `LondonTokenFactory`, plus `createCollectionWithTransferPolicy(...)` (see below). Deploys the implementation with the registry address baked in. |
| `src/erc721c/LondonTokenCBase.sol` | Implementation used via EIP-1167 clones. The London ABI plus Limit Break `CreatorTokenBase` and the custody exemption. |
| `src/erc721c/LondonERC721.sol`, `OnchainFileStorage.sol` | London's ERC-721 core and on-chain file storage, ported to OZ 5 (same storage layout and getters). |
| `src/erc721c/vendor/limitbreak/` | Unmodified Limit Break `creator-token-standards` v5.0.0 files (MIT); see its README. |

## How transfers are checked

- **Mints** (`mint`, `mintWithPayload`, `mintBatch*`) keep London's behaviour: storage is written
  directly and two `Transfer` events are emitted (`0x0 → creator`, `creator → recipient`). Mints
  are **never validated**, as in standard ERC721-C.
- **Every other transfer** goes through `_transfer`, then `_beforeTokenTransfer`, then
  `_validateBeforeTransfer`. The validator is called with `validateTransfer(caller = msg.sender, from, to, tokenId)`.
  The default validator is **Limit Break Transfer Validator v5**,
  `0x721C008fdff27BF06E7E123956E2Fe03B63342e3`. With the default policy:
  - Plain wallets sending their own NFTs are allowed (OTC).
  - Operators must be whitelisted (e.g. Payment Processor) or authorized: OpenSea's SignedZone
    signs off Seaport fills that include creator earnings.
  - Smart-contract and EIP-7702-delegated owners are blocked.
- **Custody exemption:** if `msg.sender == from` and `from` is registered in `CustodyRegistry`,
  validation is skipped.
  - Only the custody account moving **its own** tokens is exempt. An operator moving a
    custody-held token, a deposit **into** custody, and a marketplace fill are all validated
    normally.
  - The registry call never reverts the transfer. A missing, reverting or malformed registry
    means "not custody", so the transfer is validated.
  - Because the registry address is immutable in the implementation, adding a custody account
    (e.g. a future `CustodialNFTVault`) makes it work on **every existing collection** at once.

Verified on an Ethereum fork against the live v5 validator (`test/fork/EthereumERC721CFork.t.sol`):

| Scenario | Result |
|---|---|
| Venly custody withdraws, default policy | allowed |
| Artist sets Block All OTC / freezes the custody account / switches to Soulbound | custody withdrawal **still allowed**; ordinary holders blocked |
| Custody EOA gets an EIP-7702 delegation | custody withdrawal still allowed (blocked once removed from the registry) |
| `CustodialNFTVault.withdraw` | blocked (`OTCNotAllowedForSmartWallets`) until the vault is registered, then allowed |
| Operator moving a custody token; OpenSea conduit or Seaport without zone sign-off | blocked |
| Payment Processor | allowed |

## Transfer policy at deployment

`LondonTokenCFactory.createCollectionWithTransferPolicy(uri, minter, gatewayManager, name, royaltyBps, owner, policy)`
creates a collection and sets its marketplace rules **in the same transaction**. `createCollection` is
unchanged and keeps Limit Break's default lists: Payment Processor is whitelisted, and OpenSea's
SignedZone can authorise enforced-earnings fills.

```solidity
struct TransferPolicy {
    address[] whitelist;   // operators allowed to move tokens (marketplace / protocol contracts)
    address[] authorizers; // order-level authorizers, e.g. OpenSea SignedZone
    uint8 globalOptions;   // validator v5 global flags (bit 3: also apply Limit Break default lists)
    uint16 rulesetOptions; // whitelist-ruleset flags (bit 0: block all OTC, bit 3: block transfers to contracts)
}
```

During initialization the collection itself calls the validator; the validator accepts calls
from the collection, which is what makes this atomic. It then:

1. Creates a list.
2. Adds `whitelist` as the list's whitelist (type 1) and `authorizers` as its authorizers (type 2).
3. Sets the **Whitelist ruleset (id 4)** with the given flags. An explicit policy keeps whitelist
   semantics even if Limit Break rebinds the default id 0.
4. Applies the list to itself.
5. Transfers ownership of the list to `owner` (the artist).

Each list type takes at most 32 accounts, with no zero addresses. Deployment reverts if the
validator has no code.

| Goal | `whitelist` | `authorizers` | `globalOptions` | `rulesetOptions` |
|---|---|---|---|---|
| No marketplaces (holders can still send wallet-to-wallet) | `[]` | `[]` | 0 | 0 |
| No marketplaces and no wallet-to-wallet transfers | `[]` | `[]` | 0 | 1 |
| Payment Processor only (e.g. Magic Eden) | `[0x9A1D00bEd7CD04BCDA516d721A596eb22Aac6834]` | `[]` | 0 | 0 |
| OpenSea enforced earnings only | `[]` | `[0x000056F7000000EcE9003ca63978907a00FFD100]` | 0 | 0 |
| Same as Limit Break defaults | `[]` | `[]` | 8 | 0 |

Verified against the live v5 validator in `test/fork/EthereumERC721CTransferPolicyFork.t.sol`:
- Each row behaves as described.
- Custody withdrawals still succeed under every policy.
- The artist can add Payment Processor to the list later; other accounts cannot.

**Notes**
- After deployment the **artist owns the list** and can edit it, or apply another list, directly on
  the validator (e.g. via Limit Break's developer tools). Verse cannot change it.
- The superseded staging factories deployed from `a2edf2a` **do not** have this function.
  The current factories in the deployment table below include it; the existing registries
  were reused.
- On Sepolia, list creation adds state, so expect higher gas than on Base or Ethereum (see the
  Sepolia note below).

## Differences from London `LondonTokenBase`

- **Same:** the external ABI (initialize, mint\*, payloads, metadata setters, roles,
  `royaltyInfo`, file storage, `_name`/`_owners`/`_balances`/`_baseUri`/`_payloads` getters) and
  the two-step mint events. The Verse minter and indexer need no changes.
- **Added:**
  - ICreatorToken / ICreatorTokenLegacy (`getTransferValidator`, `setTransferValidator`,
    `getTransferValidationFunction`, `TransferValidatorUpdated`);
  - `custodyRegistry()` and `isVerseCustody(address)`;
  - `MintingManagerUpdated` and `GatewayManagerUpdated` events.
- **Deliberately left out:** Limit Break's validator auto-approval
  (`AutomaticValidatorTransferApproval`: `setAutomaticApprovalOfTransfersFromValidator` /
  `autoApproveTransfersFromValidator`). The collection owner chooses the validator, so
  auto-approval would let the owner install a contract that takes holders' (and Verse custody's)
  tokens without their approval, even after an explicit revoke. A validator here can only allow or
  block transfers; moving a token always needs the holder or an operator the holder approved.
  Regression test: `test_ownerInstalledValidator_cannotMoveHoldersOrCustodyTokens`.
- **Fixed:**
  - Royalties are **capped at 1000 bps** (OpenSea's maximum for enforced earnings); London
    allowed 100%.
  - `symbol()` returns `VERSE`. London clones return `""`, because the constructor sets the
    symbol only on the implementation (confirmed on mainnet clones).
  - Initialization uses an explicit flag, and the implementation is locked. London's guard
    `bytes(_name).length == 0` leaves a clone re-initializable (and ownable by anyone) if it
    was created with an empty name, or if the owner later calls `setCollectionName("")`.
  - `mintBatchWithPayload` checks the payloads array length.

## Who can change what

| Actor | Power | Effect on custody withdrawals |
|---|---|---|
| Artist (`owner()`) | Validator policy via the validator (ruleset, options, lists, frozen accounts), `setTransferValidator` (including `address(0)` or any contract), royalties, metadata, roles. **Cannot move holders' tokens:** there is no validator auto-approval. | None. The exemption bypasses the validator for registered custody. A rogue validator can at worst block other transfers. |
| Limit Break | Automatic updates of the default ruleset (ruleset id 0) and default lists | None for custody. Can change what ordinary holders and marketplaces may do. |
| Verse Safe (`CustodyRegistry` owner) | Add or remove custody accounts | **Royalty-bypass power.** A registered contract that trades for third parties could move Verse ERC721-C tokens it owns without royalties. Register only accounts that Verse controls and that only send tokens they custody. Consider a TimelockController in front of the Safe. `renounceOwnership` is disabled. |

**Not covered:** third-party ERC721-C collections deposited into Verse custody. Their policy is
not Verse's. Plain-wallet custody works under their default policy but fails if their creator
blocks OTC or freezes the account. Gate deposits with
`validator.validateTransferSim(collection, custody, custody, recipient, tokenId)`.

## Operations

- **Deploy:**
  1. Fill `deployments/erc721c/ethereum.json` (`registryOwner` = production Safe).
  2. Run `CHAIN_NAME=ethereum forge script script/DeployLondonTokenC.s.sol:DeployLondonTokenC --rpc-url ethereum --broadcast --verify -vvvv`.
  3. The script validates the manifest, deploys the registry and factory, re-reads every value
     from chain, and records addresses and bytecode hashes under `.deployment`.
- **Register a new custody account** (e.g. a mainnet `CustodialNFTVault`): the Safe calls
  `setCustodian(vault, true)`. Remove with `setCustodian(account, false)`.
- **Monitor:**
  - `CustodianSet` events on the registry; alert on any addition.
  - `TransferValidatorUpdated` on collections; alert when an artist disables or replaces the
    validator.
- **Studio integration:**
  - Add a new contract type (it maps to the existing on-chain minter path, since the mint ABI
    is unchanged).
  - Point at the factory address, and cap the royalty input at 10%.
  - Explain the trade-off: enforced collections trade only on OpenSea and Payment Processor
    marketplaces.
  - After deploy, tell the artist to enable enforced earnings in **OpenSea Studio** (the
    contract owner must do this).

## Deployments

| Chain | CustodyRegistry | LondonTokenCFactory | LondonTokenCBase implementation |
|---|---|---|---|
| Base Mainnet (staging) | `0x0805bdCd64EF1f7a23c9591242F9A15a9b01F65B` | `0x468323BCaC8186A6BBf65ec7f14F3211B239fF78` | `0x9f5BCc66890677944f1eAE40E8cd69a84EF7B484` |
| Sepolia (staging) | `0xd53f0da2419c46CEe25a88e3da257187c6B455aB` | `0xFC8ed90b708864114D1971783D751A4efBCbAfB9` | `0xecFC05FA9322393930e3aa4778eE77B5E2F8C922` |
| Ethereum Mainnet | `0x1a74DeF035593bD8B6EA1b41fae860E791B16e84` | `0x9BCB0a7ed5b13FF6Da5B84121A3b2D744818Dd4C` | `0x488f8e5d99F7C1560103b1A44ab85F4A22584b23` |

- **Current staging factories:** deployed from source revision `1c9e85a`, with
  `script/DeployLondonTokenCFactory.s.sol`, reusing the existing registries. They include the
  transfer-policy deploy option and have **no validator auto-approval**. Factory, implementation
  and registry are **Etherscan-verified** on both chains.
- **Superseded factories** (from `a2edf2a`) are listed under `.deployment.supersededFactories` in
  each manifest: Base `0x36a8…9B40`, Sepolia `0xCaAA…Aa64`. They still have validator
  auto-approval. Base has two test collections from the old factory, owned by the staging
  deployer, with auto-approval off.

- **Ethereum Mainnet (2026-11-16):** deployed with `DeployLondonTokenC.s.sol` from
  `9869463` (contract source unchanged from `1c9e85a`). Registry owner is Safe
  `0x85F33bF67E9ba90bc810044b0da374C1F0DcA978` (3-of-6, v1.3.0), set directly in
  the constructor; no ownership handoff is pending. The initial custodian is the
  production Venly EOA `0xB4B57125AF2aCf9Bf605A9D9C3D256537876f65A`.
  Registry and factory transactions landed in blocks 26427712 and 26427713;
  total gas cost was 0.000841812297829097 ETH. All three contracts have Sourcify
  exact creation/runtime matches and are **Etherscan-verified** with exact source
  matches. Source and ABI links for both explorers are recorded in the manifest.
  The Ethereum registry address also exists as a staging vault address on Base:
  always select the chain when reading these records.

- **Records:** full deployment records, including transaction hashes, blocks and bytecode hashes, are in `deployments/erc721c/<chain>.json`.
- **Original staging source:** commit `a2edf2a`, Sourcify `exact_match` for those original deployments.
- **Ownership:** the staging registries are owned by the staging deployer EOA, which also owns the staging `CustodialNFTVault`. Transfer ownership (two-step) before retiring that key.
- **Registered custodians:**
  - Base: the staging Venly custody EOA `0x1039…09F8` and the staging vault `0x1a74…6e84`.
  - Sepolia: the staging Venly custody EOA `0x48c4…5C8E`.

**Sepolia gas:** Sepolia's current gas schedule charges about 1,558 gas per byte of deployed code (200 on Ethereum and Base). Forge's local simulation therefore underestimates contract creations by about 6–7×: the first Sepolia attempt ran out of gas. The 1c9e85a factory used 28.7M gas on Sepolia against 4.1M on Base. Broadcast there with `--gas-estimate-multiplier 850`, and compare the node's `eth_estimateGas` before broadcasting on any chain that runs a newer fork than the local EVM.

## Testing

This is a self-contained Foundry project. Run these commands from
`verse-contracts/ethereum/london-token-c` after `git submodule update --init --recursive`.
`foundry.toml` pins the compiler, and `lib/` pins the dependencies used for the deployed
contracts. Keep those settings and the `src/` paths unchanged: the factory, implementation and
registry then reproduce the verified creation/runtime bytecode and metadata.

```bash
forge test --match-path "test/erc721c/*"                                   # unit (mock validator)
ETHEREUM_RPC_URL=<rpc> forge test --match-path "test/fork/*"               # live validator
```

`test/fork/EthereumERC721CFork.t.sol` also deploys the real `CustodialNFTVault` from the sibling
`../custodial-vault` project (through `include_paths`) to check vault withdrawals.

Each covered behaviour was mutation-checked: removing or loosening the exemption, the validation
hook, the initialization lock, the royalty cap, the token-type registration, the mint event pair
and the registry guards each makes at least one test fail.

## Remaining production integration checks

1. Testnet end-to-end with OpenSea:
   - list and sell with enforced earnings;
   - confirm OpenSea treats the collection as enforceable;
   - check what happens if the artist never configures earnings;
   - check the SDK `fulfillOrder` path used by the Verse trading wallet.
2. Venly `NFT_TRANSFER` on a LondonTokenC collection, including gas estimation.
3. External review of the exemption and registry governance (Safe, optional timelock).
