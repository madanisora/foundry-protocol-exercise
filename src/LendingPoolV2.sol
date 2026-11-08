// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title LendingPoolV2
 * @notice Educational upgrade adding simple per-position simple interest.
 * @dev Preserve V1 storage exactly. New variables are appended after V1 slots.
 *      This is not production lending code and is not audited.
 *
 * Storage layout:
 *   slot 0: owner + paused (packed)
 *   slot 1: totalDeposits
 *   slot 2: totalBorrows (outstanding principal only)
 *   slot 3: version
 *   slot 4: deposits mapping anchor
 *   slot 5: borrows mapping anchor
 *   slot 6: lastUpdateTimestamp
 *   slot 7: accumulatedInterest (interest actually paid/settled)
 *   slot 8: borrowTimestamps mapping anchor
 *   slot 9: accruedInterest mapping anchor (new in this corrected exercise)
 *
 * Migration policy: V1 borrowers have no timestamp. Their existing principal
 * starts accruing V2 interest only after they call syncBorrow(), or when they
 * make another borrow. No interest is retroactively charged for V1 time.
 */
contract LendingPoolV2 {
    // V1 storage: do not reorder or change types.
    address public owner;
    bool    public paused;
    uint256 public totalDeposits;
    uint256 public totalBorrows;
    uint256 public version;
    mapping(address => uint256) public deposits;
    mapping(address => uint256) public borrows;

    // V2 storage: append only.
    uint256 public lastUpdateTimestamp;
    uint256 public accumulatedInterest;
    mapping(address => uint256) public borrowTimestamps;
    mapping(address => uint256) public accruedInterest;

    uint256 public constant LTV = 75;
    uint256 public constant LIQUIDATION_THRESHOLD = 80;
    uint256 public constant ANNUAL_INTEREST_RATE = 10;
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    bytes32 private constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount);
    event Repaid(address indexed user, uint256 principalPaid, uint256 interestPaid);
    event Liquidated(address indexed user, address indexed liquidator, uint256 debtPaid, uint256 collateralSeized);
    event InterestAccrued(address indexed user, uint256 interest);
    event LegacyBorrowSynchronized(address indexed user, uint256 timestamp);

    modifier onlyOwner() {
        require(msg.sender == owner, "V2: not owner");
        _;
    }

    modifier notPaused() {
        require(!paused, "V2: paused");
        _;
    }

    /// @notice Called atomically with proxy upgradeToAndCall by the EIP-1967 proxy admin.
    function initializeV2() external {
        address proxyAdmin;
        bytes32 slot = ADMIN_SLOT;
        assembly { proxyAdmin := sload(slot) }
        require(proxyAdmin != address(0) && msg.sender == proxyAdmin, "V2: caller not proxy admin");
        require(version == 1, "V2: already migrated");
        version = 2;
        lastUpdateTimestamp = block.timestamp;
    }

    function deposit() external payable notPaused {
        require(msg.value > 0, "V2: zero deposit");
        deposits[msg.sender] += msg.value;
        totalDeposits += msg.value;
        emit Deposited(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external notPaused {
        require(amount > 0, "V2: zero withdrawal");
        require(deposits[msg.sender] >= amount, "V2: insufficient deposit");

        uint256 debt = _calcInterest(msg.sender) + borrows[msg.sender];
        uint256 newDeposit = deposits[msg.sender] - amount;
        if (debt > 0) {
            require(_healthFactor(newDeposit, debt) >= 100, "V2: would breach threshold");
        }

        deposits[msg.sender] = newDeposit;
        totalDeposits -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "V2: transfer failed");
        emit Withdrawn(msg.sender, amount);
    }

    function borrow(uint256 amount) external notPaused {
        require(amount > 0, "V2: zero borrow");
        require(address(this).balance >= amount, "V2: no liquidity");

        // Lock accrued interest before increasing principal; do not reset old debt's clock.
        if (borrows[msg.sender] > 0) _accrue(msg.sender);

        uint256 newPrincipal = borrows[msg.sender] + amount;
        uint256 debtAfterBorrow = accruedInterest[msg.sender] + newPrincipal;
        uint256 maxDebt = (deposits[msg.sender] * LTV) / 100;
        require(debtAfterBorrow <= maxDebt, "V2: exceeds LTV");

        borrows[msg.sender] = newPrincipal;
        borrowTimestamps[msg.sender] = block.timestamp;
        totalBorrows += amount;

        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "V2: transfer failed");
        emit Borrowed(msg.sender, amount);
    }

    /// @notice Start V2 interest accrual for an outstanding V1 borrow; no retroactive interest.
    function syncBorrow() external notPaused {
        require(borrows[msg.sender] > 0, "V2: no borrow to sync");
        require(borrowTimestamps[msg.sender] == 0, "V2: borrow already synchronized");
        borrowTimestamps[msg.sender] = block.timestamp;
        lastUpdateTimestamp = block.timestamp;
        emit LegacyBorrowSynchronized(msg.sender, block.timestamp);
    }

    /// @notice Repay interest first, then principal; any overpayment is refunded.
    function repay() external payable notPaused {
        require(msg.value > 0, "V2: zero repay");
        uint256 principal = borrows[msg.sender];
        require(principal > 0, "V2: no borrow");

        uint256 interestOwed = _calcInterest(msg.sender);
        uint256 totalDebt = principal + interestOwed;
        uint256 amountAccepted = msg.value > totalDebt ? totalDebt : msg.value;
        uint256 interestPaid = amountAccepted > interestOwed ? interestOwed : amountAccepted;
        uint256 principalPaid = amountAccepted - interestPaid;

        accruedInterest[msg.sender] = interestOwed - interestPaid;
        borrows[msg.sender] = principal - principalPaid;
        totalBorrows -= principalPaid;
        accumulatedInterest += interestPaid;

        if (borrows[msg.sender] == 0) {
            delete borrowTimestamps[msg.sender];
            delete accruedInterest[msg.sender];
        } else {
            // The remaining accruedInterest is carried forward; only new principal accrues from now.
            borrowTimestamps[msg.sender] = block.timestamp;
        }
        lastUpdateTimestamp = block.timestamp;

        uint256 refund = msg.value - amountAccepted;
        if (refund > 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            require(ok, "V2: refund failed");
        }
        emit Repaid(msg.sender, principalPaid, interestPaid);
    }

    function liquidate(address user) external payable notPaused {
        require(user != msg.sender, "V2: no self-liquidate");
        uint256 principal = borrows[user];
        require(principal > 0, "V2: no borrow");

        uint256 interest = _calcInterest(user);
        uint256 debt = principal + interest;
        require(_healthFactor(deposits[user], debt) < 100, "V2: position healthy");
        require(msg.value >= debt, "V2: insufficient repayment");

        uint256 collateralToSeize = (debt * 105) / 100;
        if (collateralToSeize > deposits[user]) collateralToSeize = deposits[user];

        // Clear principal and interest before external calls.
        borrows[user] = 0;
        delete borrowTimestamps[user];
        delete accruedInterest[user];
        deposits[user] -= collateralToSeize;
        totalBorrows -= principal;
        totalDeposits -= collateralToSeize;
        accumulatedInterest += interest;
        lastUpdateTimestamp = block.timestamp;

        (bool collateralOk,) = msg.sender.call{value: collateralToSeize}("");
        require(collateralOk, "V2: collateral transfer failed");

        uint256 refund = msg.value - debt;
        if (refund > 0) {
            (bool refundOk,) = msg.sender.call{value: refund}("");
            require(refundOk, "V2: refund failed");
        }
        emit Liquidated(user, msg.sender, debt, collateralToSeize);
    }

    function pendingInterest(address user) external view returns (uint256) {
        return _calcInterest(user);
    }

    function totalOwed(address user) public view returns (uint256) {
        return borrows[user] + _calcInterest(user);
    }

    function healthFactor(address user) external view returns (uint256) {
        return _healthFactor(deposits[user], totalOwed(user));
    }

    function maxBorrow(address user) external view returns (uint256) {
        uint256 maxAllowed = (deposits[user] * LTV) / 100;
        uint256 debt = totalOwed(user);
        return maxAllowed > debt ? maxAllowed - debt : 0;
    }

    function availableLiquidity() external view returns (uint256) {
        return address(this).balance;
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
    }

    function _calcInterest(address user) internal view returns (uint256) {
        uint256 interest = accruedInterest[user];
        uint256 principal = borrows[user];
        uint256 timestamp = borrowTimestamps[user];
        if (principal == 0 || timestamp == 0 || block.timestamp <= timestamp) return interest;

        uint256 elapsed = block.timestamp - timestamp;
        return interest + (principal * ANNUAL_INTEREST_RATE * elapsed) / (100 * SECONDS_PER_YEAR);
    }

    function _accrue(address user) internal {
        if (borrows[user] == 0) return;
        if (borrowTimestamps[user] == 0) {
            // Legacy V1 debt: start the clock now; never backdate interest.
            borrowTimestamps[user] = block.timestamp;
        } else {
            uint256 totalInterest = _calcInterest(user);
            accruedInterest[user] = totalInterest;
            borrowTimestamps[user] = block.timestamp;
            emit InterestAccrued(user, totalInterest);
        }
        lastUpdateTimestamp = block.timestamp;
    }

    function _healthFactor(uint256 collateral, uint256 debt) internal pure returns (uint256) {
        if (debt == 0) return type(uint256).max;
        return (collateral * LIQUIDATION_THRESHOLD) / debt;
    }
}
