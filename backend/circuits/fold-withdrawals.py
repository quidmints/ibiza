#!/usr/bin/env python3
"""Fold N withdrawals into one proof, and emit the IVC input stack `bb prove -s chonk` consumes.

  python3 fold-withdrawals.py [N]           # default 16 - build the IVC stack
  python3 fold-withdrawals.py --wrap <proof> # after `bb prove -s chonk`, witness the EVM wrapper

WHAT THIS IS. The batcher, in miniature and in one file. It runs the app circuit once per withdrawal,
threads each result through a kernel so the batch commitment accumulates, closes the stack with the
hiding kernel, and writes `ivc-inputs.msgpack`.

WHERE THE WITHDRAWALS COME FROM. `tools/build-fold-witnesses.js`, as `Prover.<i>.toml` in the app's
directory - N genuinely different spends against ONE state root, not N copies of one. That
distinction is the whole test: an accumulator over sixteen identical members cannot be told apart
from one that keeps only the last member, so a fold that silently drops fifteen of them would look
exactly like a fold that works. Run the generator first, or this refuses to start.

WHY THE CHAIN HAS TO BE EXECUTED IN ORDER. Each kernel takes the previous kernel's output through
`call_data(0)`, so its witness cannot be produced until the previous one has run. That is the whole
shape of IVC and it is why this is a loop rather than sixteen parallel invocations.

THE INPUT FORMAT IS NOT DOCUMENTED ANYWHERE OBVIOUS, so it is written down here: msgpack, an array of
maps with keys `bytecode`, `witness`, `vk` and `functionName`. `vk` must be the CHONK-flavour key
(`bb write_vk -s chonk --circuit_kind app|kernel|hiding`), never the UltraHonk one, and the hiding
kernel's is derived with `--circuit_kind hiding`, which implies the MegaZK flavour. Fewer than four
circuits is rejected outright: `num_circuits >= 4`, because `get_queue_type` uses `num_circuits - 3`.

TOOLCHAIN. Needs bb 6.0.0-nightly, installed as a node package rather than on PATH. bb 5.1.0 builds
the app and kernels but cannot build the wrapper that finally verifies this fold.
"""
import json
import os
import pathlib
import struct
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
SCRATCH = pathlib.Path(os.environ.get("FOLD_WORKDIR", HERE / ".fold"))
BB = os.environ.get("BB", "")

APP = "withdraw_ivc_app"
K_INIT = "withdraw_ivc_kernel_init"
K_INNER = "withdraw_ivc_kernel_inner"
HIDING = "withdraw_ivc_hiding"

# `CircuitKind`, a C++ enum msgpacked as a uint32 (bb.js src/cbind/circuit_kind.ts).
#
# THIS IS NOT THE SAME AXIS AS `--circuit_kind app|kernel|hiding` on write_vk, even though the words
# coincide - that one selects the FLAVOUR the key is derived under, this one tells the prover where
# each circuit sits in the stack. They agree here because a circuit's flavour and its position are
# the same fact, but a value copied from one to the other will be wrong the moment they are not.
#
# bb rejects a stack whose LAST entry is not the hiding kernel, and the only diagnostic for a missing
# entry is `Missing field kind` with no index - so the table is keyed by circuit name, which makes an
# unmapped circuit a KeyError here rather than a parse failure inside bb.
KIND_APP, KIND_KERNEL, KIND_HIDING = 0, 1, 2
CIRCUIT_KIND = {
    APP: KIND_APP,
    K_INIT: KIND_KERNEL,
    K_INNER: KIND_KERNEL,
    HIDING: KIND_HIDING,
}

WRAPPER = "withdraw_ivc_wrapper"

# Must equal vk_hash's MAX_VK_FIELDS, which is MEGA_VK_LENGTH_IN_FIELDS. Shorter keys are padded to
# it and pass their real length; the padding is never absorbed.
MAX_VK_FIELDS = 151

