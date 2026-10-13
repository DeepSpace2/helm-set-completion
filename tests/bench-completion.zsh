#!/usr/bin/env zsh

# Informational completion benchmarks; run with:
#   zsh tests/bench-completion.zsh [--iterations N] [--real-remote]
# Requires zsh, Helm, and Mike Farah yq v4. A Kubernetes cluster is not needed.

emulate -LR zsh
zmodload zsh/datetime || {
  print -u2 -- 'ERROR: zsh/datetime is required for high-resolution timings.'
  exit 2
}

local iterations=20
local real_remote=0
while (( $# )); do
  case $1 in
    --iterations)
      (( $# >= 2 )) || { print -u2 -- 'ERROR: --iterations requires a value.'; exit 2; }
      [[ $2 == <-> && $2 -gt 0 ]] || { print -u2 -- 'ERROR: iterations must be a positive integer.'; exit 2; }
      iterations=$2
      shift 2
      ;;
    --real-remote)
      real_remote=1
      shift
      ;;
    -h|--help)
      print -- 'Usage: zsh tests/bench-completion.zsh [--iterations N] [--real-remote]'
      print -- '  --iterations N  Samples per scenario (default: 20).'
      print -- '  BENCH_LOCAL_CHART  Use this local chart instead of the small generated fixture.'
      print -- '  --real-remote   Include live Helm repository lookups; this uses the network.'
      print -- '                  Override chart/repo/version with BENCH_CHART, BENCH_REPO, BENCH_VERSION.'
      exit 0
      ;;
    *)
      print -u2 -- "ERROR: unknown option: $1"
      exit 2
      ;;
  esac
done

if ! (( $+commands[yq] )); then
  print -u2 -- 'ERROR: benchmark requires Mike Farah yq v4 on PATH.'
  exit 2
fi
if ! (( $+commands[helm] )); then
  print -u2 -- 'ERROR: benchmark requires Helm on PATH.'
  exit 2
fi

typeset -gi _bench_real_remote=$real_remote
typeset -gi _bench_match_count=0
typeset -g _bench_remote_chart=${BENCH_CHART:-kube-state-metrics}
typeset -g _bench_remote_repo=${BENCH_REPO:-https://prometheus-community.github.io/helm-charts}
typeset -g _bench_remote_version=${BENCH_VERSION:-8.4.1}
typeset -g _bench_local_chart
typeset -ga _bench_candidate_keys

_helm() { return 0; }
compdef() { :; }
_message() { :; }
compadd() { return 0; }

helm() {
  if [[ $2 == --help ]]; then
    cat <<'HELP'
Usage: helm install [NAME] [CHART] [flags]

Flags:
  -f, --values strings                  values files
      --repo string                     chart repository
      --version string                  chart version
  -n, --namespace string                namespace
HELP
    return 0
  fi

  if [[ $1 == show && $2 == values ]]; then
    if (( _bench_real_remote )); then
      command helm show values "${@:3}"
    else
      cat <<'VALUES'
image:
  registry: registry.example.invalid
  repository: sample/remote
resources:
  requests:
    cpu: 100m
VALUES
    fi
    return $?
  fi

  return 1
}

source "${0:A:h:h}/helm-set-completion.zsh"

local tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/helm-completion-bench.XXXXXX")
trap 'rm -rf -- "$tmp_dir"' EXIT INT TERM

local chart="$tmp_dir/chart" dependency_chart="$tmp_dir/dependency-chart"
local values_file="$tmp_dir/extra-values.yaml"
mkdir -p "$chart" "$dependency_chart/charts/metrics"

cat > "$chart/Chart.yaml" <<'YAML'
apiVersion: v2
name: benchmark-chart
version: 0.1.0
YAML
cat > "$chart/values.yaml" <<'YAML'
image:
  registry: registry.example.invalid
  repository: sample/application
resources:
  requests:
    cpu: 100m
tolerations:
  - key: dedicated
    operator: Equal
YAML

cat > "$dependency_chart/Chart.yaml" <<'YAML'
apiVersion: v2
name: dependency-benchmark-chart
version: 0.1.0
dependencies:
  - name: metrics
    alias: telemetry
    version: 1.0.0
YAML
cat > "$dependency_chart/values.yaml" <<'YAML'
application:
  enabled: true
YAML
cat > "$dependency_chart/charts/metrics/values.yaml" <<'YAML'
collector:
  enabled: true
YAML

cat > "$values_file" <<'YAML'
custom:
  setting: benchmark
YAML
_bench_local_chart=${BENCH_LOCAL_CHART:-$chart}
if [[ ! -f "$_bench_local_chart/Chart.yaml" || ! -f "$_bench_local_chart/values.yaml" ]]; then
  print -u2 -- "ERROR: local benchmark chart must contain Chart.yaml and values.yaml: $_bench_local_chart"
  exit 2
fi
_bench_candidate_keys=(${(f)"$(<"$chart/values.yaml" _helm_yaml_to_keys '')"})

_bench_completion() {
  local scenario=$1

  case $scenario in
    candidate-prefix)
      _bench_filter_candidates prefix image.re
      return
      ;;
    candidate-fuzzy)
      _bench_filter_candidates fuzzy imgrep
      return
      ;;
    local)
      words=(helm template demo "$_bench_local_chart" --set '')
      ;;
    values-file)
      words=(helm template demo "$_bench_local_chart" -f "$values_file" --set '')
      ;;
    dependency)
      words=(helm template demo "$dependency_chart" --set '')
      ;;
    array-index)
      words=(helm template demo "$chart" \
        --set 'tolerations[0].key=dedicated' --set '')
      ;;
    remote)
      words=(helm template demo "$_bench_remote_chart" \
        --repo "$_bench_remote_repo" --version "$_bench_remote_version" --set '')
      ;;
    *)
      print -u2 -- "ERROR: unknown benchmark scenario: $scenario"
      return 2
      ;;
  esac

  CURRENT=${#words}
  PREFIX=${words[-1]}
  IPREFIX=''
  SUFFIX=''
  _helm_with_values >/dev/null
}

