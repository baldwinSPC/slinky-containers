#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Checks test-image.sh's verdicts against a stub docker. count/<gpu> reads a
# canned slurmd -G log: the detected and registered counts agree, a GPU is
# detected and not registered, another number is detected, a number that ends
# in the wanted one is detected, the plugin never enumerates, and two GPUs
# register as two records. driver/absent runs with podman's docker emulation
# printing its banner on stderr, with a driver file in the image, and with a
# find that does not run.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin"
cat >"$work/bin/docker" <<'EOF'
#!/usr/bin/env bash
# Answers the docker calls test-image.sh makes for test/gpu:1 with --expect rsmi.
# PODMAN_BANNER prints podman-docker's banner on every call, DRIVER_FILES are
# the paths find reports, and FIND_FAILS makes find fail to start.
if [[ -n ${PODMAN_BANNER:-} ]]; then
	echo "Emulate Docker CLI using podman. Create /etc/containers/nodocker to quiet msg." >&2
fi
if [[ $1 == image ]]; then
	exit 0
fi
if [[ $1 != run ]]; then
	echo "stub docker: unexpected arguments: $*" >&2
	exit 1
fi
case "$*" in
*"slurmd -G"*) cat "$GRES_LOG" ;;
*"--entrypoint slurmd test/gpu:1 -C"*)
	echo "slurmd: GPU RSMI plugin loaded"
	echo "slurmd: We were configured to autodetect nvml functionality, but we weren't able to find that lib when Slurm was configured."
	;;
*"--entrypoint slurmd test/gpu:1 -V"*) echo "slurm 26.05.4" ;;
*"ls -1 /usr/lib64/slurm/"*) echo "gpu_rsmi.so" ;;
*"/usr/share/licenses/slurm/"*) printf 'have COPYING\nhave DISCLAIMER\nhave LICENSE.OpenSSL\n1\n' ;;
*"nvml.h"*)
	if [[ -n ${FIND_FAILS:-} ]]; then
		echo "bash: line 1: find: command not found" >&2
		exit 127
	fi
	if [[ -n ${DRIVER_FILES:-} ]]; then
		printf '%s\n' "$DRIVER_FILES"
	fi
	if [[ $* == *"find exit"* ]]; then
		echo "find exit 0"
	fi
	;;
*)
	echo "stub docker: unexpected arguments: $*" >&2
	exit 1
	;;
esac
EOF
chmod +x "$work/bin/docker"

LOADED='slurmd: GRES: Using node-local AutoDetect=rsmi
slurmd: GPU RSMI plugin loaded'
GRES_1='slurmd: Gres Name=gpu Type=0x1002 Count=1 Index=128 ID=7696487 File=/dev/dri/renderD128 Cores=0-15 CoreCnt=32 Links=-1 Flags=HAS_FILE,HAS_TYPE,ENV_RSMI'
AGREE="$LOADED
slurmd: 1 GPU system device(s) detected
$GRES_1"

EXECUTED=0
FAILED=0
check() {
	EXECUTED=$((EXECUTED + 1))
	if [[ $2 == "$3" ]]; then
		echo "PASS $1"
	else
		FAILED=$((FAILED + 1))
		echo "FAIL $1: want [$3] have [$2]"
	fi
}

# harness NAME WANT LOG [VAR=VALUE...]: what test-image.sh prints for LOG as
# the slurmd -G output, with --gpu-count rsmi=WANT and the stub's settings.
harness() {
	local name="$1" want="$2"
	printf '%s\n' "$3" >"$work/$name.log"
	shift 3
	env GRES_LOG="$work/$name.log" PATH="$work/bin:$PATH" ${@+"$@"} bash "$HERE/test-image.sh" \
		--image test/gpu:1 --platform linux/amd64 --expect rsmi --gpu-count "rsmi=$want" 2>&1 || true
}

# verdict ID OUTPUT: the ID assertion's line and the counts, joined by |.
verdict() {
	grep -E "^(PASS|FAIL) $1(:|\$)|^executed=" <<<"$2" | tr '\n' '|'
}

check "agree" "$(verdict count/rsmi "$(harness agree 1 "$AGREE")")" \
	"PASS count/rsmi|executed=8 planned=8 passed=8 failed=0|"

check "dropped" "$(verdict count/rsmi "$(harness dropped 1 "$LOADED
slurmd: 1 GPU system device(s) detected")")" \
	"FAIL count/rsmi: detected 1, registered 0, want 1|executed=8 planned=8 passed=7 failed=1|"

check "other-number" "$(verdict count/rsmi "$(harness other 1 "$LOADED
slurmd: 0 GPU system device(s) detected")")" \
	"FAIL count/rsmi: detected 0, want 1|executed=8 planned=8 passed=7 failed=1|"

check "ends-in-wanted" "$(verdict count/rsmi "$(harness ten 0 "$LOADED
slurmd: 10 GPU system device(s) detected")")" \
	"FAIL count/rsmi: detected 10, want 0|executed=8 planned=8 passed=7 failed=1|"

check "no-enumeration" "$(verdict count/rsmi "$(harness none 1 "$LOADED")")" \
	"FAIL count/rsmi: no 'GPU system device(s) detected' line: the plugin did not enumerate|executed=8 planned=8 passed=7 failed=1|"

check "zero" "$(verdict count/rsmi "$(harness zero 0 "$LOADED
slurmd: 0 GPU system device(s) detected")")" \
	"PASS count/rsmi|executed=8 planned=8 passed=8 failed=0|"

check "two" "$(verdict count/rsmi "$(harness two 2 "$LOADED
slurmd: 2 GPU system device(s) detected
$GRES_1
${GRES_1//renderD128/renderD129}")")" \
	"PASS count/rsmi|executed=8 planned=8 passed=8 failed=0|"

banner="$(harness banner 1 "$AGREE" PODMAN_BANNER=1)"
check "podman-banner" "$(verdict driver/absent "$banner")$(grep '^gpu plugins:' <<<"$banner")" \
	"PASS driver/absent|executed=8 planned=8 passed=8 failed=0|gpu plugins: gpu_rsmi.so "

check "driver-file" "$(verdict driver/absent "$(harness file 1 "$AGREE" DRIVER_FILES=/usr/lib64/libnvidia-ml.so.1)")" \
	"FAIL driver/absent: 1 file(s): /usr/lib64/libnvidia-ml.so.1 |executed=8 planned=8 passed=7 failed=1|"

check "find-did-not-run" "$(verdict driver/absent "$(harness nofind 1 "$AGREE" FIND_FAILS=1)")" \
	"FAIL driver/absent: find did not run to completion|executed=8 planned=8 passed=7 failed=1|"

echo "executed=$EXECUTED failed=$FAILED"
((EXECUTED == 10 && FAILED == 0))
