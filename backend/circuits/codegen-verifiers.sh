#!/usr/bin/env bash
# Regenerate the on-chain Honk verifier contracts from the Noir circuits.
#
# Everything this script emits is GENERATED - never hand-edit the .sol files it writes, re-run this
# instead. The only post-generation edit it makes is renaming the top-level `contract HonkVerifier`
# (bb emits that same name for every circuit) to a per-circuit name, so both verifiers can coexist
# in one Forge project.
#
# TWO ARGUMENTS ARE LOAD-BEARING AND BOTH ARE EASY TO OMIT SILENTLY: `--oracle_hash keccak`, and
# `-k <vk>` on `prove`. Omitting either produces a pipeline that still builds, still passes tests,
# and is still wrong.
#
# ZERO-KNOWLEDGE: on bb 1.x - which this script pins - ZK is the DEFAULT and the opt-OUT is
# `--disable_zk`, so this script passes NO zk flag and that is correct. On 0.82.2 it was opt-IN via
# `--zk`, and omitting it silently produced non-zero-knowledge proofs that leak the witness; upstream
# inverted the flag precisely because the old default was a footgun. Older notes in this repo that
# call `--zk` load-bearing are 0.82.2-era. Verify the property either way with:
#   bb prove --scheme ultra_honk --oracle_hash keccak -b ... -w ... -o /tmp/a
#   bb prove --scheme ultra_honk --oracle_hash keccak -b ... -w ... -o /tmp/b
#   cmp /tmp/a/proof /tmp/b/proof     # identical => NOT zk; differ => blinded
# `bb write_vk` takes no --zk (the key is shared); the flavour lives in the prover and the verifier.
#
# WHY THE `--oracle_hash keccak` FLAGS ARE NOT OPTIONAL: the default (Poseidon2) transcript is for
# proofs verified *inside another circuit*. Its proofs do NOT verify against the generated Solidity
# - they revert `SumcheckFailed()`. PP-NOIR-FUSION.md's P0 log found this empirically. Every
# standalone on-chain verifier in this fusion must use the keccak transcript on all three of
# prove / write_vk / write_solidity_verifier.
#
# TOOLCHAIN (pinned, do not drift). These MUST match REQUIRED_NARGO/REQUIRED_BB below - an earlier
# revision of this header still advertised beta.1 / 0.82.2 while the guard already enforced
# beta.13 / 1.2.0, so following the header got you rejected by the script twelve lines later:
#   nargo 1.0.0-beta.13  `noirup --version 1.0.0-beta.13`
#   bb    1.2.0          `barretenberg-<arch>-darwin|linux.tar.gz` from the v1.2.0 release.
#                        Do NOT use bb < 0.82.0: bbup's own installer warns of a critical UltraHonk
#                        soundness vulnerability below that version, requiring verifier regeneration.
#                        Do NOT assume `bb` on PATH is the right one - several versions are commonly
#                        installed side by side, and the guard below exists because of that.
#
# NATIVE `bb` NEEDS AVX2/BMI2. It SIGILLs on CPUs without them (TODO.md §1 recorded this against an
# i3-U330). Check with `sysctl -n machdep.cpu.leaf7_features` (macOS) or `grep avx2 /proc/cpuinfo`.
# On a CPU that lacks them, substitute bb.js (WASM) for the `bb` calls - same subcommands.
set -euo pipefail

# ---------------------------------------------------------------------------------------------
# TOOLCHAIN GUARD - do not remove. See TODO.md sec. 2.27 for the full compatibility map.
#
# EXACTLY ONE nargo/bb combination works for this repo. Every neighbouring version fails, and -
# critically - SOME OF THEM FAIL SILENTLY:
#
#   bb 1.2.0 + nargo beta.1  ->  `bb prove` REPORTS SUCCESS and writes a proof that bb's own
#                                `bb verify` then REJECTS ("Sumcheck failed!"). Anyone who
#                                evaluates a bump by "did prove succeed?" will ship a broken system.
#   bb <= 0.87.0             ->  `--zk` is SILENTLY IGNORED under `--honk_recursion`, producing
#                                non-zero-knowledge proofs that leak the witness.
#   nargo beta.22+           ->  outright compiler ICE ("all function ids should have metadata") on
#                                query_identity / register_identity, with zero regular errors.
#                                (An earlier note here said "beta.4+ cannot compile our dependency
#                                tree" - that was true BEFORE the noir_dl_lib migration; the tree
#                                now builds on beta.13, and beta.22 fails only on the ICE.)
#
# So this guard is not pedantry about versions - it is the only thing standing between a fresh
# clone and artifacts that look fine and are not.
# ---------------------------------------------------------------------------------------------
REQUIRED_NARGO="1.0.0-beta.13"
REQUIRED_BB="1.2.0"

