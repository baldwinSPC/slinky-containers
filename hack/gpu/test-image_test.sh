#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Checks test-image.sh's count/<gpu> verdicts against a stub docker whose
# slurmd -G log is canned: the detected and registered counts agree, a GPU is
# detected and not registered, another number is detected, a number that ends
# in the wanted one is detected, the plugin never enumerates, and two GPUs
# register as two records.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin"
cat >"$work/bin/docker" <<'EOF'
#!/usr/bin/env bash
# Answers the docker calls test-image.sh makes for test/gpu:1 with --expect rsmi.
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
*"--entrypoint find"*) ;;
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

# verdict NAME WANT LOG: the count/rsmi line and the counts test-image.sh
# prints for LOG as the slurmd -G output, with --gpu-count rsmi=WANT.
verdict() {
	printf '%s\n' "$3" >"$work/$1.log"
	local out
	out="$(GRES_LOG="$work/$1.log" PATH="$work/bin:$PATH" bash "$HERE/test-image.sh" \
		--image test/gpu:1 --platform linux/amd64 --expect rsmi --gpu-count "rsmi=$2" 2>&1 || true)"
	grep -E '^(PASS|FAIL) count/rsmi|^executed=' <<<"$out" | tr '\n' '|'
}

check "agree" "$(verdict agree 1 "$LOADED
slurmd: 1 GPU system device(s) detected
$GRES_1")" "PASS count/rsmi|executed=8 planned=8 passed=8 failed=0|"

check "dropped" "$(verdict dropped 1 "$LOADED
slurmd: 1 GPU system device(s) detected")" "FAIL count/rsmi: detected 1, registered 0, want 1|executed=8 planned=8 passed=7 failed=1|"

check "other-number" "$(verdict other 1 "$LOADED
slurmd: 0 GPU system device(s) detected")" "FAIL count/rsmi: detected 0, want 1|executed=8 planned=8 passed=7 failed=1|"

check "ends-in-wanted" "$(verdict ten 0 "$LOADED
slurmd: 10 GPU system device(s) detected")" "FAIL count/rsmi: detected 10, want 0|executed=8 planned=8 passed=7 failed=1|"

check "no-enumeration" "$(verdict none 1 "$LOADED")" "FAIL count/rsmi: no 'GPU system device(s) detected' line: the plugin did not enumerate|executed=8 planned=8 passed=7 failed=1|"

check "zero" "$(verdict zero 0 "$LOADED
slurmd: 0 GPU system device(s) detected")" "PASS count/rsmi|executed=8 planned=8 passed=8 failed=0|"

check "two" "$(verdict two 2 "$LOADED
slurmd: 2 GPU system device(s) detected
$GRES_1
${GRES_1//renderD128/renderD129}")" "PASS count/rsmi|executed=8 planned=8 passed=8 failed=0|"

echo "executed=$EXECUTED failed=$FAILED"
((EXECUTED == 7 && FAILED == 0))
