# syntax=docker/dockerfile:1
# SPDX-FileCopyrightText: Copyright (C) SchedMD LLC.
# SPDX-License-Identifier: Apache-2.0

################################################################################

ARG SLURM_VERSION=26.05.4
ARG SLURM_VERSION_ARCHIVE=slurm-26-05-4-1
ARG SLURM_DIR=slurm
ARG PARENT_IMAGE=rockylinux/rockylinux:9
ARG ALPINE_IMAGE=alpine:latest

# GPU autodetect plugins to build, per architecture: a space-separated subset
# of "nvml rsmi". Empty builds Slurm without either, as upstream does.
ARG GPU_AUTODETECT_AMD64=""
ARG GPU_AUTODETECT_ARM64=""
# NVML headers and link stub, used at build time only: libnvidia-ml.so.1 is
# injected into GPU containers at run time by the NVIDIA container toolkit.
ARG CUDA_NVML_DEVEL=cuda-nvml-devel-12-9-12.9.79-1
ARG CUDA_HOME=/usr/local/cuda-12.9
# ROCm SMI is installed in the build and shipped in the slurmd-gpu image,
# because the AMD device plugin mounts /dev/kfd and /dev/dri and no library.
ARG ROCM_VERSION=7.2.4
ARG ROCM_CORE=rocm-core-7.2.4.70204-93.el8
ARG ROCM_SMI_LIB=rocm-smi-lib-7.8.0.70204-93.el8

################################################################################
FROM ${ALPINE_IMAGE} AS slurm-src

ARG SLURM_VERSION_ARCHIVE
ARG SLURM_DIR
ARG SLURM_TAR="${SLURM_VERSION_ARCHIVE}.tar.gz"
# When set, the archive must match this sha256.
ARG SLURM_SHA256=""

WORKDIR /workspace/

RUN apk add -q --no-cache tar

ADD https://github.com/SchedMD/slurm/archive/${SLURM_TAR} ${SLURM_TAR}

RUN \
  if [ -n "${SLURM_SHA256}" ]; then echo "${SLURM_SHA256}  ${SLURM_TAR}" | sha256sum -c -; fi && \
  mkdir -p ${SLURM_DIR} && \
  tar --strip-components=1 -zxvf ${SLURM_TAR} -C ${SLURM_DIR} && \
  rm ${SLURM_TAR}

################################################################################
FROM ${PARENT_IMAGE} AS build

SHELL ["bash", "-c"]

ARG SLURM_VERSION
ENV SLURM_VERSION=${SLURM_VERSION}
ARG SLURM_DIR
ARG TARGETARCH
ARG GPU_AUTODETECT_AMD64
ARG GPU_AUTODETECT_ARM64
ARG CUDA_NVML_DEVEL
ARG CUDA_HOME
ARG ROCM_VERSION
ARG ROCM_CORE
ARG ROCM_SMI_LIB

USER root
WORKDIR /tmp/

RUN --mount=type=cache,target=/var/cache/dnf,sharing=locked <<EOR
# Pre-Build Slurm
set -xeuo pipefail
dnf -q -y install --setopt='install_weak_deps=False' \
  '@Development' dnf-utils rpm-build 'dnf-command(builddep)' 'dnf-command(config-manager)' epel-release
dnf -q config-manager --enable crb
dnf -q -y upgrade
EOR

# Ref: https://slurm.schedmd.com/gres.html#AutoDetect
RUN --mount=type=cache,target=/var/cache/dnf,sharing=locked <<EOR
# Install GPU Autodetect Dependencies
set -xeuo pipefail
case "${TARGETARCH}" in
amd64) GPU_AUTODETECT="${GPU_AUTODETECT_AMD64}" ;;
arm64) GPU_AUTODETECT="${GPU_AUTODETECT_ARM64}" ;;
*) GPU_AUTODETECT="" ;;
esac
# Runtime packages for the slurmd-gpu stage, verified here against their repository key.
mkdir -p /root/gpu-rpms/
for gpu in ${GPU_AUTODETECT}; do
  case "${gpu}" in
  nvml)
    case "${TARGETARCH}" in
    amd64) CUDA_REPO_ARCH=x86_64 ;;
    arm64) CUDA_REPO_ARCH=sbsa ;;
    esac
    dnf -q config-manager --add-repo "https://developer.download.nvidia.com/compute/cuda/repos/rhel9/${CUDA_REPO_ARCH}/cuda-rhel9.repo"
    dnf -q -y install --setopt='install_weak_deps=False' "${CUDA_NVML_DEVEL}"
    ;;
  rsmi)
    if [ "${TARGETARCH}" != "amd64" ]; then
      echo "rsmi: ROCm publishes no ${TARGETARCH} packages" >&2
      exit 1
    fi
    cat <<EOF | tee /etc/yum.repos.d/rocm.repo
