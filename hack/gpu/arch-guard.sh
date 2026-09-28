#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Checks that a published multi-platform image carries exactly the platforms it
# claims, and that what is inside each one was built for it: the image config's
# os/architecture, and the ELF machine of slurmd and of every gpu plugin.
# Attestation manifests (vnd.docker.reference.type=attestation-manifest) are
# counted separately; an index lists them as unknown/unknown.
#
# Nothing is run: files are copied out of created containers and their ELF
# headers read on the host, so one runner checks every platform.
#
# usage: arch-guard.sh REF PLATFORM... e.g. arch-guard.sh ghcr.io/o/i@sha256:... linux/amd64 linux/arm64

set -euo pipefail

if (($# < 2)); then
	echo "usage: $(basename "$0") REF PLATFORM..." >&2
	exit 2
fi
REF="$1"
shift
WANT="$(printf '%s\n' "$@" | sort)"
# The repository, without a digest or tag; a registry port is not a tag.
if [[ $REF == *@* ]]; then
	REPO="${REF%@*}"
elif [[ ${REF##*/} == *:* ]]; then
	REPO="${REF%:*}"
else
	REPO="$REF"
fi

EXECUTED=0
FAILED=0
pass() {
	EXECUTED=$((EXECUTED + 1))
	echo "PASS $1"
}
fail() {
	EXECUTED=$((EXECUTED + 1))
	FAILED=$((FAILED + 1))
	echo "FAIL $1: $2"
}

# e_machine for each GOARCH-style architecture.
elf_machine_for() {
	case "$1" in
	amd64) echo 62 ;;
	arm64) echo 183 ;;
	*) echo "" ;;
	esac
}

# Prints "class data machine" of an ELF file: "2 1 <e_machine>" for 64-bit
# little-endian. e_machine is read byte by byte so the host's od and byte order
# do not matter.
elf_header() {
	local magic class data lo hi
	magic="$(od -An -t x1 -j 0 -N 4 "$1" | tr -d ' \n')"
	if [[ $magic != "7f454c46" ]]; then
		echo "not-elf - -"
		return
	fi
	read -r class data < <(od -An -t u1 -j 4 -N 2 "$1")
	read -r lo hi < <(od -An -t u1 -j 18 -N 2 "$1")
	echo "$class $data $((lo + 256 * hi))"
}

raw="$(docker buildx imagetools inspect --raw "$REF")"
media="$(jq -r '.mediaType // empty' <<<"$raw")"
case "$media" in
application/vnd.oci.image.index.v1+json | application/vnd.docker.distribution.manifest.list.v2+json)
	pass "index/media-type"
	;;
*)
	fail "index/media-type" "not an image index: '$media'"
	echo "executed=$EXECUTED failed=$FAILED"
	exit 1
	;;
esac

images="$(jq -r '.manifests[] | select((.annotations["vnd.docker.reference.type"] // "") != "attestation-manifest") | [.digest, .platform.os + "/" + .platform.architecture + (if .platform.variant then "/" + .platform.variant else "" end)] | @tsv' <<<"$raw")"
attestations="$(jq -r '.manifests[] | select((.annotations["vnd.docker.reference.type"] // "") == "attestation-manifest") | [.digest, .annotations["vnd.docker.reference.digest"]] | @tsv' <<<"$raw")"
image_count="$(grep -c . <<<"$images" || true)"
attestation_count="$(grep -c . <<<"$attestations" || true)"
echo "index: $image_count image manifest(s), $attestation_count attestation manifest(s)"

# arm64 images may carry the v8 variant; the claim is compared without it.
have="$(cut -f2 <<<"$images" | sed -E 's#^(linux/arm64)/v8$#\1#' | sort)"
if [[ $have == "$WANT" ]]; then
	pass "index/platforms"
else
	fail "index/platforms" "want [$(tr '\n' ' ' <<<"$WANT")] have [$(tr '\n' ' ' <<<"$have")]"
fi
dups="$(uniq -d <<<"$have")"
if [[ -z $dups ]]; then
	pass "index/unique"
else
	fail "index/unique" "platform listed twice: $(tr '\n' ' ' <<<"$dups")"
fi

# Every attestation manifest refers to an image manifest in this index.
orphans=0
while IFS=$'\t' read -r _ subject; do
	[[ -z $subject ]] && continue
	if ! cut -f1 <<<"$images" | grep -qx "$subject"; then
		orphans=$((orphans + 1))
	fi
done <<<"$attestations"
if ((orphans == 0)); then
	pass "index/attestations"
else
	fail "index/attestations" "$orphans attestation manifest(s) refer to no image in the index"
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

while IFS=$'\t' read -r digest platform; do
	[[ -z $digest ]] && continue
	os="${platform%%/*}"
	arch="$(cut -d/ -f2 <<<"$platform")"
	id="$os/$arch"
	config="$(docker buildx imagetools inspect "$REPO@$digest" --format '{{json .Image}}')"
	config_platform="$(jq -r '.os + "/" + .architecture' <<<"$config")"
	if [[ $config_platform == "$id" ]]; then
		pass "$id/config"
	else
		fail "$id/config" "index says $id, image config says $config_platform"
	fi

	want_machine="$(elf_machine_for "$arch")"
	# By manifest digest and without --platform: the files are checked against
	# the platform the index claims, even when the image says otherwise.
	docker pull --quiet "$REPO@$digest" >/dev/null 2>&1 || true
	if ! cid="$(docker create "$REPO@$digest" /usr/sbin/slurmd 2>/dev/null)"; then
		fail "$id/elf" "could not create a container from $REPO@$digest"
		continue
	fi
	mkdir -p "$work/$arch"
	files=(/usr/sbin/slurmd)
	if docker cp "$cid:/usr/lib64/slurm/." "$work/$arch/plugins" >/dev/null 2>&1; then
		for f in "$work/$arch/plugins"/gpu_*.so; do
			[[ -e $f ]] && files+=("/usr/lib64/slurm/$(basename "$f")")
		done
	fi
	for f in "${files[@]}"; do
		local_copy="$work/$arch/$(basename "$f")"
		if ! docker cp -L "$cid:$f" "$local_copy" >/dev/null 2>&1; then
			fail "$id/elf$f" "could not copy $f out of the image"
			continue
		fi
		read -r class data machine <<<"$(elf_header "$local_copy")"
		if [[ $class == 2 && $data == 1 && $machine == "$want_machine" ]]; then
			pass "$id/elf$f"
		else
			fail "$id/elf$f" "want 64-bit LSB e_machine=$want_machine, have class=$class data=$data e_machine=${machine:-?}"
		fi
	done
	docker rm "$cid" >/dev/null
done <<<"$images"

echo "executed=$EXECUTED failed=$FAILED"
((FAILED == 0))