# The wrapper's own globals, restated so a drift is caught here rather than inside bb's verifier.
CHONK_PROOF_LENGTH = 1221
WRAPPER_PUBLIC_INPUTS = 2  # BatchAccumulator: commitment, count

# ── msgpack, written out rather than pulled in ────────────────────────────────────────────────
# The only shapes needed are str, bin and map/array, so a dependency would cost more than it saves.


def _mstr(s: str) -> bytes:
    b = s.encode()
    return (bytes([0xA0 | len(b)]) if len(b) < 32 else b"\xd9" + bytes([len(b)])) + b


def _mbin(b: bytes) -> bytes:
    if len(b) < 256:
        return b"\xc4" + bytes([len(b)]) + b
    if len(b) < 65536:
        return b"\xc5" + struct.pack(">H", len(b)) + b
    return b"\xc6" + struct.pack(">I", len(b)) + b


def _muint(n: int) -> bytes:
    if n < 128:
        return bytes([n])
    if n < 256:
        return b"\xcc" + bytes([n])
    return b"\xce" + struct.pack(">I", n)


def _mmap(pairs) -> bytes:
    out = bytes([0x80 | len(pairs)])
    for k, v in pairs:
        out += _mstr(k) + v
    return out


def _marr(items) -> bytes:
    head = bytes([0x90 | len(items)]) if len(items) < 16 else b"\xdc" + struct.pack(">H", len(items))
    return head + b"".join(items)


# ── circuit plumbing ──────────────────────────────────────────────────────────────────────────


def artifact(name: str) -> pathlib.Path:
    return HERE / name / "target" / f"{name}.json"


_VK_CACHE: dict[str, tuple[list[str], str]] = {}


def vk_fields(name: str) -> tuple[list[str], str]:
    """Circuit `name`'s chonk VK as field elements, plus the `key_hash` a kernel must be given.

    THE FIELDS COME FROM THE JSON FORM because the binary form is bytes, and the HASH is computed
    here because bb does not supply one: `bb write_vk -s chonk` writes no `vk_hash` file at all, and
    `--output_format json` writes `"hash": ""`.

    Empty is not zero. The recursive verifier checks this value, and passing zero produces
    `Recursive Ultra Verifier: VK Hash Mismatch` and a fold that fails - so it is computed with
    Poseidon2 by the `vk_hash` circuit, which compiles against the same poseidon pin the kernels do.
    See vk_hash/src/main.nr for why it is a circuit and why the kernels must not compute it
    themselves."""
    if name in _VK_CACHE:
        return _VK_CACHE[name]

    d = json.loads((SCRATCH / f"vk_{name}" / "vk.json").read_text())
    fields = [hex(int(x, 16) if isinstance(x, str) else int(x)) for x in d["vk"]]

    padded = fields + ["0"] * (MAX_VK_FIELDS - len(fields))
    (HERE / "vk_hash" / "Prover.toml").write_text(
        f"key = {json.dumps(padded)}\nlen = \"{len(fields)}\"\n"
    )
    out = run(["nargo", "execute", f"h_{name}"], HERE / "vk_hash")
    _VK_CACHE[name] = (fields, circuit_output(out))
    return _VK_CACHE[name]


def run(cmd: list[str], cwd: pathlib.Path) -> str:
    r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"FAILED in {cwd.name}: {' '.join(cmd)}\n{r.stdout}\n{r.stderr}")
    return r.stdout


def circuit_output(stdout: str) -> str:
    """nargo prints `Circuit output: <struct literal>`; that is the only place the return_data is
    visible without decoding the witness, so it is parsed rather than recomputed."""
    for line in stdout.splitlines():
        if "Circuit output:" in line:
            return line.split("Circuit output:", 1)[1].strip()
    sys.exit(f"no circuit output found in:\n{stdout}")


