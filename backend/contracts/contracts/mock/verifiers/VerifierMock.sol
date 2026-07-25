// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/// Groth16 IVerifier double: unconditionally accepts. IVerifier is overloaded by pubSignals
/// width (uint256[8] for withdrawal proofs, uint256[4] for ragequit proofs) - both are
/// implemented here so this one mock can serve as either WITHDRAWAL_VERIFIER or
/// RAGEQUIT_VERIFIER in State.sol (previously only the [4] overload existed, which silently
/// could never satisfy an 8-signal withdrawal call - selector wouldn't resolve).
contract VerifierMock {
    function verifyProof(
        uint256[2] calldata,
        uint256[2][2] calldata,
        uint256[2] calldata,
        uint256[4] calldata
    ) public pure returns (bool) {
        return true;
    }

    function verifyProof(
        uint256[2] calldata,
        uint256[2][2] calldata,
        uint256[2] calldata,
        uint256[8] calldata
    ) public pure returns (bool) {
        return true;
    }
}
