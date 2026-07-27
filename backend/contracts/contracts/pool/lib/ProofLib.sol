// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/**
 * @title ProofLib
 * @notice Facilitates accessing the public signals of a Groth16 proof.
 * @custom:semver 0.1.0
 */
library ProofLib {
  /*///////////////////////////////////////////////////////////////
                         WITHDRAWAL PROOF 
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Struct containing a Noir/Honk proof and public signals for withdrawal verification
   * @dev Withdrawal is identity-based-ASP (backend/circuits/withdraw_identity), Noir/Honk-proved,
   * NOT Groth16 - see State.sol's WITHDRAWAL_VERIFIER (INoirVerifier). `proof` is the serialized
   * Honk proof (`bb prove_ultra_keccak_honk` output); `pubSignals` keeps the same 8-slot uint256
   * layout/order the original Groth16 design used (contract-side accessors below are unchanged),
   * converted to `bytes32[]` only at the verifier-call boundary (`publicInputsBytes32`) since
   * INoirVerifier.verify expects `bytes32[] calldata`, matching every other Noir verifier call in
   * this fusion (see RegistrationSimple._verifyNoirZKProof for the same pattern).
   * @param proof The serialized Honk proof bytes
   * @param pubSignals Array of public inputs and outputs:
   *        - [0] newCommitmentHash: Hash of the new commitment being created
   *        - [1] existingNullifierHash: Hash of the nullifier being spent
   *        - [2] withdrawnValue: Amount being withdrawn
   *        - [3] stateRoot: Current state root of the privacy pool
   *        - [4] stateTreeDepth: Current depth of the state tree
   *        - [5] ASPRoot: Current root of the IDENTITY-based Association Set tree
   *        - [6] ASPTreeDepth: Current depth of the ASP tree
   *        - [7] context: Context value for the withdrawal operation
   *        - [8] revocationRoot: Root of the RevocationRegistry the proof shows NON-membership of
   */
  struct WithdrawProof {
    bytes proof;
    uint256[9] pubSignals;
  }

  /**
   * @notice Converts `pubSignals` to the `bytes32[]` shape INoirVerifier.verify expects. A fixed
   * array can't be implicitly cast to a dynamic one in Solidity, so this copies element-by-element
   * - the same thing RegistrationSimple._verifyNoirZKProof already does manually for its own
   * (differently-shaped) public inputs.
   * @param _p The proof containing the public signals
   * @return _publicInputs The public signals as a dynamic bytes32 array, in the same order
   */
  function publicInputsBytes32(WithdrawProof memory _p) internal pure returns (bytes32[] memory _publicInputs) {
    _publicInputs = new bytes32[](9);
    for (uint256 _i = 0; _i < 9; ++_i) {
      _publicInputs[_i] = bytes32(_p.pubSignals[_i]);
    }
  }

  /**
   * @notice Retrieves the new commitment hash from the proof's public signals
   * @param _p The proof containing the public signals
   * @return The hash of the new commitment being created
   */
  function newCommitmentHash(WithdrawProof memory _p) internal pure returns (uint256) {
    return _p.pubSignals[0];
  }

  /**
   * @notice Retrieves the existing nullifier hash from the proof's public signals
   * @param _p The proof containing the public signals
   * @return The hash of the nullifier being spent in this withdrawal
   */
  function existingNullifierHash(WithdrawProof memory _p) internal pure returns (uint256) {
    return _p.pubSignals[1];
  }

  /**
   * @notice Retrieves the withdrawn value from the proof's public signals
   * @param _p The proof containing the public signals
   * @return The amount being withdrawn from Privacy Pool
   */
  function withdrawnValue(WithdrawProof memory _p) internal pure returns (uint256) {
    return _p.pubSignals[2];
  }

  /**
   * @notice Retrieves the state root from the proof's public signals
   * @param _p The proof containing the public signals
   * @return The root of the state tree at time of proof generation
   */
  function stateRoot(WithdrawProof memory _p) internal pure returns (uint256) {
    return _p.pubSignals[3];
  }

  /**
   * @notice Retrieves the state tree depth from the proof's public signals
   * @param _p The proof containing the public signals
   * @return The depth of the state tree at time of proof generation
   */
  function stateTreeDepth(WithdrawProof memory _p) internal pure returns (uint256) {
    return _p.pubSignals[4];
  }

  /**
   * @notice Retrieves the ASP root from the proof's public signals
   * @param _p The proof containing the public signals
   * @return The latest root of the ASP tree at time of proof generation
   */
  function ASPRoot(WithdrawProof memory _p) internal pure returns (uint256) {
    return _p.pubSignals[5];
  }

  /**
   * @notice Retrieves the ASP tree depth from the proof's public signals
   * @param _p The proof containing the public signals
   * @return The depth of the ASP tree at time of proof generation
   */
  function ASPTreeDepth(WithdrawProof memory _p) internal pure returns (uint256) {
    return _p.pubSignals[6];
  }

  /**
   * @notice Retrieves the context value from the proof's public signals
   * @param _p The proof containing the public signals
   * @return The context value binding the proof to specific withdrawal data
   */
  function context(WithdrawProof memory _p) internal pure returns (uint256) {
    return _p.pubSignals[7];
  }

  /// @notice Root of the revocation registry this proof asserts the withdrawer is ABSENT from.
  /// @dev PrivacyPool checks it with RevocationRegistry.isValidRoot, so a stale or invented root is
  ///      rejected on-chain - the circuit alone cannot know which roots the registry really had.
  function revocationRoot(WithdrawProof memory _p) internal pure returns (uint256) {
    return _p.pubSignals[8];
  }

  /*///////////////////////////////////////////////////////////////
                          RAGEQUIT PROOF 
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Struct containing Groth16 proof elements and public signals for ragequit verification
   * @dev The public signals array must match the order of public inputs/outputs in the circuit
   * @param pA First elliptic curve point (π_A) of the Groth16 proof, encoded as two field elements
   * @param pB Second elliptic curve point (π_B) of the Groth16 proof, encoded as 2x2 matrix of field elements
   * @param pC Third elliptic curve point (π_C) of the Groth16 proof, encoded as two field elements
   * @param pubSignals Array of public inputs and outputs:
   *        - [0] commitmentHash: Hash of the commitment being ragequit
   *        - [1] nullifierHash: Nullifier hash of commitment being ragequit
   *        - [2] value: Value of the commitment being ragequit
   *        - [3] label: Label of commitment
   */
  struct RagequitProof {
    uint256[2] pA;
    uint256[2][2] pB;
    uint256[2] pC;
    uint256[4] pubSignals;
  }

  /**
   * @notice Retrieves the new commitment hash from the proof's public signals
   * @param _p The ragequit proof containing the public signals
   * @return The new commitment hash
   */
  function commitmentHash(RagequitProof memory _p) internal pure returns (uint256) {
    return _p.pubSignals[0];
  }

  /**
   * @notice Retrieves the nullifier hash from the proof's public signals
   * @param _p The ragequit proof containing the public signals
   * @return The nullifier hash
   */
  function nullifierHash(RagequitProof memory _p) internal pure returns (uint256) {
    return _p.pubSignals[1];
  }

  /**
   * @notice Retrieves the commitment value from the proof's public signals
   * @param _p The ragequit proof containing the public signals
   * @return The commitment value
   */
  function value(RagequitProof memory _p) internal pure returns (uint256) {
    return _p.pubSignals[2];
  }

  /**
   * @notice Retrieves the commitment label from the proof's public signals
   * @param _p The ragequit proof containing the public signals
   * @return The commitment label
   */
  function label(RagequitProof memory _p) internal pure returns (uint256) {
    return _p.pubSignals[3];
  }
}
