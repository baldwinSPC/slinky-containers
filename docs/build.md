# Build

## Table of Contents

<!-- mdformat-toc start --slug=github --no-anchors --maxlevel=6 --minlevel=1 -->

- [Build](#build)
  - [Table of Contents](#table-of-contents)
  - [Overview](#overview)
    - [Compatibility](#compatibility)
  - [Slurm](#slurm)
    - [With Custom Registry](#with-custom-registry)
  - [Development](#development)
  - [Multiple Architectures](#multiple-architectures)
    - [Emulation (QEMU)](#emulation-qemu)
    - [Multiple Native Nodes](#multiple-native-nodes)
  - [GPU Autodetection](#gpu-autodetection)
  - [Extending the images with additional software](#extending-the-images-with-additional-software)

<!-- mdformat-toc end -->

## Overview

Instructions for building images via [docker bake].

### Compatibility

| Software      |                      Minimum Version                       |
| ------------- | :--------------------------------------------------------: |
| Docker Engine | [28.1.0](https://docs.docker.com/engine/release-notes/28/) |

## Slurm

Build Slurm from the selected Slurm version and Linux flavor.

```sh
cd ./schedmd/slurm/
export BAKE_IMPORTS="--file ./docker-bake.hcl --file ./$VERSION/$FLAVOR/slurm.hcl"
docker bake $BAKE_IMPORTS --print
docker bake $BAKE_IMPORTS
```

For example, the following will build Slurm 26.05 on Rocky Linux 9.

```sh
cd ./schedmd/slurm/
export BAKE_IMPORTS="--file ./docker-bake.hcl --file ./26.05/rockylinux9/slurm.hcl"
docker bake $BAKE_IMPORTS --print
docker bake $BAKE_IMPORTS
```

Environment variables can be set to modify the build behavior or artifacts:

| Environment Variable | Build Type | Description                                              |
| -------------------- | :--------: | -------------------------------------------------------- |
| REGISTRY             |    Any     | Specify the registry to tag the images with.             |
| SUFFIX               |    Any     | Specify a suffix to append to the image tags.            |
| GIT_REPO             |    Dev     | Specify the git repository to clone Slurm from.          |
| GIT_BRANCH           |    Dev     | Specify the git branch to switch to after cloning Slurm. |

### With Custom Registry

Build Slurm from the selected Slurm version and Linux flavor.

```sh
export REGISTRY="my/registry"
cd ./schedmd/slurm/
export BAKE_IMPORTS="--file ./docker-bake.hcl --file ./$VERSION/$FLAVOR/slurm.hcl"
docker bake $BAKE_IMPORTS --print
docker bake $BAKE_IMPORTS
```

## Development

Build Slurm from the selected repository and branch for a Slurm version and
Linux flavor.

> [!NOTE]
> The docker SSH agent is used to avoid credentials leaking into the image
> layers. You will need to add a default private key if the target repository is
> private.

```sh
ssh-add ~/.ssh/id_ed25519 # if private repo
```

Build Slurm from the selected Slurm version and Linux flavor.

```sh
export GIT_REPO=git@github.com:SchedMD/slurm.git
export GIT_BRANCH=master
cd ./schedmd/slurm/
export BAKE_IMPORTS="--file ./docker-bake.hcl --file ./$VERSION/$FLAVOR/slurm.hcl"
docker bake $BAKE_IMPORTS dev --print
docker bake $BAKE_IMPORTS dev
```

## Multiple Architectures

Build Slurm images with the `multiarch` target:

```sh
cd ./schedmd/slurm/
export BAKE_IMPORTS="--file ./docker-bake.hcl --file ./$VERSION/$FLAVOR/slurm.hcl"
docker bake $BAKE_IMPORTS multiarch --print
docker bake $BAKE_IMPORTS multiarch
```

There are multiple ways to configure builders for multiple
[architectures/platforms][multi-platform].

### Emulation (QEMU)

A single machine can be configured to use QEMU to emulate different
architectures.

> [!NOTE]
> Emulation with QEMU can be much slower than native builds, especially for
> compute-heavy tasks like compilation and compression or decompression.

Install host dependencies.

```sh
# RPM (e.g. RHEL, CentOS, Rocky Linux, Alma Linux)
sudo dnf install -y qemu-user-binfmt qemu-user-static
# DEB (e.g. Debian, Ubuntu)
sudo apt-get install -y binfmt-support qemu-user-static
```

Configure QEMU with docker:

```sh
docker run --rm --privileged tonistiigi/binfmt --install all
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
```

Create a docker builder for QEMU to use:

```sh
docker buildx create --name multiarch --bootstrap
docker buildx inspect multiarch
```

Build Slurm images:

```sh
cd ./schedmd/slurm/
export BAKE_IMPORTS="--file ./docker-bake.hcl --file ./$VERSION/$FLAVOR/slurm.hcl"
docker bake $BAKE_IMPORTS --builder multiarch multiarch --print
docker bake $BAKE_IMPORTS --builder multiarch multiarch
```

> [!WARNING]
> Compiling Slurm with QEMU can take more than 1 hour instead of a few minutes
> on a native architecture.

### Multiple Native Nodes

The following command creates a multi-node builder from Docker contexts named
node-amd64 and node-arm64. This example assumes that you've already added those
contexts.

```sh
docker buildx ls
docker buildx create --name multiarch node-amd64
docker buildx create --name multiarch --append node-arm64
```

Build Slurm images:

```sh
cd ./schedmd/slurm/
export BAKE_IMPORTS="--file ./docker-bake.hcl --file ./$VERSION/$FLAVOR/slurm.hcl"
docker bake $BAKE_IMPORTS --builder multiarch multiarch --print
docker bake $BAKE_IMPORTS --builder multiarch multiarch
```

## GPU Autodetection

The published `slurmd` images carry the `gpu/nvidia` autodetect plugin, which
needs no library, and not `gpu/nvml` or `gpu/rsmi`. The `gpu` group builds
`slurmd_gpu` and `slurmd_gpu_pyxis` with those two, so that `gres.conf` can use
`AutoDetect=nvml` and `AutoDetect=rsmi`. Only the `rockylinux9` flavor of 26.05
defines the `slurmd-gpu` stage.

```sh
cd ./schedmd/slurm/
export BAKE_IMPORTS="--file ./docker-bake.hcl --file ./26.05/rockylinux9/slurm.hcl"
docker bake $BAKE_IMPORTS gpu --print
docker bake $BAKE_IMPORTS gpu
```

The plugins built per architecture come from the `GPU_AUTODETECT_AMD64` and
`GPU_AUTODETECT_ARM64` build arguments. By default amd64 gets `nvml rsmi` and
arm64 gets `nvml`, because ROCm publishes no arm64 packages. The build fails if
a requested plugin is not in the Slurm package it produces.

- **NVML:** the headers and link stub come from the CUDA repository's
  `cuda-nvml-devel` package (`CUDA_NVML_DEVEL`) and are used at build time only.
  Slurm loads `libnvidia-ml.so.1` at run time, and the NVIDIA container toolkit
  mounts it into GPU containers from the node's driver.
- **ROCm SMI:** `rocm-smi-lib` (`ROCM_SMI_LIB`, from ROCm `ROCM_VERSION`) is
  installed in the image, because the AMD device plugin mounts only `/dev/kfd`
  and `/dev/dri`.
- **NCCL:** where NVML is built, the `libnccl` runtime RPM (`NCCL_VERSION`) from
  the same CUDA repository is checked against `NCCL_SHA256_AMD64` or
  `NCCL_SHA256_ARM64` and installed in `slurmd-gpu` and `login-gpu`. `login-gpu`
  also gets an `nccl/<version>` Lmod modulefile in `/etc/modulefiles`.
- **NHC:** LBNL Node Health Check (`NHC_VERSION`) is built into an RPM by its
  own spec from the release archive, checked against `NHC_SHA256`, and installed
  in `slurmd-gpu` with an `/etc/nhc/nhc.conf` that runs no checks.

## Extending the images with additional software

Image build stages may also be added or modified to manage custom software
present in images. It is generally advisable to keep the size and complexity of
each stage minimal, in order to reduce image build time and improve the number
of stages that can be reused between builds. Furthermore, changes should be made
in the most specific stage possible. For example, installing JupyterLab for
users should be done in a layer that is specific to the `slurmd` or `login`
targets, so that it is not installed unnecessarily in `slurmctld` or `slurmdbd`
images, increasing image size.

The following is an example of how the `base-extra` stage could be modified for
the installation of additional software, specifically PyTorch and JupyterLab:

```dockerfile
FROM base AS base-extra

SHELL ["bash", "-c"]

RUN  --mount=type=cache,target=/var/cache/dnf,sharing=locked <<EOR
# Install Extra Packages
set -xeuo pipefail
dnf -q -y install \
    python3 \
    python3-pip
pip3 install torch torchvision --index-url https://download.pytorch.org/whl/cu126
EOR
```

After modifying the `base-extra` layer, build the `slurmd` and `login` images:

```bash
cd ./schedmd/slurm/
export BAKE_IMPORTS="--file ./docker-bake.hcl --file ./26.05/rockylinux9/slurm.hcl"
docker bake $BAKE_IMPORTS slurmd login --print
docker bake $BAKE_IMPORTS slurmd login
```

<!-- Links -->

[docker bake]: https://docs.docker.com/build/bake/introduction/
[multi-platform]: https://docs.docker.com/build/building/multi-platform/
