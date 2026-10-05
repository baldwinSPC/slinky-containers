#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Runs the clustermax-audit wrapper against stub run.sh scripts. Outside an
# allocation it refuses with exit 2. Inside one it hands run.sh the results
# directory, the slug and the harness, prints audit.values.json after
# everything run.sh printed, even what run.sh's own tee prints late, keeps
# run.sh's exit code, fails when run.sh succeeded without writing the values,
# and removes the results directory.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="$HERE/../../schedmd/slurm/26.05/rockylinux9/files/usr/local/bin/clustermax-audit"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/tmp"

# stub NAME EXIT WRITES_VALUES: a run.sh that prints through a tee it starts
# itself, as ClusterMAX's does, records its environment, optionally writes
# audit.values.json, and exits EXIT.
stub() {
	cat >"$work/$1" <<STUB
#!/usr/bin/env bash
set -euo pipefail
echo "\$RUN_RESULTS_DIR \$CLUSTER_SLUG \$CLUSTERMAX_AUDIT_HARNESS" >"$work/$1.env"
exec > >(sleep 0.3; tee "\$RUN_RESULTS_DIR/audit.out") 2>&1
echo "collector output"
if [[ $3 == yes ]]; then
	echo '{"values": "$1"}' >"\$RUN_RESULTS_DIR/audit.values.json"
fi
echo "Results: \$RUN_RESULTS_DIR"
exit $2
STUB
	chmod +x "$work/$1"
}
stub ok 0 yes
stub fails-with-values 3 yes
stub ok-without-values 0 no
stub fails-without-values 4 no

fails=0
fail() {
	echo "FAIL $1: $2"
	sed 's/^/    | /' <<<"$3"
	fails=$((fails + 1))
}

# run_case NAME STUB WANT_EXIT WANT_LAST [ENV...]
run_case() {
	local name="$1" stub="$2" want_exit="$3" want_last="$4"
	shift 4
	local out rc last dir
	rm -f "$work/$stub.env"
	set +e
	out="$(env -u SLURM_JOB_ID TMPDIR="$work/tmp" CLUSTERMAX_RUN="$work/$stub" "$@" "$WRAPPER" 2>&1)"
	rc=$?
	set -e
	last="$(tail -n1 <<<"$out")"
	if [[ $rc != "$want_exit" ]]; then
		fail "$name" "exit $rc, want $want_exit" "$out"
		return
	fi
	if [[ $last != "$want_last" ]]; then
		fail "$name" "last line '$last', want '$want_last'" "$out"
		return
	fi
	if [[ -n $(ls -A "$work/tmp") ]]; then
		fail "$name" "left behind: $(ls -A "$work/tmp")" "$out"
		rm -rf "${work:?}/tmp/"*
		return
	fi
	if [[ $stub != none ]]; then
		dir="$(sed -n 's/^clustermax-audit: results in \([^,]*\),.*/\1/p' <<<"$out")"
		if [[ "$(cat "$work/$stub.env")" != "$dir ${WANT_SLUG:-slurm} slurm" ]]; then
			fail "$name" "run.sh saw '$(cat "$work/$stub.env")', want '$dir ${WANT_SLUG:-slurm} slurm'" "$out"
			return
		fi
		# The marker is the line before the values, and nothing run.sh printed
		# comes after it.
		if ! sed -n '/^===== audit.values.json =====$/,$p' <<<"$out" | grep -qvF -e 'collector output' -e 'Results:'; then
			fail "$name" "no values section" "$out"
			return
		fi
		if sed -n '/^===== audit.values.json =====$/,$p' <<<"$out" | grep -qF -e 'collector output' -e 'Results:'; then
			fail "$name" "run.sh output after the values" "$out"
			return
		fi
	fi
	echo "ok   $name: exit $rc, last '$last'"
}

run_case "outside an allocation" none 2 \
	"clustermax-audit runs as a Slurm step: salloc ... srun --overlap --container-image=<this image> --container-mounts=/run/slurm clustermax-audit"
run_case "run.sh writes the values" ok 0 '{"values": "ok"}' SLURM_JOB_ID=7
run_case "run.sh fails after writing the values" fails-with-values 3 '{"values": "fails-with-values"}' SLURM_JOB_ID=7
run_case "run.sh succeeds without the values" ok-without-values 1 \
	"audit.values.json was not written (run.sh exited 0)" SLURM_JOB_ID=7
run_case "run.sh fails without the values" fails-without-values 4 \
	"audit.values.json was not written (run.sh exited 4)" SLURM_JOB_ID=7
WANT_SLUG=spark-pool run_case "the slug is the Slurm cluster's name" ok 0 '{"values": "ok"}' \
	SLURM_JOB_ID=7 SLURM_CLUSTER_NAME=spark-pool
WANT_SLUG=named run_case "CLUSTER_SLUG wins" ok 0 '{"values": "ok"}' \
	SLURM_JOB_ID=7 SLURM_CLUSTER_NAME=spark-pool CLUSTER_SLUG=named

if ((fails != 0)); then
	echo "$fails case(s) failed"
	exit 1
fi
echo "all cases passed"
