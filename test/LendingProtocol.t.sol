// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {LendingPoolV2} from "../src/LendingPoolV2.sol";
import {TransparentProxy} from "../src/TransparentProxy.sol";

contract LendingProtocolTest is Test {
    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal liquidator = makeAddr("liquidator");
    address internal proxyAdmin = makeAddr("proxyAdmin");

    LendingPool internal implV1;
    LendingPoolV2 internal implV2;
    TransparentProxy internal proxy;
    LendingPool internal pool;
    LendingPoolV2 internal poolV2;

    function setUp() public {
        implV1 = new LendingPool();
        bytes memory initData = abi.encodeCall(LendingPool.initialize, (owner));
        proxy = new TransparentProxy(address(implV1), proxyAdmin, initData);
        pool = LendingPool(payable(address(proxy)));

        deal(alice, 20 ether);
        deal(bob, 20 ether);
        deal(liquidator, 20 ether);
        deal(proxyAdmin, 2 ether);
    }

    function _upgradeToV2() internal {
        implV2 = new LendingPoolV2();
        vm.prank(proxyAdmin);
        proxy.upgradeToAndCall(
            address(implV2),
            abi.encodeCall(LendingPoolV2.initializeV2, ())
        );
        poolV2 = LendingPoolV2(payable(address(proxy)));
    }

    // Proxy mechanics and storage layout.
    function test_ProxyStorageIsolation() public {
        vm.prank(alice);
        pool.deposit{value: 1 ether}();

        assertEq(pool.deposits(alice), 1 ether);
        assertEq(implV1.deposits(alice), 0);
        assertEq(implV1.owner(), address(0));
    }

    function test_EIP1967Slots() public view {
        bytes32 implSlot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        bytes32 adminSlot = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);
        address storedImpl = address(uint160(uint256(vm.load(address(proxy), implSlot))));
        address storedAdmin = address(uint160(uint256(vm.load(address(proxy), adminSlot))));
        assertEq(storedImpl, address(implV1));
        assertEq(storedAdmin, proxyAdmin);
    }

    function test_V1StorageMappingAnchors() public {
        vm.prank(alice);
        pool.deposit{value: 1 ether}();
        bytes32 depositsEntry = keccak256(abi.encode(alice, uint256(4)));
        assertEq(uint256(vm.load(address(proxy), depositsEntry)), 1 ether);
    }

    function test_TransparentProxyAdminCannotFallback() public {
        vm.prank(proxyAdmin);
        vm.expectRevert(bytes("TransparentProxy: admin cannot fallback"));
        pool.deposit{value: 1 ether}();
    }

    function test_OnlyAdminCanUpgrade() public {
        implV2 = new LendingPoolV2();

        // Non-admin calls are delegated to the implementation, where this selector is absent.
        vm.prank(alice);
        vm.expectRevert();
        proxy.upgradeTo(address(implV2));

        vm.prank(proxyAdmin);
        proxy.upgradeTo(address(implV2));
    }

    // V1 protocol logic.
    function test_DepositAndWithdraw() public {
        vm.startPrank(alice);
        pool.deposit{value: 5 ether}();
        assertEq(pool.deposits(alice), 5 ether);
        assertEq(pool.totalDeposits(), 5 ether);
        pool.withdraw(2 ether);
        assertEq(pool.deposits(alice), 3 ether);
        vm.stopPrank();
    }

    function test_BorrowWithinLTV() public {
        vm.prank(alice);
        pool.deposit{value: 4 ether}();
        assertEq(pool.maxBorrow(alice), 3 ether);
        vm.prank(alice);
        pool.borrow(3 ether);
        assertEq(pool.borrows(alice), 3 ether);
    }

    function test_CannotExceedLTV() public {
        vm.prank(alice);
        pool.deposit{value: 4 ether}();
        vm.prank(alice);
        vm.expectRevert(bytes("LendingPool: exceeds LTV"));
        pool.borrow(3.1 ether);
    }

    function test_RepayAndRefundOverpayment() public {
        vm.prank(alice);
        pool.deposit{value: 4 ether}();
        vm.prank(alice);
        pool.borrow(3 ether);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        pool.repay{value: 3.5 ether}();
        assertEq(pool.borrows(alice), 0);
        assertEq(pool.totalBorrows(), 0);
        assertEq(alice.balance, balanceBefore - 3 ether);
    }

    function test_LiquidationUsesCorrectDepositsSlotAndUpdatesTotals() public {
        vm.prank(alice);
        pool.deposit{value: 1 ether}();
        vm.prank(alice);
        pool.borrow(0.75 ether);
        assertGe(pool.healthFactor(alice), 100);

        // Mapping anchor for deposits is slot 4 (slot 5 is borrows).
        vm.store(address(proxy), keccak256(abi.encode(alice, uint256(4))), bytes32(uint256(0.8 ether)));
        vm.store(address(proxy), bytes32(uint256(1)), bytes32(uint256(0.8 ether)));
        assertLt(pool.healthFactor(alice), 100);

        uint256 liquidatorBefore = liquidator.balance;
        vm.prank(liquidator);
        pool.liquidate{value: 0.75 ether}(alice);
        assertEq(pool.borrows(alice), 0);
        assertEq(pool.totalBorrows(), 0);
        assertEq(pool.deposits(alice), 0.0125 ether);
        assertGt(liquidator.balance, liquidatorBefore);
    }

    function test_PauseBlocksActions() public {
        vm.prank(owner);
        pool.setPaused(true);
        vm.prank(alice);
        vm.expectRevert(bytes("LendingPool: protocol paused"));
        pool.deposit{value: 1 ether}();
    }

    // V1 -> V2 upgrade and interest accounting.
    function test_UpgradePreservesState() public {
        vm.prank(alice);
        pool.deposit{value: 3 ether}();
        vm.prank(alice);
        pool.borrow(1 ether);

        _upgradeToV2();
        assertEq(poolV2.deposits(alice), 3 ether);
        assertEq(poolV2.borrows(alice), 1 ether);
        assertEq(poolV2.version(), 2);
        assertEq(poolV2.owner(), owner);
        assertEq(poolV2.totalBorrows(), 1 ether);
    }

    function test_V2InterestAccrues() public {
        _upgradeToV2();
        vm.prank(alice);
        poolV2.deposit{value: 4 ether}();
        vm.prank(alice);
        poolV2.borrow(1 ether);

        skip(365 days);
        uint256 interest = poolV2.pendingInterest(alice);
        assertApproxEqAbs(interest, 0.1 ether, 1);
        assertEq(poolV2.totalOwed(alice), 1 ether + interest);
    }

    function test_V2PartialInterestPaymentIsRetained() public {
        _upgradeToV2();
        vm.prank(alice);
        poolV2.deposit{value: 4 ether}();
        vm.prank(alice);
        poolV2.borrow(1 ether);
        skip(365 days);

        vm.prank(alice);
        poolV2.repay{value: 0.04 ether}();
        assertEq(poolV2.borrows(alice), 1 ether);
        assertApproxEqAbs(poolV2.pendingInterest(alice), 0.06 ether, 1);
        assertApproxEqAbs(poolV2.totalOwed(alice), 1.06 ether, 1);
        assertEq(poolV2.totalBorrows(), 1 ether);
    }

    function test_V2AdditionalBorrowDoesNotErasePriorInterest() public {
        _upgradeToV2();
        vm.prank(alice);
        poolV2.deposit{value: 4 ether}();
        vm.prank(alice);
        poolV2.borrow(1 ether);
        skip(365 days / 2);

        vm.prank(alice);
        poolV2.borrow(0.5 ether);
        skip(365 days / 2);

        // Approx. 0.05 ETH from the first half-year plus 0.075 ETH on 1.5 ETH for the second.
        assertApproxEqAbs(poolV2.pendingInterest(alice), 0.125 ether, 2);
        assertApproxEqAbs(poolV2.totalOwed(alice), 1.625 ether, 2);
    }

    function test_V2LegacyBorrowStartsAccruingOnlyAfterSync() public {
        vm.prank(alice);
        pool.deposit{value: 4 ether}();
        vm.prank(alice);
        pool.borrow(1 ether);
        _upgradeToV2();

        skip(365 days);
        assertEq(poolV2.pendingInterest(alice), 0, "legacy debt is not backdated");
        vm.prank(alice);
        poolV2.syncBorrow();
        skip(365 days);
        assertApproxEqAbs(poolV2.pendingInterest(alice), 0.1 ether, 1);
    }

    function test_V2LiquidationClearsPrincipalAccounting() public {
        _upgradeToV2();
        vm.prank(alice);
        poolV2.deposit{value: 1.5 ether}();
        vm.prank(alice);
        poolV2.borrow(1.1 ether);
        skip(365 days);

        assertLt(poolV2.healthFactor(alice), 100);
        uint256 totalOwed = poolV2.totalOwed(alice);
        vm.prank(liquidator);
        poolV2.liquidate{value: totalOwed}(alice);
        assertEq(poolV2.borrows(alice), 0);
        assertEq(poolV2.totalBorrows(), 0);
        assertEq(poolV2.pendingInterest(alice), 0);
    }

    function test_V2InitializeCannotBeCalledByNonAdmin() public {
        implV2 = new LendingPoolV2();
        vm.prank(proxyAdmin);
        proxy.upgradeTo(address(implV2));
        vm.prank(alice);
        vm.expectRevert(bytes("V2: caller not proxy admin"));
        poolV2 = LendingPoolV2(payable(address(proxy)));
        poolV2.initializeV2();
    }

    function test_StorageLayoutSafe() public {
        vm.prank(alice);
        pool.deposit{value: 1 ether}();
        vm.prank(alice);
        pool.borrow(0.5 ether);
        _upgradeToV2();

        bytes32 slot0 = vm.load(address(proxy), bytes32(uint256(0)));
        assertEq(address(uint160(uint256(slot0))), owner);
        assertEq(poolV2.deposits(alice), 1 ether);
        assertEq(poolV2.borrows(alice), 0.5 ether);
        assertEq(poolV2.totalDeposits(), 1 ether);
        assertEq(poolV2.totalBorrows(), 0.5 ether);
    }

    function testFuzz_Deposit(uint256 amount) public {
        amount = bound(amount, 1 wei, 5 ether);
        deal(alice, amount);
        vm.prank(alice);
        pool.deposit{value: amount}();
        assertEq(pool.deposits(alice), amount);
    }

    function testFuzz_BorrowNeverExceedsLTV(uint256 depositAmount, uint256 borrowAmount) public {
        depositAmount = bound(depositAmount, 0.01 ether, 10 ether);
        borrowAmount = bound(borrowAmount, 0.01 ether, 10 ether);
        deal(alice, depositAmount);
        vm.prank(alice);
        pool.deposit{value: depositAmount}();

        uint256 maxAllowed = (depositAmount * 75) / 100;
        vm.prank(alice);
        if (borrowAmount > maxAllowed) {
            vm.expectRevert(bytes("LendingPool: exceeds LTV"));
            pool.borrow(borrowAmount);
        } else {
            pool.borrow(borrowAmount);
            assertLe(pool.borrows(alice), maxAllowed);
        }
    }
}
