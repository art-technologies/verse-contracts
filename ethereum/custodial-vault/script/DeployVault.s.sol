// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {CustodialNFTVault} from "../src/CustodialNFTVault.sol";
import {CustodialNFTVaultWithPunks} from "../src/CustodialNFTVaultWithPunks.sol";
import {ICustodialNFTVault} from "../src/interfaces/ICustodialNFTVault.sol";

/// @notice Deploys the vault from a chain manifest and records the result.
/// @dev Usage:
///   CHAIN_NAME=ethereum forge script script/DeployVault.s.sol:DeployVault \
///       --rpc-url ethereum --broadcast --verify -vvvv
///
/// Reads `deployments/<CHAIN_NAME>.json` (the approved manifest), validates
/// it off-chain before broadcast, deploys the direct (non-proxy) contract,
/// re-reads every configuration value from chain, and writes the deployment
/// record back into the manifest under `.deployment`.
contract DeployVault is Script {
    using stdJson for string;

    struct Manifest {
        uint256 chainId;
        address admin;
        address[] managers;
        address[] emergencyLockers;
        address[] auditedForwarders;
        bool allowManagerLockerOverlap;
        bool allowEOAAdmin;
        bool withPunks;
        uint16 maxTokens;
        uint32 periodSeconds;
        uint8 maxItemsPerBatch;
    }

    function run() external {
        string memory chainName = vm.envString("CHAIN_NAME");
        string memory path = string.concat("deployments/", chainName, ".json");
        Manifest memory m = _readManifest(path);

        // 2. Chain ID must match the connected RPC.
        require(block.chainid == m.chainId, "DeployVault: chain id mismatch");

        // 3-4. Validate the Safe, managers, and lockers off-chain before
        // broadcast (the constructor re-validates on-chain).
        require(m.admin != address(0), "DeployVault: zero admin");
        // An EOA admin is only accepted when the manifest explicitly opts in
        // via `allowEOAAdmin` (weaker than the default Safe requirement).
        if (!m.allowEOAAdmin) {
            require(m.admin.code.length > 0, "DeployVault: admin is not a contract (expected Safe)");
        }
        _requireCanonical(m.managers, 10, "managers");
        _requireCanonical(m.emergencyLockers, 10, "emergencyLockers");

        // Managers must be direct EOAs (a contract manager can roll back
        // auto-lock by reverting its outer frame; see docs/THREAT_MODEL.md).
        // A contract manager is only accepted when explicitly listed in the
        // manifest's `auditedForwarders` allowlist.
        _requireEOAManagers(m.managers, m.auditedForwarders);

        // Managers and emergency lockers must be disjoint unless the threat
        // model explicitly approves overlap via the manifest.
        if (!m.allowManagerLockerOverlap) {
            _requireDisjoint(m.managers, m.emergencyLockers);
        }
        require(m.maxTokens >= 1 && m.maxTokens <= 2000, "DeployVault: maxTokens out of caps");
        require(
            m.periodSeconds >= 1 && m.periodSeconds <= 2_592_000,
            "DeployVault: periodSeconds out of caps"
        );
        require(
            m.maxItemsPerBatch >= 1 && m.maxItemsPerBatch <= 50,
            "DeployVault: maxItemsPerBatch out of caps"
        );

        ICustodialNFTVault.Limits memory limits =
            ICustodialNFTVault.Limits(m.maxTokens, m.periodSeconds, m.maxItemsPerBatch);

        // 5. Direct, non-proxy deployment. `withPunks: true` in the manifest
        // deploys the CryptoPunks extension (Ethereum Mainnet only); every
        // other chain gets the base vault without the punk selector.
        vm.startBroadcast();
        CustodialNFTVault vault = m.withPunks
            ? new CustodialNFTVaultWithPunks(m.admin, m.managers, m.emergencyLockers, limits)
            : new CustodialNFTVault(m.admin, m.managers, m.emergencyLockers, limits);
        vm.stopBroadcast();

        // 6-8. Read every value back from chain and fail on any mismatch.
        require(vault.owner() == m.admin, "DeployVault: deployed admin != Safe");
        require(vault.pendingOwner() == address(0), "DeployVault: pendingAdmin not empty");
        require(!vault.isLocked(), "DeployVault: vault must start unlocked");
        _requireSameSet(vault.getManagers(), m.managers, "managers");
        _requireSameSet(vault.getEmergencyLockers(), m.emergencyLockers, "emergencyLockers");
        ICustodialNFTVault.Limits memory onchain = vault.getLimits();
        require(onchain.maxTokens == m.maxTokens, "DeployVault: maxTokens mismatch");
        require(onchain.periodSeconds == m.periodSeconds, "DeployVault: period mismatch");
        require(onchain.maxItemsPerBatch == m.maxItemsPerBatch, "DeployVault: maxItems mismatch");

        // 9. Record the deployment in the manifest. The transaction hash is
        // recorded by Foundry in broadcast/DeployVault.s.sol/<chainid>/;
        // copy it into `.deployment.transactionHash` when archiving.
        bytes memory constructorArgs = abi.encode(m.admin, m.managers, m.emergencyLockers, limits);
        string memory out = "deployment";
        out.serialize("address", address(vault));
        out.serialize("chainId", block.chainid);
        out.serialize("deploymentBlock", block.number);
        out.serialize("constructorArgs", vm.toString(constructorArgs));
        out.serialize(
            "contractName", m.withPunks ? "CustodialNFTVaultWithPunks" : "CustodialNFTVault"
        );
        out.serialize("runtimeBytecodeHash", vm.toString(address(vault).codehash));
        out.serialize(
            "creationBytecodeHash",
            vm.toString(
                m.withPunks
                    ? keccak256(type(CustodialNFTVaultWithPunks).creationCode)
                    : keccak256(type(CustodialNFTVault).creationCode)
            )
        );
        string memory finalJson = out.serialize(
            "broadcastDir",
            string.concat("broadcast/DeployVault.s.sol/", vm.toString(block.chainid))
        );
        finalJson.write(path, ".deployment");

        console.log("CustodialNFTVault deployed:", address(vault));
        console.log("chain id:", block.chainid);
        console.log("deployment recorded in:", path);
    }

    function _readManifest(string memory path) internal view returns (Manifest memory m) {
        string memory json = vm.readFile(path);
        m.chainId = json.readUint(".chainId");
        m.admin = json.readAddress(".admin");
        m.managers = json.readAddressArray(".managers");
        m.emergencyLockers = json.readAddressArray(".emergencyLockers");
        m.maxTokens = uint16(json.readUint(".limits.maxTokens"));
        m.periodSeconds = uint32(json.readUint(".limits.periodSeconds"));
        m.maxItemsPerBatch = uint8(json.readUint(".limits.maxItemsPerBatch"));
        if (vm.keyExistsJson(json, ".auditedForwarders")) {
            m.auditedForwarders = json.readAddressArray(".auditedForwarders");
        }
        if (vm.keyExistsJson(json, ".allowManagerLockerOverlap")) {
            m.allowManagerLockerOverlap = json.readBool(".allowManagerLockerOverlap");
        }
        if (vm.keyExistsJson(json, ".allowEOAAdmin")) {
            m.allowEOAAdmin = json.readBool(".allowEOAAdmin");
        }
        if (vm.keyExistsJson(json, ".withPunks")) {
            m.withPunks = json.readBool(".withPunks");
        }
    }

    function _requireEOAManagers(address[] memory managers, address[] memory auditedForwarders)
        internal
        view
    {
        for (uint256 i; i < managers.length; ++i) {
            if (managers[i].code.length == 0) continue;
            bool allowlisted;
            for (uint256 j; j < auditedForwarders.length; ++j) {
                if (auditedForwarders[j] == managers[i]) {
                    allowlisted = true;
                    break;
                }
            }
            require(allowlisted, "DeployVault: contract manager not in auditedForwarders allowlist");
        }
    }

    function _requireDisjoint(address[] memory managers, address[] memory lockers) internal pure {
        for (uint256 i; i < managers.length; ++i) {
            for (uint256 j; j < lockers.length; ++j) {
                require(
                    managers[i] != lockers[j],
                    "DeployVault: manager/locker overlap requires allowManagerLockerOverlap"
                );
            }
        }
    }

    function _requireCanonical(address[] memory arr, uint256 max, string memory label)
        internal
        pure
    {
        require(arr.length >= 1 && arr.length <= max, string.concat(label, ": bad length"));
        address prev;
        for (uint256 i; i < arr.length; ++i) {
            require(arr[i] != address(0), string.concat(label, ": zero address"));
            require(i == 0 || arr[i] > prev, string.concat(label, ": not strictly ascending"));
            prev = arr[i];
        }
    }

    function _requireSameSet(address[] memory a, address[] memory b, string memory label)
        internal
        pure
    {
        require(a.length == b.length, string.concat(label, ": length mismatch"));
        for (uint256 i; i < a.length; ++i) {
            require(a[i] == b[i], string.concat(label, ": member mismatch"));
        }
    }
}
