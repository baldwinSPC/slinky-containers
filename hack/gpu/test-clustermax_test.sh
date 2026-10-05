#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Checks test-clustermax.sh's verdicts against a stub docker. An image with
# everything passes every check. Then one thing at a time goes wrong: jq is
# missing, python3 is missing, run.sh is missing, the tree is another commit,
# the LICENSE differs, the image keeps the login's entrypoint, and the wrapper
# runs outside an allocation. Each must fail exactly its own checks, and every
# planned check must still run.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

COMMIT=1492ac5e4ac992ae436f062cc51a340d61672ca3
SHA=68aee1a6de2e8cf7b47c6e937709e049704efd2d4dd3671c4f037562d7f313dc

mkdir -p "$work/bin"
cat >"$work/bin/docker" <<EOF
#!/usr/bin/env bash
# Answers the docker calls test-clustermax.sh makes. NO_JQ, NO_PYTHON and
# NO_RUN leave that out of the image, OTHER_COMMIT and OTHER_LICENCE change
# what the image carries, LOGIN_ENTRYPOINT keeps the login's entrypoint, and
# NO_REFUSAL lets the wrapper run outside an allocation.
if [[ \$1 == image && \$2 == inspect ]]; then
	if [[ \$3 == --format ]]; then
		if [[ -n \${LOGIN_ENTRYPOINT:-} ]]; then
			echo '["/usr/local/bin/entrypoint.sh"] ["/usr/local/bin/clustermax-audit"]'
		else
			echo 'null ["/usr/local/bin/clustermax-audit"]'
		fi
	fi
	exit 0
fi
if [[ \$1 != run ]]; then
	echo "stub docker: unexpected arguments: \$*" >&2
	exit 1
fi
case "\$*" in
*"jq --version"*)
	if [[ -n \${NO_JQ:-} ]]; then
		echo "bash: line 1: jq: command not found"
		echo "jq: "
	else
		echo "jq: jq-1.6"
	fi
	if [[ -n \${NO_PYTHON:-} ]]; then
		echo "python3: bash: line 1: python3: command not found"
	else
		echo "python3: Python 3.9.21"
	fi
	;;
*"run.sh"*)
	[[ -z \${NO_RUN:-} ]] && echo "have run.sh"
	echo "have the slurm collector"
	echo "have clustermax-audit"
	c="${COMMIT}"
	[[ -n \${OTHER_COMMIT:-} ]] && c=0000000000000000000000000000000000000000
	echo "commit file \$c"
	echo "commit env \$c"
	;;
*"sha256sum"*)
	s="${SHA}"
	[[ -n \${OTHER_LICENCE:-} ]] && s=1111111111111111111111111111111111111111111111111111111111111111
	echo "\$s  /usr/share/licenses/clustermax/LICENSE"
	echo "\$s  /opt/clustermax/LICENSE"
	;;
*)
	if [[ \$* == *--entrypoint* ]]; then
		echo "stub docker: unexpected command: \$*" >&2
		exit 1
	fi
	if [[ -n \${NO_REFUSAL:-} ]]; then
		echo "===== audit.values.json ====="
		exit 0
	fi
	echo "clustermax-audit runs as a Slurm step: salloc ... srun --overlap --container-image=<this image> --container-mounts=/run/slurm clustermax-audit" >&2
	exit 2
	;;
esac
EOF
chmod +x "$work/bin/docker"

fails=0
# case NAME WANT_FAILED [ENV...]: WANT_FAILED is the space-separated ids that
# must fail, empty for none.
case_() {
	local name="$1" want="$2"
	shift 2
	local out rc failed summary
	set +e
	out="$(env PATH="$work/bin:$PATH" "$@" "$HERE/test-clustermax.sh" --image test/clustermax --platform linux/amd64 \
		--commit "$COMMIT" --licence-sha256 "$SHA" 2>&1)"
	rc=$?
	set -e
	failed="$(sed -n 's/^FAIL \([^:]*\):.*/\1/p' <<<"$out" | sort | tr '\n' ' ' | sed 's/ $//')"
	summary="$(grep -E '^executed=' <<<"$out" || true)"
	if [[ $failed != "$want" ]]; then
		echo "FAIL $name: failed [$failed], want [$want]"
		sed 's/^/    | /' <<<"$out"
		fails=$((fails + 1))
	elif [[ -z $want && $rc != 0 ]] || [[ -n $want && $rc == 0 ]]; then
		echo "FAIL $name: exit $rc with failed [$failed]"
		fails=$((fails + 1))
	elif ! grep -qE '^executed=([0-9]+) planned=\1 ' <<<"$summary"; then
		echo "FAIL $name: not every planned check ran: $summary"
		fails=$((fails + 1))
	else
		echo "ok   $name: failed [$failed], $summary"
	fi
}

case_ "an image with everything" ""
case_ "jq is missing" "tools/jq" NO_JQ=1
case_ "python3 is missing" "tools/python3" NO_PYTHON=1
case_ "run.sh is missing" "clustermax/tree" NO_RUN=1
case_ "the tree is another commit" "clustermax/commit" OTHER_COMMIT=1
case_ "the LICENSE differs" "licence/clustermax" OTHER_LICENCE=1
case_ "the login's entrypoint is kept" "image/cmd" LOGIN_ENTRYPOINT=1
case_ "the wrapper runs outside an allocation" "wrapper/refuses" NO_REFUSAL=1

if ((fails != 0)); then
	echo "$fails case(s) failed"
	exit 1
fi
echo "all cases passed"
