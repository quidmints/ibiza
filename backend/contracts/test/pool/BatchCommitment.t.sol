// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test, console} from 'forge-std/Test.sol';
import {BatchCommitmentLib} from 'contracts/pool/lib/BatchCommitmentLib.sol';

/*
 * THE CIRCUIT AND THE CONTRACT MUST AGREE ABOUT THE BATCH COMMITMENT (TODO.md sec. 2.4).
 *
 * The aggregation verifier exposes ONE public input - the commitment - so this fold is the only
 * thing tying that field back to the individual withdrawals a batch settles. If the two
 * implementations diverge, nothing says so: the circuit proves happily, the contract recomputes
 * happily, and they simply produce different field elements.
 *
 * Solidity testing Solidity cannot catch that, exactly as Go testing Go could not catch the notary
 * Merkle mismatch (see NotaryRegistryProofTest) - a shared misunderstanding makes a generator and
 * its own checker agree and both be wrong.
 *
 * THIS TEST ONCE HELD A FROZEN CONSTANT AND SLEPT THROUGH A REAL DIVERGENCE (2026-08-04). The
 * circuit moved to keccak256 while `BatchCommitmentLib` stayed on chained Poseidon v1, and this file
 * kept passing - because a pinned number only asks whether SOLIDITY has changed, and the question is
 * whether the two SIDES agree. The library would have rejected every real batch.
 *
 * SO THE EXPECTATION IS CONSTRUCTED, NOT PASTED. `_circuitCommitment` below is an independent
 * transcription of `aggregate_withdrawals::batch_commitment` - keccak over the signals as 32-byte
 * big-endian words, reduced into the field - written from the circuit rather than from the library.
 * It is a second implementation ON PURPOSE: if the library is edited to match a wrong idea of the
 * circuit, this does not follow it. Moving either side breaks the test.
 *
 * FIXTURE PROVENANCE. `pi[i][j] = i * 100 + j + 1`, the same vector the circuit prints from a
 * `println(batch_commitment(pi))` test in backend/circuits/aggregate_withdrawals/src/main.nr. At
 * N=2 that circuit emits 0x2769ca7e6b0f6b41f45f61a850fb6c3d83b2cf85f4e3658b20b4a83b861a9cda, which
 * `test_TheTranscriptionMatchesTheCircuitAtN2` holds this transcription to.
 */
