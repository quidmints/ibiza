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

import {AccessControlUpgradeable} from '@oz-upgradeable/access/AccessControlUpgradeable.sol';
import {UUPSUpgradeable} from '@oz-upgradeable/proxy/utils/UUPSUpgradeable.sol';
// OZ 5.6.1 dropped ReentrancyGuardUpgradeable: the transient-storage (EIP-1153) variant carries no
// persistent state, so there's no upgradeable-vs-plain distinction left to make - use the plain one.
import {ReentrancyGuardTransient} from '@oz/utils/ReentrancyGuardTransient.sol';
import {SafeERC20} from '@oz/token/ERC20/utils/SafeERC20.sol';

import {IERC20} from '@oz/interfaces/IERC20.sol';

import {Constants} from './lib/Constants.sol';
import {ProofLib} from './lib/ProofLib.sol';

import {IEntrypoint} from 'interfaces/IEntrypoint.sol';
import {IPrivacyPool} from 'interfaces/IPrivacyPool.sol';
import {IEvidenceRegistry} from '@rarimo/evidence-registry/interfaces/IEvidenceRegistry.sol';
import {InternalLeanIMT, LeanIMTData} from 'lean-imt/InternalLeanIMT.sol';
import {EIP712Upgradeable} from '@oz-upgradeable/utils/cryptography/EIP712Upgradeable.sol';
import {ECDSA} from '@oz/utils/cryptography/ECDSA.sol';

/**
 * @title Entrypoint
 * @notice Serves as the main entrypoint for a series of ASP-operated Privacy Pools
 */
