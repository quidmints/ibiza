// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {PoseidonT2Inline as PoseidonT2} from "./inline/PoseidonT2Inline.sol";
import {PoseidonT3Inline as PoseidonT3} from "./inline/PoseidonT3Inline.sol";
import {PoseidonT4Inline as PoseidonT4} from "./inline/PoseidonT4Inline.sol";
import {PoseidonT5Inline as PoseidonT5} from "./inline/PoseidonT5Inline.sol";
import {PoseidonT6Inline as PoseidonT6} from "./inline/PoseidonT6Inline.sol";

library PoseidonUnit1L {
    function poseidon(uint256[1] memory inputs_) internal pure returns (uint256) {
        return PoseidonT2.hash([inputs_[0]]);
    }
}

library PoseidonUnit2L {
    function poseidon(uint256[2] memory inputs_) internal pure returns (uint256) {
        return PoseidonT3.hash([inputs_[0], inputs_[1]]);
    }
}

library PoseidonUnit3L {
    function poseidon(uint256[3] memory inputs_) internal pure returns (uint256) {
        return PoseidonT4.hash([inputs_[0], inputs_[1], inputs_[2]]);
    }
}

library PoseidonUnit4L {
    function poseidon(uint256[4] memory inputs_) internal pure returns (uint256) {
        return PoseidonT5.hash([inputs_[0], inputs_[1], inputs_[2], inputs_[3]]);
    }
}

library PoseidonUnit5L {
    function poseidon(uint256[5] memory inputs_) internal pure returns (uint256) {
        return PoseidonT6.hash([inputs_[0], inputs_[1], inputs_[2], inputs_[3], inputs_[4]]);
    }
}
