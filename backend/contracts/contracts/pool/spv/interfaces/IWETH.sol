// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {IERC20} from "@oz/interfaces/IERC20.sol";

/// @notice Canonical WETH9 surface (deposit/withdraw), extending plain ERC20 for the
/// transfer/approve calls AaveCreditLine also needs. Aave's `IPool` is ERC20-only - it has no
/// native-ETH entrypoint of its own (that's what the separate, less standardized WETHGateway
/// contracts are for) - so wrapping/unwrapping at this boundary is the standard, portable pattern.
interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}
