#!/usr/bin/env bash
# Build the passport verifiers that macOS cannot build, in a pinned Linux container.
#
#   ./build-passport-verifiers-docker.sh                 # the profiles listed below
#   ./build-passport-verifiers-docker.sh <name> [<name>] # specific profiles
#
# See passport-verifiers.Dockerfile for WHY these five cannot be built natively - it is a 2 GiB
# single-syscall limit on macOS, not a memory problem, and no RAM or swap setting reaches it.
#
# The CRS lives in a NAMED VOLUME so the ~2 GiB download happens once and survives container removal.
# The repo is mounted, so the generated .sol land straight in the working tree and show up in
# `git status` exactly as the natively-built ones do.
set -euo pipefail

CIRCUITS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${CIRCUITS_DIR}/../.." && pwd)"
IMAGE="ibiza-passport-verifiers:beta26-bb5.1.0"

# The profiles that need a 2^25-point CRS. Everything else builds natively; there is no reason to
# pay container startup and a re-download for them.
DEFAULT_PROFILES=(
  25_384_3_5_576_248_20_3768_3_2008
  26_512_3_3_336_248_NA
  26_512_3_3_336_264_1_1968_2_256
  27_512_3_4_336_248_NA
  28_384_3_3_576_264_24_2024_4_2792
)
if [ "$#" -gt 0 ]; then PROFILES=("$@"); else PROFILES=("${DEFAULT_PROFILES[@]}"); fi

command -v docker >/dev/null || { echo "docker is not on PATH" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "the docker daemon is not responding - is Docker Desktop running?" >&2; exit 1; }

# CHECK MEMORY BEFORE SPENDING TWENTY MINUTES ON IT. An under-provisioned VM does not fail cleanly,
# it gets the process OOM-killed - the same trap this project already hit with cargo under Docker.
# HOW MUCH MEMORY, MEASURED RATHER THAN GUESSED. bb's peak is set by the circuit's polynomials
# (2^25 field elements x 32 bytes each), so it does NOT respond to any scheduling knob. All of these
# were tried against a known-failing profile and NONE moved the peak off 11.2 GiB:
#   HARDWARE_CONCURRENCY=2   (bb honours it - "num threads: 2" - and the peak did not change)
#   BB_STORAGE_BUDGET        (no effect; an earlier claim that it halved memory was a false positive
#                             from comparing two DIFFERENT circuits)
#   --cpuset-cpus            (silently ignored - bb reads host CPU count, still reported 8 threads)
#   3 GiB of VM swap         (kernel OOM-killed with 2.7 GiB of it still FREE: the allocation
#                             outran reclaim, so swap does not rescue this)
#   pre-seeding a 2^25 CRS   (bb dies before it reaches the CRS)
# The kernel's own record is the authority: anon-rss:11690980kB, task=bb, global_oom.
#
# 72 of the 75 profiles build in a ~10 GiB VM. THREE DO NOT AND CANNOT HERE - they need roughly
# 13-14 GiB, which is not safe to allocate on a 16 GB host:
#   25_384_3_5_576_248_20_3768_3_2008, 27_512_3_4_336_248_NA, 28_384_3_3_576_264_24_2024_4_2792
# Those three want a bigger machine, not a different setting.
mem_bytes="$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)"
mem_gib=$(( mem_bytes / 1073741824 ))
echo "Docker VM memory: ${mem_gib} GiB"
if [ "${mem_gib}" -lt 9 ]; then
  cat >&2 <<EOF

REFUSING TO START: the VM has ${mem_gib} GiB. Most profiles need ~10 GiB; the three named above need ~13-14.

  Docker Desktop -> Settings -> Resources -> Memory: ~10 GiB
  (or less memory plus 4 GiB of Swap - VM swap is a file on disk, so it costs disk, not host RAM)

That setting is GUI-only and cannot be scripted. Nothing has been built; rerun when it is raised.
EOF
  exit 1
fi

echo "building ${IMAGE} (cached after the first run)"
docker build --platform linux/amd64 -f "${CIRCUITS_DIR}/passport-verifiers.Dockerfile" -t "${IMAGE}" "${CIRCUITS_DIR}"

printf '%s\n' "${PROFILES[@]}" > "${CIRCUITS_DIR}/.docker-profiles.txt"
trap 'rm -f "${CIRCUITS_DIR}/.docker-profiles.txt"' EXIT

echo "building ${#PROFILES[@]} profile(s) in the container"
docker run --rm --platform linux/amd64 \
  -v "${REPO_ROOT}":/repo \
  -v ibiza-bb-crs:/root/.bb-crs \
  -w /repo/backend/circuits \
  -e ONLY_FILE=/repo/backend/circuits/.docker-profiles.txt \
  "${IMAGE}" \
  ./codegen-passport-verifiers.sh

echo
echo "NEXT, on the host:"
echo "  python3 <scratch>/validate_passport_verifiers.py   # structural checks over the whole set"
echo "  cd ../contracts && forge build --sizes && forge test"
