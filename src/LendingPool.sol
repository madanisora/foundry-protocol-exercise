// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title LendingPool
 * @notice Educational ETH-collateral lending implementation (V1).
 * @dev This contract is for local testing and security education only.
 *      Keep the declaration order unchanged when upgrading the proxy.
 *
 * Storage layout (Solidity 0.8.20):
 *   slot 0: owner (20 bytes) + paused (1 byte, packed)
 *   slot 1: totalDeposits
 *   slot 2: totalBorrows
 *   slot 3: version
 *   slot 4: deposits mapping anchor
 *   slot 5: borrows mapping anchor
 */
contract LendingPool {
    address public owner;
    bool    public paused;
    uint256 public totalDeposits;
    uint256 public totalBorrows;
    uint256 public version;

    mapping(address => uint256) public deposits;
    mapping(address => uint256) public borrows;

    uint256 public constant LTV = 75;
    uint256 public constant LIQUIDATION_THRESHOLD = 80;
    uint256 public constant BASE_INTEREST_RATE = 5; // reserved V1 constant; V1 does not accrue interest

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount);
    event Repaid(address indexed user, uint256 amount);
    event Liquidated(address indexed user, address indexed liquidator, uint256 debt, uint256 collateralSeized);

    modifier onlyOwner() {
        require(msg.sender == owner, "LendingPool: not owner");
        _;
    }

    modifier notPaused() {
        require(!paused, "LendingPool: protocol paused");
        _;
    }

    /// @notice Initialize proxy storage once. The implementation itself is not initialized.
    function initialize(address _owner) external {
        require(owner == address(0), "LendingPool: already initialized");
        require(_owner != address(0), "LendingPool: zero owner");
        owner = _owner;
        version = 1;
    }

    function deposit() external payable notPaused {
        require(msg.value > 0, "LendingPool: zero deposit");
        deposits[msg.sender] += msg.value;
        totalDeposits += msg.value;
        emit Deposited(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external notPaused {
        require(amount > 0, "LendingPool: zero withdrawal");
        require(deposits[msg.sender] >= amount, "LendingPool: insufficient deposit");

        uint256 newDeposit = deposits[msg.sender] - amount;
        if (borrows[msg.sender] > 0) {
            require(_healthFactor(newDeposit, borrows[msg.sender]) >= 100, "LendingPool: would breach threshold");
        }

        deposits[msg.sender] = newDeposit;
        totalDeposits -= amount;

        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "LendingPool: ETH transfer failed");
        emit Withdrawn(msg.sender, amount);
    }

    function borrow(uint256 amount) external notPaused {
        require(amount > 0, "LendingPool: zero borrow");
        require(address(this).balance >= amount, "LendingPool: insufficient liquidity");

        uint256 maxBorrowAllowed = (deposits[msg.sender] * LTV) / 100;
        require(borrows[msg.sender] + amount <= maxBorrowAllowed, "LendingPool: exceeds LTV");

        borrows[msg.sender] += amount;
        totalBorrows += amount;

        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "LendingPool: ETH transfer failed");
        emit Borrowed(msg.sender, amount);
    }

    function repay() external payable notPaused {
        require(msg.value > 0, "LendingPool: zero repay");
        uint256 debt = borrows[msg.sender];
        require(debt > 0, "LendingPool: no active borrow");

        uint256 principalPaid = msg.value > debt ? debt : msg.value;
        borrows[msg.sender] = debt - principalPaid;
        totalBorrows -= principalPaid;

        uint256 refund = msg.value - principalPaid;
        if (refund > 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            require(ok, "LendingPool: refund failed");
        }
        emit Repaid(msg.sender, principalPaid);
    }

    function liquidate(address user) external payable notPaused {
        require(user != msg.sender, "LendingPool: cannot self-liquidate");
        uint256 debt = borrows[user];
        require(debt > 0, "LendingPool: no active borrow");
        require(_healthFactor(deposits[user], debt) < 100, "LendingPool: position healthy");
        require(msg.value >= debt, "LendingPool: insufficient repayment");

        uint256 collateralToSeize = (debt * 105) / 100;
        if (collateralToSeize > deposits[user]) collateralToSeize = deposits[user];

        // Effects before interactions.
        borrows[user] = 0;
        deposits[user] -= collateralToSeize;
        totalBorrows -= debt;
        totalDeposits -= collateralToSeize;

        (bool collateralOk,) = msg.sender.call{value: collateralToSeize}("");
        require(collateralOk, "LendingPool: collateral transfer failed");

        uint256 refund = msg.value - debt;
        if (refund > 0) {
            (bool refundOk,) = msg.sender.call{value: refund}("");
            require(refundOk, "LendingPool: refund failed");
        }
        emit Liquidated(user, msg.sender, debt, collateralToSeize);
    }

    function healthFactor(address user) external view returns (uint256) {
        if (borrows[user] == 0) return type(uint256).max;
        return _healthFactor(deposits[user], borrows[user]);
    }

    function availableLiquidity() external view returns (uint256) {
        return address(this).balance;
    }

    function maxBorrow(address user) external view returns (uint256) {
        uint256 maxAllowed = (deposits[user] * LTV) / 100;
        return maxAllowed > borrows[user] ? maxAllowed - borrows[user] : 0;
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
    }

    function _healthFactor(uint256 depositAmount, uint256 debtAmount) internal pure returns (uint256) {
        if (debtAmount == 0) return type(uint256).max;
        return (depositAmount * LIQUIDATION_THRESHOLD) / debtAmount;
    }
}
