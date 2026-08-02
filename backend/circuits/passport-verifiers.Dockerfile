# Linux toolchain for the passport verifiers that CANNOT be built on macOS.
#
# WHY THIS EXISTS - and it is not about RAM. The largest profiles need a CRS of 2^25 points, which is
# EXACTLY 2 GiB. bb reads and writes the CRS whole-file in a single syscall, and macOS caps one
# read()/write() at INT_MAX, so both directions fail with EINVAL. Measured with dd rather than
# inferred: a single 2 GiB read transfers 0 bytes and fails, while 2 GiB minus 64 reads at 2.4 GB/s.
# It fails when bb writes the decompressed CRS AND when it is handed one ready-made, and
# BB_SLOW_LOW_MEMORY=1 does not change that path. Linux has no such limit.
#
# STOCK nargo IS CORRECT HERE. The passport crates compile on released beta.26 - the BigNumParams
# accommodation in noir_dl_lib was kept precisely so they do - and stock and our patched build emit a
# BYTE-IDENTICAL artifact for them (md5 8ea5345bad87c71a45808ae4b6179c99 either way). The patch fixes
# an ICE; where nothing ICEs, nothing differs. So a container needs no rebuilt compiler and its
# output is consistent with the profiles built natively.
#
# bb IS PINNED EXACTLY. A different bb produces a different verification key, which would make these
# verifiers disagree with the rest of the set.
#
# MEMORY: bb peaks near 9.7 GiB computing the proving key for these circuits. Give the Docker VM
# ~10 GiB, or less RAM plus swap - VM swap is disk-backed, so it costs disk rather than host memory.
# build-passport-verifiers-docker.sh checks this before it starts and tells you what it found.
FROM --platform=linux/amd64 ubuntu:24.04

ARG NARGO_VERSION=1.0.0-beta.26
ARG BB_VERSION=5.1.0

# git IS REQUIRED, not incidental: noir_dl_lib pulls its dependencies (poseidon, sort, sha256)
# from git, and nargo shells out to clone them. Without it nargo PANICS with
# "git clone command failed to start" rather than reporting a missing tool.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl python3 libstdc++6 libgomp1 \
      git \
    && rm -rf /var/lib/apt/lists/*

# nargo (stock release - see the note above on why that is the right choice here)
RUN curl -fsSL -o /tmp/nargo.tar.gz \
      "https://github.com/noir-lang/noir/releases/download/v${NARGO_VERSION}/nargo-x86_64-unknown-linux-gnu.tar.gz" \
    && tar -xzf /tmp/nargo.tar.gz -C /usr/local/bin \
    && rm /tmp/nargo.tar.gz \
    && nargo --version

# barretenberg, pinned. The archive holds a BARE `bb` with no directory prefix, so it extracts into
# bin/ directly - extracting to /usr/local would leave it at /usr/local/bb, off PATH.
RUN curl -fsSL -o /tmp/bb.tar.gz \
      "https://github.com/AztecProtocol/aztec-packages/releases/download/v${BB_VERSION}/barretenberg-amd64-linux.tar.gz" \
    && tar -xzf /tmp/bb.tar.gz -C /usr/local/bin \
    && rm /tmp/bb.tar.gz \
    && chmod +x /usr/local/bin/bb \
    && bb --version

# Fail the BUILD, not some later run, if either pin drifted. An image that quietly carries the wrong
# bb would emit verifiers that disagree with every other one in the repo.
RUN test "$(nargo --version | sed -n 's/^nargo version = //p' | head -1)" = "${NARGO_VERSION}" \
    && test "$(bb --version | head -1)" = "${BB_VERSION}" \
    && echo "toolchain pinned: nargo ${NARGO_VERSION}, bb ${BB_VERSION}"

WORKDIR /repo/backend/circuits
