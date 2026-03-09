// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {LendingPool}      from "../src/LendingPool.sol";
import {LendingPoolV2}    from "../src/LendingPoolV2.sol";
import {TransparentProxy} from "../src/TransparentProxy.sol";

/**
 * @title DeployProtocol
 * @notice Deploy script for the lending protocol
 *
 *  Run:
 *    forge script script/Deploy.s.sol --rpc-url <RPC> --broadcast
 *
 *  Upgrade:
 *    forge script script/Deploy.s.sol:UpgradeToV2 --rpc-url <RPC> --broadcast
 */
contract DeployProtocol is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        // 1. Deploy implementation
        LendingPool impl = new LendingPool();
        console2.log("Implementation V1:", address(impl));

        // 2. Encode initialize call
        bytes memory initData = abi.encodeCall(LendingPool.initialize, (deployer));

        // 3. Deploy proxy (admin = deployer for simplicity; use ProxyAdmin in prod)
        TransparentProxy proxy = new TransparentProxy(
            address(impl),
            deployer,       // proxyAdmin
            initData
        );
        console2.log("Proxy (use this address):", address(proxy));

        vm.stopBroadcast();

        // Verify
        LendingPool pool = LendingPool(payable(address(proxy)));
        console2.log("Owner via proxy:", pool.owner());
        console2.log("Version:", pool.version());
    }
}

contract UpgradeToV2 is Script {
    // Set these after initial deploy
    address constant PROXY       = address(0); // TODO: fill in
    address constant PROXY_ADMIN = address(0); // TODO: fill in

    function run() external {
        uint256 adminKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(adminKey);

        // Deploy new implementation
        LendingPoolV2 implV2 = new LendingPoolV2();
        console2.log("Implementation V2:", address(implV2));

        // Upgrade proxy + call initializeV2 atomically
        TransparentProxy proxy = TransparentProxy(payable(PROXY));
        proxy.upgradeToAndCall(
            address(implV2),
            abi.encodeCall(LendingPoolV2.initializeV2, ())
        );

        vm.stopBroadcast();

        LendingPoolV2 pool = LendingPoolV2(payable(PROXY));
        console2.log("Upgraded to version:", pool.version());
    }
}
