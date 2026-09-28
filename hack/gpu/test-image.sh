#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Checks a slurmd image's GPU autodetection without a GPU: which gpu plugins it
# carries, that Slurm loads them through slurmd -C and through slurmd -G with a
# stub gres.conf, that nothing from the NVIDIA driver is inside it, and that its
# Slurm is the same release as the given reference images.
#
# Prints PASS <id> or FAIL <id> for every assertion and then the counts. Exits 0
# only when every planned assertion ran and passed.

set -euo pipefail

usage() {
	cat <<EOF
usage: $(basename "$0") --image REF --platform PLATFORM --expect "nvml rsmi" [options]

  --image REF              image to check
  --platform PLATFORM      linux/amd64 or linux/arm64; must be the host's for slurmd to run
  --expect LIST            gpu autodetect plugins the image must carry, from "nvml rsmi";
                           the rest must be absent
  --nvml-stub FILE         a libnvidia-ml.so.1 to mount for the load check; never part of an image
  --same-slurm-as BIN=REF  BIN -V in REF must print what slurmd -V prints in the image (repeatable)
  --pyxis                  the image must carry pyxis and enroot
  --plugins-of REF         every Slurm plugin slurmd can load from REF, the image this one
                           replaces, must be in the image too, less the exceptions below
EOF
}

IMAGE=""
PLATFORM=""
EXPECT=""
NVML_STUB=""
SAME_AS=()
PYXIS=false
PLUGINS_OF=""
while (($#)); do
	case "$1" in
	--image)
		IMAGE="$2"
		shift 2
		;;
	--platform)
		PLATFORM="$2"
		shift 2
		;;
	--expect)
		EXPECT="$2"
		shift 2
		;;
	--nvml-stub)
		NVML_STUB="$2"
		shift 2
		;;
	--same-slurm-as)
		SAME_AS+=("$2")
		shift 2
		;;
	--pyxis)
		PYXIS=true
		shift
		;;
	--plugins-of)
		PLUGINS_OF="$2"
		shift 2
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		echo "unknown argument: $1" >&2
		usage >&2
		exit 2
		;;
	esac
done
if [[ -z $IMAGE || -z $PLATFORM ]]; then
	usage >&2
	exit 2
fi
for gpu in $EXPECT; do
	case "$gpu" in
	nvml | rsmi) ;;
	*)
		echo "--expect: unknown gpu autodetect plugin: $gpu" >&2
		exit 2
		;;
	esac
done
if [[ -n $NVML_STUB && ! -f $NVML_STUB ]]; then
	echo "--nvml-stub: no such file: $NVML_STUB" >&2
	exit 2
fi

expects() {
	[[ " $EXPECT " == *" $1 "* ]]
}

# A multi-platform index is run through its per-platform manifest: Docker
# Desktop's containerd store refuses to re-pull an index digest for a second
# platform ("cannot overwrite digest").
platform_ref() {
	local ref="$1" raw
	if [[ $ref != *@sha256:* ]] || ! raw="$(docker buildx imagetools inspect --raw "$ref" 2>/dev/null)"; then
		echo "$ref"
		return
	fi
	local os="${PLATFORM%%/*}" arch="${PLATFORM#*/}" digest
	digest="$(jq -r --arg os "$os" --arg arch "$arch" \
		'if .manifests then [.manifests[] | select(.platform.os == $os and .platform.architecture == $arch)][0].digest // empty else empty end' <<<"$raw")"
	if [[ -z $digest ]]; then
		echo "$ref"
		return
	fi
	echo "${ref%@*}@${digest}"
}

# Output of a command in the image, stdout and stderr; a failure to run shows
# up as missing lines in the assertions that read it. Images are pulled first
# so docker's own progress never lands in the output.
run_in() {
	local ref="$1" entrypoint="$2"
	shift 2
	pull "$ref"
	docker run --rm --platform "$PLATFORM" --entrypoint "$entrypoint" "$ref" "$@" 2>&1 || true
}

# Standard output only, for values compared as strings.
run_stdout() {
	local ref="$1" entrypoint="$2"
	shift 2
	pull "$ref"
	docker run --rm --platform "$PLATFORM" --entrypoint "$entrypoint" "$ref" "$@" 2>/dev/null || true
}

pull() {
	if ! docker image inspect "$1" >/dev/null 2>&1; then
		docker pull --quiet --platform "$PLATFORM" "$1" >/dev/null 2>&1 || true
	fi
}

