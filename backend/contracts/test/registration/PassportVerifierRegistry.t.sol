// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Registration2} from "../../contracts/registration/Registration2.sol";
import {StateKeeper} from "../../contracts/state/StateKeeper.sol";
import {PoseidonSMT} from "../../contracts/state/PoseidonSMT.sol";
import {
    NoirRegisterIdentity_1_160_3_3_576_200_NA
} from "../../contracts/passport/verifiers2/noir/NoirRegisterIdentity_1_160_3_3_576_200_NA.sol";

/*
 * THE FIRST TEST OF THE PASSPORT VERIFIER REGISTRY (sec. 2.18gz-signer).
 *
 * WHY IT DID NOT EXIST, AND WHAT THAT COST. `Registration2` holds the only entrypoint that verifies
 * the ICAO chain, and NOTHING instantiated it - 56 test files, zero coverage. Four mention it and
 * only import types. `Registration2Mock.mockAddPassportVerifier` has existed the whole time and was
 * never called by anything: a dead setter on a mock.
 *
 * The consequence went unnoticed for exactly that reason. `passportVerifiers` is EMPTY - no deploy
 * script, no migration, nothing calls `updateDependency` - and `_getPassportVerifier` reverts on
 * zero, so **`registerViaNoir` reverts for every document.** 88 correct, current bb 6.0 verifiers
 * are bound to nothing. A suite that never touches the contract cannot notice that.
 *
 * NO MOCKS HERE, DELIBERATELY. The real `Registration2`, the real `StateKeeper` and real
 * `PoseidonSMT` instances, registered through the real owner-gated `updateDependency` rather than
 * the mock's bypass, binding a REAL generated verifier contract rather than a placeholder address.
 * An earlier draft used `Registration2Mock` and `address(0xBEEF)`; that would have proven the
 * mapping stores what you put in it, which was never in doubt. What is worth proving is that the
 * OWNER-GATED path binds a DEPLOYED verifier under the key the deployment will actually compute.
 *
 * WHAT THIS FILE DOES NOT PIN: that any proof verifies. That needs a real travel document, which
 * this repo does not have and does not fabricate. This proves the BINDING, never the cryptography.
 *
 * THE SCHEME IS UPSTREAM'S, NOT INVENTED HERE. rarimo's `scripts/utils/types.ts` defines each
 * constant as keccak256 of its own name and `deploy/10_setup.migration.ts` registers each verifier
 * under it. Reproduced here as `keccak256("Z_NOIR_PASSPORT_" + profile)`.
 */
/// The repo's standard empty-init proxy for tests (same as TitleLedger.t.sol / HolderRegistration.t.sol).
/// `StateKeeper` and `PoseidonSMT` initialise circularly - each needs the other's address - so neither
/// can be constructed with its init calldata inline. This is deployment plumbing, NOT a mock: every
/// contract behind it is the real implementation.
contract UnsafeTestProxy is ERC1967Proxy {
    constructor(address impl) ERC1967Proxy(impl, "") {}

    function _unsafeAllowUninitialized() internal pure override returns (bool) {
        return true;
    }
}

