#!/usr/bin/env bash
#****************************************************************************
#* ci/run.sh -- the checks CI runs on every commit, on either forge.
#*
#* Both workflow files (.github/workflows/ci.yml, .forgejo/workflows/ci.yml)
#* call this and nothing else to do the work, so what a check IS lives in one
#* place and the two forges cannot drift on it. It runs unchanged on a laptop,
#* which is how it gets debugged. fwvip-wb's ci/run.sh is the same shape.
#*
#*   1. bootstrap -- ivpm into a venv, then `ivpm update` of the dep-set
#*   2. the checks -- one `dfm run` each; all always run, so one failing does
#*      not hide the others. Each check's logs are collected into $CI_REPORTS
#*      for the artifact upload.
#*   3. summarize -- a job summary, and one verdict line per check
#*
#* Exit status is nonzero iff any check failed (or bootstrap did).
#*
#* Each check is one root of the developer project (flow.dv) -- exactly what
#* a developer types:
#*
#*   sim           dfm run wb-proto     back-to-back kit sim (Verilator)
#*   formal-bmc    dfm run fv           SymbiYosys BMC of the cores
#*   formal-cover  dfm run fv-cover     every cover() reachable (non-vacuity)
#*
#* Each check's verdict is its exit status: the sim bench ends in $fatal on
#* any error, and the formal tasks fail on any sby result but PASS. The kit's
#* tests are not on the project archetype yet, so there are no CTRF/JUnit
#* reports; the logs are the record.
#*
#* Environment:
#*   CI_DEP_SET   ivpm dep-set to fetch (default: dev)
#*   CI_REPORTS   where the logs are collected (default: ci-reports)
#*   IVPM_CACHE   ivpm's package cache (default: ~/.cache/ivpm, the path the
#*                workflows cache between runs)
#*   CI_CACHE_DAYS
#*                prune cache entries not linked for this many days
#*                (default: 14; see ci/ivpm-cache-key.sh)
#*   CI_SKIP_BOOTSTRAP=1
#*                use packages/ as it is -- on a laptop that already has it,
#*                this is just the checks
#****************************************************************************
set -u -o pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

dep_set="${CI_DEP_SET:-dev}"
reports="${CI_REPORTS:-ci-reports}"
export IVPM_CACHE="${IVPM_CACHE:-$HOME/.cache/ivpm}"
mkdir -p "$IVPM_CACHE"

group()    { echo "::group::$*"; }
endgroup() { echo "::endgroup::"; }

# ---- 1. bootstrap ----------------------------------------------------------
if [ "${CI_SKIP_BOOTSTRAP:-0}" != "1" ]; then
    group "bootstrap: ivpm update -d $dep_set"
    if ! command -v direnv >/dev/null 2>&1; then
        # packages/packages.envrc is written for direnv (source_env, PATH_add),
        # so the environment a developer gets from `direnv allow` is the one CI
        # gets too.
        sudo=""
        [ "$(id -u)" = "0" ] || sudo="sudo"
        $sudo apt-get update -qq && $sudo apt-get install -y -qq direnv >/dev/null \
            || { echo "::error::could not install direnv"; exit 1; }
    fi
    # uv as well as ivpm: without uv, ivpm installs python content with pip,
    # whose editable install writes egg-info into the package -- and a cached
    # package (yosys) is a read-only directory, so it fails.
    python3 -m venv .ci-venv \
        && .ci-venv/bin/pip install -q --upgrade pip ivpm uv \
        || { echo "::error::could not install ivpm"; exit 1; }
    .ci-venv/bin/ivpm --version 2>/dev/null || true
    # -a: clone git URLs as written (HTTPS). A runner has no ssh identity.
    PATH="$root/.ci-venv/bin:$PATH" .ci-venv/bin/ivpm update -a -d "$dep_set" \
        || { echo "::error::ivpm update -d $dep_set failed"; exit 1; }
    # Drop cache entries no run has linked for a while, so the saved cache
    # does not grow without bound.
    .ci-venv/bin/ivpm cache clean --days "${CI_CACHE_DAYS:-14}" \
        || echo "::warning::ivpm cache clean failed; the cache is unchanged"
    direnv allow . || exit 1
    endgroup
fi

# ---- 2. the checks ----------------------------------------------------------
rm -rf "$reports"
mkdir -p "$reports"

# check name -> the `dfm run` arguments that are that check.
checks=(sim formal-bmc formal-cover)
declare -A runs=(
    [sim]="wb-proto"
    [formal-bmc]="fv"
    [formal-cover]="fv-cover"
)
declare -A status
for check in "${checks[@]}"; do
    group "$check: dfm run ${runs[$check]}"
    # shellcheck disable=SC2086  # the arguments are meant to split
    direnv exec . dfm run ${runs[$check]} -u log
    status[$check]=$?
    endgroup
    # The run's logs: the sim log, or sby's logfile and per-engine logs.
    d="rundir/fw.proto.wb.dev.${runs[$check]}"
    if [ -d "$d" ]; then
        mkdir -p "$reports/$check"
        (cd "$d" && find . \( -name '*.log' -o -name 'logfile*.txt' -o -name 'status' \) \
            -exec cp --parents {} "$root/$reports/$check/" \;)
    fi
    # On a failure, the logs in the job log too: a forge with no artifact
    # viewer still shows why.
    if [ "${status[$check]}" != "0" ] && [ -d "$reports/$check" ]; then
        find "$reports/$check" -type f | while read -r f; do
            group "log: $f"; tail -n 200 "$f"; endgroup
        done
    fi
done

# ---- 3. summarize ----------------------------------------------------------
verdict() { [ "${status[$1]}" = "0" ] && echo "pass" || echo "FAIL (status ${status[$1]})"; }

# A job summary where the forge has one. GitHub renders it; Forgejo echoes it
# into the log, which does no harm.
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
        echo "| Check | Command | Verdict |"
        echo "|---|---|---|"
        for check in "${checks[@]}"; do
            echo "| \`$check\` | \`dfm run ${runs[$check]}\` | $(verdict $check) |"
        done
    } >> "$GITHUB_STEP_SUMMARY"
fi

rc=0
for check in "${checks[@]}"; do
    printf '%-14s %s\n' "$check:" "$(verdict $check)"
    [ "${status[$check]}" = "0" ] || rc=1
done
exit $rc
