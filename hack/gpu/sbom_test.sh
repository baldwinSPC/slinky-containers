#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Checks sbom.sh's licence_read join against a stub docker whose `rpm -qa`
# answers canned rows: the noted version carries its note, another version of
# the same package and a package with no note carry none.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin"
cat >"$work/bin/docker" <<'EOF'
#!/usr/bin/env bash
# Answers `docker run ... --entrypoint rpm IMAGE -qa --qf ...` for two images.
image=""
for a in "$@"; do
	case "$a" in
	test/noted | test/other) image="$a" ;;
	esac
done
case "$image" in
test/noted)
	printf 'rocm-smi-lib\t0:7.8.0.70204-93.el8\tx86_64\tNCSA\trocm-smi-lib-7.8.0.70204-93.el8.src.rpm\tAdvanced Micro Devices, Inc.\n'
	printf 'bash\t0:5.1.8-9.el9\tx86_64\tGPLv3+\tbash-5.1.8-9.el9.src.rpm\tRocky\n'
	;;
test/other)
	printf 'rocm-smi-lib\t0:7.9.0.70300-1.el8\tx86_64\tNCSA\trocm-smi-lib-7.9.0.70300-1.el8.src.rpm\tAdvanced Micro Devices, Inc.\n'
	;;
*)
	echo "stub docker: unexpected arguments: $*" >&2
	exit 1
	;;
esac
EOF
chmod +x "$work/bin/docker"

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

noted="$(PATH="$work/bin:$PATH" bash "$HERE/sbom.sh" --image test/noted --platform linux/amd64 2>/dev/null)"
other="$(PATH="$work/bin:$PATH" bash "$HERE/sbom.sh" --image test/other --platform linux/amd64 2>/dev/null)"

check "header/licence_read" "$(head -n1 <<<"$noted" | awk -F'\t' '{ print NF ":" $7 }')" "7:licence_read"
check "noted/rocm-smi-lib" "$(awk -F'\t' '$1 == "rocm-smi-lib" { print $4 " -> " substr($7, 1, 4) }' <<<"$noted")" "NCSA -> MIT "
check "noted/bash" "$(awk -F'\t' '$1 == "bash" { print "[" $7 "]" }' <<<"$noted")" "[]"
check "other-version/rocm-smi-lib" "$(awk -F'\t' '$1 == "rocm-smi-lib" { print "[" $7 "]" }' <<<"$other")" "[]"

echo "executed=$EXECUTED failed=$FAILED"
((EXECUTED == 4 && FAILED == 0))
