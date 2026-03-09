// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title LendingPool (Implementation)
 * @notice Simple lending protocol — deposit ETH, borrow against collateral
 * @dev Storage layout MUST match proxy. Never change order of state vars!
 *
 *  Inspired by: Aave V2 simplified
 *
 *  Flow:
 *   1. User deposits ETH → gets "shares" (like aTokens)
 *   2. User borrows up to 75% LTV of their deposit
 *   3. If health factor < 1 → anyone can liquidate
 */
contract LendingPool {
    // ─── Storage Layout (PROXY-SAFE, never reorder!) ──────────────────────────
    address public owner;
    bool    public paused;
    uint256 public totalDeposits;   // in wei
    uint256 public totalBorrows;    // in wei
    uint256 public version;         // incremented on upgrade

    // user address => deposit amount (wei)
    mapping(address => uint256) public deposits;

    // user address => borrow amount (wei)
    mapping(address => uint256) public borrows;

    // ─── Constants ─────────────────────────────────────────────────────────────
    uint256 public constant LTV             = 75;   // 75% loan-to-value
    uint256 public constant LIQUIDATION_THRESHOLD = 80; // 80%
    uint256 public constant BASE_INTEREST_RATE    = 5;  // 5% APR (simplified)

    // ─── Events ────────────────────────────────────────────────────────────────
    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount);
    event Repaid(address indexed user, uint256 amount);
    event Liquidated(address indexed user, address indexed liquidator, uint256 amount);
    event Upgraded(address indexed newImplementation, uint256 newVersion);

    // ─── Modifiers ─────────────────────────────────────────────────────────────
    modifier onlyOwner() {
        require(msg.sender == owner, "LendingPool: not owner");
        _;
    }

    modifier notPaused() {
        require(!paused, "LendingPool: protocol paused");
        _;
    }

    // ─── Initializer (replaces constructor for proxy pattern) ──────────────────
    /**
     * @notice Called once by proxy on first deployment — NOT a constructor
     * @dev constructor() would set state on implementation, not proxy storage!
     */
    function initialize(address _owner) external {
        require(owner == address(0), "LendingPool: already initialized");
        owner   = _owner;
        version = 1;
    }

    // ─── Core Protocol Functions ───────────────────────────────────────────────

    /// @notice Deposit ETH into pool, earn yield share
    function deposit() external payable notPaused {
        require(msg.value > 0, "LendingPool: zero deposit");

        deposits[msg.sender] += msg.value;
        totalDeposits         += msg.value;

        emit Deposited(msg.sender, msg.value);
    }

    /// @notice Withdraw your deposited ETH (minus any active borrows)
    function withdraw(uint256 amount) external notPaused {
        require(deposits[msg.sender] >= amount, "LendingPool: insufficient deposit");

        // After withdrawal, health factor must remain safe
        uint256 newDeposit = deposits[msg.sender] - amount;
        if (borrows[msg.sender] > 0) {
            require(
                _healthFactor(newDeposit, borrows[msg.sender]) >= 100,
                "LendingPool: would breach LTV"
            );
        }

        deposits[msg.sender] -= amount;
        totalDeposits         -= amount;

        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "LendingPool: ETH transfer failed");

        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Borrow ETH against your deposited collateral (max 75% LTV)
    function borrow(uint256 amount) external notPaused {
        require(amount > 0, "LendingPool: zero borrow");
        require(address(this).balance >= amount, "LendingPool: insufficient liquidity");

        uint256 maxBorrow = (deposits[msg.sender] * LTV) / 100;
        require(
            borrows[msg.sender] + amount <= maxBorrow,
            "LendingPool: exceeds LTV"
        );

        borrows[msg.sender] += amount;
        totalBorrows          += amount;

        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "LendingPool: ETH transfer failed");

        emit Borrowed(msg.sender, amount);
    }

    /// @notice Repay borrowed ETH
    function repay() external payable notPaused {
        require(msg.value > 0, "LendingPool: zero repay");
        require(borrows[msg.sender] > 0, "LendingPool: no active borrow");

        uint256 repayAmount = msg.value > borrows[msg.sender]
            ? borrows[msg.sender]
            : msg.value;

        borrows[msg.sender] -= repayAmount;
        totalBorrows          -= repayAmount;

        // Refund overpayment
        if (msg.value > repayAmount) {
            (bool ok,) = msg.sender.call{value: msg.value - repayAmount}("");
            require(ok, "LendingPool: refund failed");
        }

        emit Repaid(msg.sender, repayAmount);
    }

    /**
     * @notice Liquidate an undercollateralized position
     * @dev Anyone can liquidate if health factor < 100 (i.e. borrow > 80% of collateral)
     *      Liquidator repays debt and receives collateral at discount
     */
    function liquidate(address user) external payable notPaused {
        require(user != msg.sender, "LendingPool: cannot self-liquidate");
        require(borrows[user] > 0, "LendingPool: no active borrow");
        require(
            _healthFactor(deposits[user], borrows[user]) < 100,
            "LendingPool: position healthy"
        );

        uint256 debt = borrows[user];
        require(msg.value >= debt, "LendingPool: insufficient repayment");

        // Liquidator gets collateral (5% bonus)
        uint256 collateralToSeize = (debt * 105) / 100;
        if (collateralToSeize > deposits[user]) {
            collateralToSeize = deposits[user];
        }

        borrows[user]   = 0;
        deposits[user]  -= collateralToSeize;
        totalBorrows     -= debt;
        totalDeposits    -= collateralToSeize;

        // Send collateral to liquidator
        (bool ok,) = msg.sender.call{value: collateralToSeize}("");
        require(ok, "LendingPool: collateral transfer failed");

        emit Liquidated(user, msg.sender, debt);
    }

    // ─── View Functions ────────────────────────────────────────────────────────

    /// @notice Returns health factor * 100 (100 = exactly at threshold)
    function healthFactor(address user) external view returns (uint256) {
        if (borrows[user] == 0) return type(uint256).max;
        return _healthFactor(deposits[user], borrows[user]);
    }

    /// @notice Available liquidity in pool
    function availableLiquidity() external view returns (uint256) {
        return address(this).balance;
    }

    /// @notice Max borrowable for a user
    function maxBorrow(address user) external view returns (uint256) {
        uint256 maxAllowed = (deposits[user] * LTV) / 100;
        return maxAllowed > borrows[user] ? maxAllowed - borrows[user] : 0;
    }

    // ─── Admin ─────────────────────────────────────────────────────────────────

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
    }

    // ─── Internal ──────────────────────────────────────────────────────────────

    /// Returns health factor scaled by 100 (>=100 is safe)
    function _healthFactor(uint256 depositAmt, uint256 borrowAmt) internal pure returns (uint256) {
        if (borrowAmt == 0) return type(uint256).max;
        // healthFactor = (deposit * liquidationThreshold) / borrow
        return (depositAmt * LIQUIDATION_THRESHOLD) / borrowAmt;
    }
}
