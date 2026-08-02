#!/usr/bin/env bash
# Regenerate the passport registration verifiers (NoirRegisterIdentity_*.sol) on OUR toolchain.
#
# WHY THIS EXISTS. The 76 committed `contracts/passport/verifiers2/noir/NoirRegisterIdentity_*.sol`
# arrived with the fork import and were built by rarimo on **noir 1.0.0-beta.1** (read from their own
# artifacts, not assumed). A verifier is generated from a circuit's VK, the VK follows the constraint
# system, and the constraint system follows the compiler - so those verifiers do not accept proofs
# produced by our patched beta.26. They must be rebuilt here, and nothing did that.
#
# WHY IT WAS THOUGHT IMPOSSIBLE, AND WHY IT IS NOT. Each profile is an instantiation of
# `noir_dl::not_passports_zk_circuits::register_identity` with FOURTEEN generic arguments, five of
# which (EC_LEN, SA_LEN, DG15_LEN, N, plus the exact DG1_LEN) are DER byte lengths of a real
# passport. The file names carry only some of them, and only as 64-byte buckets, so they cannot be
# inverted - which is why this looked like it needed 76 physical documents.
#
# IT NEEDS NONE. Every compiled Noir artifact embeds its own sources in `file_map` for debugging, so
# rarimo's published `registerIdentity_*.json` release assets each contain the exact `main.nr` they
# were built from - the full 14-tuple and the circuit's own `//name` comment, verbatim. The tuples in
# `passport-profiles.json` were read out of those artifacts. No document was used, and none is needed.
#
# THE MANIFEST IS THE INPUT, and it quarantines what it cannot vouch for: three published assets
# embed a DIFFERENT circuit than their file name claims (one is a byte-identical duplicate of another
# profile). Regenerating those from their artifacts would emit a verifier that rejects every proof
# for that profile, silently, so they are held back rather than guessed at.
#
# TOOLCHAIN: the same guard as codegen-verifiers.sh - nargo 1.0.0-beta.26+quid-icefix1 and bb 5.1.0,
# with `~/.bb` on PATH. Stock beta.26 ICEs on this dependency tree; that is what the patch is for.
#
#   ./codegen-passport-verifiers.sh              # every clean profile
#   ./codegen-passport-verifiers.sh 1_256_3_4    # only profiles whose name contains this
set -euo pipefail

CIRCUITS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${CIRCUITS_DIR}/passport-profiles.json"
DEST="${CIRCUITS_DIR}/../contracts/contracts/passport/verifiers2/noir"
WORK="${CIRCUITS_DIR}/.passport-build"
FILTER="${1:-}"

REQUIRED_NARGO="1.0.0-beta.26+quid-icefix1"
REQUIRED_BB="5.1.0"
actual_nargo="$(nargo --version 2>/dev/null | sed -n 's/^nargo version = //p' | head -1)"
actual_bb="$(bb --version 2>/dev/null | head -1)"
if [ "${actual_nargo}" != "${REQUIRED_NARGO}" ] || [ "${actual_bb}" != "${REQUIRED_BB}" ]; then
  echo "TOOLCHAIN MISMATCH - refusing to emit verifiers." >&2
  echo "  nargo required ${REQUIRED_NARGO}  found '${actual_nargo:-<not on PATH>}'" >&2
  echo "  bb    required ${REQUIRED_BB}     found '${actual_bb:-<not on PATH>}'" >&2
  echo "  (bb lives in ~/.bb, which is not on PATH by default)" >&2
  exit 1
fi

names=$(python3 -c "
import json,sys
m=json.load(open('${MANIFEST}'))
f='${FILTER}'
print('\n'.join(n for n in m['profiles'] if not f or f in n))")

[ -n "${names}" ] || { echo "no profiles matched '${FILTER}'" >&2; exit 1; }
echo "profiles to build: $(echo "${names}" | wc -l | tr -d ' ')"

mkdir -p "${WORK}/src"
cat > "${WORK}/Nargo.toml" <<'TOML'
[package]
name = "register_identity_profile"
type = "bin"
authors = [""]

[dependencies]
noir_dl = { path = "../noir_dl_lib" }
TOML

built=0
for name in ${names}; do
  echo "=== ${name} ==="

  # main.nr is written from the manifest tuple - the same shape rarimo's own generator emits, minus
  # its `test_main` module, which needs witness inputs we deliberately do not have.
  python3 - "${name}" "${MANIFEST}" > "${WORK}/src/main.nr" <<'PY'
import json,sys
name,man=sys.argv[1],sys.argv[2]
g=json.load(open(man))['profiles'][name]['generics']
order=["DG1_LEN","DG15_LEN","EC_LEN","SA_LEN","N","EC_FIELD_SIZE","DG_HASH_ALGO","HASH_ALGO",
       "SIG_TYPE","DG1_SHIFT","DG15_SHIFT","EC_SHIFT","AA_SIG_TYPE","AA_SHIFT"]
v={k:g[k] for k in order}
print(f"""//registerIdentity_{name}
use noir_dl::not_passports_zk_circuits::register_identity;

fn main(
\tdg1: [u8; {v['DG1_LEN']}],
\tdg15: [u8; {v['DG15_LEN']}],
\tec: [u8; {v['EC_LEN']}],
\tsa: [u8; {v['SA_LEN']}],
\tpk: [Field; {v['N']}],
\treduction_pk: [Field; {v['N']}],
\tsig: [Field; {v['N']}],
\tsk_identity: Field,
\ticao_root: Field,
\tinclusion_branches: [Field; 80]) -> pub (Field, Field, Field, Field, Field){{
\tlet tmp = register_identity::<{', '.join(str(v[k]) for k in order)}>(
\tdg1, dg15, ec, sa, pk, reduction_pk, sig, sk_identity, icao_root, inclusion_branches);
\t(tmp.0, tmp.1, tmp.2, tmp.3, icao_root)
}}""")
PY

  ( cd "${WORK}" && nargo compile )
  artifact="${WORK}/target/register_identity_profile.json"
  [ -f "${artifact}" ] || { echo "ERROR: ${name} produced no artifact" >&2; exit 1; }

  ( cd "${WORK}" && bb write_vk -t evm -b "${artifact}" -o target )
  out="${DEST}/NoirRegisterIdentity_${name}.sol"
  ( cd "${WORK}" && bb write_solidity_verifier -t evm -k target/vk -o "${out}" )

  # bb emits every verifier as `HonkVerifier`; both flavours are handled, and an unrenamed file is a
  # hard failure rather than a silent collision with every other verifier in the project.
  if grep -q '^contract HonkVerifier is\| contract HonkVerifier is' "${out}"; then
    sed -i '' "s/contract HonkVerifier is/contract NoirRegisterIdentity_${name} is/" "${out}"
  fi
  grep -q "contract NoirRegisterIdentity_${name} is" "${out}" || {
    echo "ERROR: ${name} verifier was not renamed - refusing to leave a colliding contract" >&2
    exit 1
  }
  built=$((built+1))
done

echo
echo "regenerated ${built} passport verifiers into ${DEST}"
echo "NEXT: forge build --sizes   (EIP-170 is 24,576 bytes and these are close to it)"
