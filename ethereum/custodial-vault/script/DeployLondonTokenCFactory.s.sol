// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {CustodyRegistry} from "../src/erc721c/CustodyRegistry.sol";
import {LondonTokenCBase} from "../src/erc721c/LondonTokenCBase.sol";
import {LondonTokenCFactory} from "../src/erc721c/LondonTokenCFactory.sol";

/// @notice Redeploys LondonTokenCFactory (and with it the LondonTokenCBase implementation) against
///         the CustodyRegistry already recorded for a chain, e.g. to ship a new implementation
///         without changing the registry or its custodians.
/// @dev Usage:
///   CHAIN_NAME=sepolia forge script script/DeployLondonTokenCFactory.s.sol:DeployLondonTokenCFactory \
///       --rpc-url <rpc> --broadcast -vvvv
///
/// Reads `deployments/erc721c/<CHAIN_NAME>.json`, requires `.deployment.custodyRegistry` to be a
/// live CustodyRegistry on the connected chain, deploys the factory, re-reads the wiring from chain,
/// and overwrites the factory / implementation fields of `.deployment`. Previous factory records are
/// archived by the operator (see docs/ERC721C.md, "Deployments").
contract DeployLondonTokenCFactory is Script {
    using stdJson for string;

    address internal constant VALIDATOR_V5 = 0x721C008fdff27BF06E7E123956E2Fe03B63342e3;

    function run() external {
        string memory chainName = vm.envString("CHAIN_NAME");
        string memory path = string.concat("deployments/erc721c/", chainName, ".json");
        string memory json = vm.readFile(path);

        require(block.chainid == json.readUint(".chainId"), "DeployFactory: chain id mismatch");
        require(
            block.chainid == json.readUint(".deployment.chainId"),
            "DeployFactory: no registry deployment recorded for this chain"
        );
        CustodyRegistry registry = CustodyRegistry(json.readAddress(".deployment.custodyRegistry"));
        require(address(registry).code.length > 0, "DeployFactory: registry has no code");
        require(
            registry.owner() == json.readAddress(".registryOwner"),
            "DeployFactory: registry owner differs from manifest"
        );
        require(registry.custodians().length > 0, "DeployFactory: registry has no custodians");
        require(VALIDATOR_V5.code.length > 0, "DeployFactory: validator v5 not deployed");

        vm.startBroadcast();
        LondonTokenCFactory factory = new LondonTokenCFactory(address(registry));
        vm.stopBroadcast();

        address implementation = factory.tokenImplementation();
        require(factory.custodyRegistry() == address(registry), "DeployFactory: factory registry");
        require(
            address(LondonTokenCBase(implementation).custodyRegistry()) == address(registry),
            "DeployFactory: implementation registry mismatch"
        );
        require(
            LondonTokenCBase(implementation).getTransferValidator() == VALIDATOR_V5,
            "DeployFactory: unexpected default validator"
        );

        vm.writeJson(vm.toString(address(factory)), path, ".deployment.factory");
        vm.writeJson(vm.toString(implementation), path, ".deployment.tokenImplementation");
        vm.writeJson(
            vm.toString(abi.encode(address(registry))), path, ".deployment.factoryConstructorArgs"
        );
        vm.writeJson(
            vm.toString(address(factory).codehash), path, ".deployment.factoryRuntimeBytecodeHash"
        );
        vm.writeJson(
            vm.toString(implementation.codehash),
            path,
            ".deployment.implementationRuntimeBytecodeHash"
        );

        console.log("LondonTokenCFactory:", address(factory));
        console.log("LondonTokenCBase implementation:", implementation);
        console.log("CustodyRegistry (reused):", address(registry));
        console.log("deployment recorded in:", path);
    }
}
