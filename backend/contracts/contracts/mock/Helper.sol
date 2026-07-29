// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

// solhint-disable

/*
 * DELIBERATELY NOTHING BUT IMPORTS. This file declares no contract, and every symbol below is
 * "unused" in the only sense a linter can see.
 *
 * Its job is to pull these three into the compilation unit so Forge EMITS THEIR ARTIFACTS. Tests
 * and deployment scripts deploy `EvidenceDB`, `EvidenceRegistry` and `ERC1967Proxy` by name, and
 * nothing in `contracts/` imports them otherwise - drop these lines and the artifacts vanish, with
 * the failure appearing far away as "artifact not found" rather than here.
 *
 * Recorded because this looks exactly like dead code to anyone tidying imports, which is precisely
 * how it would get deleted (TODO.md sec. 2.18t).
 */

import {EvidenceDB} from "@rarimo/evidence-registry/EvidenceDB.sol";
import {EvidenceRegistry} from "@rarimo/evidence-registry/EvidenceRegistry.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
