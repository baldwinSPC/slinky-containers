# GPU slurmd images: notices and sources

This repository is a fork of
[SlinkyProject/containers](https://github.com/SlinkyProject/containers). It adds
two images, built from `schedmd/slurm/26.05/rockylinux9/`:

- `ghcr.io/baldwinspc/slinky-containers/slurmd_gpu`
- `ghcr.io/baldwinspc/slinky-containers/slurmd_gpu_pyxis`

They are built and published from this repository by baldwinSPC, not by SchedMD.
Each is Slurm's `slurmd` with GPU autodetection. `gres.conf` can say
`AutoDetect=nvml` on linux/amd64 and linux/arm64 and `AutoDetect=rsmi` on
linux/amd64. The published `ghcr.io/slinkyproject/slurmd` images carry neither.

Every publish run creates a GitHub release that lists the image digests,
attaches an SBOM of every package in each image, and attaches the Slurm source
archive the images were built from.

## Slurm

Both images contain Slurm, Copyright (C) SchedMD LLC and the Slurm contributors.
It is licensed under the GNU General Public License, version 2 or later, with an
exception permitting linking with OpenSSL. The images carry the licence at
`/usr/share/licenses/slurm/` (`COPYING`, `DISCLAIMER`, `LICENSE.OpenSSL`).

**Corresponding source:**

- The Slurm release archive
  <https://github.com/SchedMD/slurm/archive/slurm-26-05-4-1.tar.gz>, sha256
  `0e522d39324b7b7da5e8096c678c4af00500ca4c3fe2e6da7e4f8d01f7082ec7`. This is
  SchedMD's tag `slurm-26-05-4-1`, commit
  `85014568d41355489419c92bd41b3d8c63849020`. The build refuses an archive with
  any other checksum, and each release attaches a copy.
- The build definition in this repository, at the commit recorded in each
  image's `org.opencontainers.image.revision` label and provenance attestation.

**Modifications:** none to Slurm's source. The build selects configure options:
`--with-nvml` and `--with pmix`, and ROCm SMI found under `/opt/rocm`. They are
set in `schedmd/slurm/26.05/rockylinux9/Dockerfile`.

## What the fork adds

Each licence was read at the version pinned here.

| Component                       | Version                                                   | Licence                                                                                                                                        | In                       |
| ------------------------------- | --------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------ |
| ROCm SMI (`rocm-smi-lib`)       | 7.8.0.70204, ROCm 7.2.4                                   | MIT. The package's `LICENSE.md` and `LICENSE.md` at `ROCm/rocm_smi_lib` tag `rocm-7.2.4` are identical; the RPM header's licence tag says NCSA | both images, linux/amd64 |
| `rocm-core`                     | 7.2.4.70204                                               | MIT (`LICENSE.md` in the package)                                                                                                              | both images, linux/amd64 |
| enroot, enroot+caps             | 4.2.1                                                     | Apache-2.0 (`LICENSE` at `NVIDIA/enroot` tag `v4.2.1`)                                                                                         | `slurmd_gpu_pyxis`       |
| pyxis                           | 0.24.0                                                    | Apache-2.0 (`LICENSE` at `NVIDIA/pyxis` tag `v0.24.0`)                                                                                         | `slurmd_gpu_pyxis`       |
| nvidia-container-toolkit, -base | 1.20.1                                                    | Apache-2.0 (`LICENSE` at `NVIDIA/nvidia-container-toolkit` tag `v1.20.1`)                                                                      | `slurmd_gpu_pyxis`       |
| libnvidia-container1, -tools    | 1.20.1, built from `NVIDIA/libnvidia-container` `v1.20.0` | Apache-2.0 (`LICENSE`). Its `NOTICE` adds the LGPL-3.0-or-later terms of elfutils `libelf`, which this build links                             | `slurmd_gpu_pyxis`       |

The pyxis image also carries the Rocky Linux and EPEL packages enroot and the
toolkit depend on, and the SBOM lists each of them.

These are used at build time only and are not in the images:

- **The NVML headers and link stub**, `cuda-nvml-devel-12-9` 12.9.79 from the
  NVIDIA CUDA Toolkit, under the CUDA Toolkit End User License Agreement. Slurm
  loads `libnvidia-ml.so.1` at run time, and the NVIDIA container toolkit
  provides it from the node's driver.
- **The ROCm SMI headers**, from the same `rocm-smi-lib` package the image
  ships.

`nvml.h` asks that software built with it include this notice in its
documentation:

> NVIDIA MAKES NO REPRESENTATION ABOUT THE SUITABILITY OF THIS SOURCE CODE FOR
> ANY PURPOSE. IT IS PROVIDED "AS IS" WITHOUT EXPRESS OR IMPLIED WARRANTY OF ANY
> KIND. NVIDIA DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOURCE CODE,
> INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY, NONINFRINGEMENT, AND
> FITNESS FOR A PARTICULAR PURPOSE. IN NO EVENT SHALL NVIDIA BE LIABLE FOR ANY
> SPECIAL, INDIRECT, INCIDENTAL, OR CONSEQUENTIAL DAMAGES, OR ANY DAMAGES
> WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION
> OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN
> CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOURCE CODE.
>
> U.S. Government End Users. This source code is a "commercial item" as that
> term is defined at 48 C.F.R. 2.101 (OCT 1995), consisting of "commercial
> computer software" and "commercial computer software documentation" as such
> terms are used in 48 C.F.R. 12.212 (SEPT 1995) and is provided to the U.S.
> Government only as a commercial end item. Consistent with 48 C.F.R.12.212 and
> 48 C.F.R. 227.7202-1 through 227.7202-4 (JUNE 1995), all U.S. Government End
> Users acquire the source code with only those rights set forth herein.

## Distribution packages

The images are built on `rockylinux/rockylinux:9`, pinned by digest in
`schedmd/slurm/26.05/rockylinux9/gpu.hcl`. They carry packages from Rocky Linux
and EPEL, as upstream's images do. Many of those carry GPL or LGPL licences,
under the licence each package names. The SBOM attached to each release lists
every package with its version, licence tag and source RPM. The source for each
is in the source repositories of Rocky Linux
(<https://dl.rockylinux.org/vault/rocky/>) and EPEL
(<https://dl.fedoraproject.org/pub/epel/>).

## Where the fork differs from upstream's rockylinux9 images

- `gpu_nvml` and `gpu_rsmi`, as above.
- `mpi_pmix` (PMIx 3.2.3 from EL9) and `compress_lz4`. Upstream's rockylinux9
  `slurmd` lacks both. Its `26.05-ubuntu26.04` `slurmd` has both.
- The pyxis RPM is installed. Upstream's `slurmd-pyxis:26.05-rockylinux9` copies
  RPMs from a path that `make rpm` does not write, and ships without pyxis.
- `/etc/slurm/plugstack.conf.d` is mode 755. Upstream creates it with mode 644.
- The enroot, pyxis and nvidia-container-toolkit versions are pinned, and the
  downloads are checked against `pyxis-checksums/SHA256SUMS`. Upstream resolves
  the latest release at build time.
