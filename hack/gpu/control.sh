#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Runs test-image.sh against an image built without the GPU autodetect plugins
# (the stock slurmd) and requires it to fail exactly the assertions about the
# expected plugins, plus any named with --also-fail, and pass the rest. A test
# that passed there, or failed for another reason, would say nothing about the
# slurmd_gpu image.
#
# usage: control.sh --image STOCK_REF --platform P --expect "nvml rsmi" \
#          [--also-fail ID]... [test-image.sh options]

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

EXPECT=""
ALSO_FAIL=()
args=()
while (($#)); do
	case "$1" in
	--expect)
		EXPECT="$2"
		args+=("$1" "$2")
		shift 2
		;;
	--also-fail)
		ALSO_FAIL+=("$2")
		shift 2
		;;
	--pyxis | --nccl | --nhc)
		args+=("$1")
		shift
		;;
	*)
		args+=("$1" "$2")
		shift 2
		;;
	esac
done
if [[ -z $EXPECT ]]; then
	echo "control.sh: --expect is required" >&2
	exit 2
fi

set +e
out="$("$HERE/test-image.sh" "${args[@]}")"
rc=$?
set -e
echo "$out"

failed_ids="$(awk '$1 == "FAIL" { sub(":", "", $2); print $2 }' <<<"$out" | sort)"
passed_ids="$(awk '$1 == "PASS" { print $2 }' <<<"$out" | sort)"
summary="$(grep -E '^executed=' <<<"$out" || true)"

# Every assertion naming an expected plugin, and every --also-fail one, must
# fail on the stock image.
want_failed="$(awk '$1 == "PASS" || $1 == "FAIL" { id = $2; sub(":", "", id); print id }' <<<"$out" |
	while read -r id; do
		for gpu in $EXPECT; do
			if [[ $id == */$gpu || $id == */$gpu/* ]]; then
				echo "$id"
				continue 2
			fi
		done
		for also in ${ALSO_FAIL[@]+"${ALSO_FAIL[@]}"}; do
			if [[ $id == "$also" ]]; then
				echo "$id"
				continue 2
			fi
		done
	done | sort)"

echo "control: stock image failed [$(tr '\n' ' ' <<<"$failed_ids")]"
echo "control: expected to fail   [$(tr '\n' ' ' <<<"$want_failed")]"
if [[ -z $summary ]]; then
	echo "control: CANNOT TELL: test-image.sh printed no summary (exit $rc)" >&2
	exit 1
fi
if ((rc == 0)); then
	echo "control: FAIL: test-image.sh passed an image without the plugins" >&2
	exit 1
fi
if [[ -z $want_failed ]]; then
	echo "control: CANNOT TELL: no assertion names an expected plugin" >&2
	exit 1
fi
if [[ $failed_ids != "$want_failed" ]]; then
	echo "control: FAIL: the stock image failed a different set of assertions than the plugin ones" >&2
	exit 1
fi
echo "control: PASS: the $(grep -c . <<<"$failed_ids") expected assertions failed on the stock image, $(grep -c . <<<"$passed_ids") others passed ($summary)"