[rocm]
name=ROCm ${ROCM_VERSION}
baseurl=https://repo.radeon.com/rocm/rhel9/${ROCM_VERSION}/main
enabled=1
gpgcheck=1
gpgkey=https://repo.radeon.com/rocm/rocm.gpg.key
EOF
    # rocm_smi.h includes libdrm/drm.h; rocm-smi-lib only suggests libdrm-devel,
    # and configure drops rsmi when the header does not compile.
    dnf -q -y install --setopt='install_weak_deps=False' "${ROCM_CORE}" "${ROCM_SMI_LIB}" libdrm-devel
    dnf -q download --destdir=/root/gpu-rpms/ "${ROCM_CORE}" "${ROCM_SMI_LIB}"
    # configure probes /opt/rocm; the packages install under /opt/rocm-<version>.
    ln -sfn "/opt/rocm-${ROCM_VERSION}" /opt/rocm
    ;;
  *)
    echo "unknown GPU autodetect plugin: ${gpu}" >&2
    exit 1
    ;;
  esac
done
EOR

COPY --from=slurm-src /workspace/${SLURM_DIR} ${SLURM_DIR}

# Ref: https://slurm.schedmd.com/quickstart_admin.html#rpmbuild
RUN --mount=type=cache,target=/var/cache/dnf,sharing=locked <<EOR
# Build Slurm
set -xeuo pipefail
SLURM_RPM_DIR="$(rpmspec -q ${SLURM_DIR}/slurm.spec 2> /dev/null | grep -Eo "slurm-[[:digit:]]+\.[[:digit:]]+\.[[:digit:]]+(-[[:alnum:]]+)?" | head -n1 | sed -E 's/-[[:digit:]]+$//g')"
if [ "${SLURM_DIR}" != "$SLURM_RPM_DIR" ]; then
  mv ${SLURM_DIR} $SLURM_RPM_DIR
fi
rm -f ${SLURM_RPM_DIR}.tar.bz2
tar -caf ${SLURM_RPM_DIR}.tar.bz2 $SLURM_RPM_DIR
dnf -y builddep \
  -D '_with_cgroupv2 1' \
  -D '_with_slurmrestd 1' \
  -D '_with_jwt 1' \
  -D '_with_yaml 1' \
  -D '_with_hwloc --with-hwloc' \
  -D '_with_numa 1' \
  -D '_with_pmix --with-pmix' \
  -D '_with_ucx --with-ucx' \
  -D '_with_lua yes' \
  -D '_with_freeipmi 1' \
  -D '_with_hdf5 yes' \
  -D '_with_libcurl yes' \
  -D '_enable_debug 1' \
  ${SLURM_RPM_DIR}/slurm.spec >/dev/null
## FIXME: remove package installations after RPM spec makes them dependencies: --with-hdf5
# lz4-devel: configure builds compress_lz4 (sbcast --compress=lz4) when it finds lz4.
dnf -q -y install --setopt='install_weak_deps=False' \
  hdf5-devel lz4-devel
case "${TARGETARCH}" in
amd64) GPU_AUTODETECT="${GPU_AUTODETECT_AMD64}" ;;
arm64) GPU_AUTODETECT="${GPU_AUTODETECT_ARM64}" ;;
*) GPU_AUTODETECT="" ;;
esac
RPMBUILD_GPU=()
for gpu in ${GPU_AUTODETECT}; do
  case "${gpu}" in
  # Passed to rpmbuild, where configure fails without NVML. builddep ignores it:
  # slurm.spec declares no build dependency for NVML.
  nvml) RPMBUILD_GPU+=(-D "_with_nvml --with-nvml=${CUDA_HOME}") ;;
  # slurm.spec has no rsmi option; configure finds ROCm SMI under /opt/rocm.
  rsmi) ;;
  esac
