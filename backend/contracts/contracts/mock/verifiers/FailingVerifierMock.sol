// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/// Groth16 IVerifier double that always rejects - the negative counterpart to VerifierMock (which
/// always accepts), needed to exercise PrivacyPool's InvalidProof revert path.
contract FailingVerifierMock {
    function verifyProof(
        uint256[2] calldata,
        uint256[2][2] calldata,
        uint256[2] calldata,
        uint256[4] calldata
    ) public pure returns (bool) {
        return false;
    }

    function verifyProof(
        uint256[2] calldata,
        uint256[2][2] calldata,
        uint256[2] calldata,
        uint256[8] calldata
    ) public pure returns (bool) {
        return false;
    }
}