actual_nargo="$(nargo --version 2>/dev/null | sed -n 's/^nargo version = //p' | head -1)"
actual_bb="$(bb --version 2>/dev/null | tail -1 | sed 's/^v//')"

if [ "${actual_nargo}" != "${REQUIRED_NARGO}" ] || [ "${actual_bb}" != "${REQUIRED_BB}" ]; then
  cat >&2 <<EOF
ERROR: wrong toolchain. Refusing to generate verifiers.

  nargo  required ${REQUIRED_NARGO}   found '${actual_nargo:-<not on PATH>}'
  bb     required ${REQUIRED_BB}      found '${actual_bb:-<not on PATH>}'

Install exactly these:
  noirup --version ${REQUIRED_NARGO}
  # bb: untar barretenberg-<arch>-darwin|linux.tar.gz from
  #     https://github.com/AztecProtocol/aztec-packages/releases/tag/v${REQUIRED_BB}
  #     (bbup also resolves it: it reads the installed nargo)

DO NOT "just use a newer version" - see TODO.md sec. 2.27. Several newer combinations produce
artifacts that appear valid and are not. If you are deliberately testing a bump, verify ALL THREE
before trusting it:
  1. native  'bb verify'  accepts the proof
  2. two prover runs on one witness produce DIFFERENT bytes  (confirms ZK; identical => NOT zk)
  3. the generated Solidity verifier accepts a real proof on-chain  (forge test)
EOF
  exit 1
fi

# ---------------------------------------------------------------------------------------------
# bb_checked <expected-artifact> -- <bb args...>
#
# EVERY bb call goes through this. bb fails in two ways that a bare invocation does not catch, and
# both have already cost this project real time:
#
#   1. IT EXITS 0 AND WRITES NOTHING. `bb write_solidity_verifier` with a missing -k prints
#      "Unable to open file: target/vk" and returns 0. `set -e` cannot see that. Only checking that
#      the artifact exists catches it.
#   2. IT SIGSEGVS (exit 139) ON A WRONG IN-CIRCUIT VK LENGTH, after already printing
#      "Scheme is: ultra_honk" - so stdout looks like a normal run. The recursive
#      `verification_key` parameter is 128 FIELDS, not the 55 fields of the on-disk target/vk.
#      Passing 55 segfaults with no diagnostic. See TODO.md sec. 2.4pre.
#
# Checking the ARTIFACT rather than the exit code is the general defence: it holds for failure
# modes nobody has classified yet, which is the whole reason the self-checks further down exist.
bb_checked() {
  local artifact="$1"; shift
  [ "$1" = "--" ] && shift

  set +e
  "$@"
  local code=$?
  set -e

  if [ ${code} -eq 139 ]; then
    echo "ERROR: bb SEGFAULTED (exit 139) on: $*" >&2
    echo "       If this is a recursive circuit, the in-circuit verification_key is 128 FIELDS," >&2
    echo "       NOT the 55 fields of the on-disk target/vk. A wrong length segfaults bb with no" >&2
    echo "       diagnostic. See TODO.md sec. 2.4pre." >&2
    exit 1
  fi

  if [ ${code} -ne 0 ]; then
    echo "ERROR: bb exited ${code} on: $*" >&2
    exit 1
  fi

  # The load-bearing check: bb can exit 0 having produced nothing.
  if [ ! -s "${artifact}" ]; then
    echo "ERROR: bb reported success but produced no '${artifact}'." >&2
    echo "       Command: $*" >&2
    echo "       bb exits 0 on some failures (e.g. a missing -k on write_solidity_verifier)," >&2
    echo "       so exit status alone is not evidence the artifact was written." >&2
    exit 1
  fi
}

CIRCUITS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACTS_DIR="${CIRCUITS_DIR}/../contracts/contracts"

# circuit_dir : destination .sol : generated contract name : number of public inputs
TARGETS=(
  "withdraw_identity:${CONTRACTS_DIR}/pool/verifiers/WithdrawalHonkVerifier.sol:WithdrawalHonkVerifier:9"
  "title_holder:${CONTRACTS_DIR}/title/TitleHolderHonkVerifier.sol:TitleHolderHonkVerifier:2"
  "ragequit:${CONTRACTS_DIR}/pool/verifiers/RagequitHonkVerifier.sol:RagequitHonkVerifier:4"
)

