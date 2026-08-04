// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test, console} from 'forge-std/Test.sol';
import {AggregationHonkVerifier} from '../../contracts/pool/verifiers/AggregationHonkVerifier.sol';

/*
 * THE N=16 AGGREGATION HAPPY PATH, WITH A REAL PROOF (2026-08-04).
 *
 * `WithdrawBatchGuards.t.sol` states plainly what it cannot cover: *"Settling a real batch needs a
 * genuine N=16 aggregation proof, ~27 GB to produce, so it cannot be made on an ordinary dev
 * machine"*. That was true until the container swapfile made it producible - so this file exists to
 * close exactly that gap, and nothing wider.
 *
 * WHAT THE FIXTURE IS. A REAL proof, not a construction: sixteen genuine `withdraw_identity` proofs
 * (`-t noir-recursive`, 458 fields each, 7 public signals each) folded by `aggregate_withdrawals`,
 * whose witness SOLVED - meaning all sixteen were verified in-circuit against the PINNED inner
 * verification key and the batch commitment matched. The outer proof was then produced with
 * `bb prove -t evm` and checked with `bb verify -t evm` before export.
 *
 * WHY THIS MATTERS MORE THAN A UNIT TEST. It is the only thing that exercises the WHOLE chain end to
 * end - Noir circuit, pinned inner VK, bb prover, generated Solidity verifier - on the CURRENT
 * toolchain pin. TODO recorded the last end-to-end run on beta.13 + bb 1.2.0; every proof format in
 * between has shifted at least once (sec. 2.4: 507 vs 458 fields, PROOF_TYPE 0 vs 6). A green here
 * means the pin is coherent from circuit to contract.
 *
 * WHAT IT STILL DOES NOT COVER, so the green is not over-read: `withdrawBatch` itself is not called -
 * that needs a funded pool and sixteen matching withdrawals. This tests the VERIFIER the entrypoint
 * depends on. Items 1 and 3 of `WithdrawBatchGuards.t.sol`'s untested list remain untested.
 */
contract AggregationProofOnChainTest is Test {
    AggregationHonkVerifier internal verifier;
    string internal fixture;

    function setUp() public {
        fixture = vm.readFile('test/fixtures/aggregation_n16.json');
        verifier = new AggregationHonkVerifier();
    }

    function _proof() internal view returns (bytes memory) {
        return vm.parseJsonBytes(fixture, '.proof');
    }

    function _publicInputs() internal view returns (bytes32[] memory) {
        return vm.parseJsonBytes32Array(fixture, '.publicInputs');
    }

    /// THE CLAIM: a genuine sixteen-withdrawal aggregation proof is accepted by the deployed verifier.
    function test_aRealN16AggregationProofVerifiesOnChain() public view {
        assertTrue(
            verifier.verify(_proof(), _publicInputs()),
            'the real N=16 aggregation proof was rejected by its own generated verifier'
        );
    }

    /// And the shape is what the circuit declares, so a silent format drift is caught here rather
    /// than as an unexplained rejection. 370 fields x 32 bytes; ONE public input, the commitment.
    function test_theProofShapeMatchesTheCircuit() public view {
        assertEq(_proof().length, 370 * 32, 'proof is not 370 field elements');
        assertEq(_publicInputs().length, 1, 'aggregation exposes exactly one public input');
    }

    /*
     * THE ECONOMICS, ISOLATED. The claim aggregation rests on is that verifying N withdrawals in one
     * proof is far cheaper per withdrawal than verifying them singly. TODO sec. 2.4 says ~68k each at
     * N=16 against ~200k+ single; the circuit's own header says ~152k. Neither was ever measured
     * on-chain, so this measures ONLY the `verify` call - no fixture parsing, no settlement.
     */
    function test_MeasureAggregatedVerificationGas() public view {
        bytes memory p = _proof();
        bytes32[] memory pubs = _publicInputs();

        uint256 g0 = gasleft();
        bool ok = verifier.verify(p, pubs);
        uint256 used = g0 - gasleft();

        assertTrue(ok);
        console.log('aggregated verify() gas (batch of 16):', used);
        console.log('  per withdrawal:', used / 16);
    }

    /*
     * NON-VACUITY. Without these, a verifier that ignored its arguments would pass the test above.
     * Both mutations must be REFUSED.
     */
    /// NOTE THE FAILURE MODE: this verifier REVERTS (`SumcheckFailed()`) rather than returning
    /// false, which is the stronger behaviour - a caller cannot ignore a boolean it never receives.
    function test_aTamperedProofIsRejected() public {
        bytes memory p = _proof();
        p[3000] = bytes1(uint8(p[3000]) ^ 0x01);
        vm.expectRevert();
        verifier.verify(p, _publicInputs());
    }

    /// THE ONE THAT MATTERS MOST: the public input IS the batch commitment, so changing it claims a
    /// DIFFERENT set of sixteen withdrawals. If this passed, a batcher could settle any batch with
    /// any proof, and every guard in `withdrawBatch` would be decoration.
    function test_aDifferentBatchCommitmentIsRejected() public {
        bytes32[] memory pubs = _publicInputs();
        pubs[0] = bytes32(uint256(pubs[0]) ^ 1);
        vm.expectRevert();
        verifier.verify(_proof(), pubs);
    }
}
