#!/usr/bin/env python3
"""
Surface loose ends from a session transcript AND the code, in ONE pass.

WHY THIS EXISTS. Closing out a long thread on 2026-08-02 took FIVE passes to find everything, and
each pass used a different vocabulary. Findings that were real — a stables leg never wired, a
mapped-but-unexecuted cleanup, an unrotated token, an ECDSA soundness hole — had each been STATED in
a reply and never lifted into a task. Recorded somewhere, actionable nowhere. This script does all
the passes at once so the next close-out is one command.

    python3 tools/scan-loose-ends.py --transcript ~/.claude/projects/<proj>/<session>.jsonl

    python3 tools/scan-loose-ends.py            # code-only scan, no transcript needed

WHAT IT WILL NOT DO, and why you still have to think:

  1. It reports CANDIDATES, not findings. Every hit needs a human deciding "is this booked?".
     **THE BOOKED-FILTER IS WEAK AND YOU SHOULD NOT LEAN ON IT.** Three implementations were tried
     against a real 55 MB transcript (572 passages): substring-on-prose flagged 519 as unbooked and
     filtered nothing; any-word-of-4+-chars flagged 0 and hid everything, because a ~10k-line tracker
     contains almost every ordinary word; identifier-shaped tokens (the current one) flags ~503.
     **The value of this tool is the ENUMERATION, not the filtering.** Read the families you care
     about in full. If someone builds a filter that actually works, replace this note with it.
  2. The transcript scan CANNOT see what was never said. The worst bug found that day —
     `// TODO: NONE OF THIS IS CONSTRAINED YET. FIX!` in vendored circuit code, a signature-forgery
     hole — appears in NO transcript pass, because nobody ever mentioned it. That is why the code
     scan below is not optional.
  3. An absent result is not a finding. See RUN THE CONTROL at the bottom.
"""

import argparse, json, pathlib, re, sys
from collections import OrderedDict

# ── the vocabulary families. Each pass on 2026-08-02 used ONE of these and found things the
# ── others missed, so they are run together. Add to them; do not replace them.
FAMILIES = OrderedDict([
    ("incomplete", r"I (?:did ?n[o']t|have ?n[o']t|couldn'?t|wasn'?t able)|not (?:done|implemented|wired|applied|covered)|still (?:need|needs|missing|absent|lacks)|remains? (?:open|unaddressed|untested|unwired)|left (?:out|open|undone|unwired)|stopped short|partially"),
    ("deferred",   r"deferred|for now|later|not yet|another run|next run|out of scope|follow[- ]up|revisit|come back to|punt"),
    ("dismissal",  r"false positive|artifact of|not a real|just a coincidence|harmless|not a gap|non-requirement|nothing to fix|already covered|superseded|moot"),
    ("absence",    r"empty = |no matches|zero hits|never referenced|nothing outside|0 of \d+|refs?=0"),
    ("decision",   r"governance call|design call|policy call|product call|your call|not (?:mine|ours) to (?:make|decide)|decided unilaterally|needs? (?:a )?(?:human|your) (?:decision|call)"),
    ("risk",       r"silently (?:wrong|passes|fails|drops|breaks)|fails silently|no way to tell|nothing would catch|footgun|the trap is|fragile|brittle|only works because|happens to work"),
    ("unverified", r"unverified|never (?:run|tested|exercised|checked)|not verified|cannot verify|assumed|untested|approximate|from memory"),
    ("oughtto",    r"should probably|worth (?:doing|checking|fixing|a look)|would be better|ideally|one day|eventually|if this ever|someone should|nice to have"),
    ("security",   r"unrotated|not rotated|leaked|exposed (?:token|key|secret)|hard[- ]?coded (?:secret|key|token)|plaintext"),
])

# ── markers that live in the CODE. The transcript cannot find these.
CODE_MARKERS = r"\b(TODO|FIXME|HACK|XXX|WIP|TEMP|PLACEHOLDER|NOT IMPLEMENTED|unimplemented)\b"
# In ZK circuits an `unsafe` block is an UNCONSTRAINED prover-supplied value. Every one needs a
# constraint after it. This is how the forgery hole was found.
CIRCUIT_HINTS = r"unsafe\s*\{"
CODE_EXTS = (".sol", ".nr", ".ts", ".tsx", ".go", ".rs", ".py", ".sh")
SKIP_DIRS = ("node_modules", "/lib/", "/build/", "/target/", "/.git/", "/out/", "/cache/")


def scan_transcript(path, ctx=190):
    hits = {k: [] for k in FAMILIES}
    seen = set()
    with open(path, errors="ignore") as fh:
        for line in fh:
            try:
                msg = (json.loads(line).get("message") or {})
            except Exception:
                continue
            if msg.get("role") != "assistant":
                continue
            c = msg.get("content")
            # READ text AND thinking. Measured on a real 56 MB transcript, assistant content is
            # 2,617 `text` blocks, 2,390 `thinking` blocks and 4,174 `tool_use` blocks — so keying on
            # "text" alone covered 28% of what the model actually produced. Thinking blocks are
            # exactly where an unbooked finding hides: reasoning that never reached the reply.
            txt = (" ".join(x.get("text", "") or x.get("thinking", "") for x in c if isinstance(x, dict))
                   if isinstance(c, list) else str(c))
            for fam, pat in FAMILIES.items():
                for mo in re.finditer(pat, txt, re.I):
                    s = txt[max(0, mo.start() - ctx):mo.end() + ctx].replace("\n", " ").strip()
                    key = re.sub(r"\W", "", s)[:55]
                    if key in seen:
                        continue
                    seen.add(key)
                    hits[fam].append(s)
    return hits


