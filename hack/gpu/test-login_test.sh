#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Checks test-login.sh's verdicts against a stub docker. A login image with
# everything passes every check. Then one thing at a time goes missing: srun
# does not offer --container-image because pyxis did not load, srun lists no
# pmix, srun lists only the pmix_v3 version line, a plugin of the replaced
# image is absent, srun reports another Slurm release, a login shell has no
# module command, Lmod lists no nccl module, and libnccl is not in the image.
# Each must fail exactly its own checks, and every planned check must still run.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin"
cat >"$work/bin/docker" <<'EOF'
#!/usr/bin/env bash
# Answers the docker calls test-login.sh makes. The image under test is
# test/login; any other image is the reference. NO_CONTAINER_IMAGE drops the
# pyxis option from srun --help, MPI_LIST replaces srun --mpi=list's output,
# MISSING_PLUGIN is left out of the image's plugin list, SRUN_VERSION
# replaces srun -V, NO_LMOD leaves a login shell without the module command,
# NO_NCCL_MODULE leaves the nccl modulefile out, and NO_NCCL leaves libnccl out.
if [[ $1 == image ]]; then
	exit 0
fi
if [[ $1 != run ]]; then
	echo "stub docker: unexpected arguments: $*" >&2
	exit 1
fi
image=""
for a in "$@"; do
	case "$a" in
	test/* | ref/*) image="$a" ;;
	esac
done
case "$*" in
*"slurmctld -V"*)
	echo "slurm 26.05.4"
	;;
*"have \$f"*"plugstack resolves"*)
	echo "have /usr/lib64/slurm/spank_pyxis.so"
	echo "have /usr/share/pyxis/pyxis.conf"
	echo "plugstack resolves"
	echo "plugstack.conf.d mode 755"
	echo "enroot 4.2.1"
	echo "env ENROOT_VERSION=4.2.1 PYXIS_VERSION=0.24.0"
	;;
*"module load nccl"*)
	if [[ -n ${NO_LMOD:-} ]]; then
		echo "bash: line 1: module: command not found"
	elif [[ -n ${NO_NCCL_MODULE:-} ]]; then
		echo "Lmod has detected the following error: The following module(s) are unknown: \"nccl\""
	elif [[ -n ${NO_NCCL:-} ]]; then
		echo "NCCL_HOME=/usr"
		echo "ls: cannot access '/usr/lib64/libnccl.so.2': No such file or directory"
	else
		echo "NCCL_HOME=/usr"
		echo "/usr/lib64/libnccl.so.2"
	fi
	;;
*"module avail"*)
	if [[ -n ${NO_LMOD:-} ]]; then
		echo "bash: line 1: module: command not found"
		echo "module exit 127"
	else
		echo "---------------------------- /opt/modulefiles/Core ----------------------------"
		if [[ -z ${NO_NCCL_MODULE:-} ]]; then
			echo "   nccl/2.32.3"
		fi
		echo "module exit 0"
	fi
	;;
*"libnccl.so"*)
	if [[ -z ${NO_NCCL:-} ]]; then
		printf '%s\n' /usr/lib64/libnccl.so.2 /usr/lib64/libnccl.so.2.32.3
	fi
	echo "find exit 0"
	;;
*"srun --help"*)
	echo "Usage: srun [OPTIONS(0)... [executable(0) [args(0)...]]]"
	echo "  -e, --error=err             location of stderr redirection"
	if [[ -z ${NO_CONTAINER_IMAGE:-} ]]; then
		echo "      --container-image=[USER@][REGISTRY#]IMAGE[:TAG]|PATH"
	fi
	;;
*"srun --mpi=list"*)
	printf '%b\n' "${MPI_LIST:-MPI plugin types are...\n\tnone\n\tcray_shasta\n\tpmix\n\tpmi2\nspecific pmix plugin versions available: pmix_v3}"
	;;
*"srun -V"*)
	echo "${SRUN_VERSION:-slurm 26.05.4}"
	;;
*"licenses/slurm"*)
	echo "have COPYING"
	echo "have DISCLAIMER"
	echo "have LICENSE.OpenSSL"
	;;
*"basename"*)
	for p in mpi_pmix.so mpi_pmi2.so compress_lz4.so spank_pyxis.so; do
		if [[ $image == ref/* || $p != "${MISSING_PLUGIN:-}" ]]; then
			echo "$p"
		fi
	done | sort
	;;
*)
	echo "stub docker: unexpected command: $*" >&2
	exit 1
	;;
esac
EOF
chmod +x "$work/bin/docker"

fails=0
# case NAME WANT_FAILED [ENV...]: WANT_FAILED is the space-separated ids that
# must fail, empty for none.
case_() {
	local name="$1" want="$2"
	shift 2
	local out rc failed summary
	set +e
	out="$(env PATH="$work/bin:$PATH" "$@" "$HERE/test-login.sh" --image test/login --platform linux/amd64 \
		--same-slurm-as slurmctld=ref/slurmctld --plugins-of ref/login 2>&1)"
	rc=$?
	set -e
	failed="$(sed -n 's/^FAIL \([^:]*\):.*/\1/p' <<<"$out" | sort | tr '\n' ' ' | sed 's/ $//')"
	summary="$(grep -E '^executed=' <<<"$out" || true)"
	if [[ $failed != "$want" ]]; then
		echo "FAIL $name: failed [$failed], want [$want]"
		sed 's/^/    | /' <<<"$out"
		fails=$((fails + 1))
	elif [[ -z $want && $rc != 0 ]] || [[ -n $want && $rc == 0 ]]; then
		echo "FAIL $name: exit $rc with failed [$failed]"
		fails=$((fails + 1))
	elif ! grep -qE '^executed=([0-9]+) planned=\1 ' <<<"$summary"; then
		echo "FAIL $name: not every planned check ran: $summary"
		fails=$((fails + 1))
	else
		echo "ok   $name: failed [$failed], $summary"
	fi
}

case_ "a login with everything" ""
case_ "srun did not load pyxis" "srun/pyxis" NO_CONTAINER_IMAGE=1
case_ "srun lists no pmix" "mpi/pmix" MPI_LIST='MPI plugin types are...\n\tnone\n\tcray_shasta\n\tpmi2'
case_ "only the pmix version line" "mpi/pmix" MPI_LIST='MPI plugin types are...\n\tnone\n\tpmi2\nspecific pmix plugin versions available: pmix_v3'
case_ "a plugin of the replaced image is absent" "plugins/parity" MISSING_PLUGIN=mpi_pmix.so
case_ "another Slurm release" "version/slurmctld" SRUN_VERSION="slurm 26.05.3"
case_ "a login shell without Lmod" "lmod/avail lmod/load" NO_LMOD=1
case_ "Lmod lists no nccl module" "lmod/avail lmod/load" NO_NCCL_MODULE=1
case_ "libnccl is not in the image" "lmod/load nccl/present" NO_NCCL=1

if ((fails != 0)); then
	echo "$fails case(s) failed"
	exit 1
fi
echo "all cases passed"