_bench_filter_candidates() {
  emulate -L zsh
  local mode=$1 needle=$2 key
  local -i matches=0

  for key in $_bench_candidate_keys; do
    case $mode in
      prefix) [[ ${key:l} == ${needle:l}* ]] && (( matches++ )) ;;
      fuzzy) _helm_value_fuzzy_match "$needle" "$key" && (( matches++ )) ;;
    esac
  done
  _bench_match_count=$matches
}

_bench_clear_completion_caches() {
  _helm_local_value_keys_cache=()
  _helm_local_value_cache_fingerprint=()
  _helm_local_value_cache_loaded=()
  _helm_remote_value_keys_cache=()
  _helm_remote_value_cache_loaded=()
}

_bench_report() {
  local label=$1 scenario=$2 sample_count=$3 clear_cache=$4
  local -F started finished elapsed
  local i median_index p95_index median p95
  local -a samples sorted_samples

  for (( i = 1; i <= sample_count; i++ )); do
    (( clear_cache )) && _bench_clear_completion_caches
    started=$EPOCHREALTIME
    _bench_completion "$scenario"
    finished=$EPOCHREALTIME
    elapsed=$(( (finished - started) * 1000.0 ))
    samples+=($elapsed)
  done

  sorted_samples=("${(@on)samples}")
  median_index=$(( (sample_count + 1) / 2 ))
  p95_index=$(( (sample_count * 95 + 99) / 100 ))
  median=${sorted_samples[median_index]}
  p95=${sorted_samples[p95_index]}
  printf '%-30s n=%-3d median %8.3f ms  p95 %8.3f ms\n' \
    "$label" "$sample_count" "$median" "$p95"
}

# Prime Helm help metadata and zsh dispatch before timing feature scenarios.
_helm_load_value_arg_flags template || {
  print -u2 -- 'ERROR: could not load Helm template option metadata.'
  exit 1
}
local local_cold_samples=$(( iterations < 3 ? iterations : 3 ))
_bench_filter_candidates prefix image.re
local prefix_match_count=$_bench_match_count
_bench_filter_candidates fuzzy imgrep
local fuzzy_match_count=$_bench_match_count

print -- "Helm completion benchmark (target: $iterations samples; local cold capped at 3, live remote capped at 5)"
print -- "zsh: ${ZSH_VERSION}; $(command helm version --short); $(command yq --version)"
print -- 'Times include completion data loading and candidate matching; shell startup is excluded.'
print -- 'Remote default mode uses a deterministic Helm stub; live repository mode is opt-in.'
print -- "Preloaded-key match counts: prefix=$prefix_match_count fuzzy=$fuzzy_match_count"
print -- ''

_bench_report 'local chart cold cache' local $local_cold_samples 1
_bench_completion local
_bench_report 'local chart warm cache' local $iterations 0
_bench_report 'chart plus -f values file' values-file $iterations 0
_bench_report 'chart with dependency defaults' dependency $iterations 1
_bench_completion array-index
_bench_report 'array next-index suggestions' array-index $iterations 0
_bench_report 'candidate filtering (prefix)' candidate-prefix $iterations 0
_bench_report 'candidate filtering (fuzzy)' candidate-fuzzy $iterations 0
_bench_report 'mock remote cold cache' remote $iterations 1
_bench_completion remote
_bench_report 'mock remote warm cache' remote $iterations 0

if (( real_remote )); then
  local real_remote_samples=$(( iterations < 5 ? iterations : 5 ))
  print -- ''
  print -- "Live remote chart: $_bench_remote_chart from $_bench_remote_repo (version $_bench_remote_version)"
  _bench_report 'live remote cold cache' remote $real_remote_samples 1
  _bench_completion remote
  _bench_report 'live remote warm cache' remote $iterations 0
fi
