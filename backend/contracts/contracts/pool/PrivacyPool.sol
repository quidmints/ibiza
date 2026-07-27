// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/*

Made with ♥ for 0xBow by

░██╗░░░░░░░██╗░█████╗░███╗░░██╗██████╗░███████╗██████╗░██╗░░░░░░█████╗░███╗░░██╗██████╗░
░██║░░██╗░░██║██╔══██╗████╗░██║██╔══██╗██╔════╝██╔══██╗██║░░░░░██╔══██╗████╗░██║██╔══██╗
░╚██╗████╗██╔╝██║░░██║██╔██╗██║██║░░██║█████╗░░██████╔╝██║░░░░░███████║██╔██╗██║██║░░██║
░░████╔═████║░██║░░██║██║╚████║██║░░██║██╔══╝░░██╔══██╗██║░░░░░██╔══██║██║╚████║██║░░██║
░░╚██╔╝░╚██╔╝░╚█████╔╝██║░╚███║██████╔╝███████╗██║░░██║███████╗██║░░██║██║░╚███║██████╔╝
░░░╚═╝░░░╚═╝░░░╚════╝░╚═╝░░╚══╝╚═════╝░╚══════╝╚═╝░░╚═╝╚══════╝╚═╝░░╚═╝╚═╝░░╚══╝╚═════╝░

https://defi.sucks/

*/

import {PoseidonT4} from 'poseidon/PoseidonT4.sol';

import {Constants} from './lib/Constants.sol';
import {ProofLib} from './lib/ProofLib.sol';
import {IIdentityAspRegistry} from '../interfaces/registry/IIdentityAspRegistry.sol';

import {IPrivacyPool} from 'interfaces/IPrivacyPool.sol';

import {State} from './State.sol';

/**
 * @title PrivacyPool
 * @notice Allows publicly depositing and privately withdrawing funds.
 * @dev Withdrawals require a valid proof of being approved by an ASP.
 * @dev Deposits can be irreversibly suspended by the Entrypoint, while withdrawals can't.
 */
