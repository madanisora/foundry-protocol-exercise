// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title TransparentProxy
 * @notice EIP-1967 Transparent Upgradeable Proxy
 *
 *  How it works:
 *  ┌─────────────────────────────────────────────────────┐
 *  │  User calls proxy.deposit{value: 1 ether}()         │
 *  │        │                                            │
 *  │        ▼ fallback()                                 │
 *  │  delegatecall → LendingPool.deposit()               │
 *  │        │  (runs in PROXY's storage context!)        │
 *  │        ▼                                            │
 *  │  proxy.deposits[msg.sender] += 1 ether  ✓           │
 *  └─────────────────────────────────────────────────────┘
 *
 *  Key insight: implementation code runs, proxy storage changes.
 *
 *  EIP-1967 storage slots (collision-resistant):
 *  - Implementation: keccak256("eip1967.proxy.implementation") - 1
 *  - Admin:          keccak256("eip1967.proxy.admin") - 1
 */
contract TransparentProxy {
    // ─── EIP-1967 Storage Slots ────────────────────────────────────────────────
    bytes32 private constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    bytes32 private constant ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    // ─── Events ────────────────────────────────────────────────────────────────
    event Upgraded(address indexed implementation);
    event AdminChanged(address indexed previousAdmin, address indexed newAdmin);

    // ─── Constructor ───────────────────────────────────────────────────────────
    /**
     * @param _implementation  Address of LendingPool (the logic contract)
     * @param _admin           Who can upgrade (ProxyAdmin or deployer)
     * @param _data            Calldata for initializer (e.g. initialize(owner))
     */
    constructor(
        address _implementation,
        address _admin,
        bytes memory _data
    ) {
        _setImplementation(_implementation);
        _setAdmin(_admin);

        // Call initializer on first deploy
        if (_data.length > 0) {
            (bool ok,) = _implementation.delegatecall(_data);
            require(ok, "TransparentProxy: init failed");
        }
    }

    // ─── Admin Functions (only callable by admin, NOT delegated) ───────────────

    /**
     * @notice Upgrade to a new implementation
     * @dev Admin calls land here directly — NOT forwarded to implementation
     *      This prevents "function selector clash" attacks
     */
    function upgradeTo(address newImplementation) external onlyAdmin {
        _setImplementation(newImplementation);
        emit Upgraded(newImplementation);
    }

    /// @notice Upgrade AND call initializer in one tx
    function upgradeToAndCall(
        address newImplementation,
        bytes calldata data
    ) external onlyAdmin {
        _setImplementation(newImplementation);
        (bool ok,) = newImplementation.delegatecall(data);
        require(ok, "TransparentProxy: upgrade call failed");
        emit Upgraded(newImplementation);
    }

    function changeAdmin(address newAdmin) external onlyAdmin {
        address prev = _getAdmin();
        _setAdmin(newAdmin);
        emit AdminChanged(prev, newAdmin);
    }

    function implementation() external view onlyAdmin returns (address) {
        return _getImplementation();
    }

    function admin() external view onlyAdmin returns (address) {
        return _getAdmin();
    }

    // ─── Fallback (delegates all non-admin calls to implementation) ────────────

    fallback() external payable {
        _delegate(_getImplementation());
    }

    receive() external payable {
        _delegate(_getImplementation());
    }

    // ─── Internal ──────────────────────────────────────────────────────────────

    function _delegate(address impl) internal {
        assembly {
            // Copy calldata to memory
            calldatacopy(0, 0, calldatasize())

            // delegatecall: run impl code but write to THIS contract's storage
            let result := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)

            // Copy returndata
            returndatacopy(0, 0, returndatasize())

            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    function _setImplementation(address impl) private {
        require(impl.code.length > 0, "TransparentProxy: not a contract");
        assembly {
            sstore(IMPLEMENTATION_SLOT, impl)
        }
    }

    function _getImplementation() private view returns (address impl) {
        assembly {
            impl := sload(IMPLEMENTATION_SLOT)
        }
    }

    function _setAdmin(address _admin) private {
        assembly {
            sstore(ADMIN_SLOT, _admin)
        }
    }

    function _getAdmin() private view returns (address adm) {
        assembly {
            adm := sload(ADMIN_SLOT)
        }
    }

    modifier onlyAdmin() {
        require(msg.sender == _getAdmin(), "TransparentProxy: not admin");
        _;
    }
}