done
# --with pmix: builddep above installs pmix-devel for '_with_pmix', but configure
# leaves mpi/pmix out unless rpmbuild passes it too.
rpmbuild -ta --with slurmrestd --with jwt --with pmix "${RPMBUILD_GPU[@]}" ${SLURM_RPM_DIR}.tar.bz2 >/dev/null
# configure drops a plugin with a warning when its library is missing, so check
# that every requested one is in the package slurmd installs.
SLURM_RPM_FILES="$(rpm -qlp /root/rpmbuild/RPMS/*/slurm-[0-9]*.rpm)"
for gpu in ${GPU_AUTODETECT}; do
  if ! grep -qx "/usr/lib64/slurm/gpu_${gpu}.so" <<<"${SLURM_RPM_FILES}"; then
    echo "gpu_${gpu}.so is not in the slurm package" >&2
    exit 1
  fi
done
EOR

################################################################################
FROM ${PARENT_IMAGE} AS base

SHELL ["bash", "-c"]

ARG SLURM_VERSION
ENV SLURM_VERSION=${SLURM_VERSION}

USER root
WORKDIR /tmp/

ARG SLURM_USER=slurm
ARG SLURM_USER_UID=401
ARG SLURM_USER_GID=401

RUN <<EOR
# Create SlurmUser
set -xeuo pipefail
groupadd --system --gid=${SLURM_USER_GID} ${SLURM_USER}
useradd --system --no-log-init --uid=${SLURM_USER_UID} --gid=${SLURM_USER_GID} --shell=/usr/sbin/nologin ${SLURM_USER}
EOR

RUN <<EOR
# Remove Users
set -xeuo pipefail
for user in $(ls /home/); do
  userdel --remove $user
done
EOR

RUN --mount=type=cache,target=/var/cache/dnf,sharing=locked <<EOR
# Install Dependencies
set -xeuo pipefail
# For: Slurm RPM Dependencies
dnf -q -y install --setopt='install_weak_deps=False' \
  'dnf-command(config-manager)' epel-release
dnf config-manager --enable crb
dnf -q -y upgrade
# Init System
dnf -q -y install --setopt='install_weak_deps=False' \
  supervisor tini
# Debug
dnf -q -y install --setopt='install_weak_deps=False' \
  procps-ng iputils ncurses
EOR

COPY --from=build /root/rpmbuild/RPMS/**/*.rpm /tmp/

################################################################################
FROM base AS base-extra

SHELL ["bash", "-c"]

RUN --mount=type=cache,target=/var/cache/dnf,sharing=locked <<EOR
# Install Extra Packages
set -xeuo pipefail
dnf -q -y install --setopt='install_weak_deps=False' \
  openmpi
EOR

################################################################################
FROM base AS slurmctld

SHELL ["bash", "-c"]

USER root
WORKDIR /tmp/

# Ref: https://slurm.schedmd.com/quickstart_admin.html#pkg_install
RUN --mount=type=cache,target=/var/cache/dnf,sharing=locked <<EOR
# Install Slurm Packages
set -xeuo pipefail
dnf -q -y install --setopt='install_weak_deps=False' \
  socat \
  authselect sssd sssd-ad sssd-idp sssd-ipa sssd-krb5 sssd-ldap \
  krb5-pkinit \
  ./slurm-slurmctld-[0-9]*.rpm \
  ./slurm-[0-9]*.rpm
rm *.rpm
# Configure
mkdir -p /etc/authselect
authselect create-profile slinky -b sssd
authselect select custom/slinky --force
EOR

COPY files/etc/supervisord.conf /etc/
COPY \
  files/etc/supervisord.d/slurmctld.ini \
  files/etc/supervisord.d/fakesystemd.ini \
  files/etc/supervisord.d/sssd.ini \
  /etc/supervisord.d/
COPY files/usr/local/bin/fakesystemd.sh /usr/local/bin/
COPY files/usr/local/bin/slurmctld-entrypoint.sh /usr/local/bin/entrypoint.sh

EXPOSE 6817/tcp
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

################################################################################
FROM base-extra AS slurmd

SHELL ["bash", "-c"]

USER root
WORKDIR /tmp/