for target in "${TARGETS[@]}"; do
  IFS=':' read -r circuit dest contract_name npub <<<"${target}"
  echo "==> ${circuit}"
  pushd "${CIRCUITS_DIR}/${circuit}" >/dev/null

  nargo compile
  bb_checked target/vk -- bb write_vk --scheme ultra_honk --oracle_hash keccak \
    -b "target/${circuit}.json" -o target
  # ZERO KNOWLEDGE IS NON-NEGOTIABLE HERE, and on bb 1.x it is the DEFAULT - so no flag is passed
  # and NOTHING must ever add `--disable_zk`. (On 0.82.2 this needed an explicit `--zk`; an earlier
  # revision of this comment said "--zk IS NOT OPTIONAL" while the command below already, correctly,
  # passed no zk flag at all.) A non-ZK pair is SOUND BUT LEAKS: proving one witness twice yields
  # BYTE-IDENTICAL proofs, which a zero-knowledge system cannot do, because blinding needs
  # randomness. withdraw_identity's witness holds `nullifier`, `secret`, `label`, `value` and
  # `sk_identity`; title_holder's holds `sk_identity`. Shipping non-ZK proofs over those destroys
  # exactly the unlinkability both circuits exist to provide. ZK costs ~+51% verify gas and +51
  # field elements of proof - that is the price of the property, not overhead to trim. The
  # determinism self-check below is what actually enforces this. See TODO.md sec. 2.17.
  bb_checked "${dest}" -- bb write_solidity_verifier --scheme ultra_honk \
    -k target/vk -o "${dest}"

  # bb names every generated contract `HonkVerifier`; give each a distinct name so a single Forge
  # project can hold both. Only the top-level contract is renamed - the file-scoped libraries keep
  # their generated names and are harmless, since Forge keys artifacts by source path.
  # bb emits the ZK verifier as ` contract HonkVerifier is IVerifier {` (note the leading space)
  # and the non-ZK one as `contract HonkVerifier is BaseHonkVerifier`. Match both so this keeps
  # working if the flavour is ever changed, rather than silently leaving the name unrenamed.
  sed -i.bak -E "s/^[[:space:]]*contract HonkVerifier is /contract ${contract_name} is /" "${dest}"
  rm -f "${dest}.bak"
  grep -q "^contract ${contract_name} is " "${dest}" || {
    echo "ERROR: failed to rename generated contract in ${dest}" >&2; exit 1;
  }

  # Regenerate the committed proof fixture from a COMMITTED witness, so the fixture can never drift
  # from the verifier it is tested against - and so a fixture proved WITHOUT --zk cannot linger
  # unnoticed (it would be 51 field elements shorter and the ZK verifier would reject it).
  #
  # `Prover.baseline.toml` takes precedence over `Prover.toml`. withdraw_identity has TWO committed
  # witnesses (baseline + wallet, both emitted by tools/build-withdrawal-fixture.js) and only the
  # baseline corresponds to test/fixtures/<circuit>.proof; the wallet one is regenerated by that
  # tool, not here. This branch previously keyed on `Prover.toml` alone while NO Prover.toml was ever
  # committed for withdraw_identity - so it silently skipped, and the "cannot drift" guarantee in the
  # old version of this comment did not actually hold for that circuit.
  _prover=""
  if   [ -f Prover.baseline.toml ]; then _prover="Prover.baseline.toml"
  elif [ -f Prover.toml ];          then _prover="Prover.toml"
  fi
  if [ -n "${_prover}" ]; then
    # Guarded: `cp x x` is an error under set -e, and title_holder's only witness IS Prover.toml.
    [ "${_prover}" = "Prover.toml" ] || cp "${_prover}" Prover.toml
    echo "  witness: ${_prover}"
    nargo execute witness
    # -k IS MANDATORY ON bb 1.x AND WAS NOT ON 0.82.2. Omitting it does not error - bb exits 0 and
    # writes a proof against a DIFFERENT key, which its own verifier then rejects with
    # `SumcheckFailed()`. That single missing flag masqueraded as a bb-version incompatibility for a
    # long time. The self-checks below would catch it, but pass it explicitly.
    bb_checked target/proof -- bb prove --scheme ultra_honk --oracle_hash keccak \
      -b "target/${circuit}.json" -w target/witness.gz -k target/vk -o target

    # ----- SELF-VALIDATION: never emit an artifact we have not checked -----
    # A version guard alone is a proxy. These two checks test the ARTIFACT, so they hold even for a
    # toolchain nobody has classified yet.

    # (1) NATIVE VERIFY. bb 1.2.0 + nargo beta.1 reports proving success and emits a proof that bb's
    #     OWN verifier rejects. Only this check catches that; `bb prove`'s exit code does not.
    if ! bb verify --scheme ultra_honk --oracle_hash keccak \
         -k target/vk -p target/proof -i target/public_inputs >/dev/null 2>&1; then
      echo "ERROR: ${circuit}: bb generated a proof its own verifier REJECTS." >&2
      echo "       The prover/VK pair is incompatible with this circuit. Do NOT use these" >&2
      echo "       artifacts. See TODO.md sec. 2.27." >&2
      exit 1
    fi

    # (2) ZERO-KNOWLEDGE. Prove the SAME witness twice: a ZK prover must produce different bytes,
    #     because blinding requires randomness. Identical output is conclusive proof that ZK is OFF
    #     - which is how `--zk` being silently ignored under `--honk_recursion` was found, and how
    #     the original missing-`--zk` bug was found. Output dirs are cleared first: comparing stale
    #     files once produced a false negative here.
    rm -rf target/_zkcheck_a target/_zkcheck_b
    mkdir -p target/_zkcheck_a target/_zkcheck_b
    for _d in a b; do
      bb_checked "target/_zkcheck_${_d}/proof" -- bb prove --scheme ultra_honk --oracle_hash keccak \
        -b "target/${circuit}.json" -w target/witness.gz -k target/vk \
        -o "target/_zkcheck_${_d}" >/dev/null 2>&1
    done
    if cmp -s target/_zkcheck_a/proof target/_zkcheck_b/proof; then
      echo "ERROR: ${circuit}: proving the same witness twice produced IDENTICAL bytes." >&2
      echo "       A deterministic prover cannot be zero-knowledge. These proofs would leak the" >&2
      echo "       witness (sk_identity, nullifier, secret). Do NOT use them. TODO.md sec. 2.17." >&2
      exit 1
    fi
    rm -rf target/_zkcheck_a target/_zkcheck_b
    echo "  self-check ok: native verify passed, prover is non-deterministic (ZK)"
    python3 - "${circuit}" "${CONTRACTS_DIR}/../test/fixtures" "${npub}" <<'PYEOF'
