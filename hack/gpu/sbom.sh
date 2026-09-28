#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Lists every RPM in an image as tab-separated name, epoch:version-release,
# arch, licence tag, source RPM and vendor, sorted by name. With --baseline,
# prints only the packages the image has and the baseline image does not.
# Counts go to stderr: packages, and how many licence tags name GPL (LGPL and
# AGPL included) or MPL.
#
# usage: sbom.sh --image REF --platform PLATFORM [--baseline REF]

set -euo pipefail

IMAGE=""
PLATFORM=""
BASELINE=""
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
	--baseline)
		BASELINE="$2"
		shift 2
		;;
	*)
		echo "unknown argument: $1" >&2
		exit 2
		;;
	esac
done
if [[ -z $IMAGE || -z $PLATFORM ]]; then
	echo "usage: $(basename "$0") --image REF --platform PLATFORM [--baseline REF]" >&2
	exit 2
fi

QF='%{NAME}\t%{EPOCHNUM}:%{VERSION}-%{RELEASE}\t%{ARCH}\t%{LICENSE}\t%{SOURCERPM}\t%{VENDOR}\n'

packages() {
	docker run --rm --platform "$PLATFORM" --entrypoint rpm "$1" -qa --qf "$QF" | LC_ALL=C sort
}

list="$(packages "$IMAGE")"
if [[ -z $list ]]; then
	echo "sbom.sh: rpm listed no packages in $IMAGE" >&2
	exit 1
fi
if [[ -n $BASELINE ]]; then
	base_names="$(packages "$BASELINE" | cut -f1)"
	if [[ -z $base_names ]]; then
		echo "sbom.sh: rpm listed no packages in $BASELINE" >&2
		exit 1
	fi
	list="$(awk -F'\t' 'NR == FNR { seen[$1] = 1; next } !($1 in seen)' <(echo "$base_names") <(echo "$list"))"
fi

printf 'name\tepoch:version-release\tarch\tlicense\tsource_rpm\tvendor\n'
if [[ -n $list ]]; then
	echo "$list"
fi

total="$(grep -c . <<<"$list" || true)"
gpl="$(cut -f4 <<<"$list" | grep -c -E 'GPL' || true)"
mpl="$(cut -f4 <<<"$list" | grep -c -E 'MPL' || true)"
echo "packages=$total gpl_family=$gpl mpl=$mpl${BASELINE:+ (added over $BASELINE)}" >&2