# Ref: https://slurm.schedmd.com/quickstart_admin.html#pkg_install
RUN --mount=type=cache,target=/var/cache/dnf,sharing=locked <<EOR
# Install Slurm Packages
set -xeuo pipefail
dnf -q -y install --setopt='install_weak_deps=False' \
  gawk socat \
  openssh-server \
  authselect sssd sssd-ad sssd-idp sssd-ipa sssd-krb5 sssd-ldap \
  krb5-pkinit \
  ./slurm-devel-[0-9]*.rpm \
  ./slurm-libpmi-[0-9]*.rpm \
  ./slurm-pam_slurm-[0-9]*.rpm \
  ./slurm-slurmd-[0-9]*.rpm \
  ./slurm-[0-9]*.rpm
rm *.rpm
# Configure
mkdir -p /var/spool/slurmd/
mkdir -p /etc/authselect
authselect create-profile slinky -b sssd
sed -i -E '/^(passwd|group):/ { /slurm/! s/(files)/\1 slurm/g }' /etc/authselect/custom/slinky/nsswitch.conf
authselect select custom/slinky with-mkhomedir --force
rm -f /etc/ssh/ssh_host_*
mkdir -p /usr/local/entrypoint.d/
EOR

COPY files/etc/supervisord.conf /etc/
COPY \
  files/etc/supervisord.d/fakesystemd.ini \
  files/etc/supervisord.d/slurmd.ini \
  files/etc/supervisord.d/sshd.ini \
  files/etc/supervisord.d/sssd.ini \
  /etc/supervisord.d/
COPY files/usr/local/bin/fakesystemd.sh /usr/local/bin/
COPY files/usr/local/bin/slurmd-entrypoint.sh /usr/local/bin/entrypoint.sh

EXPOSE 6818/tcp 22/tcp
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

################################################################################
FROM slurmd AS slurmd-gpu

SHELL ["bash", "-c"]

ARG TARGETARCH
ARG GPU_AUTODETECT_AMD64
ARG GPU_AUTODETECT_ARM64
ARG ROCM_VERSION
ARG SLURM_DIR

USER root
WORKDIR /tmp/

# slurm.spec installs no licence file.
COPY --from=slurm-src \
  /workspace/${SLURM_DIR}/COPYING \
  /workspace/${SLURM_DIR}/DISCLAIMER \
  /workspace/${SLURM_DIR}/LICENSE.OpenSSL \
  /usr/share/licenses/slurm/

# Slurm dlopens libnvidia-ml.so.1 or librocm_smi64.so itself when gres.conf sets
# AutoDetect=nvml or AutoDetect=rsmi; neither plugin links the library.
RUN --mount=type=cache,target=/var/cache/dnf,sharing=locked \
  --mount=type=bind,from=build,source=/root/gpu-rpms/,target=/tmp/gpu-rpms/ <<EOR
# Install GPU Autodetect Runtime
set -xeuo pipefail
case "${TARGETARCH}" in
amd64) GPU_AUTODETECT="${GPU_AUTODETECT_AMD64}" ;;
arm64) GPU_AUTODETECT="${GPU_AUTODETECT_ARM64}" ;;
*) GPU_AUTODETECT="" ;;
esac
if [ -z "${GPU_AUTODETECT}" ]; then
  echo "slurmd-gpu: no GPU autodetect plugin requested for ${TARGETARCH}" >&2
  exit 1