import sys, pathlib
circuit, fixtures, npub = sys.argv[1], pathlib.Path(sys.argv[2]), int(sys.argv[3])
proof = (pathlib.Path("target") / "proof").read_bytes()
pub = (pathlib.Path("target") / "public_inputs").read_bytes()

# bb 1.x proof format, DIFFERENT from 0.82.2:
#   - no 4-byte big-endian field-count prefix
#   - public inputs are written to their OWN file, not prepended to the proof
#   - the proof carries a 16-field pairing-point accumulator, which the generated Solidity reads
#     from the proof itself (it takes `publicInputsSize - PAIRING_POINTS_SIZE` from calldata)
# So the fixture is the proof VERBATIM, and the calldata public-input count is unchanged.
assert len(proof) % 32 == 0, len(proof)
assert len(pub) == npub * 32, (len(pub), npub * 32)
fixtures.mkdir(parents=True, exist_ok=True)
(fixtures / f"{circuit}.proof").write_bytes(proof)
print(f"  fixture {circuit}.proof: {len(proof)//32} proof fields, {npub} public inputs (separate)")
PYEOF
  fi

  popd >/dev/null
done

# Refresh the circuits BUNDLED INTO THE WALLET. These are the same ACIR artifacts the prover runs
# on-device, and they are published nowhere, so the app ships them (see the wallet's
# metro.config.js). Copying them here is what stops the bundled bytecode drifting from the circuit
# this script just generated a verifier for - a drift that would produce proofs the on-chain
# verifier rejects, with nothing pointing at the stale asset as the cause.
WALLET_CIRCUITS="${CIRCUITS_DIR}/../../frontend/identity-wallet/assets/circuits"
if [ -d "${WALLET_CIRCUITS}" ]; then
  echo
  echo "==> Refreshing wallet-bundled circuits"
  for target in "${TARGETS[@]}"; do
    IFS=':' read -r circuit _rest <<<"${target}"
    src="${CIRCUITS_DIR}/${circuit}/target/${circuit}.json"
    if [ -f "${src}" ]; then
      cp "${src}" "${WALLET_CIRCUITS}/${circuit}.circuit"
      echo "  ${circuit}.circuit  ($(wc -c <"${src}" | tr -d ' ') bytes)"
    fi
  done
fi

echo
echo "==> Done. Verify with:"
echo "    cd ${CONTRACTS_DIR}/.. && forge build --sizes && forge test"
echo
echo "    Both verifiers must stay under the EIP-170 24,576-byte runtime limit. As of the last run"
echo "    they were 24,491 bytes - only ~85 bytes of headroom, already with optimizer_runs = 1"
echo "    scoped to them. A circuit whose public-input count or log-size grows WILL push a verifier"
echo "    over it, and the failure appears only at deploy time - check --sizes after every run."