contract Entrypoint is
  AccessControlUpgradeable,
  UUPSUpgradeable,
  EIP712Upgradeable,
  ReentrancyGuardTransient,
  IEntrypoint
{
  using SafeERC20 for IERC20;
  using ProofLib for ProofLib.WithdrawProof;
  using InternalLeanIMT for LeanIMTData;

  /// @dev 0xb19546dff01e856fb3f010c267a7b1c60363cf8a4664e21cc89c26224620214e
  bytes32 internal constant _OWNER_ROLE = keccak256('OWNER_ROLE');
  /// @dev 0xfc84ade01695dae2ade01aa4226dc40bdceaf9d5dbd3bf8630b1dd5af195bbc5
  bytes32 internal constant _ASP_POSTMAN = keccak256('ASP_POSTMAN');

  /// @notice EIP-712 typehash for an off-chain admission authorization (see
  ///         `admitIdentityWithAuthorization`).
  bytes32 internal constant _ADMIT_TYPEHASH =
    keccak256('AdmitIdentity(uint256 holderRoot,uint256 deadline)');

  /// @inheritdoc IEntrypoint
  mapping(uint256 _scope => IPrivacyPool _pool) public scopeToPool;

  /// @inheritdoc IEntrypoint
  mapping(IERC20 _asset => AssetConfig _config) public assetConfig;

  /*
   * THE ASP TREE IS MAINTAINED HERE, ON-CHAIN, AND IS APPEND-ONLY BY CONSTRUCTION.
   *
   * Upstream (and this fork until 2026-07-26) stored an array of postman-pushed roots computed
   * entirely off-chain. Nothing forced root N+1's leaf set to be a superset of root N's, so the
   * postman could drop any member simply by publishing a tree without them - and because a
   * withdrawal had to match the single latest active root, that removal took effect within the
   * activation delay and killed the member's private exit permanently (their only fallback,
   * `ragequit`, pays out to the original depositor and destroys the unlinkability the deposit
   * bought). See TODO.md sec. 2.13 for the full analysis of that lever.
   *
   * Maintaining the tree here instead removes the capability rather than bounding it: the contract
   * computes every root itself from the insertion sequence, so there is no root a postman can
   * author. YOU CANNOT BE REMOVED FROM AN INSERT-ONLY TREE. The postman role survives but is
   * reduced to admit-only, which is strictly less authority than upstream PP granted it.
   *
   * Removal has NOT been abolished - it is relocated to a separate, predicate-bound revocation
   * channel (TODO.md sec. 2.14) so that provable dissociation is preserved. Deleting removal
   * outright would have nullified the ASP's entire purpose, since taint is normally discovered
   * only after a deposit has already been made.
   *
   * Cost, measured not estimated (test/pool/AspTreeGasProbe.t.sol): admission is one O(log n)
   * insert - ~69k gas at size 1, ~328k at 1,024, ~397k at 4,096, growing ~23k per depth level. For
   * scale, a single withdrawal `verify()` is ~1.78M gas, and because this fork keys ASP membership
   * by IDENTITY rather than by deposit label, one admission covers every future deposit and
   * withdrawal that identity makes.
   */
  LeanIMTData internal _aspTree;

  /// @notice Every ASP root this contract has ever computed, mapped to the timestamp it was
  ///         created at. Historical roots stay valid forever: the tree is append-only, so an old
  ///         root's membership set is a strict subset of the current one and honouring it grants
  ///         nothing the current root would not. This is the same reasoning that makes `State`'s
  ///         64-root window safe for the commitment tree. `0` means "never seen".
  mapping(uint256 _root => uint256 _createdAt) public aspRootCreatedAt;

  /// @notice Guards against inserting the same identity twice, which would waste gas and put a
  ///         duplicate leaf in the tree for no benefit.
  mapping(uint256 _holderRoot => bool _admitted) public aspAdmitted;

  /// @inheritdoc IEntrypoint
  mapping(uint256 _precommitment => bool _used) public usedPrecommitments;

  /// @inheritdoc IEntrypoint
  IEvidenceRegistry public EVIDENCE_REGISTRY;

  /*///////////////////////////////////////////////////////////////
                          INITIALIZATION
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Disables initializers. Using UUPS upgradeability pattern
   */
  constructor() {
    _disableInitializers();
  }

  /// @inheritdoc IEntrypoint
  function initialize(address _owner, address _postman, address _evidenceRegistry) external initializer {
    // Sanity check initial addresses
    if (_owner == address(0)) revert ZeroAddress();
    if (_postman == address(0)) revert ZeroAddress();
    if (_evidenceRegistry == address(0)) revert ZeroAddress();

    // ERC-7812 evidence registry: shared, tamper-evident anchor for every ASP root (the same
    // registry rarime anchors identity state roots in — one truth registry for both).
    EVIDENCE_REGISTRY = IEvidenceRegistry(_evidenceRegistry);

    // Initialize upgradeable contracts
    // UUPSUpgradeable has no storage/init step in OZ 5.6.1 (it's a thin, stateless wrapper);
    // ReentrancyGuardTransient is likewise stateless (EIP-1153 transient storage).
    __AccessControl_init();
    // Domain separator for `admitIdentityWithAuthorization`'s off-chain postman signatures. Binds
    // each authorization to THIS contract and chain, so a signature cannot be replayed onto another
    // deployment of the same code.
    __EIP712_init('QuidPrivacyPoolEntrypoint', '1');

    // Initialize roles
    _setRoleAdmin(DEFAULT_ADMIN_ROLE, _OWNER_ROLE);
    _setRoleAdmin(_OWNER_ROLE, _OWNER_ROLE); // Owner can manage owner role
    _setRoleAdmin(_ASP_POSTMAN, _OWNER_ROLE); // Owner can manage postman role

    _grantRole(_OWNER_ROLE, _owner);
    _grantRole(_ASP_POSTMAN, _postman);
  }

  /*///////////////////////////////////////////////////////////////
                      ASSOCIATION SET METHODS
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IEntrypoint
  /// @dev DELIBERATELY THE ONLY WAY THE ASP ROOT CAN EVER CHANGE. `updateRoot(root, ipfsCID)` -
  ///      which let the postman publish an arbitrary off-chain-computed root - was REMOVED, not
  ///      deprecated. Leaving it in place would have kept the removal channel wide open and made
  ///      the append-only property here worthless, since a postman could simply publish a tree
  ///      omitting whoever they liked and bypass this function entirely.
  function admitIdentity(uint256 _holderRoot) external onlyRole(_ASP_POSTMAN) returns (uint256 _root) {
    _root = _admitIdentity(_holderRoot);
  }

  /**
   * @notice Admit an identity using an OFF-CHAIN postman signature, submitted by anyone.
   *
   * Folds admission into a transaction the user is already sending (their first deposit), instead
   * of requiring a separate postman-sent transaction. Same authority - only the postman can
   * authorize an admission - but the postman no longer needs to run a transaction-sending service
   * or hold ETH, and the user saves a whole transaction's base cost and latency.
   *
   * Why this does NOT widen the postman's power: `_admitIdentity` can only ever INSERT. There is no
   * removal path to authorize, so a leaked or misused signature can at worst admit an identity that
   * the postman already decided to admit. See TODO.md sec. 2.13 for why insert-only is the point.
   *
   * @dev Replay protection is `aspAdmitted[_holderRoot]`, which already reverts a second admission
   *      of the same identity - so no separate nonce is needed. `_deadline` bounds how long a
   *      signature stays usable if the postman changes its mind before it is redeemed.
   * @param _holderRoot The identity's holder root
   * @param _deadline Unix timestamp after which the authorization is void
   * @param _signature Postman's EIP-712 signature over (holderRoot, deadline)
   * @return _root The ASP root after insertion
   */
  function admitIdentityWithAuthorization(
    uint256 _holderRoot,
    uint256 _deadline,
    bytes calldata _signature
  ) external returns (uint256 _root) {
    if (block.timestamp > _deadline) revert AuthorizationExpired();

    bytes32 _digest = _hashTypedDataV4(keccak256(abi.encode(_ADMIT_TYPEHASH, _holderRoot, _deadline)));
    address _signer = ECDSA.recover(_digest, _signature);
    if (!hasRole(_ASP_POSTMAN, _signer)) revert InvalidAuthorization();

    _root = _admitIdentity(_holderRoot);
  }

  /// @dev Shared admission logic. The ONLY writer of the ASP tree.
  function _admitIdentity(uint256 _holderRoot) internal returns (uint256 _root) {
    // LeanIMT reserves 0 as "empty sibling"; a zero leaf would corrupt inclusion proofs.
    if (_holderRoot == 0) revert EmptyRoot();
    if (_holderRoot >= Constants.SNARK_SCALAR_FIELD) revert LeafOutOfField();
    if (aspAdmitted[_holderRoot]) revert AlreadyAdmitted();

    aspAdmitted[_holderRoot] = true;
    _root = _aspTree._insert(_holderRoot);

    uint256 _index = _aspTree.size - 1;
    aspRootCreatedAt[_root] = block.timestamp;

    // Anchor the root in the ERC-7812 evidence registry: tamper-evident, independently
    // timestamped, auditable in the same registry as identity roots. Unchanged from the previous
    // design - the anchoring was never the weak part.
    bytes32 _statementKey = _aspStatementKey(_index);
    EVIDENCE_REGISTRY.addStatement(_statementKey, bytes32(_root));

    emit IdentityAdmitted(_holderRoot, _root, _index);
    emit RootAnchored(_root, _index, _statementKey);
  }

  /*///////////////////////////////////////////////////////////////
                          DEPOSIT METHODS
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IEntrypoint
  function deposit(uint256 _precommitment) external payable nonReentrant returns (uint256 _commitment) {
    // Handle deposit as native asset
    _commitment = _handleDeposit(IERC20(Constants.NATIVE_ASSET), msg.value, _precommitment);
  }

  /// @inheritdoc IEntrypoint
  function deposit(
    IERC20 _asset,
    uint256 _value,
    uint256 _precommitment
  ) external nonReentrant returns (uint256 _commitment) {
    // Pull funds from user
    _asset.safeTransferFrom(msg.sender, address(this), _value);
    // Handle deposit as ERC20
    _commitment = _handleDeposit(_asset, _value, _precommitment);
  }

  /*///////////////////////////////////////////////////////////////
                               RELAY
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IEntrypoint
  function relay(
    IPrivacyPool.Withdrawal calldata _withdrawal,
    ProofLib.WithdrawProof calldata _proof,
    uint256 _scope
  ) external nonReentrant {
    // Check withdrawn amount is non-zero
    if (_proof.withdrawnValue() == 0) revert InvalidWithdrawalAmount();
    // Check allowed processooor is this Entrypoint
    if (_withdrawal.processooor != address(this)) revert InvalidProcessooor();

    // Fetch pool by scope
    IPrivacyPool _pool = scopeToPool[_scope];
    if (address(_pool) == address(0)) revert PoolNotFound();

    // Store pool asset
    IERC20 _asset = IERC20(_pool.ASSET());
    uint256 _balanceBefore = _assetBalance(_asset);

    // Process withdrawal
    _pool.withdraw(_withdrawal, _proof);

    // Decode relay data
    RelayData memory _data = abi.decode(_withdrawal.data, (RelayData));

    if (_data.relayFeeBPS > assetConfig[_asset].maxRelayFeeBPS) revert RelayFeeGreaterThanMax();

    uint256 _withdrawnAmount = _proof.withdrawnValue();

    // Deduct fees
    uint256 _amountAfterFees = _deductFee(_withdrawnAmount, _data.relayFeeBPS);

    uint256 _feeAmount = _withdrawnAmount - _amountAfterFees;

    // Transfer withdrawn funds to recipient
    _transfer(_asset, _data.recipient, _amountAfterFees);
    // Transfer fees to fee recipient
    _transfer(_asset, _data.feeRecipient, _feeAmount);

    // Check pool balance has not been reduced
    uint256 _balanceAfter = _assetBalance(_asset);
    if (_balanceBefore > _balanceAfter) revert InvalidPoolState();

    emit WithdrawalRelayed(msg.sender, _data.recipient, _asset, _withdrawnAmount, _feeAmount);
  }

  /*///////////////////////////////////////////////////////////////
                          POOL MANAGEMENT 
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IEntrypoint
  function registerPool(
    IERC20 _asset,
    IPrivacyPool _pool,
    uint256 _minimumDepositAmount,
    uint256 _vettingFeeBPS,
    uint256 _maxRelayFeeBPS
  ) external onlyRole(_OWNER_ROLE) {
    // Sanity check addresses
    if (address(_asset) == address(0)) revert ZeroAddress();
    if (address(_pool) == address(0)) revert ZeroAddress();

    // Fetch pool configuration
    AssetConfig storage _config = assetConfig[_asset];
    if (address(_config.pool) != address(0)) revert AssetPoolAlreadyRegistered();

    if (_pool.dead()) revert PoolIsDead();
    if (address(_pool.ENTRYPOINT()) != address(this)) revert InvalidEntrypointForPool();

    // Fetch pool scope and validate asset
    uint256 _scope = _pool.SCOPE();
    if (address(scopeToPool[_scope]) != address(0)) revert ScopePoolAlreadyRegistered();
    if (_asset != IERC20(_pool.ASSET())) revert AssetMismatch();

    // Store pool configuration
    scopeToPool[_scope] = _pool;
    _config.pool = _pool;

    // Update pool configuration with validation
    _setPoolConfiguration(_config, _minimumDepositAmount, _vettingFeeBPS, _maxRelayFeeBPS);

    // If asset is an ERC20, approve pool to spend
    if (address(_asset) != Constants.NATIVE_ASSET) _asset.forceApprove(address(_pool), type(uint256).max);

    emit PoolRegistered(_pool, _asset, _scope);
  }

  /// @inheritdoc IEntrypoint
  function removePool(IERC20 _asset) external onlyRole(_OWNER_ROLE) {
    // Fetch pool by asset
    IPrivacyPool _pool = assetConfig[_asset].pool;
    if (address(_pool) == address(0)) revert PoolNotFound();

    // Fetch pool scope
    uint256 _scope = _pool.SCOPE();

    // If asset is an ERC20, revoke pool allowance
    if (address(_asset) != Constants.NATIVE_ASSET) _asset.forceApprove(address(_pool), 0);

    // Remove pool configuration
    delete scopeToPool[_scope];
    delete assetConfig[_asset];

    emit PoolRemoved(_pool, _asset, _scope);
  }

  /// @inheritdoc IEntrypoint
  function updatePoolConfiguration(
    IERC20 _asset,
    uint256 _minimumDepositAmount,
    uint256 _vettingFeeBPS,
    uint256 _maxRelayFeeBPS
  ) external onlyRole(_OWNER_ROLE) {
    // Fetch pool configuration
    AssetConfig storage _config = assetConfig[_asset];
    if (address(_config.pool) == address(0)) revert PoolNotFound();

    // Update pool configuration with validation
    _setPoolConfiguration(_config, _minimumDepositAmount, _vettingFeeBPS, _maxRelayFeeBPS);

    emit PoolConfigurationUpdated(_config.pool, _asset, _minimumDepositAmount, _vettingFeeBPS, _maxRelayFeeBPS);
  }

  /// @inheritdoc IEntrypoint
  function windDownPool(IPrivacyPool _pool) external onlyRole(_OWNER_ROLE) {
    // Call `windDown` on pool
    _pool.windDown();

    emit PoolWindDown(_pool);
  }

  /// @inheritdoc IEntrypoint
  function withdrawFees(IERC20 _asset, address _recipient) external nonReentrant onlyRole(_OWNER_ROLE) {
    // Fetch current asset balance
    uint256 _balance = _assetBalance(_asset);

    // Transfer funds
    _transfer(_asset, _recipient, _balance);

    emit FeesWithdrawn(_asset, _recipient, _balance);
  }

  /*///////////////////////////////////////////////////////////////
                           VIEW METHODS 
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IEntrypoint
  function latestRoot() external view returns (uint256 _root) {
    if (_aspTree.size == 0) revert NoRootsAvailable();
    _root = _aspTree._root();
  }

  /// @inheritdoc IEntrypoint
  /// @dev Replaces the old `latestActiveRoot()` equality check. Any root this contract has ever
  ///      computed is accepted, forever - safe ONLY because the tree is append-only, which is now
  ///      enforced by construction rather than assumed of an off-chain operator. An old root's
  ///      membership set is a strict subset of the current one, so accepting it grants nothing the
  ///      current root would not.
  ///
  ///      There is deliberately no activation delay here. Upstream's existed so watchers could
  ///      spot "a malicious/equivocating postman" pushing a fabricated root - a threat that no
  ///      longer exists, because no postman can author a root at all. Keeping the delay would only
  ///      have forced a newly admitted identity to wait an hour before their own inclusion proof
  ///      worked, buying nothing: there was never any mechanism to act on the warning it gave.
  function isKnownAspRoot(uint256 _root) external view returns (bool) {
    if (_root == 0) return false;
    return aspRootCreatedAt[_root] != 0;
  }

  /// @notice Current size (leaf count) and depth of the ASP tree, for wallets building inclusion
  ///         proofs against it.
  function aspTreeSize() external view returns (uint256) {
    return _aspTree.size;
  }

  /// @notice Current depth of the ASP tree - the `asp_tree_depth` public signal a withdrawal proof
  ///         must carry.
  function aspTreeDepth() external view returns (uint256) {
    return _aspTree.depth;
  }

  /// @notice Deterministic, field-reduced ERC-7812 statement key for the ASP root at `_index`.
  function _aspStatementKey(uint256 _index) internal view returns (bytes32) {
    return
      bytes32(uint256(keccak256(abi.encodePacked('PP_ASP_ROOT', address(this), _index))) % Constants.SNARK_SCALAR_FIELD);
  }

  /*///////////////////////////////////////////////////////////////
                            RECEIVE
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Needed to receive native asset from a pool when withdrawing
   * @dev Only accepts native asset from the local native asset pool
   */
  receive() external payable {
    address _nativePool = address(assetConfig[IERC20(Constants.NATIVE_ASSET)].pool);
    if (msg.sender != _nativePool) revert NativeAssetNotAccepted();
  }

  /*///////////////////////////////////////////////////////////////
                        INTERNAL METHODS 
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc UUPSUpgradeable
  function _authorizeUpgrade(address) internal override onlyRole(_OWNER_ROLE) {}

  /**
   * @notice Handle deposit logic for both native asset and ERC20 deposits
   * @param _asset The asset being deposited
   * @param _value The amount being deposited
   * @param _precommitment The precommitment for the deposit
   * @return _commitment The deposit commitment hash
   */
  function _handleDeposit(IERC20 _asset, uint256 _value, uint256 _precommitment) internal returns (uint256 _commitment) {
    // Fetch pool by asset
    AssetConfig memory _config = assetConfig[_asset];
    IPrivacyPool _pool = _config.pool;
    if (address(_pool) == address(0)) revert PoolNotFound();

    // Check if the `_precommitment` has already been used
    if (usedPrecommitments[_precommitment]) revert PrecommitmentAlreadyUsed();
    // Mark it as used
    usedPrecommitments[_precommitment] = true;

    // Check minimum deposit amount
    if (_value < _config.minimumDepositAmount) revert MinimumDepositAmount();

    // Deduct vetting fees
    uint256 _amountAfterFees = _deductFee(_value, _config.vettingFeeBPS);

    // Deposit commitment into pool (forwarding native asset if applicable)
    uint256 _nativeAssetValue = address(_asset) == Constants.NATIVE_ASSET ? _amountAfterFees : 0;
    _commitment = _pool.deposit{value: _nativeAssetValue}(msg.sender, _amountAfterFees, _precommitment);

    emit Deposited(msg.sender, _pool, _commitment, _amountAfterFees);
  }

  /**
   * @notice Transfer out an asset to a recipient
   * @param _asset The asset to send
   * @param _recipient The recipient address
   * @param _amount The amount to send
   */
  function _transfer(IERC20 _asset, address _recipient, uint256 _amount) internal {
    if (_recipient == address(0)) revert ZeroAddress();

    if (_asset == IERC20(Constants.NATIVE_ASSET)) {
      (bool _success,) = _recipient.call{value: _amount}('');
      if (!_success) revert NativeAssetTransferFailed();
    } else {
      _asset.safeTransfer(_recipient, _amount);
    }
  }

  /**
   * @notice Fetch asset balance for the Entrypoint
   * @param _asset The asset address
   * @return _balance The asset balance
   */
  function _assetBalance(IERC20 _asset) internal view returns (uint256 _balance) {
    if (_asset == IERC20(Constants.NATIVE_ASSET)) {
      _balance = address(this).balance;
    } else {
      _balance = _asset.balanceOf(address(this));
    }
  }

  /**
   * @notice Deduct fees from an amount
   * @param _amount The amount before fees
   * @param _feeBPS The fee in basis points
   * @return _afterFees The amount after fees are deducted
   */
  function _deductFee(uint256 _amount, uint256 _feeBPS) internal pure returns (uint256 _afterFees) {
    _afterFees = _amount - ((_amount * _feeBPS) / 10_000);
  }

  /**
   * @notice Sets pool configuration parameters with validation
   * @dev Validates and sets minimum deposit amount and vetting fee
   * @param _config The pool configuration to update
   * @param _minimumDepositAmount The new minimum deposit amount
   * @param _vettingFeeBPS The new vetting fee in basis points
   * @param _maxRelayFeeBPS The maximum relay fee in basis points
   */
  function _setPoolConfiguration(
    AssetConfig storage _config,
    uint256 _minimumDepositAmount,
    uint256 _vettingFeeBPS,
    uint256 _maxRelayFeeBPS
  ) internal {
    // Check fee is less than 100%
    if (_vettingFeeBPS >= 10_000 || _maxRelayFeeBPS >= 10_000) revert InvalidFeeBPS();

    _config.minimumDepositAmount = _minimumDepositAmount;
    _config.vettingFeeBPS = _vettingFeeBPS;
    _config.maxRelayFeeBPS = _maxRelayFeeBPS;
  }
}
