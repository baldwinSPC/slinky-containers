#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Checks what clustermax_audit adds to login_gpu_pyxis: jq and python3, the
# ClusterMAX tree at the pinned commit with its audit entry point and Slurm
# collector, ClusterMAX's LICENSE at the pinned sha256, the image's command, and
# that the wrapper refuses to run outside a Slurm allocation. test-login.sh
# checks the login underneath.
#
# Prints PASS <id> or FAIL <id> for every assertion and then the counts. Exits 0
# only when every planned assertion ran and passed.

set -euo pipefail

usage() {
	cat <<EOF
usage: $(basename "$0") --image REF --platform PLATFORM --commit SHA --licence-sha256 SHA256

  --image REF              image to check
  --platform PLATFORM      linux/amd64 or linux/arm64; must be the host's
  --commit SHA             the ClusterMAX commit the image must carry
  --licence-sha256 SHA256  the sha256 its LICENSE must have
EOF
}

IMAGE=""
PLATFORM=""
COMMIT=""
LICENCE_SHA256=""
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
	--commit)
		COMMIT="$2"
		shift 2
		;;
	--licence-sha256)
		LICENCE_SHA256="$2"
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
if [[ -z $IMAGE || -z $PLATFORM || -z $COMMIT || -z $LICENCE_SHA256 ]]; then
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

# Output of a bash script in the image, stdout and stderr; a failure to run
# shows up as missing lines in the assertions that read it.
run_in() {
	local ref="$1"
	shift
	pull "$ref"
	docker run --rm --platform "$PLATFORM" --entrypoint bash "$ref" -c "$1" 2>&1 || true
}

PLANNED=7
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

# check ID OUTPUT WANT...
check() {
	local id="$1" out="$2" s
	shift 2
	for s in "$@"; do
		if ! grep -qF -- "$s" <<<"$out"; then
			fail "$id" "missing: $s"
			tail -n 25 <<<"$out" | sed 's/^/    | /'
			return
		fi
	done
	pass "$id"
}

IMAGE_REF="$(platform_ref "$IMAGE")"
echo "image:    $IMAGE"
echo "run as:   $IMAGE_REF ($PLATFORM)"

tools="$(run_in "$IMAGE_REF" 'echo "jq: $(jq --version)"; echo "python3: $(python3 --version 2>&1)"')"
echo "$tools" | sed 's/^/tools: /'
check "tools/jq" "$tools" "jq: jq-1."
check "tools/python3" "$tools" "python3: Python 3."

tree="$(run_in "$IMAGE_REF" '
	d=/opt/clustermax/cmax/scripts/1-audit
	[ -x "$d/run.sh" ] && echo "have run.sh"
	[ -f "$d/cluster-audit-slurm.sh" ] && echo "have the slurm collector"
	[ -x /usr/local/bin/clustermax-audit ] && echo "have clustermax-audit"
	echo "commit file $(cat /usr/share/licenses/clustermax/COMMIT)"
	echo "commit env ${CLUSTERMAX_COMMIT:-}"')"
echo "$tree" | sed 's/^/tree: /'
check "clustermax/tree" "$tree" "have run.sh" "have the slurm collector" "have clustermax-audit"
check "clustermax/commit" "$tree" "commit file $COMMIT" "commit env $COMMIT"

# Apache-2.0 section 4(a): the licence travels with the scripts.
licence="$(run_in "$IMAGE_REF" 'sha256sum /usr/share/licenses/clustermax/LICENSE /opt/clustermax/LICENSE')"
echo "$licence" | sed 's/^/licence: /'
check "licence/clustermax" "$licence" \
	"$LICENCE_SHA256  /usr/share/licenses/clustermax/LICENSE" "$LICENCE_SHA256  /opt/clustermax/LICENSE"

pull "$IMAGE_REF"
cmd="$(docker image inspect --format '{{json .Config.Entrypoint}} {{json .Config.Cmd}}' "$IMAGE_REF" 2>&1 || true)"
echo "entrypoint and cmd: $cmd"
if [[ $cmd == 'null ["/usr/local/bin/clustermax-audit"]' || $cmd == '[] ["/usr/local/bin/clustermax-audit"]' ]]; then
	pass "image/cmd"
else
	fail "image/cmd" "want no entrypoint and the wrapper as the command, got $cmd"
fi

# The image's own command, with no Slurm job around it.
set +e
refuse="$(docker run --rm --platform "$PLATFORM" "$IMAGE_REF" 2>&1)"
rc=$?
set -e
echo "$refuse" | sed 's/^/outside an allocation: /'
if [[ $rc == 2 ]] && grep -qF "clustermax-audit runs as a Slurm step" <<<"$refuse"; then
	pass "wrapper/refuses"
else
	fail "wrapper/refuses" "exit $rc outside an allocation, want 2 and the usage line"
fi

echo "executed=$EXECUTED planned=$PLANNED passed=$PASSED failed=$FAILED"
if ((EXECUTED != PLANNED)); then
	echo "ran $EXECUTED of $PLANNED planned assertions" >&2
	exit 1
fi
((FAILED == 0))