fi
for gpu in ${GPU_AUTODETECT}; do
  if [ ! -f "/usr/lib64/slurm/gpu_${gpu}.so" ]; then
    echo "gpu_${gpu}.so is not installed" >&2
    exit 1
  fi
  case "${gpu}" in
  # The NVIDIA container toolkit injects libnvidia-ml.so.1 into GPU containers.
  nvml) ;;
  rsmi)
    dnf -q -y install --setopt='install_weak_deps=False' /tmp/gpu-rpms/*.rpm
    echo "/opt/rocm-${ROCM_VERSION}/lib" >/etc/ld.so.conf.d/rocm-smi.conf
    ldconfig
    ;;
  esac
done
EOR

################################################################################
FROM base AS slurmdbd

SHELL ["bash", "-c"]

USER root
WORKDIR /tmp/

# Ref: https://slurm.schedmd.com/quickstart_admin.html#pkg_install
RUN --mount=type=cache,target=/var/cache/dnf,sharing=locked <<EOR
# Install Slurm Packages
set -xeuo pipefail
dnf -q -y install --setopt='install_weak_deps=False' \
  ./slurm-slurmdbd-[0-9]*.rpm \
  ./slurm-[0-9]*.rpm
rm *.rpm
EOR

EXPOSE 6819/tcp
ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/sbin/slurmdbd", "-D"]

################################################################################
FROM base AS slurmrestd

SHELL ["bash", "-c"]

USER root
WORKDIR /tmp/

# Ref: https://slurm.schedmd.com/quickstart_admin.html#pkg_install
RUN --mount=type=cache,target=/var/cache/dnf,sharing=locked <<EOR
# Install Slurm Packages
set -xeuo pipefail
dnf -q -y install --setopt='install_weak_deps=False' \
  ./slurm-slurmrestd-[0-9]*.rpm \
  ./slurm-[0-9]*.rpm
rm *.rpm
EOR

EXPOSE 6820/tcp
ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/sbin/slurmrestd"]
CMD ["0.0.0.0:6820"]

################################################################################
FROM base-extra AS sackd

SHELL ["bash", "-c"]

USER root
WORKDIR /tmp/

ADD https://dl.k8s.io/release/stable.txt kubernetes_stable.txt

# Ref: https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/#install-using-native-package-management
RUN --mount=type=cache,target=/var/cache/dnf,sharing=locked <<EOR
# Install kubectl
set -xeuo pipefail
VERSION="$(cat kubernetes_stable.txt | grep -Eo '^v[0-9]+\.[0-9]+')"
cat <<EOF | tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/${VERSION}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/${VERSION}/rpm/repodata/repomd.xml.key
EOF
dnf -q -y install --setopt='install_weak_deps=False' kubectl
rm *.txt
EOR

# Ref: https://slurm.schedmd.com/quickstart_admin.html#pkg_install
RUN --mount=type=cache,target=/var/cache/dnf,sharing=locked <<EOR
# Install Slurm Packages
set -xeuo pipefail
dnf -q -y install --setopt='install_weak_deps=False' \
  socat \
  ./slurm-sackd-[0-9]*.rpm \
  ./slurm-[0-9]*.rpm
rm *.rpm
# Prepare Directories
mkdir -p /run/slurm/
EOR

COPY files/etc/supervisord.conf /etc/
COPY \
  files/etc/supervisord.d/sackd.ini \
  files/etc/supervisord.d/fakesystemd.ini \
  /etc/supervisord.d/
COPY files/usr/local/bin/fakesystemd.sh /usr/local/bin/
COPY files/usr/local/bin/sackd-entrypoint.sh /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

################################################################################
FROM sackd AS login

SHELL ["bash", "-c"]

USER root
WORKDIR /tmp/

# Ref: https://slurm.schedmd.com/quickstart_admin.html#pkg_install
RUN --mount=type=cache,target=/var/cache/dnf,sharing=locked <<EOR
# Install Packages
set -xeuo pipefail
dnf -q -y install --setopt='install_weak_deps=False' \
  socat \
  openssh-server \
  authselect sssd sssd-ad sssd-idp sssd-ipa sssd-krb5 sssd-ldap \
  krb5-pkinit
# Configure
mkdir -p /etc/authselect
authselect create-profile slinky -b sssd
authselect select custom/slinky with-mkhomedir --force
rm -f /etc/ssh/ssh_host_*
mkdir -p /usr/local/entrypoint.d/
EOR

COPY files/etc/supervisord.conf /etc/
COPY \
  files/etc/supervisord.d/fakesystemd.ini \
  files/etc/supervisord.d/sackd.ini \
  files/etc/supervisord.d/sshd.ini \
  files/etc/supervisord.d/sssd.ini \
  /etc/supervisord.d/
COPY files/usr/local/bin/fakesystemd.sh /usr/local/bin/
COPY files/usr/local/bin/login-entrypoint.sh /usr/local/bin/entrypoint.sh

EXPOSE 22/tcp
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

################################################################################
FROM login AS login-gpu

SHELL ["bash", "-c"]

ARG SLURM_DIR

# slurm.spec installs no licence file.
COPY --from=slurm-src \
  /workspace/${SLURM_DIR}/COPYING \
  /workspace/${SLURM_DIR}/DISCLAIMER \
  /workspace/${SLURM_DIR}/LICENSE.OpenSSL \
  /usr/share/licenses/slurm/