PLANNED=0
EXECUTED=0
PASSED=0
FAILED=0

pass() {
	EXECUTED=$((EXECUTED + 1))
	PASSED=$((PASSED + 1))
	echo "PASS $1"
}

fail() {
	EXECUTED=$((EXECUTED + 1))
	FAILED=$((FAILED + 1))
	echo "FAIL $1: $2"
}

# check ID OUTPUT WANT... [-- UNWANTED...]
check() {
	local id="$1" out="$2"
	shift 2
	local unwanted=false s
	for s in "$@"; do
		if [[ $s == "--" ]]; then
			unwanted=true
			continue
		fi
		if ! $unwanted && ! grep -qF -- "$s" <<<"$out"; then
			fail "$id" "missing: $s"
			tail -n 25 <<<"$out" | sed 's/^/    | /'
			return
		fi
		if $unwanted && grep -qF -- "$s" <<<"$out"; then
			fail "$id" "present: $s"
			tail -n 25 <<<"$out" | sed 's/^/    | /'
			return
		fi
	done
	pass "$id"
}

# The lines Slurm 26.05 logs from _get_gpu_type (src/interfaces/gpu.c) and the
# gpu plugins' init().
NVML_NOT_BUILT="We were configured to autodetect nvml functionality, but we weren't able to find that lib when Slurm was configured."
NVML_NO_LIB="We were configured with nvml functionality, but that lib wasn't found on the system."
NVML_LOADED="GPU NVML plugin loaded"
RSMI_NOT_BUILT="Configured with rsmi, but rsmi isn't enabled during the build."
RSMI_NO_LIB="Configured with rsmi, but that lib wasn't found."
RSMI_LOADED="GPU RSMI plugin loaded"

# A throwaway configuration written inside the container, so its ownership and
# mode are root's on every host: a bind mount keeps the host's uid on linux.
gres_script() {
	cat <<EOF
set -eu
mkdir -p /tmp/gpu-test
cd /tmp/gpu-test
cat >slurm.conf <<'CONF'
ClusterName=gpu-autodetect-test
SlurmctldHost=localhost
AuthType=auth/slurm
CredType=cred/slurm
ProctrackType=proctrack/linuxproc
TaskPlugin=task/none
GresTypes=gpu
NodeName=gputest CPUs=1 RealMemory=100 Gres=gpu:1 State=UNKNOWN
PartitionName=test Nodes=gputest Default=YES State=UP
CONF
echo 'CgroupPlugin=disabled' >cgroup.conf
echo 'NodeName=gputest AutoDetect=$1' >gres.conf
dd if=/dev/urandom of=slurm.key bs=1024 count=1 2>/dev/null
chmod 600 slurm.key
exec slurmd -G -N gputest -f /tmp/gpu-test/slurm.conf -vvvv
EOF
}

IMAGE_REF="$(platform_ref "$IMAGE")"
echo "image:    $IMAGE"
echo "run as:   $IMAGE_REF ($PLATFORM)"
echo "expect:   ${EXPECT:-none}"
echo "nvml stub: ${NVML_STUB:-none}"

