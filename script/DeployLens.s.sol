// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {GemoonLens} from "../src/contracts/lens/GemoonLens.sol";
import {GemoonController} from "../src/contracts/Gemoon.sol";
import {HookManager} from "../src/contracts/hooks/HookManager.sol";
import {IVault} from "../src/contracts/interfaces/IVault.sol";

/// @notice Deploys GemoonLens with CREATE2, so the address depends only on the salt, the
/// constructor arguments and the bytecode: after a reset of the devnet fork the same command
/// redeploys it to the same address, and a run against a chain where it already exists sends
/// nothing.
/// @dev In `forge script --broadcast` CREATE2 goes through the deterministic deployer at
/// `CREATE2_FACTORY` (0x4e59b448...); in `forge test` it is the script contract itself.
///
/// Env:
///  - CONTROLLER_PROXY_ADDRESS  GemoonController proxy
///  - VAULT_PROXY_ADDRESS       Vault proxy
///  - HOOK_ADDRESS        HookManager
///  - POOL_MANAGER              Uniswap V4 PoolManager
///  - LENS_SALT                 CREATE2 salt (optional, default 0)
///
/// Usage: `make deploy-lens` (or `make simulate-lens` without broadcast).
contract DeployLens is Script {
    struct Params {
        address controller;
        address vault;
        address hook;
        address poolManager;
        bytes32 salt;
    }

    error WiringMismatch(string what);
    error Create2FactoryMissing();
    error Create2AddressMismatch(address expected, address actual);

    /// @notice Deploys the Lens from the env configuration, or finds the existing one.
    /// @return lens Lens at the deterministic address.
    function run() external returns (GemoonLens lens) {
        Params memory params = Params({
            controller: vm.envAddress("CONTROLLER_PROXY_ADDRESS"),
            vault: vm.envAddress("VAULT_PROXY_ADDRESS"),
            hook: vm.envAddress("HOOK_ADDRESS"),
            poolManager: vm.envAddress("POOL_MANAGER"),
            salt: vm.envOr("LENS_SALT", bytes32(0))
        });
        if (CREATE2_FACTORY.code.length == 0) revert Create2FactoryMissing();

        vm.startBroadcast();
        lens = deploy(CREATE2_FACTORY, params);
        vm.stopBroadcast();

        console.log("GemoonLens:", address(lens));
        console.log("Block:", block.number);
    }

    /// @notice Address the Lens gets for `params` when deployed through `create2Deployer`.
    /// @param create2Deployer Account CREATE2 is executed from.
    /// @param params          Constructor arguments and salt.
    /// @return Deterministic Lens address.
    function predict(
        address create2Deployer,
        Params memory params
    ) public pure returns (address) {
        return
            vm.computeCreate2Address(
                params.salt,
                keccak256(_initCode(params)),
                create2Deployer
            );
    }

    /// @notice Checks the wiring, then deploys the Lens unless it already exists.
    /// @param create2Deployer Account CREATE2 is executed from, see the contract docs.
    /// @param params          Constructor arguments and salt.
    /// @return lens           Lens at `predict(create2Deployer, params)`.
    function deploy(
        address create2Deployer,
        Params memory params
    ) public returns (GemoonLens lens) {
        _checkWiring(params);

        address expected = predict(create2Deployer, params);
        if (expected.code.length != 0) {
            console.log("GemoonLens already deployed, nothing sent");
            return GemoonLens(expected);
        }

        lens = new GemoonLens{salt: params.salt}(
            params.controller,
            params.vault,
            params.hook,
            params.poolManager
        );
        if (address(lens) != expected)
            revert Create2AddressMismatch(expected, address(lens));
    }

    /// @dev A Lens over contracts that do not point at each other would read wrong pools.
    function _checkWiring(Params memory params) internal view {
        if (
            GemoonController(payable(params.controller)).vault() !=
            IVault(params.vault)
        ) {
            revert WiringMismatch("controller.vault");
        }
        if (
            GemoonController(payable(params.controller)).hook() != params.hook
        ) {
            revert WiringMismatch("controller.hook");
        }
        if (IVault(params.vault).hook() != params.hook)
            revert WiringMismatch("vault.hook");
        if (HookManager(params.hook).vault() != params.vault)
            revert WiringMismatch("hook.vault");
        if (
            address(HookManager(params.hook).poolManager()) !=
            params.poolManager
        ) {
            revert WiringMismatch("hook.poolManager");
        }
    }

    function _initCode(
        Params memory params
    ) internal pure returns (bytes memory) {
        return
            abi.encodePacked(
                type(GemoonLens).creationCode,
                abi.encode(
                    params.controller,
                    params.vault,
                    params.hook,
                    params.poolManager
                )
            );
    }
}
