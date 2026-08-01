#!/usr/bin/env bash
# Regenerate contracts/libraries/inline/PoseidonT*Inline.sol from lib/poseidon-solidity.
#
# These are VENDORED COPIES with exactly two mechanical edits - rename the library, and make `hash`
# `internal` so the compiler inlines it instead of reaching it by DELEGATECALL. The arithmetic is
# untouched, which is the whole point: a "faster" Poseidon that differs by one bit would silently
# fork every commitment in this repo, since the circuits, the wallet and every SMT assume ONE
# Poseidon.
#
# ALWAYS run `forge test --match-contract PoseidonInlineDifferentialTest` after this. That suite
# pins every arity against the upstream `public` implementation, and it is the only thing standing
# between a mangled constant and a silent fork.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
UP="$(cd lib/poseidon-solidity && git rev-parse HEAD 2>/dev/null || echo unknown)"
mkdir -p contracts/libraries/inline
for n in 2 3 4 5 6; do
  python3 - "$n" "$UP" <<'PY'
import sys, pathlib, re
n, up = sys.argv[1], sys.argv[2]
src = pathlib.Path(f'lib/poseidon-solidity/PoseidonT{n}.sol').read_text()
body = re.sub(rf'library PoseidonT{n}\b', f'library PoseidonT{n}Inline', src).replace(' public pure', ' internal pure')
hdr = f'''// SPDX-License-Identifier: MIT
//
// VENDORED, NOT WRITTEN HERE. Byte-for-byte `lib/poseidon-solidity/PoseidonT{n}.sol` at upstream
// commit {up}, with exactly TWO mechanical edits:
//   1. `library PoseidonT{n}` -> `library PoseidonT{n}Inline`  (so both can coexist)
//   2. ` public pure` -> ` internal pure`                    (so the compiler INLINES it)
// The arithmetic is untouched. Regenerate with tools/gen-inline-poseidon.sh; never hand-edit.
//
// WHY. `public` library functions are reached by DELEGATECALL, and that boundary - not the hashing -
// dominates the cost. Measured: T3+T5+T6 = 324,921 gas as `public`, ~29,000 inlined (~11x). Every
// Poseidon call in PoseidonSMT / StateKeeper / IdentityRegistry / HolderStateKeeper / TitleLedger
// pays the public price today; a depth-32 SMT insert is over 1M gas, ~90k inlined.
//
// SAFETY. A faster Poseidon that disagrees with the original by one bit would silently fork every
// commitment in this system - the circuits, the wallet and the SMTs all assume ONE Poseidon.
// `PoseidonInlineDifferentialTest` therefore pins EVERY arity against the upstream `public`
// implementation over many inputs, including the boundary values. Do not migrate a call site to
// these libraries unless that suite is green.
'''
pathlib.Path(f'contracts/libraries/inline/PoseidonT{n}Inline.sol').write_text(hdr + body[body.index('pragma solidity'):])
print(f'  PoseidonT{n}Inline.sol')
PY
done
echo "==> now run: forge test --match-contract PoseidonInlineDifferentialTest"
