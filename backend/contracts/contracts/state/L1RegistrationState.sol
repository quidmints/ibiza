// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {TypeCaster} from "@solarity/solidity-lib/libs/utils/TypeCaster.sol";
import {AMultiOwnable} from "@solarity/solidity-lib/access/AMultiOwnable.sol";

contract L1RegistrationState is Initializable, AMultiOwnable, UUPSUpgradeable {
    using TypeCaster for address;

    uint256 public constant ROOT_VALIDITY = 1 hours;

    address public rarimoRollup;

    bytes32 public latestRoot;
    uint256 public latestRootTimestamp;

    mapping(bytes32 => uint256) public roots;

    event RootSet(bytes32 root);

    error NotRarimoRollup(address sender);

    modifier onlyRarimoRollup() {
        _requireRarimoRollup();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function __L1RegistrationState_init(
        address initialOwner_,
        address rarimoRollup_
    ) external initializer {
        __AMultiOwnable_init(initialOwner_.asSingletonArray());

        rarimoRollup = rarimoRollup_;
    }

    function setRegistrationRoot(bytes32 root_, uint256 timestamp_) external onlyRarimoRollup {
        roots[root_] = timestamp_;

        if (timestamp_ >= latestRootTimestamp) {
            latestRoot = root_;
            latestRootTimestamp = timestamp_;
        }

        emit RootSet(root_);
    }

    function setRarimoRollup(address rarimoRollup_) external onlyOwner {
        rarimoRollup = rarimoRollup_;
    }

    function isRootLatest(bytes32 root_) public view virtual returns (bool) {
        return latestRoot == root_;
    }

    /**
     * @notice Checks if the root is valid.
     *
     * A ROOT THIS CONTRACT HAS NEVER HELD MUST BE INVALID, and saying so needs the existence check
     * below. An unrecorded root maps to 0, so the age test alone reads as
     * `0 + ROOT_VALIDITY > block.timestamp` - TRUE for every invented root while `block.timestamp`
     * is under ROOT_VALIDITY. Live chains are far past that, which is the only reason this was ever
     * safe: a fact about the world, not something the code states. Third copy of the same defect
     * (TODO.md sec. 2.18o); every one of them guards a proof.
     */
    function isRootValid(bytes32 root_) external view virtual returns (bool) {
        if (root_ == bytes32(0)) {
            return false;
        }

        if (isRootLatest(root_)) {
            return true;
        }

        uint256 transitionedAt_ = roots[root_];

        return transitionedAt_ != 0 && transitionedAt_ + ROOT_VALIDITY > block.timestamp;
    }

    // solhint-disable-next-line no-empty-blocks
    function _authorizeUpgrade(address) internal virtual override onlyOwner {}

    function implementation() external view returns (address) {
        return ERC1967Utils.getImplementation();
    }

    function _requireRarimoRollup() internal view {
        if (msg.sender != rarimoRollup) {
            revert NotRarimoRollup(msg.sender);
        }
    }
}
