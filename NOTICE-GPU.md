# GPU slurmd images: notices and sources

This repository is a fork of
[SlinkyProject/containers](https://github.com/SlinkyProject/containers). It adds
four images, built from `schedmd/slurm/26.05/rockylinux9/`:

- `ghcr.io/baldwinspc/slinky-containers/slurmd_gpu`
- `ghcr.io/baldwinspc/slinky-containers/slurmd_gpu_pyxis`
- `ghcr.io/baldwinspc/slinky-containers/login_gpu_pyxis`
- `ghcr.io/baldwinspc/slinky-containers/clustermax_audit`

They are built and published from this repository by baldwinSPC, not by SchedMD.
The first two are Slurm's `slurmd` with GPU autodetection. `gres.conf` can say
`AutoDetect=nvml` on linux/amd64 and linux/arm64 and `AutoDetect=rsmi` on
linux/amd64. The published `ghcr.io/slinkyproject/slurmd` images carry neither.
`login_gpu_pyxis` is upstream's `login` stage built from the same Slurm build,
with pyxis, so `srun --container-image` works from it and `srun --mpi=pmix`
finds `mpi_pmix`. All three carry the NCCL runtime library, and in
`login_gpu_pyxis` a login shell's `module avail` lists an `nccl` module for it.
`clustermax_audit` is `login_gpu_pyxis` plus `jq`, `python3` and the audit
scripts of SemiAnalysisAI/ClusterMAX, so the ClusterMAX Slurm audit runs as a
Slurm step through pyxis. See [ClusterMAX](#clustermax) below.

`slurmd_gpu` and `slurmd_gpu_pyxis` carry LBNL Node Health Check (NHC) for
Slurm's `HealthCheckProgram`.

Every publish run creates a GitHub release that lists the image digests,
attaches an SBOM of every package in each image, and attaches the Slurm source
archive the images were built from.

## Slurm

All four images contain Slurm, Copyright (C) SchedMD LLC and the Slurm
contributors. It is licensed under the GNU General Public License, version 2 or
later, with an exception permitting linking with OpenSSL. The images carry the
licence at `/usr/share/licenses/slurm/` (`COPYING`, `DISCLAIMER`,
`LICENSE.OpenSSL`).

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

| Component                           | Version                                                   | Licence                                                                                                                                             | In                       |
| ----------------------------------- | --------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------ |
| ROCm SMI (`rocm-smi-lib`)           | 7.8.0.70204, ROCm 7.2.4                                   | MIT. The package's `LICENSE.md` and `LICENSE.md` at `ROCm/rocm_smi_lib` tag `rocm-7.2.4` are identical; the RPM header's licence tag says NCSA      | both images, linux/amd64 |
| `rocm-core`                         | 7.2.4.70204                                               | MIT (`LICENSE.md` in the package)                                                                                                                   | both images, linux/amd64 |
| enroot, enroot+caps                 | 4.2.1                                                     | Apache-2.0 (`LICENSE` at `NVIDIA/enroot` tag `v4.2.1`). The same file notes that enroot bundles makeself (GPL-2.0), installed as `enroot-makeself`  | both pyxis images        |
| pyxis                               | 0.24.0                                                    | Apache-2.0 (`LICENSE` at `NVIDIA/pyxis` tag `v0.24.0`)                                                                                              | both pyxis images        |
| nvidia-container-toolkit, -base     | 1.20.1                                                    | Apache-2.0 (`LICENSE` at `NVIDIA/nvidia-container-toolkit` tag `v1.20.1`)                                                                           | both pyxis images        |
| libnvidia-container1, -tools        | 1.20.1, built from `NVIDIA/libnvidia-container` `v1.20.0` | Apache-2.0 (`LICENSE`). Its `NOTICE` adds the LGPL-3.0-or-later terms of elfutils `libelf`, which this build links                                  | both pyxis images        |
| NCCL (`libnccl`)                    | 2.32.3-1+cuda12.9                                         | Apache-2.0, with parts under BSD-3-Clause. See below                                                                                                | all three images         |
| LBNL Node Health Check (`lbnl-nhc`) | 1.4.3, commit `d534d41d`                                  | BSD-3-Clause under the Regents of the University of California (LBNL) and Michael Jennings, plus LBNL's "Enhancements" grant-back clause. See below | both slurmd images       |

**NCCL.** The `libnccl` RPM comes from NVIDIA's CUDA repository for RHEL 9, the
same repository as the NVML headers, and each architecture's RPM is checked
against the sha256 pinned in `schedmd/slurm/26.05/rockylinux9/Dockerfile`. It
installs `libnccl.so.2` and the device-code files `libnccl_device.bc` and
`libnccl_device.ltoir` in `/usr/lib64`, and its licence at
`/usr/share/doc/libnccl/LICENSE.txt`. That file is identical to `LICENSE.txt` at
`NVIDIA/nccl` tag `v2.32.3-1` (commit `12df1a11`): Apache-2.0, with parts
retaining a BSD-3-Clause licence. The RPM header's licence tag says
`Proprietary`. The library statically links the CUDA runtime: NCCL's
`src/Makefile` links `cudart_static` by default, and `libnccl.so.2.32.3` needs
no `libcudart` and carries the runtime's own strings. The CUDA Toolkit End User
License Agreement lists `libcudart_static.a` as distributable in its Attachment
A. No headers, CUDA compiler or other CUDA Toolkit component is in the images.

**NHC.** `lbnl-nhc` 1.4.3 is built from the release archive
<https://github.com/mej/nhc/releases/download/1.4.3/lbnl-nhc-1.4.3.tar.gz>,
sha256 `d2d2108284eb7f833c13b70be1b33ba0115f598491e34ccb701df2a9eb0807b1`, the
value the release's `SHA256SUMS` lists. The release is tag `1.4.3`, commit
`d534d41db4237b018f18a3063c4ceb86b91fbe42`, and every file in the archive is
identical to that commit's; the archive adds the generated `configure` and
`Makefile.in`. The build refuses any other checksum. NHC's own `lbnl-nhc.spec`
builds it into an RPM with its autotools build and runs its unit tests, so
`rpm -q lbnl-nhc` reports `1.4.3-1.el9` and the SBOM lists it. It installs
`/usr/sbin/nhc`, `nhc-genconf` and `nhc-wrapper`, the helpers
`node-mark-offline` and `node-mark-online` in `/usr/libexec/nhc/`, the check
libraries in `/etc/nhc/scripts/`, and `/etc/logrotate.d/nhc`. The archive and
`make install` leave out `scripts/csc_nvidia_smi.nhc` (the
`check_nvsmi_healthmon` check, by Johan Guldmyr of CSC), so the build fetches it
from the same commit, checks it against sha256
`3834facd81f03c95c797ce4af6aae665ea9fc8b2795b975c36ba369f219971f1`, and installs
it beside the others. It carries no licence of its own and is distributed under
the repository's `LICENSE`. The only change from the archive is the first line
of the three `/usr/sbin` scripts and the two helpers, which EL9's rpmbuild
rewrites from `#!/bin/bash` to `#!/usr/bin/bash`. `/etc/nhc/nhc.conf` is
replaced by a file of two comment lines, so `nhc` run without `-c` runs no
checks and exits 0; the archive's sample configuration runs checks and is not
installed.

`LICENSE` at that commit, carried in the images at
`/usr/share/licenses/lbnl-nhc/LICENSE`, opens:

> Copyright (c) 2010-2021, Michael Jennings <mej@eterm.org>
>
> LBNL Node Health Check (NHC), Copyright (c) 2015, The Regents of the
> University of California, through Lawrence Berkeley National Laboratory
> (subject to receipt of any required approvals from the U.S. Dept. of Energy).
> All rights reserved.

Its three conditions and disclaimer are BSD-3-Clause's, with the University of
California, Lawrence Berkeley National Laboratory and the U.S. Dept. of Energy
in the non-endorsement clause. It ends with LBNL's grant-back clause: there is
no obligation to provide bug fixes, patches or upgrades ("Enhancements") to
anyone, but Enhancements made available publicly, or directly to LBNL, without a
separate written licence agreement are licensed to LBNL non-exclusively,
royalty-free and perpetually, to install, use, modify, prepare derivative works,
incorporate into other software, distribute and sublicense, in binary and source
form. The image changes no NHC source, so it makes no Enhancement. The spec's
licence tag is `BSD-3-Clause-LBNL`.

**Lmod.** The `nccl/2.32.3` modulefile in `login_gpu_pyxis` is at
`/etc/modulefiles/nccl/2.32.3.lua` and sets `NCCL_HOME=/usr`. `module` is Lmod
8.7.65 from EPEL, which every image here and upstream's already carry because
`openmpi` requires `environment(modules)`; `login_gpu_pyxis` now installs it by
name. Its RPM licence tag is `MIT AND LGPL-2.0-only`: Lmod is MIT, and its
`tools/base64.lua` is LGPL-2.0 and ships as Lua source.

The pyxis images also carry the Rocky Linux and EPEL packages enroot and the
toolkit depend on, and the SBOM lists each of them. `login_gpu_pyxis` also
carries what upstream's `sackd` and `login` stages install: kubectl from
`pkgs.k8s.io` (Apache-2.0, the stable release at build time), OpenSSH and SSSD.

## ClusterMAX

`clustermax_audit` carries the tree of
[SemiAnalysisAI/ClusterMAX](https://github.com/SemiAnalysisAI/ClusterMAX) at
commit `1492ac5e4ac992ae436f062cc51a340d61672ca3` (branch `master`, 2026-09-30)
under `/opt/clustermax/`, unmodified, and the wrapper
`/usr/local/bin/clustermax-audit` from this repository, which runs the audit's
`cmax/scripts/1-audit/run.sh` and prints its `audit.values.json` last.

ClusterMAX is Copyright 2025 SemiAnalysis and licensed under the Apache License,
Version 2.0. Its `LICENSE` was read at that commit: sha256
`68aee1a6de2e8cf7b47c6e937709e049704efd2d4dd3671c4f037562d7f313dc`, the same
file as at tag `v0.2.1`. The build refuses a tree whose `LICENSE` has any other
checksum, and the image carries it at `/usr/share/licenses/clustermax/LICENSE`,
with the commit in `COMMIT` beside it. ClusterMAX has no `NOTICE` file at that
commit.

The audit's Python scripts import only the standard library. The image does not
install the `cmax` command-line package or its dependencies. `jq` (MIT) and
`python3` (PSF-2.0) are Rocky Linux packages, listed in the SBOM with the rest.

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
- The pyxis RPM is installed. Upstream's `slurmd-pyxis:26.05-rockylinux9` and
  `login-pyxis:26.05-rockylinux9` copy RPMs from a path that `make rpm` does not
  write, and ship without pyxis.
- `login_gpu_pyxis` is built from this fork's Slurm build. Upstream's
  `login:26.05-rockylinux9` has no `mpi_pmix`, which srun loads on the
  submitting side for `--mpi=pmix`.
- `/etc/slurm/plugstack.conf.d` is mode 755. Upstream creates it with mode 644.
- The enroot, pyxis and nvidia-container-toolkit versions are pinned, and the
  downloads are checked against `pyxis-checksums/SHA256SUMS`. Upstream resolves
  the latest release at build time.
- NCCL is in all three images, and `login_gpu_pyxis` has the `nccl` modulefile.
  Upstream's images have neither.
- `clustermax_audit` has no counterpart upstream.
- NHC is in `slurmd_gpu` and `slurmd_gpu_pyxis`. Upstream's images have none.