def parse_struct(text: str) -> dict:
    """`Name { a: 0x1, b: 0x2 }` -> {'a': '0x1', 'b': '0x2'}."""
    body = text[text.index("{") + 1 : text.rindex("}")]
    out = {}
    for part in body.split(","):
        if ":" not in part:
            continue
        k, v = part.split(":", 1)
        out[k.strip()] = v.strip()
    return out


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] == "--wrap":
        if not BB:
            sys.exit("set BB to the 6.0.0-nightly bb, e.g. BB=./node_modules/.bin/bb")
        SCRATCH.mkdir(parents=True, exist_ok=True)
        return wrap(pathlib.Path(sys.argv[2]))

    n = int(sys.argv[1]) if len(sys.argv) > 1 else 16
    if n < 4:
        sys.exit("bb rejects fewer than 4 circuits in an IVC stack (get_queue_type uses N-3)")
    if not BB:
        sys.exit("set BB to the 6.0.0-nightly bb, e.g. BB=./node_modules/.bin/bb")

    SCRATCH.mkdir(parents=True, exist_ok=True)
    app_vk, app_vk_hash = vk_fields(APP)

    def vk_toml(section: str, name: str) -> list[str]:
        """The `VkData` block naming circuit `name`'s key.

        WHICH KEY A KERNEL IS HANDED IS NOT A CONSTANT, and getting it wrong is quiet. The first
        inner kernel's predecessor is the INIT kernel; every later one's is another inner kernel.
        Handing the inner key to the first inner kernel produced `HypernovaFoldingVerifier:
        instance-to-accumulator sumcheck failed` and, because IVC is a chain, that failure repeated
        at every later step - so the log named four broken folds and not the one that was wrong."""
        key, key_hash = vk_fields(name)
        return ["", f"[{section}]", f"key = {json.dumps(key)}", f'hash = "{key_hash}"']

    entries = []

    def add(name: str, witness: str):
        vk = (SCRATCH / f"vk_{name}" / "vk").read_bytes()  # the stack wants the BINARY key
        entries.append(
            _mmap(
                [
                    ("bytecode", _mbin(json_bytecode(name))),
                    ("witness", _mbin((HERE / name / "target" / witness).read_bytes())),
                    ("vk", _mbin(vk)),
                    ("functionName", _mstr(name)),
                    ("kind", _muint(CIRCUIT_KIND[name])),
                ]
            )
        )

    def json_bytecode(name: str) -> bytes:
        import base64

        return base64.b64decode(json.loads(artifact(name).read_text())["bytecode"])

    # Fail before the first circuit runs rather than N-1 members in, and name the generator.
    missing = [i for i in range(n) if not (HERE / APP / f"Prover.{i}.toml").exists()]
    if missing:
        sys.exit(
            f"missing witnesses for members {missing}.\n"
            f"  cd frontend/identity-wallet && npm run build:pp\n"
            f"  node tools/build-fold-witnesses.js --build frontend/identity-wallet/build --count {n}"
        )

    print(f"folding {n} withdrawals")
    seen_signals = set()
    for i in range(n):
        # 1. the app proves one withdrawal and returns its seven signals. `nargo execute` reads
        #    Prover.toml and nothing else, so member i's witness is moved into place first.
        (HERE / APP / "Prover.toml").write_text((HERE / APP / f"Prover.{i}.toml").read_text())
        out = run(["nargo", "execute", f"w{i}"], HERE / APP)
        signals = parse_struct(circuit_output(out))
        add(APP, f"w{i}.gz")

        # The members must actually differ. Without this the run below would still print a rising
        # count and a changing commitment while folding the same withdrawal N times, which is
        # precisely the reassuring-but-empty result the old N=16 fixture produced.
        key = tuple(sorted(signals.items()))
        if key in seen_signals:
            sys.exit(f"member {i} has the same seven signals as an earlier member - not a real batch")
        seen_signals.add(key)

        # 2. the kernel absorbs them. init starts the chain; every later step also verifies the
        #    kernel before it, which is what stops a batcher re-rooting the accumulator mid-batch.
        if i == 0:
            toml = ["[app_signals]"] + [f'{k} = "{v}"' for k, v in signals.items()]
            toml += vk_toml("app_vk", APP)
            (HERE / K_INIT / "Prover.toml").write_text("\n".join(toml) + "\n")
            out = run(["nargo", "execute", f"k{i}"], HERE / K_INIT)
            add(K_INIT, f"k{i}.gz")
        else:
            toml = ["[prev]"] + [f'{k} = "{v}"' for k, v in acc.items()]
            toml += vk_toml("prev_kernel_vk", prev_kernel)
            toml += ["", "[app_signals]"] + [f'{k} = "{v}"' for k, v in signals.items()]
            toml += vk_toml("app_vk", APP)
            (HERE / K_INNER / "Prover.toml").write_text("\n".join(toml) + "\n")
            out = run(["nargo", "execute", f"k{i}"], HERE / K_INNER)
            add(K_INNER, f"k{i}.gz")
        prev_kernel = K_INIT if i == 0 else K_INNER
        acc = parse_struct(circuit_output(out))
        print(f"  {i + 1:>3}/{n}  count={int(acc['count'], 16)}  commitment={acc['commitment'][:18]}...")

    # 3. the hiding kernel closes the stack and must be last. Its predecessor is whatever ran last,
    #    which is the init kernel only in the degenerate single-withdrawal case bb rejects anyway.
    toml = ["[prev]"] + [f'{k} = "{v}"' for k, v in acc.items()]
    toml += vk_toml("prev_kernel_vk", prev_kernel)
    (HERE / HIDING / "Prover.toml").write_text("\n".join(toml) + "\n")
    run(["nargo", "execute", "hiding"], HERE / HIDING)
    add(HIDING, "hiding.gz")

    out_path = SCRATCH / "ivc-inputs.msgpack"
    out_path.write_bytes(_marr(entries))
    print(f"\n{len(entries)} circuits -> {out_path} ({out_path.stat().st_size / 1e6:.1f} MB)")
    print(f"final commitment {acc['commitment']}  count {int(acc['count'], 16)}")
    print(f"\nnext: {BB} prove -s chonk --ivc_inputs_path {out_path} -o <dir>")
    print(f"then: python3 {__file__} --wrap <proof>")
    return 0


