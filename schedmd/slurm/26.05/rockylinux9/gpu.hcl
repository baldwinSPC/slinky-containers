// Pins for the slurmd_gpu, login_gpu_pyxis and clustermax_audit images published from
// baldwinSPC/slinky-containers. Load after docker-bake.hcl and slurm.hcl:
//   docker buildx bake --file docker-bake.hcl --file 26.05/rockylinux9/slurm.hcl \
//     --file 26.05/rockylinux9/gpu.hcl gpu

################################################################################

variable "GIT_REVISION" {
  default = ""
}

_fork_labels = {
  "org.opencontainers.image.authors" = "https://github.com/baldwinSPC/slinky-containers"
  "org.opencontainers.image.source" = "https://github.com/baldwinSPC/slinky-containers"
  "org.opencontainers.image.url" = "https://github.com/baldwinSPC/slinky-containers/blob/main/NOTICE-GPU.md"
  "org.opencontainers.image.vendor" = "baldwinSPC"
  "org.opencontainers.image.revision" = GIT_REVISION
  "org.opencontainers.image.licenses" = "GPL-2.0-or-later WITH openssl-exception"
  "vendor" = "baldwinSPC"
  "release" = "https://github.com/baldwinSPC/slinky-containers"
}

// The Slurm build, shared by slurmd_gpu and login_gpu so both carry one Slurm.
_slurm_build_args = {
  # rockylinux/rockylinux:9 (index: linux/amd64, linux/arm64/v8, linux/ppc64le, linux/s390x).
  PARENT_IMAGE = "rockylinux/rockylinux:9@sha256:8101994123cf3d0a8fee517bee7f39e555c7d92bd2d9eb3303cc988a0eeed00f"
  # alpine:3.24.2, used only to unpack the Slurm source.
  ALPINE_IMAGE = "alpine@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6"
  # https://github.com/SchedMD/slurm/archive/slurm-26-05-4-1.tar.gz, tag
  # slurm-26-05-4-1 at commit 85014568d41355489419c92bd41b3d8c63849020.
  SLURM_SHA256 = "0e522d39324b7b7da5e8096c678c4af00500ca4c3fe2e6da7e4f8d01f7082ec7"
}

// enroot, pyxis and the NVIDIA container toolkit, shared by both pyxis images.
_pyxis_args = {
  ENROOT_VERSION = "4.2.1"
  PYXIS_VERSION = "0.24.0"
  NVIDIA_CONTAINER_TOOLKIT_VERSION = "1.20.1-1"
}

target "slurmd_gpu" {
  args = _slurm_build_args
  labels = _fork_labels
}

target "slurmd_gpu_pyxis" {
  args = _pyxis_args
  contexts = {
    checksums = "26.05/rockylinux9/pyxis-checksums"
  }
  labels = _fork_labels
}

target "login_gpu" {
  args = _slurm_build_args
  labels = _fork_labels
}

target "login_gpu_pyxis" {
  args = _pyxis_args
  contexts = {
    checksums = "26.05/rockylinux9/pyxis-checksums"
  }
  labels = _fork_labels
}

target "clustermax_audit" {
  args = {
    # SemiAnalysisAI/ClusterMAX, branch master, 2026-09-30. Its LICENSE is
    # Apache-2.0, "Copyright 2025 SemiAnalysis", the same file as at tag v0.2.1.
    CLUSTERMAX_COMMIT = "1492ac5e4ac992ae436f062cc51a340d61672ca3"
    CLUSTERMAX_LICENSE_SHA256 = "68aee1a6de2e8cf7b47c6e937709e049704efd2d4dd3671c4f037562d7f313dc"
  }
  labels = merge(_fork_labels, {
    "org.opencontainers.image.licenses" = "GPL-2.0-or-later WITH openssl-exception AND Apache-2.0"
  })
}