# Plan: 2 plugin inventory + 1 driver + 1 licence + 2 probes + 1 gres per
# expected plugin + a stub load and a symbol check when nvml is expected and a
# stub is given + 1 per reference.
PLANNED=$((2 + 1 + 1 + 2 + ${#SAME_AS[@]}))
for gpu in $EXPECT; do
	PLANNED=$((PLANNED + 1))
done
if expects nvml && [[ -n $NVML_STUB ]]; then
	PLANNED=$((PLANNED + 2))
fi
if $PYXIS; then
	PLANNED=$((PLANNED + 3))
fi
if [[ -n $PLUGINS_OF ]]; then
	PLANNED=$((PLANNED + 1))
fi

plugins="$(run_in "$IMAGE_REF" bash -c 'ls -1 /usr/lib64/slurm/ | grep -E "^gpu_" || true')"
echo "gpu plugins: $(tr '\n' ' ' <<<"$plugins")"
for gpu in nvml rsmi; do
	if expects "$gpu"; then
		if grep -qx "gpu_${gpu}.so" <<<"$plugins"; then pass "plugin/$gpu/present"; else fail "plugin/$gpu/present" "no /usr/lib64/slurm/gpu_${gpu}.so"; fi
	else
		if grep -qx "gpu_${gpu}.so" <<<"$plugins"; then fail "plugin/$gpu/absent" "found /usr/lib64/slurm/gpu_${gpu}.so"; else pass "plugin/$gpu/absent"; fi
	fi
done

driver_files="$(run_in "$IMAGE_REF" find / -xdev \( -name 'libnvidia-ml*' -o -name 'nvml.h' \) -print)"
driver_count="$(grep -c . <<<"$driver_files" || true)"
if [[ $driver_count == 0 ]]; then
	pass "driver/absent"
else
	fail "driver/absent" "$driver_count file(s): $(tr '\n' ' ' <<<"$driver_files")"
fi

# GPL-2.0 travels with the binary: slurm.spec installs no licence file, so the
# image carries Slurm's own.
licence="$(run_in "$IMAGE_REF" bash -c 'for f in COPYING DISCLAIMER LICENSE.OpenSSL; do head -c 4096 "/usr/share/licenses/slurm/$f" >/dev/null && echo "have $f"; done; grep -c "GNU GENERAL PUBLIC LICENSE" /usr/share/licenses/slurm/COPYING')"
check "licence/slurm" "$licence" "have COPYING" "have DISCLAIMER" "have LICENSE.OpenSSL" -- "No such file"

# slurmd -C tries every autodetect plugin itself; it never reads gres.conf.
probe="$(run_in "$IMAGE_REF" slurmd -C -vvvv)"
if expects nvml; then
	check "probe/nvml" "$probe" "$NVML_NO_LIB" -- "$NVML_NOT_BUILT"
else
	check "probe/nvml/unbuilt" "$probe" "$NVML_NOT_BUILT"
fi
if expects rsmi; then
	check "probe/rsmi" "$probe" "$RSMI_LOADED" -- "$RSMI_NO_LIB" "$RSMI_NOT_BUILT"
else
	check "probe/rsmi/unbuilt" "$probe" "$RSMI_NOT_BUILT"
fi

# slurmd -G reads gres.conf, the path a NodeSet's AutoDetect line takes.
for gpu in $EXPECT; do
	gres="$(run_in "$IMAGE_REF" bash -c "$(gres_script "$gpu")")"
	case "$gpu" in
	nvml) check "gres/nvml" "$gres" "GRES: Using node-local AutoDetect=nvml" "$NVML_NO_LIB" -- "$NVML_NOT_BUILT" ;;
	rsmi) check "gres/rsmi" "$gres" "GRES: Using node-local AutoDetect=rsmi" "$RSMI_LOADED" -- "$RSMI_NO_LIB" "$RSMI_NOT_BUILT" ;;
	esac
done

# With a libnvidia-ml.so.1 present the gpu/nvml plugin loads.
if expects nvml && [[ -n $NVML_STUB ]]; then
	stub_path="$(cd "$(dirname "$NVML_STUB")" && pwd)/$(basename "$NVML_STUB")"
	pull "$IMAGE_REF"
	stub="$(docker run --rm --platform "$PLATFORM" -v "$stub_path:/usr/lib64/libnvidia-ml.so.1:ro" \
		--entrypoint slurmd "$IMAGE_REF" -C -vvvv 2>&1 || true)"
	check "probe/nvml/stub" "$stub" "$NVML_LOADED" -- "$NVML_NO_LIB" "$NVML_NOT_BUILT"

	# Slurm loads the plugin lazily, so an NVML symbol missing from the library
	# surfaces only when called. Compare the plugin's imports with the exports.
	work="$(mktemp -d)"
	cid="$(docker create --platform "$PLATFORM" "$IMAGE_REF")"
	if docker cp "$cid:/usr/lib64/slurm/gpu_nvml.so" "$work/gpu_nvml.so" >/dev/null 2>&1; then
		nm -D --undefined-only "$work/gpu_nvml.so" | awk '$NF ~ /^nvml/ { print $NF }' | sort -u >"$work/imports"
		nm -D --defined-only "$stub_path" | awk '{ print $NF }' | sort -u >"$work/exports"
		missing="$(comm -23 "$work/imports" "$work/exports")"
		imports="$(grep -c . "$work/imports" || true)"
		echo "gpu_nvml.so imports $imports NVML symbols: $(tr '\n' ' ' <"$work/imports")"
		if [[ $imports == 0 ]]; then
			fail "symbols/nvml" "read no NVML imports from gpu_nvml.so"
		elif [[ -n $missing ]]; then
			fail "symbols/nvml" "not exported by the stub: $(tr '\n' ' ' <<<"$missing")"
		else
			pass "symbols/nvml"
		fi
	else
		fail "symbols/nvml" "could not copy gpu_nvml.so out of the image"
	fi
	docker rm "$cid" >/dev/null
	rm -rf "$work"
fi

if $PYXIS; then
	pyxis="$(run_in "$IMAGE_REF" bash -c '
		for f in /usr/lib64/slurm/spank_pyxis.so /usr/share/pyxis/pyxis.conf; do
			[ -f "$f" ] && echo "have $f"
		done
		[ -e /etc/slurm/plugstack.conf.d/pyxis.conf ] && echo "plugstack resolves"
		stat -c "plugstack.conf.d mode %a" /etc/slurm/plugstack.conf.d
		ldd /usr/lib64/slurm/spank_pyxis.so | grep "not found"
		echo "enroot $(enroot version)"
		echo "env ENROOT_VERSION=${ENROOT_VERSION} PYXIS_VERSION=${PYXIS_VERSION}"')"
	echo "$pyxis" | sed 's/^/pyxis: /'
	check "pyxis/plugin" "$pyxis" "have /usr/lib64/slurm/spank_pyxis.so" "have /usr/share/pyxis/pyxis.conf" -- "not found"
	check "pyxis/plugstack" "$pyxis" "plugstack resolves" "plugstack.conf.d mode 755"
	enroot_env="$(sed -n 's/^env ENROOT_VERSION=\([^ ]*\) .*/\1/p' <<<"$pyxis")"
	if [[ -n $enroot_env ]]; then
		check "pyxis/enroot" "$pyxis" "enroot $enroot_env"
	else
		fail "pyxis/enroot" "ENROOT_VERSION is not set in the image"
	fi
fi

# Plugins in the replaced image that slurmd does not need, each with its reason.
PLUGIN_EXCEPTIONS=(
	# slurmdbd's storage plugin; slurm.spec packages it in slurm-slurmdbd.
	accounting_storage_mysql.so
	# slurm.spec deletes these five after make install.
	auth_none.so cred_none.so job_submit_defaults.so job_submit_logging.so job_submit_partition.so
	# A slurmctld job completion plugin; EL9 ships no librdkafka to build it with.
	jobcomp_kafka.so
	# PMIx 5 is the ubuntu image's; EL9 ships PMIx 3, whose plugin is mpi_pmix_v3.so.
	mpi_pmix_v5.so
)
if [[ -n $PLUGINS_OF ]]; then
	list_plugins='for f in /usr/lib64/slurm/*.so /usr/lib/*/slurm/*.so; do [ -e "$f" ] && basename "$f"; done | sort -u'
	ours="$(run_stdout "$IMAGE_REF" bash -c "$list_plugins")"
	theirs="$(run_stdout "$(platform_ref "$PLUGINS_OF")" bash -c "$list_plugins")"
	missing="$(comm -13 <(echo "$ours") <(echo "$theirs") | grep -v -x -F -f <(printf '%s\n' "${PLUGIN_EXCEPTIONS[@]}") || true)"
	echo "plugins: image $(grep -c . <<<"$ours" || true), $PLUGINS_OF $(grep -c . <<<"$theirs" || true)"
	if [[ -z $theirs ]]; then
		fail "plugins/parity" "listed no plugins in $PLUGINS_OF"
	elif [[ -n $missing ]]; then
		fail "plugins/parity" "in $PLUGINS_OF and not in the image: $(tr '\n' ' ' <<<"$missing")"
	else
		pass "plugins/parity"
	fi
fi

version="$(run_stdout "$IMAGE_REF" slurmd -V)"
echo "slurmd -V: $version"
for spec in ${SAME_AS[@]+"${SAME_AS[@]}"}; do
	bin="${spec%%=*}"
	ref="$(platform_ref "${spec#*=}")"
	theirs="$(run_stdout "$ref" "$bin" -V)"
	echo "$bin -V in $ref: $theirs"
	if [[ -n $version && $version == "$theirs" ]]; then
		pass "version/$bin"
	else
		fail "version/$bin" "image: '$version', $bin in $ref: '$theirs'"
	fi
done

echo "executed=$EXECUTED planned=$PLANNED passed=$PASSED failed=$FAILED"
if ((EXECUTED != PLANNED)); then
	echo "ran $EXECUTED of $PLANNED planned assertions" >&2
	exit 1
fi
((FAILED == 0))