def scan_code(root):
    out = {"markers": [], "circuit_hints": []}
    for p in pathlib.Path(root).rglob("*"):
        s = str(p)
        # Skip this file: it necessarily contains every marker it searches for.
        if p.name == "scan-loose-ends.py":
            continue
        if not p.is_file() or not s.endswith(CODE_EXTS) or any(d in s for d in SKIP_DIRS):
            continue
        try:
            text = p.read_text(errors="ignore")
        except Exception:
            continue
        rel = s.replace(str(root) + "/", "")
        for i, line in enumerate(text.splitlines(), 1):
            # A bare reference to the tracker file is not a marker.
            if re.search(CODE_MARKERS, line) and not re.search(r"TODO\.md|TODO ?sec", line):
                out["markers"].append(f"{rel}:{i}: {line.strip()[:110]}")
            if re.search(CIRCUIT_HINTS, line):
                out["circuit_hints"].append(f"{rel}:{i}: {line.strip()[:110]}")
    return out


# Words too common to identify anything. A passage matched only by these is not "booked".
STOP = set("""the a an and or but if is are was were be been being to of in on at by for with from
that this these those it its as not no now then than so such can may might will would should could
about into over under again more most other some any all each which what when where who whom why how
we you they i he she them us our your their my me him her one two do does did done have has had
work code test tests file files line lines run runs make makes made need needs still just only also
""".split())


def booked(term, docs):
    """Is this passage's SUBJECT already written down?

    TWO FAILED VERSIONS ARE WORTH KNOWING ABOUT, because both failure modes look like success:
      • substring on a 40-char slice of prose -> flagged 519 of 572 as unbooked. Filtered NOTHING.
      • any word of 4+ chars -> flagged 0 of 572. Hid EVERYTHING. The tracker is ~10k lines, so
        almost every ordinary word appears in it somewhere; word presence carries no information.

    Only IDENTIFIER-SHAPED tokens identify a subject: snake_case, dotted.paths, file/paths, CamelCase,
    or anything containing a digit. Those are what a tracker entry about the same thing would repeat.
    """
    toks = {w for w in re.findall(r"[A-Za-z_][A-Za-z0-9_./-]{3,}", term)
            if re.search(r"[_./]|\d|[a-z][A-Z]", w)}
    if len(toks) < 2:
        return False          # nothing distinctive to match on — show it and let a human judge
    present = sum(1 for tk in toks if any(tk.lower() in d for d in docs))
    return present >= (len(toks) + 1) // 2      # a majority of its identifiers already recorded


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--transcript", help="path to the session .jsonl")
    ap.add_argument("--root", default=".", help="repo root to scan for code markers")
    ap.add_argument("--docs", nargs="*", default=["TODO.md", "README.md"],
                    help="tracker files to cross-check against")
    ap.add_argument("--limit", type=int, default=8, help="passages shown per family")
    a = ap.parse_args()

    docs = []
    for d in a.docs:
        p = pathlib.Path(a.root) / d
        if p.exists():
            docs.append(re.sub(r"\W+", " ", p.read_text(errors="ignore").lower()))

    print("=" * 78)
    print("CODE SCAN — the transcript cannot see these. Do not skip.")
    print("=" * 78)
    code = scan_code(pathlib.Path(a.root).resolve())
    print(f"\n[{len(code['markers'])}] unresolved markers in code")
    for m in code["markers"][:40]:
        print("   ", m)
    print(f"\n[{len(code['circuit_hints'])}] `unsafe {{` sites — in a ZK circuit each is an UNCONSTRAINED,")
    print("     prover-supplied value. Every one needs a constraint immediately after it.")
    for m in code["circuit_hints"][:25]:
        print("   ", m)

    if a.transcript:
        print("\n" + "=" * 78)
        print("TRANSCRIPT SCAN — what was SAID and may never have been BOOKED")
        print("=" * 78)
        hits = scan_transcript(a.transcript)
        for fam, items in hits.items():
            flagged = [s for s in items if not booked(s, docs)]
            print(f"\n--- {fam.upper()}: {len(items)} passages, {len(flagged)} after the (WEAK) booked-filter ---")
            for s in flagged[:a.limit]:
                print(f"  • {s[:250]}")

    print("\n" + "=" * 78)
    print("""TRIAGE — apply to every candidate above

  1. RUN THE CONTROL BEFORE CONCLUDING. An absent result proves nothing on its own. Three wrong
     conclusions in one day came from skipping this: "RootValidity is tested" (two suites were NAMED
     after it and neither imported it); "the bisect was superseded" (never checked what it was for);
     "35 verifiers are dead, refs=0" (the LIVE Noir verifiers also scored 0 — the metric could not
     distinguish dead from unwired). Ask: would this measurement look the same if I were wrong?

  2. A DISMISSAL IS A CONCLUSION. "That's a false positive" needs the same evidence as a finding.

  3. LIFT IT IN THE SAME TURN. Every miss that day was already written down in prose and never
     turned into a task. If a finding is stated in a reply and not booked, it does not exist.

  4. VENDORED CODE NEEDS READING, NOT JUST BUILDING. The worst bug found that day was a vendor's own
     `// TODO: NONE OF THIS IS CONSTRAINED YET. FIX!` in a file that had been ported, pruned,
     dependency-bumped and tested — without being read.

  5. READ THE RECORDED EXIT CODE, NOT THE HARNESS SUMMARY. A background task reported "exit code 0"
     for a run that exited 101; a `grep | tail -1` turned "70 passed, 7 failed" into "70 passed".""")
    print("=" * 78)


if __name__ == "__main__":
    sys.exit(main())