def wrap(proof_path: pathlib.Path) -> int:
    """Turn a proven fold into the wrapper's witness - the last hop before the EVM.

    THE PUBLIC INPUTS ARE PREPENDED TO THE PROOF FILE, not stored beside it. A chonk proof on disk is
    `[commitment, count] ++ 1221 proof fields`, and the wrapper wants those two groups as separate
    arguments. Splitting it by the pinned lengths rather than by 'whatever is left over' means a
    format shift shows up as a length assertion here instead of as an unexplained rejection two
    circuits later."""
    raw = proof_path.read_bytes()
    fields = ["0x" + raw[i : i + 32].hex() for i in range(0, len(raw), 32)]
    expected = WRAPPER_PUBLIC_INPUTS + CHONK_PROOF_LENGTH
    if len(fields) != expected:
        sys.exit(f"{proof_path} is {len(fields)} fields, expected {expected}")
    public, proof = fields[:WRAPPER_PUBLIC_INPUTS], fields[WRAPPER_PUBLIC_INPUTS:]

    vk, vk_hash = vk_fields(HIDING)
    toml = [
        f"proof = {json.dumps(proof)}",
        f"vk = {json.dumps(vk)}",
        f'vk_hash = "{vk_hash}"',
        "",
        "[accumulator]",
        f'commitment = "{public[0]}"',
        f'count = "{public[1]}"',
    ]
    (HERE / WRAPPER / "Prover.toml").write_text("\n".join(toml) + "\n")
    run(["nargo", "execute", "wrap"], HERE / WRAPPER)

    print(f"wrapper witness solved for batch {public[0]}, count {int(public[1], 16)}")
    print(f"\nnext: {BB} write_vk -t evm -b {WRAPPER}/target/{WRAPPER}.json -o <dir>")
    return 0


if __name__ == "__main__":
    sys.exit(main())
