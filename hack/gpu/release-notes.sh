#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Prints the release notes for a publish run: the digests to pin, and where
# the source of everything in the images comes from. Pins are read from the
# files that set them, so the notes cannot disagree with the build.
#
# usage: release-notes.sh INDEXES_FILE
#   INDEXES_FILE has one "image index-digest amd64-image-digest arm64-image-digest"
#   line per image, the image digests being the manifests the index lists.
#   Test records are read from sbom/test-*.txt (before the push) and
#   digests/test-*-pushed.txt (the pushed digests) beside it.
# Environment: REGISTRY, SLURM_TAG, GITHUB_SHA, GITHUB_SERVER_URL, GITHUB_REPOSITORY.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SLURM="$HERE/../../schedmd/slurm"
FLAVOR="$SLURM/26.05/rockylinux9"

indexes="${1:?usage: release-notes.sh INDEXES_FILE}"
: "${REGISTRY:?}" "${SLURM_TAG:?}" "${GITHUB_SHA:?}" "${GITHUB_SERVER_URL:?}" "${GITHUB_REPOSITORY:?}"

# value FILE NAME: the quoted value of NAME = "..." in an HCL file.
hcl_value() {
	sed -n -E "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*\"([^\"]*)\".*/\1/p" "$1" | head -n1
}
# arg FILE NAME: the default of ARG NAME=... in a Dockerfile.
arg_default() {
	sed -n -E "s/^ARG $2=(.*)$/\1/p" "$1" | head -n1
}

slurm_version="$(hcl_value "$FLAVOR/slurm.hcl" slurm_version)"
slurm_sha256="$(hcl_value "$FLAVOR/gpu.hcl" SLURM_SHA256)"
parent_image="$(hcl_value "$FLAVOR/gpu.hcl" PARENT_IMAGE)"
enroot="$(hcl_value "$FLAVOR/gpu.hcl" ENROOT_VERSION)"
pyxis="$(hcl_value "$FLAVOR/gpu.hcl" PYXIS_VERSION)"
toolkit="$(hcl_value "$FLAVOR/gpu.hcl" NVIDIA_CONTAINER_TOOLKIT_VERSION)"
cuda_nvml="$(arg_default "$FLAVOR/Dockerfile" CUDA_NVML_DEVEL)"
rocm_version="$(arg_default "$FLAVOR/Dockerfile" ROCM_VERSION)"
rocm_smi="$(arg_default "$FLAVOR/Dockerfile" ROCM_SMI_LIB)"
archive="slurm-${slurm_version//./-}-1"

for v in slurm_version slurm_sha256 parent_image enroot pyxis toolkit cuda_nvml rocm_version rocm_smi; do
	if [[ -z ${!v} ]]; then
		echo "release-notes.sh: could not read $v" >&2
		exit 1
	fi
done

repo_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}"

cat <<EOF
Pin these by digest. Each index carries linux/amd64 and linux/arm64 plus build provenance and SBOM attestations.

| image | index digest |
|---|---|
EOF
while read -r image index _ _; do
	echo "| \`${image}\` | \`${REGISTRY}/${image}@${index}\` |"
done <"$indexes"

cat <<EOF

The image manifests each index lists:

| image | linux/amd64 | linux/arm64 |
|---|---|---|
EOF
while read -r image _ amd64 arm64; do
	echo "| \`${image}\` | \`${amd64}\` | \`${arm64}\` |"
done <"$indexes"

cat <<EOF

Tags \`${SLURM_TAG}\` and \`${SLURM_TAG%.*}-rockylinux9\` pointed at these indexes when this release was cut; tags move, digests do not.

## GPU autodetection

- **linux/amd64:** \`gpu_nvml\` and \`gpu_rsmi\`. ROCm SMI (\`${rocm_smi}\`, ROCm ${rocm_version}) is in the image.
- **linux/arm64:** \`gpu_nvml\`. ROCm publishes no arm64 packages.
- \`libnvidia-ml.so.1\` is not in either image. The NVIDIA container toolkit injects it into GPU containers at run time. Slurm dlopens it only when gres.conf sets \`AutoDetect=nvml\`.
- NVML headers from \`${cuda_nvml}\` were used at build time and are not in the images.

## Source

- **Slurm ${slurm_version}**, GPL-2.0-or-later with the OpenSSL exception: <https://github.com/SchedMD/slurm/archive/${archive}.tar.gz>, sha256 \`${slurm_sha256}\`, tag \`${archive}\`. The build checks the sha256.
- **Build definition:** ${repo_url}/tree/${GITHUB_SHA}, \`schedmd/slurm/26.05/rockylinux9/\`. The provenance attestation on each image records the same commit and the build arguments.
- **Base image:** \`${parent_image}\`. The attached \`*.tsv\` files list every RPM in each image, with its licence tag and source RPM. The source for Rocky Linux and EPEL packages is in those distributions' source repositories.
- **enroot ${enroot}** and **pyxis ${pyxis}** (Apache-2.0) and **nvidia-container-toolkit ${toolkit}** (Apache-2.0; libnvidia-container links elfutils libelf, LGPL-3.0-or-later) are in \`slurmd_gpu_pyxis\` and \`login_gpu_pyxis\`.
- Notices: ${repo_url}/blob/${GITHUB_SHA}/NOTICE-GPU.md

## Checks

EOF
for f in "$(dirname "$indexes")"/sbom/test-*.txt "$(dirname "$indexes")"/digests/test-*-pushed.txt; do
	[[ -e $f ]] || continue
	echo "- \`$(basename "$f" .txt)\`: $(grep -E '^executed=' "$f" | tail -n1)"
done