abstract contract PrivacyPool is State, IPrivacyPool {
  using ProofLib for ProofLib.WithdrawProof;
  using ProofLib for ProofLib.RagequitProof;

  /**
   * @notice Does a series of sanity checks on the proof public signals
   * @param _withdrawal The withdrawal data structure containing withdrawal details
   * @param _proof The withdrawal proof data structure containing proof details
   */
  modifier validWithdrawal(Withdrawal memory _withdrawal, ProofLib.WithdrawProof memory _proof) {
    // Check caller is the allowed processooor
    if (msg.sender != _withdrawal.processooor) revert InvalidProcessooor();

    // Check the context matches to ensure its integrity
    if (_proof.context() != uint256(keccak256(abi.encode(_withdrawal, SCOPE))) % Constants.SNARK_SCALAR_FIELD) {
      revert ContextMismatch();
    }

    // Check the tree depth signals are less than the max tree depth
    if (_proof.stateTreeDepth() > MAX_TREE_DEPTH || _proof.ASPTreeDepth() > MAX_TREE_DEPTH) revert InvalidTreeDepth();

    // Check the state root is known
    if (!_isKnownRoot(_proof.stateRoot())) revert UnknownStateRoot();

    // Check the ASP root is one the Entrypoint has ever computed.
    //
    // This deliberately accepts ANY historical root, where upstream required equality with the
    // single latest active one. That equality check was the mechanism by which an ASP operator
    // could retroactively kill an existing member's private exit: publish a root omitting them and,
    // once it activated, their withdrawal proof matched nothing - forcing `ragequit`, which pays
    // out to the original depositor and destroys the unlinkability the deposit bought. See
    // TODO.md sec. 2.13.
    //
    // Accepting historical roots is safe ONLY because `Entrypoint` now maintains the ASP tree
    // on-chain and append-only, so a historical root's membership set is a strict subset of the
    // current one. It would NOT have been safe under the old design, where a root was an arbitrary
    // operator-supplied snapshot: honouring old roots there would have re-admitted everyone ever
    // removed and made removal a global no-op. The same reasoning already justifies `_isKnownRoot`
    // accepting 64 historical state roots on the line above.
    // Asked of the REGISTRY, not the Entrypoint. Routing this through the Entrypoint - even as a
    // pass-through - would preserve the exact hole this split closes: the Entrypoint is
    // upgradeable by OWNER_ROLE, so an upgraded one could simply lie about which roots are
    // genuine. See TODO.md sec. 2.5a.
    if (!ASP_REGISTRY.isKnownAspRoot(_proof.ASPRoot())) revert IncorrectASPRoot();
    _;
  }

  /**
   * @notice Number of buckets `_precommitmentHash` is folded into for the indexed `Deposited`
   *         topic. Purely a DISCOVERY aid - it lets a recovering wallet fetch only the logs that
   *         could contain its own notes instead of every deposit ever made.
   * @dev This is a PRIVACY/SPEED DIAL, and the trade must be understood before changing it.
   *      Indexing `_precommitmentHash` itself would be the fastest option and the wrong one: a
   *      wallet querying its exact precommitments tells its RPC provider precisely which notes are
   *      its own, reintroducing off-chain the linkage the pool removes on-chain. Bucketing means a
   *      query returns roughly `totalDeposits / PRECOMMITMENT_BUCKETS` notes belonging to many
   *      unrelated users, so the provider learns only a coarse bucket.
   *      MORE buckets  = faster sync, SMALLER crowd to hide in.
   *      FEWER buckets = slower sync, LARGER crowd.
   *      256 keeps sync ~256x cheaper than a full scan while each query still covers a broad slice.
   *      Nothing new is revealed ON-CHAIN either way: the bucket is derived from
   *      `_precommitmentHash`, which the same log already publishes in the clear.
   */
  uint256 public constant PRECOMMITMENT_BUCKETS = 256;

  /**
   * @notice Initializes the contract state addresses
   * @param _entrypoint Address of the Entrypoint that operates this pool
   * @param _withdrawalVerifier Address of the Groth16 verifier for withdrawal proofs
   * @param _ragequitVerifier Address of the Groth16 verifier for ragequit proofs
   * @param _asset Address of the pool asset
   */
  /// @notice The append-only identity ASP tree. NON-UPGRADEABLE and referenced directly, so no
  ///         upgradeable contract sits between this pool and the membership set it trusts.
  IIdentityAspRegistry public immutable ASP_REGISTRY;

  constructor(
    address _entrypoint,
    address _withdrawalVerifier,
    address _ragequitVerifier,
    address _asset,
    address _aspRegistry
  ) State(_asset, _entrypoint, _withdrawalVerifier, _ragequitVerifier) {
    if (_aspRegistry == address(0)) revert ZeroAspRegistry();
    ASP_REGISTRY = IIdentityAspRegistry(_aspRegistry);
  }

  /*///////////////////////////////////////////////////////////////
                             USER METHODS 
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IPrivacyPool
  function deposit(
    address _depositor,
    uint256 _value,
    uint256 _precommitmentHash
  ) external payable onlyEntrypoint returns (uint256 _commitment) {
    // Check deposits are enabled
    if (dead) revert PoolIsDead();

    if (_value >= type(uint128).max) revert InvalidDepositValue();
    // Every other input to the commitment Poseidon hash below is explicitly field-reduced
    // (`_label` via `% Constants.SNARK_SCALAR_FIELD`); `_precommitmentHash` is depositor-supplied
    // and was the one input with no such check. An out-of-field value doesn't corrupt anyone
    // else's funds, but it produces a commitment a Groth16/Noir withdrawal circuit (which computes
    // Poseidon over an implicitly-reduced field element) can never reconstruct - i.e. a
    // self-locking deposit from a buggy or malicious client SDK. Reject it up front instead.
    if (_precommitmentHash >= Constants.SNARK_SCALAR_FIELD) revert InvalidPrecommitmentHash();

    // Compute label
    uint256 _label = uint256(keccak256(abi.encodePacked(SCOPE, ++nonce))) % Constants.SNARK_SCALAR_FIELD;
    // Store depositor
    depositors[_label] = _depositor;

    // Compute commitment hash
    _commitment = PoseidonT4.hash([_value, _label, _precommitmentHash]);

    // Insert commitment in state (revert if already present)
    _insert(_commitment);

    // Pull funds from caller
    _pull(msg.sender, _value);

    emit Deposited(
      _depositor, _precommitmentHash % PRECOMMITMENT_BUCKETS, _commitment, _label, _value, _precommitmentHash
    );
  }

  /// @inheritdoc IPrivacyPool
  function withdraw(
    Withdrawal memory _withdrawal,
    ProofLib.WithdrawProof memory _proof
  ) external validWithdrawal(_withdrawal, _proof) {
    // Verify proof with the Noir/Honk verifier (identity-based ASP withdrawal, see ProofLib.WithdrawProof)
    if (!WITHDRAWAL_VERIFIER.verify(_proof.proof, _proof.publicInputsBytes32())) revert InvalidProof();

    // Mark existing commitment nullifier as spent
    _spend(_proof.existingNullifierHash());

    // Insert new commitment in state
    _insert(_proof.newCommitmentHash());

    // Transfer out funds to procesooor
    _push(_withdrawal.processooor, _proof.withdrawnValue());

    emit Withdrawn(
      _withdrawal.processooor, _proof.withdrawnValue(), _proof.existingNullifierHash(), _proof.newCommitmentHash()
    );
  }

  /// @inheritdoc IPrivacyPool
  function ragequit(ProofLib.RagequitProof memory _proof) external {
    // Check if caller is original depositor
    uint256 _label = _proof.label();
    if (depositors[_label] != msg.sender) revert OnlyOriginalDepositor();

    // Verify proof with Groth16 verifier
    if (!RAGEQUIT_VERIFIER.verifyProof(_proof.pA, _proof.pB, _proof.pC, _proof.pubSignals)) revert InvalidProof();

    // Check commitment exists in state
    if (!_isInState(_proof.commitmentHash())) revert InvalidCommitment();

    // Mark existing commitment nullifier as spent
    _spend(_proof.nullifierHash());

    // Transfer out funds to ragequitter
    _push(msg.sender, _proof.value());

    emit Ragequit(msg.sender, _proof.commitmentHash(), _proof.label(), _proof.value());
  }

  /*///////////////////////////////////////////////////////////////
                             WIND DOWN
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IPrivacyPool
  function windDown() external onlyEntrypoint {
    // Check pool is still alive
    if (dead) revert PoolIsDead();

    // Die
    dead = true;

    emit PoolDied();
  }

  /*///////////////////////////////////////////////////////////////
                          ASSET OVERRIDES
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Handle receiving an asset
   * @dev To be implemented by an asset specific contract
   * @param _sender The address of the user sending funds
   * @param _value The amount of asset being received
   */
  function _pull(address _sender, uint256 _value) internal virtual;

  /**
   * @notice Handle sending an asset
   * @dev To be implemented by an asset specific contract
   * @param _recipient The address of the user receiving funds
   * @param _value The amount of asset being sent
   */
  function _push(address _recipient, uint256 _value) internal virtual;
}
