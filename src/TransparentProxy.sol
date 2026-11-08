// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title TransparentProxy
 * @notice Minimal educational EIP-1967 transparent proxy.
 * @dev For production use a well-reviewed implementation such as OpenZeppelin.
 *      Admin calls are handled by proxy functions; non-admin calls are delegated.
 *      The admin is explicitly forbidden from falling back to implementation code.
 */
contract TransparentProxy {
    bytes32 private constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 private constant ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    event Upgraded(address indexed implementation);
    event AdminChanged(address indexed previousAdmin, address indexed newAdmin);

    constructor(address implementation_, address admin_, bytes memory data_) payable {
        _setImplementation(implementation_);
        _setAdmin(admin_);
        if (data_.length > 0) {
            (bool ok, bytes memory reason) = implementation_.delegatecall(data_);
            if (!ok) _revertWith(reason, "TransparentProxy: init failed");
        }
    }

    modifier ifAdmin() {
        if (msg.sender == _getAdmin()) {
            _;
        } else {
            _fallback();
        }
    }

    function upgradeTo(address newImplementation) external ifAdmin {
        _setImplementation(newImplementation);
        emit Upgraded(newImplementation);
    }

    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable ifAdmin {
        _setImplementation(newImplementation);
        if (data.length > 0) {
            (bool ok, bytes memory reason) = newImplementation.delegatecall(data);
            if (!ok) _revertWith(reason, "TransparentProxy: upgrade call failed");
        }
        emit Upgraded(newImplementation);
    }

    function changeAdmin(address newAdmin) external ifAdmin {
        address previousAdmin = _getAdmin();
        _setAdmin(newAdmin);
        emit AdminChanged(previousAdmin, newAdmin);
    }

    function implementation() external ifAdmin returns (address) {
        return _getImplementation();
    }

    function admin() external ifAdmin returns (address) {
        return _getAdmin();
    }

    fallback() external payable {
        _fallback();
    }

    receive() external payable {
        _fallback();
    }

    function _fallback() private {
        require(msg.sender != _getAdmin(), "TransparentProxy: admin cannot fallback");
        _delegate(_getImplementation());
    }

    function _delegate(address implementation_) private {
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), implementation_, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    function _setImplementation(address implementation_) private {
        require(implementation_.code.length > 0, "TransparentProxy: not a contract");
        bytes32 slot = IMPLEMENTATION_SLOT;
        assembly { sstore(slot, implementation_) }
    }

    function _getImplementation() private view returns (address implementation_) {
        bytes32 slot = IMPLEMENTATION_SLOT;
        assembly { implementation_ := sload(slot) }
    }

    function _setAdmin(address admin_) private {
        require(admin_ != address(0), "TransparentProxy: zero admin");
        bytes32 slot = ADMIN_SLOT;
        assembly { sstore(slot, admin_) }
    }

    function _getAdmin() private view returns (address admin_) {
        bytes32 slot = ADMIN_SLOT;
        assembly { admin_ := sload(slot) }
    }

    function _revertWith(bytes memory reason, string memory fallbackMessage) private pure {
        if (reason.length > 0) {
            assembly { revert(add(reason, 32), mload(reason)) }
        }
        revert(fallbackMessage);
    }
}
