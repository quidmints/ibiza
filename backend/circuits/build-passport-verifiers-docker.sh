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

# CHECK MEMORY BEFORE SPENDING TWENTY MINUTES ON IT. bb peaks near 9.7 GiB on these circuits; an
# under-provisioned VM does not fail cleanly, it gets the process OOM-killed with no diagnostic at
# all - the same trap this project already hit with cargo under Docker.
mem_bytes="$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)"
mem_gib=$(( mem_bytes / 1073741824 ))
echo "Docker VM memory: ${mem_gib} GiB"
if [ "${mem_gib}" -lt 9 ]; then
  cat >&2 <<EOF

REFUSING TO START: the VM has ${mem_gib} GiB and bb needs ~9.7 GiB for these circuits.

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
