// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {CustodyRegistry} from "../src/erc721c/CustodyRegistry.sol";
import {LondonTokenCBase} from "../src/erc721c/LondonTokenCBase.sol";
import {LondonTokenCFactory} from "../src/erc721c/LondonTokenCFactory.sol";

/// @notice Deploys the Verse ERC721-C stack (CustodyRegistry + LondonTokenCFactory, which deploys
///         the LondonTokenCBase implementation) from a chain manifest and records the result.
/// @dev Usage:
///   CHAIN_NAME=ethereum forge script script/DeployLondonTokenC.s.sol:DeployLondonTokenC \
///       --rpc-url ethereum --broadcast --verify -vvvv
///
/// Reads `deployments/erc721c/<CHAIN_NAME>.json`, validates it before broadcast, deploys, re-reads
/// every value from chain, and writes the deployment record into the manifest under `.deployment`.
contract DeployLondonTokenC is Script {
    using stdJson for string;

    address internal constant VALIDATOR_V5 = 0x721C008fdff27BF06E7E123956E2Fe03B63342e3;

    struct Manifest {
        uint256 chainId;
        address registryOwner;
        bool allowEOAOwner;
        address[] initialCustodians;
    }

    function run() external {
        string memory chainName = vm.envString("CHAIN_NAME");
        string memory path = string.concat("deployments/erc721c/", chainName, ".json");
        Manifest memory m = _readManifest(path);

        require(block.chainid == m.chainId, "DeployLondonTokenC: chain id mismatch");
        require(m.registryOwner != address(0), "DeployLondonTokenC: zero registry owner");
        // The registry owner can exempt any account from royalty enforcement on every Verse
        // ERC721-C collection; it must be the production Safe unless explicitly overridden.
        if (!m.allowEOAOwner) {
            require(
                m.registryOwner.code.length > 0,
                "DeployLondonTokenC: registry owner is not a contract (expected Safe)"
            );
        }
        _requireCustodians(m.initialCustodians);
        // Collections default to this validator; refuse to deploy where it does not exist yet.
        require(VALIDATOR_V5.code.length > 0, "DeployLondonTokenC: validator v5 not deployed");

        vm.startBroadcast();
        CustodyRegistry registry = new CustodyRegistry(m.registryOwner, m.initialCustodians);
        LondonTokenCFactory factory = new LondonTokenCFactory(address(registry));
        vm.stopBroadcast();

        address implementation = factory.tokenImplementation();
        require(registry.owner() == m.registryOwner, "DeployLondonTokenC: registry owner mismatch");
        require(registry.pendingOwner() == address(0), "DeployLondonTokenC: pending owner set");
        _requireSameSet(registry.custodians(), m.initialCustodians);
        require(factory.custodyRegistry() == address(registry), "DeployLondonTokenC: factory reg");
        require(
            address(LondonTokenCBase(implementation).custodyRegistry()) == address(registry),
            "DeployLondonTokenC: implementation registry mismatch"
        );
        require(
            LondonTokenCBase(implementation).getTransferValidator() == VALIDATOR_V5,
            "DeployLondonTokenC: unexpected default validator"
        );

        string memory out = "deployment";
        out.serialize("custodyRegistry", address(registry));
        out.serialize("factory", address(factory));
        out.serialize("tokenImplementation", implementation);
        out.serialize("chainId", block.chainid);
        out.serialize("deploymentBlock", block.number);
        out.serialize(
            "registryConstructorArgs", vm.toString(abi.encode(m.registryOwner, m.initialCustodians))
        );
        out.serialize("factoryConstructorArgs", vm.toString(abi.encode(address(registry))));
        out.serialize("registryRuntimeBytecodeHash", vm.toString(address(registry).codehash));
        out.serialize("factoryRuntimeBytecodeHash", vm.toString(address(factory).codehash));
        out.serialize("implementationRuntimeBytecodeHash", vm.toString(implementation.codehash));
        string memory finalJson = out.serialize(
            "broadcastDir",
            string.concat("broadcast/DeployLondonTokenC.s.sol/", vm.toString(block.chainid))
        );
        finalJson.write(path, ".deployment");

        console.log("CustodyRegistry:", address(registry));
        console.log("LondonTokenCFactory:", address(factory));
        console.log("LondonTokenCBase implementation:", implementation);
        console.log("deployment recorded in:", path);
    }

    function _readManifest(string memory path) internal view returns (Manifest memory m) {
        string memory json = vm.readFile(path);
        m.chainId = json.readUint(".chainId");
        m.registryOwner = json.readAddress(".registryOwner");
        m.initialCustodians = json.readAddressArray(".initialCustodians");
        if (vm.keyExistsJson(json, ".allowEOAOwner")) {
            m.allowEOAOwner = json.readBool(".allowEOAOwner");
        }
    }

    function _requireCustodians(address[] memory custodians) internal pure {
        require(custodians.length >= 1, "DeployLondonTokenC: no initial custodians");
        for (uint256 i; i < custodians.length; ++i) {
            require(custodians[i] != address(0), "DeployLondonTokenC: zero custodian");
            for (uint256 j; j < i; ++j) {
                require(custodians[i] != custodians[j], "DeployLondonTokenC: duplicate custodian");
            }
        }
    }

    function _requireSameSet(address[] memory a, address[] memory b) internal pure {
        require(a.length == b.length, "DeployLondonTokenC: custodians length mismatch");
        for (uint256 i; i < a.length; ++i) {
            bool found;
            for (uint256 j; j < b.length; ++j) {
                if (a[i] == b[j]) {
                    found = true;
                    break;
                }
            }
            require(found, "DeployLondonTokenC: custodians mismatch");
        }
    }
}
