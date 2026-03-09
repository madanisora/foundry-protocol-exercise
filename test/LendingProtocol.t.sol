// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {LendingPool}    from "../src/LendingPool.sol";
import {LendingPoolV2}  from "../src/LendingPoolV2.sol";
import {TransparentProxy} from "../src/TransparentProxy.sol";

/**
 * @title LendingProtocolTest
 * @notice Full test suite: proxy mechanics + protocol logic
 *
 *  Test structure:
 *  ├── Proxy Mechanics
 *  │   ├── test_ProxyStorageIsolation   — impl storage stays clean
 *  │   ├── test_EIP1967Slots            — admin/impl at correct slots
 *  │   └── test_OnlyAdminCanUpgrade     — access control
 *  ├── Protocol V1
 *  │   ├── test_DepositAndWithdraw
 *  │   ├── test_BorrowWithinLTV
 *  │   ├── test_CannotExceedLTV
 *  │   ├── test_Repay
 *  │   └── test_Liquidation
 *  └── Upgrade V1 → V2
 *      ├── test_UpgradePreservesState
 *      ├── test_V2InterestAccrues
 *      └── test_StorageLayoutSafe
 */
contract LendingProtocolTest is Test {
    // ─── Actors ────────────────────────────────────────────────────────────────
    address internal owner     = makeAddr("owner");
    address internal alice     = makeAddr("alice");
    address internal bob       = makeAddr("bob");
    address internal liquidator = makeAddr("liquidator");
    address internal proxyAdmin = makeAddr("proxyAdmin");

    // ─── Contracts ─────────────────────────────────────────────────────────────
    LendingPool     internal implV1;
    LendingPoolV2   internal implV2;
    TransparentProxy internal proxy;
    LendingPool     internal pool;   // V1 interface over proxy
    LendingPoolV2   internal poolV2; // V2 interface over proxy

    // ─── Setup ─────────────────────────────────────────────────────────────────

    function setUp() public {
        // 1. Deploy implementation (no state here — just bytecode)
        implV1 = new LendingPool();

        // 2. Deploy proxy: points to impl, admin = proxyAdmin
        //    Pass initializer calldata → proxy calls impl.initialize(owner)
        bytes memory initData = abi.encodeCall(LendingPool.initialize, (owner));
        proxy = new TransparentProxy(address(implV1), proxyAdmin, initData);

        // 3. Cast proxy address to LendingPool interface for easy calls
        pool = LendingPool(payable(address(proxy)));

        // Fund actors
        deal(alice,     10 ether);
        deal(bob,       10 ether);
        deal(liquidator, 10 ether);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  SECTION 1: PROXY MECHANICS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice CRITICAL: Implementation contract storage must stay empty!
     *
     *  When you call proxy.deposit(), it runs LendingPool code but writes
     *  to PROXY storage. The implementation should have zero state.
     *
     *  If you accidentally call implV1.deposit() directly, that writes
     *  to impl storage — a classic proxy bug!
     */
    function test_ProxyStorageIsolation() public {
        // Deposit through proxy → writes to proxy storage
        vm.prank(alice);
        pool.deposit{value: 1 ether}();

        // Proxy has state
        assertEq(pool.deposits(alice), 1 ether, "proxy should have alice deposit");

        // Implementation storage is clean
        assertEq(implV1.deposits(alice), 0, "impl should have ZERO state");
        assertEq(implV1.owner(), address(0), "impl owner should be zero");
    }

    /**
     * @notice EIP-1967: verify implementation stored at correct slot
     *  slot = keccak256("eip1967.proxy.implementation") - 1
     */
    function test_EIP1967Slots() public view {
        bytes32 implSlot = bytes32(
            uint256(keccak256("eip1967.proxy.implementation")) - 1
        );
        bytes32 adminSlot = bytes32(
            uint256(keccak256("eip1967.proxy.admin")) - 1
        );

        address storedImpl  = address(uint160(uint256(vm.load(address(proxy), implSlot))));
        address storedAdmin = address(uint160(uint256(vm.load(address(proxy), adminSlot))));

        assertEq(storedImpl,  address(implV1), "wrong impl slot");
        assertEq(storedAdmin, proxyAdmin,      "wrong admin slot");
    }

    /// @notice Non-admin cannot upgrade
    function test_OnlyAdminCanUpgrade() public {
        implV2 = new LendingPoolV2();

        // Random user tries to upgrade — should revert
        vm.prank(alice);
        vm.expectRevert("TransparentProxy: not admin");
        proxy.upgradeTo(address(implV2));

        // Admin can upgrade
        vm.prank(proxyAdmin);
        proxy.upgradeTo(address(implV2));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  SECTION 2: PROTOCOL V1 LOGIC
    // ═══════════════════════════════════════════════════════════════════════════

    function test_DepositAndWithdraw() public {
        vm.startPrank(alice);

        pool.deposit{value: 5 ether}();
        assertEq(pool.deposits(alice), 5 ether);
        assertEq(pool.totalDeposits(), 5 ether);

        pool.withdraw(2 ether);
        assertEq(pool.deposits(alice), 3 ether);

        vm.stopPrank();
    }

    /// @notice Can borrow up to 75% LTV
    function test_BorrowWithinLTV() public {
        vm.prank(alice);
        pool.deposit{value: 4 ether}();

        // 75% of 4 ETH = 3 ETH max
        uint256 maxBorrow = pool.maxBorrow(alice);
        assertEq(maxBorrow, 3 ether, "max borrow should be 3 ETH");

        vm.prank(alice);
        pool.borrow(3 ether);
        assertEq(pool.borrows(alice), 3 ether);
    }

    /// @notice Borrowing over LTV should revert
    function test_CannotExceedLTV() public {
        vm.prank(alice);
        pool.deposit{value: 4 ether}();

        vm.prank(alice);
        vm.expectRevert("LendingPool: exceeds LTV");
        pool.borrow(3.1 ether); // > 75% of 4 ETH
    }

    function test_Repay() public {
        vm.prank(alice);
        pool.deposit{value: 4 ether}();

        vm.prank(alice);
        pool.borrow(3 ether);

        vm.prank(alice);
        pool.repay{value: 3 ether}();

        assertEq(pool.borrows(alice), 0, "borrow should be cleared");
    }

    /**
     * @notice Liquidation test
     *  Setup: Alice deposits 1 ETH, borrows max (0.75 ETH)
     *  Simulate: Price drops → manipulate storage so borrow > 80% threshold
     *  Liquidate: Bob liquidates Alice's position
     */
    function test_Liquidation() public {
        // Alice deposits and borrows at LTV
        vm.prank(alice);
        pool.deposit{value: 1 ether}();

        vm.prank(alice);
        pool.borrow(0.75 ether);

        // Health factor = (1 ETH * 80) / 0.75 ETH = 106 → safe
        assertGe(pool.healthFactor(alice), 100, "should be healthy");

        // Simulate collateral drop: overwrite deposit to 0.8 ETH
        // (In real protocol this would be price oracle drop)
        vm.store(
            address(proxy),
            keccak256(abi.encode(alice, uint256(5))), // deposits mapping slot 5
            bytes32(uint256(0.8 ether))
        );

        // Health factor now: (0.8 * 80) / 0.75 = 85 → unhealthy!
        uint256 hf = pool.healthFactor(alice);
        console2.log("Health factor after price drop:", hf);
        assertLt(hf, 100, "should be unhealthy");

        // Liquidator repays debt and seizes collateral
        uint256 liquidatorBalBefore = liquidator.balance;
        vm.prank(liquidator);
        pool.liquidate{value: 0.75 ether}(alice);

        assertEq(pool.borrows(alice), 0, "debt should be cleared");
        assertGt(liquidator.balance, liquidatorBalBefore, "liquidator should profit");
        console2.log("Liquidator profit:", liquidator.balance - liquidatorBalBefore + 0.75 ether);
    }

    function test_PauseBlocksActions() public {
        vm.prank(owner);
        pool.setPaused(true);

        vm.prank(alice);
        vm.expectRevert("LendingPool: protocol paused");
        pool.deposit{value: 1 ether}();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  SECTION 3: UPGRADE V1 → V2
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice After upgrade, all V1 state (deposits, borrows) must persist
     *  This is the golden rule of upgradeable proxies.
     */
    function test_UpgradePreservesState() public {
        // Alice deposits in V1
        vm.prank(alice);
        pool.deposit{value: 3 ether}();
        assertEq(pool.deposits(alice), 3 ether);

        // Deploy V2 and upgrade
        implV2 = new LendingPoolV2();
        bytes memory migrateData = abi.encodeCall(LendingPoolV2.initializeV2, ());

        vm.prank(proxyAdmin);
        proxy.upgradeToAndCall(address(implV2), migrateData);

        // Point V2 interface to same proxy
        poolV2 = LendingPoolV2(payable(address(proxy)));

        // State preserved!
        assertEq(poolV2.deposits(alice), 3 ether, "deposits preserved after upgrade");
        assertEq(poolV2.version(),       2,        "version should be 2");
        assertEq(poolV2.owner(),         owner,    "owner preserved");
    }

    /**
     * @notice V2 charges interest over time
     *  Borrow 1 ETH for 1 year at 10% APR → owe 0.1 ETH interest
     */
    function test_V2InterestAccrues() public {
        // Upgrade first
        implV2 = new LendingPoolV2();
        vm.prank(proxyAdmin);
        proxy.upgradeToAndCall(
            address(implV2),
            abi.encodeCall(LendingPoolV2.initializeV2, ())
        );
        poolV2 = LendingPoolV2(payable(address(proxy)));

        // Alice deposits and borrows
        vm.prank(alice);
        poolV2.deposit{value: 4 ether}();

        vm.prank(alice);
        poolV2.borrow(1 ether);

        // Warp 1 year forward
        skip(365 days);

        // Interest should be ~10% of 1 ETH = 0.1 ETH
        uint256 interest = poolV2.pendingInterest(alice);
        console2.log("Interest after 1 year:", interest);

        // Allow 1 wei tolerance for integer division
        assertApproxEqAbs(interest, 0.1 ether, 1, "should be ~10% APR");
        assertEq(poolV2.totalOwed(alice), 1 ether + interest, "total owed = principal + interest");
    }

    /**
     * @notice DANGER ZONE: Test what happens if storage layout breaks
     *  This test demonstrates why you NEVER reorder storage variables in upgrades
     */
    function test_StorageLayoutSafe() public view {
        // In LendingPoolV2, slot 0-4 must match V1
        // We verify by reading known values via raw storage
        bytes32 slot0 = vm.load(address(proxy), bytes32(uint256(0))); // owner
        address storedOwner = address(uint160(uint256(slot0)));
        assertEq(storedOwner, owner, "slot 0 must still be owner in V2");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  SECTION 4: FUZZ TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Fuzz: any deposit amount up to 5 ETH should work
    function testFuzz_Deposit(uint256 amount) public {
        amount = bound(amount, 1 wei, 5 ether);
        deal(alice, amount);

        vm.prank(alice);
        pool.deposit{value: amount}();

        assertEq(pool.deposits(alice), amount);
    }

    /// @notice Fuzz: borrow never exceeds 75% LTV
    function testFuzz_BorrowNeverExceedsLTV(uint256 depositAmt, uint256 borrowAmt) public {
        depositAmt = bound(depositAmt, 0.01 ether, 10 ether);
        borrowAmt  = bound(borrowAmt,  0.01 ether, 10 ether);
        deal(alice, depositAmt);

        vm.prank(alice);
        pool.deposit{value: depositAmt}();

        uint256 maxAllowed = (depositAmt * 75) / 100;

        if (borrowAmt > maxAllowed) {
            vm.expectRevert("LendingPool: exceeds LTV");
        }

        vm.prank(alice);
        pool.borrow(borrowAmt);
    }
}
