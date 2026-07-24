// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Test} from "forge-std/Test.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SparseMerkleTree} from "@solarity/solidity-lib/libs/data-structures/SparseMerkleTree.sol";

import {HolderStateKeeper} from "../../contracts/holder/HolderStateKeeper.sol";
import {HolderStateKeeperMock} from "../../contracts/mock/holder/HolderStateKeeperMock.sol";
import {PoseidonSMTMock} from "../../contracts/mock/state/PoseidonSMTMock.sol";
import {PoseidonUnit1L, PoseidonUnit2L, PoseidonUnit3L} from "../../contracts/libraries/Poseidon.sol";

/// Holder-rooted credential tree — one key, many documents (SCOPE.md §7.8). Forge port.
contract HolderStateKeeperTest is Test {
    uint256 internal constant TREE = 80;
    bytes32 internal constant ICAO = 0x2c50ce3aa92bc3dd0351a89970b02630415547ea83c487befbc8b1795ea90c45;

    bytes32 internal constant HOLDER = bytes32(uint256(0x1111));
    bytes32 internal constant HOLDER2 = bytes32(uint256(0x2222));
    bytes32 internal constant DOC_A = bytes32(uint256(0x0a0a));
    bytes32 internal constant DOC_B = bytes32(uint256(0x0b0b));
    bytes32 internal constant DOC_C = bytes32(uint256(0x0c0c));
    uint256 internal constant DG_A = 111;
    uint256 internal constant DG_B = 222;
    uint256 internal constant DG_C = 333;

    // DocStatus
    uint8 internal constant CURRENT = 1;
    uint8 internal constant SUPERSEDED = 2;
    uint8 internal constant REVOKED = 3;

    address internal OWNER = address(0xA11CE);
    address internal REG = address(0xBEEF); // acts as the registration contract

    HolderStateKeeperMock internal sk;
    PoseidonSMTMock internal smt;
    bytes32 internal DOC_PASSPORT;
    bytes32 internal DOC_NATIONAL_ID;

    function setUp() public {
        smt = PoseidonSMTMock(_proxy(address(new PoseidonSMTMock())));
        PoseidonSMTMock certs = PoseidonSMTMock(_proxy(address(new PoseidonSMTMock())));
        sk = HolderStateKeeperMock(_proxy(address(new HolderStateKeeperMock())));

        // Real minimal evidence registry (the PoseidonSMT only calls addStatement on root
        // commits). Rarimo's EvidenceRegistry uses a Poseidon-isolated key that Forge's
        // auto-linker leaves unlinked → 0 → false collisions; this keccak-isolated registry has
        // identical per-(sender,root) dedup semantics. Contracts UNDER TEST are unmodified.
        TestEvidenceRegistry reg = new TestEvidenceRegistry();

        smt.__PoseidonSMT_init(address(sk), address(reg), TREE);
        certs.__PoseidonSMT_init(address(sk), address(reg), TREE);

        sk.__StateKeeper_init(OWNER, address(smt), address(certs), ICAO);

        string[] memory keys = new string[](1);
        keys[0] = "holder-reg";
        address[] memory vals = new address[](1);
        vals[0] = REG;
        sk.mockAddRegistrations(keys, vals);

        DOC_PASSPORT = sk.DOC_PASSPORT();
        DOC_NATIONAL_ID = sk.DOC_NATIONAL_ID();
    }

    function _proxy(address impl) internal returns (address) {
        return address(new ERC1967Proxy(impl, ""));
    }

    function _leafIndex(bytes32 documentKey, bytes32 holderRoot) internal pure returns (bytes32) {
        return bytes32(PoseidonUnit2L.poseidon([uint256(documentKey), uint256(holderRoot)]));
    }

    // ── the old 1:1 binding is disabled ────────────────────────────────────────────────────

    function test_addBond_disabled() public {
        vm.prank(REG);
        vm.expectRevert("HolderStateKeeper: use addDocument (holder tree)");
        sk.addBond(DOC_A, bytes32(0), HOLDER, 0);
    }

    function test_writes_gated_to_registrations() public {
        vm.expectRevert("StateKeeper: not a registration");
        sk.addDocument(DOC_A, bytes32(0), HOLDER, DOC_PASSPORT, DG_A, 0);
    }

    // ── many documents, one holder ─────────────────────────────────────────────────────────

    function test_many_documents_one_holder() public {
        vm.startPrank(REG);
        sk.addDocument(DOC_A, bytes32(0), HOLDER, DOC_PASSPORT, DG_A, 0);
        sk.addDocument(DOC_B, bytes32(0), HOLDER, DOC_NATIONAL_ID, DG_B, 0);
        vm.stopPrank();

        assertEq(sk.getActiveDocumentCount(HOLDER), 2, "two current docs under one holder");

        bytes32[] memory docs = sk.getHolderDocuments(HOLDER);
        assertEq(docs.length, 2);
        assertEq(docs[0], DOC_A);
        assertEq(docs[1], DOC_B);

        HolderStateKeeper.DocumentBond memory a = sk.getDocument(DOC_A);
        assertEq(a.holderRoot, HOLDER);
        assertEq(a.docType, DOC_PASSPORT);
        assertEq(uint8(a.status), CURRENT);

        assertTrue(smt.getProof(_leafIndex(DOC_A, HOLDER)).existence);
        assertTrue(smt.getProof(_leafIndex(DOC_B, HOLDER)).existence);
    }

    function test_no_double_bind() public {
        vm.prank(REG);
        sk.addDocument(DOC_A, bytes32(0), HOLDER, DOC_PASSPORT, DG_A, 0);
        vm.prank(REG);
        vm.expectRevert("HolderStateKeeper: document bound");
        sk.addDocument(DOC_A, bytes32(0), HOLDER2, DOC_PASSPORT, DG_A, 0);
    }

    function test_document_hash_anti_replay() public {
        bytes32 h = bytes32(uint256(0xeeee));
        vm.prank(REG);
        sk.addDocument(DOC_A, h, HOLDER, DOC_PASSPORT, DG_A, 0);
        vm.prank(REG);
        vm.expectRevert("HolderStateKeeper: document hash used");
        sk.addDocument(DOC_B, h, HOLDER, DOC_PASSPORT, DG_B, 0);
    }

    // ── renewal preserves the holder root ──────────────────────────────────────────────────

    function test_renewal_supersedes_and_preserves_root() public {
        vm.startPrank(REG);
        sk.addDocument(DOC_A, bytes32(0), HOLDER, DOC_PASSPORT, DG_A, 0);
        sk.addDocument(DOC_B, bytes32(0), HOLDER, DOC_NATIONAL_ID, DG_B, 0);

        sk.renewDocument(DOC_A, DOC_C, bytes32(0), HOLDER, DOC_PASSPORT, DG_C, 0);
        vm.stopPrank();

        assertEq(uint8(sk.getDocument(DOC_A).status), SUPERSEDED);
        HolderStateKeeper.DocumentBond memory c = sk.getDocument(DOC_C);
        assertEq(uint8(c.status), CURRENT);
        assertEq(c.holderRoot, HOLDER, "continuity: same root");
        assertEq(c.seq, 1, "next sequence");
        assertEq(sk.getActiveDocumentCount(HOLDER), 2); // B + C
    }

    function test_renew_rejects_non_current() public {
        vm.startPrank(REG);
        sk.addDocument(DOC_A, bytes32(0), HOLDER, DOC_PASSPORT, DG_A, 0);
        sk.renewDocument(DOC_A, DOC_C, bytes32(0), HOLDER, DOC_PASSPORT, DG_C, 0);
        vm.expectRevert("HolderStateKeeper: old not current");
        sk.renewDocument(DOC_A, DOC_B, bytes32(0), HOLDER, DOC_PASSPORT, DG_B, 0);
        vm.stopPrank();
    }

    function test_renew_rejects_wrong_holder() public {
        vm.startPrank(REG);
        sk.addDocument(DOC_A, bytes32(0), HOLDER, DOC_PASSPORT, DG_A, 0);
        vm.expectRevert("HolderStateKeeper: holder mismatch");
        sk.renewDocument(DOC_A, DOC_C, bytes32(0), HOLDER2, DOC_PASSPORT, DG_C, 0);
        vm.stopPrank();
    }

    // ── revocation ─────────────────────────────────────────────────────────────────────────

    function test_revoke() public {
        vm.startPrank(REG);
        sk.addDocument(DOC_A, bytes32(0), HOLDER, DOC_PASSPORT, DG_A, 0);
        sk.revokeDocument(DOC_A);
        vm.stopPrank();

        assertEq(uint8(sk.getDocument(DOC_A).status), REVOKED);
        assertEq(sk.getActiveDocumentCount(HOLDER), 0);
    }

    function test_cannot_revoke_twice() public {
        vm.startPrank(REG);
        sk.addDocument(DOC_A, bytes32(0), HOLDER, DOC_PASSPORT, DG_A, 0);
        sk.revokeDocument(DOC_A);
        vm.expectRevert("HolderStateKeeper: not current");
        sk.revokeDocument(DOC_A);
        vm.stopPrank();
    }

    function test_non_membership_of_unregistered() public {
        assertFalse(smt.getProof(_leafIndex(DOC_C, HOLDER)).existence);
    }

    // ── EXECUTABLE circuit-compat proof: leaf value == Poseidon3(dgCommit, seq, timestamp) ──
    // This is what query_identity reconstructs; a revoked leaf's value is a marker → the
    // circuit's membership check fails for it (revocation enforced by value-mismatch).

    function test_leaf_value_matches_circuit_reconstruction() public {
        vm.prank(REG);
        sk.addDocument(DOC_A, bytes32(0), HOLDER, DOC_PASSPORT, DG_A, 0);
        uint64 ts = uint64(block.timestamp);

        SparseMerkleTree.Proof memory p = smt.getProof(_leafIndex(DOC_A, HOLDER));
        // exactly the value query_identity rebuilds: Poseidon3(dgCommit, seq=0, timestamp)
        bytes32 expected = bytes32(PoseidonUnit3L.poseidon([DG_A, uint256(0), uint256(ts)]));
        assertEq(p.value, expected, "current leaf == Poseidon3(dgCommit, seq, ts)");

        // revoke → leaf value becomes Poseidon1(REVOKED) marker, which can NEVER equal the
        // Poseidon3 reconstruction → the query circuit auto-rejects a revoked document.
        vm.prank(REG);
        sk.revokeDocument(DOC_A);
        SparseMerkleTree.Proof memory p2 = smt.getProof(_leafIndex(DOC_A, HOLDER));
        bytes32 revokedMarker = bytes32(PoseidonUnit1L.poseidon([uint256(keccak256("REVOKED"))]));
        assertEq(p2.value, revokedMarker, "revoked leaf == Poseidon1(REVOKED) marker");
        assertTrue(p2.value != expected, "marker can't match circuit reconstruction");
    }
}

/// Minimal, real evidence registry: records each (sender, root) statement once. Same dedup
/// semantics as Rarimo's, keccak-isolated (Poseidon-free) so it links cleanly under Forge.
contract TestEvidenceRegistry {
    mapping(bytes32 => bytes32) public statements;

    error KeyAlreadyExists(bytes32 key);

    function addStatement(bytes32 key_, bytes32 value_) external {
        bytes32 isolated = keccak256(abi.encodePacked(msg.sender, key_));
        if (statements[isolated] != bytes32(0)) revert KeyAlreadyExists(key_);
        statements[isolated] = value_;
    }
}
