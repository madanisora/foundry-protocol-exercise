// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {LendingPoolV2} from "../src/LendingPoolV2.sol";
import {TransparentProxy} from "../src/TransparentProxy.sol";

/**
 * @notice Educational deployment examples. Use a local Anvil chain first.
 *         Never commit PRIVATE_KEY or other secrets to the repository.
 */
contract DeployProtocol is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);
        LendingPool implementation = new LendingPool();
        bytes memory initData = abi.encodeCall(LendingPool.initialize, (deployer));
        TransparentProxy proxy = new TransparentProxy(
            address(implementation),
            deployer,
            initData
        );
        vm.stopBroadcast();

        console2.log("Implementation V1:", address(implementation));
        console2.log("Proxy:", address(proxy));
        console2.log("Owner:", LendingPool(payable(address(proxy))).owner());
    }
}

contract UpgradeToV2 is Script {
    function run() external {
        uint256 adminKey = vm.envUint("PRIVATE_KEY");
        address proxyAddress = vm.envAddress("PROXY_ADDRESS");
        address expectedAdmin = vm.envAddress("PROXY_ADMIN");
        require(vm.addr(adminKey) == expectedAdmin, "private key is not proxy admin");

        vm.startBroadcast(adminKey);
        LendingPoolV2 implementationV2 = new LendingPoolV2();
        TransparentProxy proxy = TransparentProxy(payable(proxyAddress));
        proxy.upgradeToAndCall(
            address(implementationV2),
            abi.encodeCall(LendingPoolV2.initializeV2, ())
        );
        vm.stopBroadcast();

        console2.log("Implementation V2:", address(implementationV2));
        console2.log("Proxy:", proxyAddress);
        console2.log("Version:", LendingPoolV2(payable(proxyAddress)).version());
    }
}