contract BatchCommitmentTest is Test {
  uint256 internal constant N = 16;
  uint256 internal constant PUB_LEN = 7;

  /// BN254's scalar field order. Restated here rather than imported so this transcription does not
  /// inherit a constant from the library it is checking.
  uint256 internal constant FIELD_MODULUS =
    21888242871839275222246405745257275088548364400416034343698204186575808495617;

  /// The circuit at N=2 on this vector, copied from `nargo test --show-output`. Small enough to run
  /// in the circuit cheaply, which is why the anchor is taken at N=2 rather than N=16.
  uint256 internal constant CIRCUIT_AT_N2 =
    0x2769ca7e6b0f6b41f45f61a850fb6c3d83b2cf85f4e3658b20b4a83b861a9cda;

  /// `aggregate_withdrawals::batch_commitment`, transcribed from the CIRCUIT. Independent of
  /// BatchCommitmentLib on purpose - see the header.
  function _circuitCommitment(uint256[PUB_LEN][] memory signals) internal pure returns (uint256) {
    bytes memory preimage;
    for (uint256 i = 0; i < signals.length; ++i) {
      for (uint256 j = 0; j < PUB_LEN; ++j) {
        preimage = bytes.concat(preimage, bytes32(signals[i][j]));
      }
    }
    return uint256(keccak256(preimage)) % FIELD_MODULUS;
  }

  function _signals() internal pure returns (uint256[PUB_LEN][] memory s) {
    s = new uint256[PUB_LEN][](N);
    for (uint256 i = 0; i < N; ++i) {
      for (uint256 j = 0; j < PUB_LEN; ++j) {
        s[i][j] = i * 100 + j + 1;
      }
    }
  }

  /// THE ANCHOR: the transcription reproduces what the circuit actually printed. Without this the
  /// transcription could drift from the circuit and still agree with the library, which is exactly
  /// the mutual-agreement failure this file exists to prevent.
  function test_TheTranscriptionMatchesTheCircuitAtN2() public pure {
    uint256[PUB_LEN][] memory s = new uint256[PUB_LEN][](2);
    for (uint256 i = 0; i < 2; ++i) {
      for (uint256 j = 0; j < PUB_LEN; ++j) {
        s[i][j] = i * 100 + j + 1;
      }
    }
    assertEq(_circuitCommitment(s), CIRCUIT_AT_N2, 'the transcription no longer matches the circuit');
  }

  /// THE BASELINE: the library reproduces what the circuit computes.
  function test_MatchesTheCircuit() public pure {
    assertEq(
      BatchCommitmentLib.batchCommitment(_signals()),
      _circuitCommitment(_signals()),
      'the circuit and the contract disagree about the batch commitment'
    );
  }

  /// ...and it is not vacuous: changing any single signal must change the result. Without this, a
  /// fold that ignored its inputs entirely would pass the test above.
  function test_EverySignalIsBound() public pure {
    uint256 baseline = BatchCommitmentLib.batchCommitment(_signals());
    for (uint256 i = 0; i < N; ++i) {
      for (uint256 j = 0; j < PUB_LEN; ++j) {
        uint256[PUB_LEN][] memory m = _signals();
        m[i][j] ^= 1;
        assertTrue(
          BatchCommitmentLib.batchCommitment(m) != baseline,
          'a signal position does not affect the commitment'
        );
      }
    }
  }

  /// ORDER-BINDING. Swapping two withdrawals must change the commitment, or a batcher could permute
  /// the batch relative to the calldata the contract walks - moving one user's recipient context
  /// onto another's nullifier while still matching.
  function test_OrderIsBound() public pure {
    uint256[PUB_LEN][] memory a = _signals();
    uint256[PUB_LEN][] memory b = _signals();
    (b[0], b[1]) = (b[1], b[0]);
    assertTrue(
      BatchCommitmentLib.batchCommitment(a) != BatchCommitmentLib.batchCommitment(b),
      'the fold is commutative - withdrawals can be permuted'
    );
  }

  /// A batch of a different LENGTH must not collide with this one. Truncating the calldata is the
  /// cheapest thing an attacker can try.
  function test_LengthIsBound() public pure {
    uint256[PUB_LEN][] memory full = _signals();
    uint256[PUB_LEN][] memory short = new uint256[PUB_LEN][](N - 1);
    for (uint256 i = 0; i < N - 1; ++i) short[i] = full[i];
    assertTrue(
      BatchCommitmentLib.batchCommitment(short) != BatchCommitmentLib.batchCommitment(full),
      'a shorter batch produced the same commitment'
    );
  }

  /// GAS: what the on-chain recompute actually costs per withdrawal.
  function test_GasOfTheFold() public view {
    uint256[PUB_LEN][] memory s = _signals();
    uint256 g0 = gasleft();
    BatchCommitmentLib.batchCommitment(s);
    uint256 used = g0 - gasleft();
    console.log("fold gas total", used);
    console.log("per withdrawal ", used / N);
  }

  /// The empty batch must not collide with any real one. It is keccak256("") reduced into the field,
  /// NOT zero as it was under the Poseidon chain - which is the better property: zero is what an
  /// uninitialised slot reads back as, so a commitment that can never be zero cannot be matched by
  /// one. `BatchVerifierLib` rejects an empty batch before reaching here regardless.
  function test_EmptyBatchIsDistinct() public pure {
    uint256[PUB_LEN][] memory none = new uint256[PUB_LEN][](0);
    uint256 empty = BatchCommitmentLib.batchCommitment(none);
    assertEq(empty, _circuitCommitment(none), 'the empty batch disagrees with the circuit');
    assertTrue(empty != 0, 'the empty commitment is zero, which an empty storage slot also reads as');
    assertTrue(BatchCommitmentLib.batchCommitment(_signals()) != empty, 'a real batch collides with the empty one');
  }
}