contract PassportVerifierRegistryTest is Test {
    Registration2 internal registration;
    StateKeeper internal stateKeeper;

    address internal owner = address(this);

    string internal constant MANIFEST = "../circuits/passport-profiles.json";
    string internal constant PREFIX = "Z_NOIR_PASSPORT_";
    string internal constant PROFILE = "1_160_3_3_576_200_NA";

    uint256 internal constant TREE_DEPTH = 80;
    bytes32 internal constant ICAO_ROOT = bytes32(uint256(1));

    function setUp() public {
        stateKeeper = StateKeeper(_proxy(address(new StateKeeper())));
        PoseidonSMT registrationSmt = PoseidonSMT(_proxy(address(new PoseidonSMT())));
        PoseidonSMT certificatesSmt = PoseidonSMT(_proxy(address(new PoseidonSMT())));

        registrationSmt.__PoseidonSMT_init(address(stateKeeper), address(0), TREE_DEPTH);
        certificatesSmt.__PoseidonSMT_init(address(stateKeeper), address(0), TREE_DEPTH);

        stateKeeper.__StateKeeper_init(
            owner, address(registrationSmt), address(certificatesSmt), ICAO_ROOT
        );

        registration = Registration2(_proxy(address(new Registration2())));
        registration.__Registration_init(address(stateKeeper));
    }

    function _proxy(address impl) private returns (address) {
        return address(new UnsafeTestProxy(impl));
    }

    function _zkType(string memory profile) private pure returns (bytes32) {
        return keccak256(bytes(string.concat(PREFIX, profile)));
    }

    /// An unregistered zkType resolves to zero - which is what makes `_getPassportVerifier` revert,
    /// and is the state EVERY profile is in today.
    function test_unregisteredZkTypeResolvesToZero() public view {
        assertEq(
            registration.passportVerifiers(_zkType(PROFILE)),
            address(0),
            "an unregistered zkType must resolve to zero - this is why registerViaNoir reverts today"
        );
    }

    /// The owner-gated path binds a REAL deployed verifier, and binds only its own key.
    function test_ownerCanBindARealVerifier() public {
        address verifier = address(new NoirRegisterIdentity_1_160_3_3_576_200_NA());
        bytes32 zkType = _zkType(PROFILE);

        registration.updateDependency(
            Registration2.MethodId.AddPassportVerifier, abi.encode(zkType, verifier)
        );

        assertEq(registration.passportVerifiers(zkType), verifier, "zkType must bind its verifier");
        assertEq(
            registration.passportVerifiers(_zkType("2_256_3_4_336_248_NA")),
            address(0),
            "registering one profile must not bind any other"
        );
    }

    /// Registration is owner-gated. Anyone else registering their own verifier under a real
    /// profile's key would redirect that profile's proofs to a contract of their choosing.
    function test_nonOwnerCannotBindAVerifier() public {
        address verifier = address(new NoirRegisterIdentity_1_160_3_3_576_200_NA());

        vm.prank(address(0xD1A5));
        vm.expectRevert("Registration: not an owner");
        registration.updateDependency(
            Registration2.MethodId.AddPassportVerifier, abi.encode(_zkType(PROFILE), verifier)
        );
    }

    /// EVERY zkType in the manifest must equal Solidity's own keccak of its label.
    ///
    /// The manifest's values are produced off-chain and the deployment registers them on-chain, so
    /// this is the only place the two derivations meet. A mismatch would not fail loudly at deploy
    /// time - it would register verifiers under keys nothing ever looks up.
    function test_manifestZkTypesMatchSolidityKeccak() public view {
        string memory json = vm.readFile(MANIFEST);
        string[] memory names = vm.parseJsonKeys(json, ".profiles");

        // A FLOOR, NOT `> 0`. If `parseJsonKeys` silently returned one key - a path typo, a schema
        // change - the loop would assert one profile and pass, reporting green while checking almost
        // nothing. The floor sits well under the current 88 so adding or retiring a profile does not
        // fail this for the wrong reason; it exists only to catch the manifest not being read.
        assertGt(names.length, 80, "manifest parsed too few profiles - it is probably not being read");

        for (uint256 i = 0; i < names.length; ++i) {
            bytes32 recorded = vm.parseJsonBytes32(
                json, string.concat(".profiles.", _quote(names[i]), ".zk_type")
            );

            assertEq(
                recorded,
                _zkType(names[i]),
                string.concat("zk_type does not match keccak(label) for ", names[i])
            );
        }
    }

    /// Every zkType is distinct: a collision would let one profile shadow another's verifier, and
    /// the shadowed one would then verify proofs against the wrong circuit.
    function test_manifestZkTypesAreDistinct() public view {
        string memory json = vm.readFile(MANIFEST);
        string[] memory names = vm.parseJsonKeys(json, ".profiles");

        bytes32[] memory seen = new bytes32[](names.length);

        for (uint256 i = 0; i < names.length; ++i) {
            bytes32 zkType = _zkType(names[i]);

            for (uint256 j = 0; j < i; ++j) {
                assertTrue(seen[j] != zkType, string.concat("zk_type collision at ", names[i]));
            }
            seen[i] = zkType;
        }
    }

    /// `parseJson`'s path syntax needs the key quoted, or a profile name would be read as a series
    /// of path segments at every underscore.
    function _quote(string memory key) private pure returns (string memory) {
        return string.concat('["', key, '"]');
    }
}
