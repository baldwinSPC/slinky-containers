#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Checks a login image that submits pyxis jobs: that it carries pyxis and
# enroot, that srun loads the pyxis SPANK plugin from a plugstack.conf and
# offers --container-image, that srun can load mpi/pmix, that its Slurm is the
# release the reference images run, and that it carries every Slurm plugin the
# login image it replaces carries, that a login shell's module avail lists an
# nccl module and loading it finds libnccl, and that libnccl is in the image.
# srun runs against a throwaway slurm.conf and never contacts a controller.
#
# Prints PASS <id> or FAIL <id> for every assertion and then the counts. Exits 0
# only when every planned assertion ran and passed.

set -euo pipefail

usage() {
	cat <<EOF
usage: $(basename "$0") --image REF --platform PLATFORM [options]

  --image REF              image to check
  --platform PLATFORM      linux/amd64 or linux/arm64; must be the host's for srun to run
  --same-slurm-as BIN=REF  BIN -V in REF must print what srun -V prints in the image (repeatable)
  --plugins-of REF         every Slurm plugin in REF, the login image this one replaces,
                           must be in the image too, less the exceptions below
EOF
}

IMAGE=""
PLATFORM=""
SAME_AS=()
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
	--same-slurm-as)
		SAME_AS+=("$2")
		shift 2
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

pull() {
	if ! docker image inspect "$1" >/dev/null 2>&1; then
		docker pull --quiet --platform "$PLATFORM" "$1" >/dev/null 2>&1 || true
	fi
}

# Output of a command in the image, stdout and stderr; a failure to run shows
# up as missing lines in the assertions that read it.
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

# A throwaway configuration written inside the container, so its ownership and
# mode are root's on every host. The first argument is plugstack.conf's one
# line and the second the srun command. The pyxis check names the plugin
# directly, as the Slurm cluster's own plugstack.conf does, so a missing plugin
# is an error and not a skipped include; the other checks load no plugin, so
# they do not depend on pyxis.
srun_script() {
	cat <<EOF
set -eu
mkdir -p /tmp/login-test
cd /tmp/login-test
cat >slurm.conf <<CONF
ClusterName=login-test
SlurmctldHost=localhost
AuthType=auth/slurm
CredType=cred/slurm
PlugStackConfig=/tmp/login-test/plugstack.conf
NodeName=n1 CPUs=1 State=UNKNOWN
PartitionName=test Nodes=n1 Default=YES State=UP
CONF
echo '$1' >plugstack.conf
dd if=/dev/urandom of=slurm.key bs=1024 count=1 2>/dev/null
chmod 600 slurm.key
export SLURM_CONF=/tmp/login-test/slurm.conf
$2
EOF
}
PYXIS_LINE="required /usr/lib64/slurm/spank_pyxis.so"
NO_PLUGIN="# no SPANK plugin"

IMAGE_REF="$(platform_ref "$IMAGE")"
echo "image:    $IMAGE"
echo "run as:   $IMAGE_REF ($PLATFORM)"

# Plan: 3 pyxis + 1 srun/pyxis + 1 mpi + 1 licence + 2 lmod + 1 nccl + 1 per
# reference + 1 parity.
PLANNED=$((3 + 1 + 1 + 1 + 2 + 1 + ${#SAME_AS[@]}))
if [[ -n $PLUGINS_OF ]]; then
	PLANNED=$((PLANNED + 1))
fi

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

# srun prints the options its SPANK plugins register in --help, so the option
# is there only when srun loaded pyxis.
help="$(run_in "$IMAGE_REF" bash -c "$(srun_script "$PYXIS_LINE" 'srun --help')")"
check "srun/pyxis" "$help" "--container-image" -- "spank: "

# srun loads the MPI plugin --mpi names on the submitting side.
mpi="$(run_in "$IMAGE_REF" bash -c "$(srun_script "$NO_PLUGIN" 'srun --mpi=list')")"
echo "$mpi" | sed 's/^/mpi: /'
if grep -qE '^[[:space:]]*pmix([[:space:]]|$)' <<<"$mpi"; then
	pass "mpi/pmix"
else
	fail "mpi/pmix" "srun --mpi=list does not list pmix"
fi

# GPL-2.0 travels with the binary: slurm.spec installs no licence file, so the
# image carries Slurm's own.
licence="$(run_in "$IMAGE_REF" bash -c 'for f in COPYING DISCLAIMER LICENSE.OpenSSL; do head -c 4096 "/usr/share/licenses/slurm/$f" >/dev/null && echo "have $f"; done')"
check "licence/slurm" "$licence" "have COPYING" "have DISCLAIMER" "have LICENSE.OpenSSL" -- "No such file"

# A login shell reads /etc/profile.d, where Lmod defines module. Lmod prints
# avail on stderr. A ClusterMAX harness passes lmod when avail lists a cuda,
# hpcx or nccl module.
avail="$(run_in "$IMAGE_REF" bash -lc 'module avail 2>&1; echo "module exit $?"')"
echo "$avail" | sed 's/^/lmod: /'
if ! grep -qx 'module exit 0' <<<"$avail"; then
	fail "lmod/avail" "module avail did not succeed in a login shell"
elif ! grep -qE '(^|[[:space:]])nccl/[0-9]' <<<"$avail"; then
	fail "lmod/avail" "module avail lists no nccl module"
else
	pass "lmod/avail"
fi

# The nccl module names an NCCL that is in the image.
load="$(run_in "$IMAGE_REF" bash -lc 'module load nccl 2>&1 && echo "NCCL_HOME=$NCCL_HOME" && ls "$NCCL_HOME"/lib64/libnccl.so.2')"
check "lmod/load" "$load" "NCCL_HOME=/" "/lib64/libnccl.so.2" -- "command not found" "No such file" "Lmod has detected"

# The search a ClusterMAX harness runs; only paths count, and find reports its
# exit status last.
nccl_out="$(run_in "$IMAGE_REF" bash -c 'find /usr /opt /lib /lib64 -name "libnccl.so*" -print; echo "find exit $?"')"
nccl_files="$(grep '^/' <<<"$nccl_out" || true)"
echo "nccl: $(tr '\n' ' ' <<<"$nccl_files")"
if ! grep -qx 'find exit 0' <<<"$nccl_out"; then
	fail "nccl/present" "find did not run to completion"
	tail -n 25 <<<"$nccl_out" | sed 's/^/    | /'
elif [[ -z $nccl_files ]]; then
	fail "nccl/present" "no libnccl.so* under /usr /opt /lib /lib64"
else
	pass "nccl/present"
fi

# Plugins in the replaced image that srun does not need, each with its reason.
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

# srun reads slurm.conf before it prints its version.
version="$(run_stdout "$IMAGE_REF" bash -c "$(srun_script "$NO_PLUGIN" 'srun -V')")"
echo "srun -V: $version"
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
