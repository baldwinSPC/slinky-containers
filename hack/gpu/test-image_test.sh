#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Checks test-image.sh's verdicts against a stub docker. count/<gpu> reads a
# canned slurmd -G log: the detected and registered counts agree, a GPU is
# detected and not registered, another number is detected, a number that ends
# in the wanted one is detected, the plugin never enumerates, and two GPUs
# register as two records. driver/absent runs with podman's docker emulation
# printing its banner on stderr, with a driver file in the image, and with a
# find that does not run. The GPU runs model the runtime: --gpus injects
# libnvidia-ml.so.1 and must reach only slurmd -C and slurmd -G, and --device
# must reach slurmd -G for the GPU to be seen.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin"
cat >"$work/bin/docker" <<'EOF'
#!/usr/bin/env bash
# Answers the docker calls test-image.sh makes for test/gpu:1.
# IMAGE_GPUS is the image's gpu plugin, rsmi (the default) or nvml. A run given
# --gpus has libnvidia-ml.so.1 injected, as the NVIDIA toolkit does. With
# REQUIRE_GPU, slurmd -G prints GRES_LOG only when --gpus or --device reached
# it, and otherwise what the plugin logs with no GPU. PODMAN_BANNER prints
# podman-docker's banner on every call, DRIVER_FILES are driver files in the
# image, and FIND_FAILS makes find fail to start.
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
injected=false
gpu_passed=false
for a in "$@"; do
	case "$a" in
	--gpus) injected=true gpu_passed=true ;;
	--device) gpu_passed=true ;;
	esac
done
image_gpus="${IMAGE_GPUS:-rsmi}"
case "$*" in
*"slurmd -G"*)
	if [[ -z ${REQUIRE_GPU:-} ]] || $gpu_passed; then
		cat "$GRES_LOG"
	elif [[ $image_gpus == nvml ]]; then
		echo "slurmd: GRES: Using node-local AutoDetect=nvml"
		echo "slurmd: We were configured with nvml functionality, but that lib wasn't found on the system."
	else
		echo "slurmd: GRES: Using node-local AutoDetect=rsmi"
		echo "slurmd: GPU RSMI plugin loaded"
		echo "slurmd: 0 GPU system device(s) detected"
	fi
	;;
*"--entrypoint slurmd test/gpu:1 -C"*)
	if [[ $image_gpus == nvml ]]; then
		echo "slurmd: Configured with rsmi, but rsmi isn't enabled during the build."
		if $injected; then
			echo "slurmd: GPU NVML plugin loaded"
		else
			echo "slurmd: We were configured with nvml functionality, but that lib wasn't found on the system."
		fi
	else
		echo "slurmd: GPU RSMI plugin loaded"
		echo "slurmd: We were configured to autodetect nvml functionality, but we weren't able to find that lib when Slurm was configured."
	fi
	;;
*"--entrypoint slurmd test/gpu:1 -V"*) echo "slurm 26.05.4" ;;
*"ls -1 /usr/lib64/slurm/"*) echo "gpu_${image_gpus}.so" ;;
*"/usr/share/licenses/slurm/"*) printf 'have COPYING\nhave DISCLAIMER\nhave LICENSE.OpenSSL\n1\n' ;;
*"nvml.h"*)
	if [[ -n ${FIND_FAILS:-} ]]; then
		echo "bash: line 1: find: command not found" >&2
		exit 127
	fi
	if [[ -n ${DRIVER_FILES:-} ]]; then
		printf '%s\n' "$DRIVER_FILES"
	fi
	if $injected; then
		echo "/usr/lib64/libnvidia-ml.so.1"
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
NVML_AGREE='slurmd: GRES: Using node-local AutoDetect=nvml
slurmd: GPU NVML plugin loaded
slurmd: 1 GPU system device(s) detected
slurmd: Gres Name=gpu Type=nvidia_gb10 Count=1 Index=0 ID=7696487 File=/dev/nvidia0 Cores=0-19 CoreCnt=20 Links=-1 Flags=HAS_FILE,HAS_TYPE,ENV_NVML'

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

# harness_run NAME LOG [VAR=VALUE...] -- ARGS...: what test-image.sh prints
# for LOG as the slurmd -G output, with the stub's settings and ARGS.
harness_run() {
	local name="$1"
	printf '%s\n' "$2" >"$work/$name.log"
	shift 2
	local settings=()
	while [[ $1 != -- ]]; do
		settings+=("$1")
		shift
	done
	shift
	env GRES_LOG="$work/$name.log" PATH="$work/bin:$PATH" ${settings[@]+"${settings[@]}"} bash "$HERE/test-image.sh" \
		--image test/gpu:1 --platform linux/amd64 "$@" 2>&1 || true
}

# harness NAME WANT LOG [VAR=VALUE...]: harness_run for the rsmi image with
# --gpu-count rsmi=WANT.
harness() {
	local name="$1" want="$2" log="$3"
	shift 3
	harness_run "$name" "$log" ${@+"$@"} -- --expect rsmi --gpu-count "rsmi=$want"
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

check "device-reaches-gres" "$(verdict count/rsmi "$(harness_run device "$AGREE" REQUIRE_GPU=1 -- \
	--expect rsmi --device /dev/kfd --device /dev/dri --gpu-count rsmi=1)")" \
	"PASS count/rsmi|executed=8 planned=8 passed=8 failed=0|"

nvml="$(harness_run gpus "$NVML_AGREE" IMAGE_GPUS=nvml REQUIRE_GPU=1 -- --expect nvml --gpus all --gpu-count nvml=1)"
check "gpus-reach-autodetection-only" "$(grep -E '^FAIL ' <<<"$nvml" | tr '\n' '|')$(verdict count/nvml "$nvml")" \
	"PASS count/nvml|executed=8 planned=8 passed=8 failed=0|"

check "gpus-absent" "$(verdict probe/nvml "$(harness_run nogpus "$NVML_AGREE" IMAGE_GPUS=nvml REQUIRE_GPU=1 -- \
	--expect nvml --gpu-count nvml=1)")" \
	"PASS probe/nvml|executed=8 planned=8 passed=7 failed=1|"

echo "executed=$EXECUTED failed=$FAILED"
((EXECUTED == 13 && FAILED == 0))
