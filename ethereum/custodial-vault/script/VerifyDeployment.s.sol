// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {CustodialNFTVault} from "../src/CustodialNFTVault.sol";
import {ICustodialNFTVault} from "../src/interfaces/ICustodialNFTVault.sol";

/// @notice Independently verifies a recorded deployment against the approved
///         manifest. Fails (reverts) on ANY mismatch between on-chain state
///         and `deployments/<CHAIN_NAME>.json`.
/// @dev Usage:
///   CHAIN_NAME=ethereum forge script script/VerifyDeployment.s.sol:VerifyDeployment \
///       --rpc-url ethereum -vvvv
///
/// Do not rely solely on explorer verification: this script also compares
/// the deployed runtime bytecode hash with both the recorded hash and the
/// hash of the locally compiled runtime code.
contract VerifyDeployment is Script {
    using stdJson for string;

    function run() external view {
        string memory chainName = vm.envString("CHAIN_NAME");
        string memory path = string.concat("deployments/", chainName, ".json");
        string memory json = vm.readFile(path);

        // Manifest (approved configuration). `withPunks` selects the
        // expected contract variant (CustodialNFTVaultWithPunks on Ethereum
        // Mainnet, base CustodialNFTVault elsewhere).
        bool withPunks;
        if (vm.keyExistsJson(json, ".withPunks")) {
            withPunks = json.readBool(".withPunks");
        }
        uint256 chainId = json.readUint(".chainId");
        address admin = json.readAddress(".admin");
        address[] memory managers = json.readAddressArray(".managers");
        address[] memory lockers = json.readAddressArray(".emergencyLockers");
        uint16 maxTokens = uint16(json.readUint(".limits.maxTokens"));
        uint32 periodSeconds = uint32(json.readUint(".limits.periodSeconds"));
        uint8 maxItemsPerBatch = uint8(json.readUint(".limits.maxItemsPerBatch"));

        // Recorded deployment.
        address vaultAddr = json.readAddress(".deployment.address");

        require(block.chainid == chainId, "Verify: chain id mismatch");
        require(vaultAddr.code.length > 0, "Verify: no code at recorded address");

        CustodialNFTVault vault = CustodialNFTVault(payable(vaultAddr));

        // Roles and administration.
        require(vault.owner() == admin, "Verify: admin mismatch");
        _requireSameSet(vault.getManagers(), managers, "managers");
        _requireSameSet(vault.getEmergencyLockers(), lockers, "emergencyLockers");
        for (uint256 i; i < managers.length; ++i) {
            require(vault.isManager(managers[i]), "Verify: manager mapping mismatch");
        }
        for (uint256 i; i < lockers.length; ++i) {
            require(vault.isEmergencyLocker(lockers[i]), "Verify: locker mapping mismatch");
        }

        // Limits.
        ICustodialNFTVault.Limits memory limits = vault.getLimits();
        require(limits.maxTokens == maxTokens, "Verify: maxTokens mismatch");
        require(limits.periodSeconds == periodSeconds, "Verify: periodSeconds mismatch");
        require(limits.maxItemsPerBatch == maxItemsPerBatch, "Verify: maxItemsPerBatch mismatch");

        _verifyBytecodeAndVariant(json, vaultAddr, withPunks);

        console.log("Verification OK for", vaultAddr);
        console.log(
            "  variant:           ", withPunks ? "CustodialNFTVaultWithPunks" : "CustodialNFTVault"
        );
        console.log("  chain id:          ", block.chainid);
        console.log("  admin (Safe):      ", vault.owner());
        console.log("  managers:          ", managers.length);
        console.log("  emergency lockers: ", lockers.length);
        console.log("  locked:            ", vault.isLocked());
        console.log("  used / remaining:  ", vault.getRecentWithdrawn(), vault.getRemainingLimit());
    }

    /// @dev Runtime bytecode: the on-chain hash must equal both the recorded
    ///      hash and the locally compiled runtime code of the variant the
    ///      manifest selects via `withPunks`; the recorded contract name
    ///      (written by DeployVault) must agree with that variant. Split out
    ///      of {run} to keep its stack depth within non-via-IR limits.
    function _verifyBytecodeAndVariant(string memory json, address vaultAddr, bool withPunks)
        internal
        view
    {
        string memory recordedRuntimeHash = json.readString(".deployment.runtimeBytecodeHash");
        bytes32 onchainHash = vaultAddr.codehash;
        require(
            keccak256(bytes(vm.toString(onchainHash))) == keccak256(bytes(recordedRuntimeHash)),
            "Verify: runtime bytecode hash differs from recorded manifest"
        );
        bytes32 localHash = keccak256(
            vm.getDeployedCode(
                withPunks
                    ? "CustodialNFTVaultWithPunks.sol:CustodialNFTVaultWithPunks"
                    : "CustodialNFTVault.sol:CustodialNFTVault"
            )
        );
        require(
            onchainHash == localHash,
            "Verify: on-chain runtime bytecode differs from local build of the expected variant (check compiler pinning and the manifest withPunks flag)"
        );

        if (vm.keyExistsJson(json, ".deployment.contractName")) {
            string memory recordedName = json.readString(".deployment.contractName");
            require(
                keccak256(bytes(recordedName))
                    == keccak256(
                        bytes(withPunks ? "CustodialNFTVaultWithPunks" : "CustodialNFTVault")
                    ),
                "Verify: recorded contractName does not match the manifest withPunks flag"
            );
        }
    }

    function _requireSameSet(address[] memory a, address[] memory b, string memory label)
        internal
        pure
    {
        require(a.length == b.length, string.concat("Verify: ", label, " length mismatch"));
        for (uint256 i; i < a.length; ++i) {
            require(a[i] == b[i], string.concat("Verify: ", label, " member mismatch"));
        }
    }
}
