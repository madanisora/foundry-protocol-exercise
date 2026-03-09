// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title LendingPoolV2 (Upgraded Implementation)
 * @notice Adds interest accrual to V1
 * @dev CRITICAL: Storage layout must be IDENTICAL to V1 for first 7 slots!
 *      Only ADD new variables at the END. Never reorder existing ones.
 *
 *  Storage Layout:
 *  Slot 0: owner          ← same as V1 ✓
 *  Slot 1: paused         ← same as V1 ✓
 *  Slot 2: totalDeposits  ← same as V1 ✓
 *  Slot 3: totalBorrows   ← same as V1 ✓
 *  Slot 4: version        ← same as V1 ✓
 *  (mappings are hashed, no slot conflict)
 *  NEW → Slot 5: lastUpdateTimestamp  ← appended safely ✓
 *  NEW → Slot 6: accumulatedInterest  ← appended safely ✓
 */
contract LendingPoolV2 {
    // ─── Storage Layout (V1 slots preserved!) ─────────────────────────────────
    address public owner;
    bool    public paused;
    uint256 public totalDeposits;
    uint256 public totalBorrows;
    uint256 public version;

    mapping(address => uint256) public deposits;
    mapping(address => uint256) public borrows;

    // ─── V2 NEW STORAGE (only append!) ────────────────────────────────────────
    uint256 public lastUpdateTimestamp;
    uint256 public accumulatedInterest;
    mapping(address => uint256) public borrowTimestamps; // when user last borrowed

    // ─── Constants ─────────────────────────────────────────────────────────────
    uint256 public constant LTV                   = 75;
    uint256 public constant LIQUIDATION_THRESHOLD = 80;
    uint256 public constant ANNUAL_INTEREST_RATE  = 10;  // 10% APR
    uint256 public constant SECONDS_PER_YEAR      = 365 days;

    // ─── Events ────────────────────────────────────────────────────────────────
    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount);
    event Repaid(address indexed user, uint256 amount, uint256 interest);
    event Liquidated(address indexed user, address indexed liquidator, uint256 amount);
    event InterestAccrued(address indexed user, uint256 interest);

    modifier onlyOwner() {
        require(msg.sender == owner, "V2: not owner");
        _;
    }

    modifier notPaused() {
        require(!paused, "V2: paused");
        _;
    }

    // ─── V2 Initializer (migration from V1) ───────────────────────────────────
    /**
     * @notice Called via upgradeToAndCall — migrates V1 state to V2
     * @dev Safe to call multiple times (idempotent check via version)
     */
    function initializeV2() external {
        require(version == 1, "V2: already migrated");
        version              = 2;
        lastUpdateTimestamp  = block.timestamp;
    }

    // ─── Core Functions (same interface as V1) ─────────────────────────────────

    function deposit() external payable notPaused {
        require(msg.value > 0, "V2: zero deposit");
        deposits[msg.sender] += msg.value;
        totalDeposits         += msg.value;
        emit Deposited(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external notPaused {
        require(deposits[msg.sender] >= amount, "V2: insufficient deposit");

        uint256 newDeposit = deposits[msg.sender] - amount;
        if (borrows[msg.sender] > 0) {
            require(
                _healthFactor(newDeposit, borrows[msg.sender]) >= 100,
                "V2: would breach LTV"
            );
        }

        deposits[msg.sender] -= amount;
        totalDeposits         -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "V2: transfer failed");

        emit Withdrawn(msg.sender, amount);
    }

    function borrow(uint256 amount) external notPaused {
        require(amount > 0, "V2: zero borrow");
        require(address(this).balance >= amount, "V2: no liquidity");

        uint256 maxBorrowAmt = (deposits[msg.sender] * LTV) / 100;
        require(borrows[msg.sender] + amount <= maxBorrowAmt, "V2: exceeds LTV");

        borrows[msg.sender]        += amount;
        borrowTimestamps[msg.sender] = block.timestamp; // track for interest
        totalBorrows                 += amount;

        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "V2: transfer failed");

        emit Borrowed(msg.sender, amount);
    }

    /**
     * @notice Repay with interest (NEW in V2)
     * @dev Interest = principal * rate * time
     */
    function repay() external payable notPaused {
        require(msg.value > 0, "V2: zero repay");
        require(borrows[msg.sender] > 0, "V2: no borrow");

        uint256 principal = borrows[msg.sender];
        uint256 interest  = _calcInterest(msg.sender);
        uint256 totalOwed = principal + interest;

        uint256 repayAmount = msg.value >= totalOwed ? totalOwed : msg.value;

        // Interest first, then principal
        if (repayAmount >= interest) {
            accumulatedInterest              += interest;
            borrows[msg.sender]               = principal - (repayAmount - interest);
            borrowTimestamps[msg.sender]      = block.timestamp;
        } else {
            // Partial interest payment
            borrows[msg.sender] = principal;
        }

        if (borrows[msg.sender] == 0) {
            totalBorrows -= principal;
        } else {
            totalBorrows -= (principal - borrows[msg.sender]);
        }

        // Refund overpayment
        if (msg.value > repayAmount) {
            (bool ok,) = msg.sender.call{value: msg.value - repayAmount}("");
            require(ok, "V2: refund failed");
        }

        emit Repaid(msg.sender, repayAmount, interest);
    }

    function liquidate(address user) external payable notPaused {
        require(user != msg.sender, "V2: no self-liquidate");
        require(borrows[user] > 0, "V2: no borrow");
        require(
            _healthFactor(deposits[user], borrows[user]) < 100,
            "V2: position healthy"
        );

        uint256 debt             = borrows[user] + _calcInterest(user);
        require(msg.value >= debt, "V2: insufficient repayment");

        uint256 collateralToSeize = (debt * 105) / 100;
        if (collateralToSeize > deposits[user]) collateralToSeize = deposits[user];

        borrows[user]  = 0;
        deposits[user] -= collateralToSeize;
        totalBorrows   -= borrows[user];
        totalDeposits  -= collateralToSeize;

        (bool ok,) = msg.sender.call{value: collateralToSeize}("");
        require(ok, "V2: collateral transfer failed");

        emit Liquidated(user, msg.sender, debt);
    }

    // ─── V2 New View Functions ─────────────────────────────────────────────────

    /// @notice How much interest has accrued on a user's borrow
    function pendingInterest(address user) external view returns (uint256) {
        return _calcInterest(user);
    }

    /// @notice Total owed by user (principal + interest)
    function totalOwed(address user) external view returns (uint256) {
        return borrows[user] + _calcInterest(user);
    }

    function healthFactor(address user) external view returns (uint256) {
        if (borrows[user] == 0) return type(uint256).max;
        return _healthFactor(deposits[user], borrows[user]);
    }

    function availableLiquidity() external view returns (uint256) {
        return address(this).balance;
    }

    // ─── Admin ─────────────────────────────────────────────────────────────────

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
    }

    // ─── Internal ──────────────────────────────────────────────────────────────

    function _calcInterest(address user) internal view returns (uint256) {
        if (borrows[user] == 0 || borrowTimestamps[user] == 0) return 0;
        uint256 elapsed = block.timestamp - borrowTimestamps[user];
        // interest = principal * rate * elapsed / SECONDS_PER_YEAR
        return (borrows[user] * ANNUAL_INTEREST_RATE * elapsed) / (100 * SECONDS_PER_YEAR);
    }

    function _healthFactor(uint256 dep, uint256 bor) internal pure returns (uint256) {
        if (bor == 0) return type(uint256).max;
        return (dep * LIQUIDATION_THRESHOLD) / bor;
    }
}
