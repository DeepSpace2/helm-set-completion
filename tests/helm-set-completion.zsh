#!/usr/bin/env zsh

# Run with: zsh -f tests/helm-set-completion.zsh
# Requires zsh and Mike Farah yq v4. Helm and a Kubernetes cluster are not
# needed; completion dispatch and compadd are stubbed below.

emulate -LR zsh
setopt no_unset

if ! (( $+commands[yq] )); then
  print -u2 -- 'ERROR: tests require yq v4 (Mike Farah).'
  exit 2
fi

typeset -gi original_completion_calls=0
typeset -gi failures=0
typeset -gi awk_calls=0
typeset -ga offered_completions completion_messages
typeset -g compadd_prefix compadd_iprefix IPREFIX help_calls_file remote_lookup_file remote_lookup_args
typeset -gi compadd_quote_disabled=0

_helm() {
  (( original_completion_calls++ ))
  return 0
}

helm() {
  if [[ $2 == --help ]]; then
    [[ $1 == template || $1 == install || $1 == upgrade ]] || return 1
    print -r -- "$1" >> "$help_calls_file"
    cat <<'HELP'
Usage: helm install [NAME] [CHART] [flags]

Flags:
  -f, --values strings                  values files
      --generated-option customValue     test dynamically discovered value option
      --custom-switch                    test dynamically discovered boolean option
      --name-template string             test named option
      --chart-channel string             test chart option
      --kube-token string                test global option
      --repo string                      test chart repository option
      --version string                   test chart version option
  -n, --namespace string                 test short and long option
Global Flags:
HELP
    return 0
  fi
  if [[ $1 == show && $2 == values ]]; then
    print -r -- "show:$3" >> "$help_calls_file"
    print -r -- "${(j: :)@}" >> "$remote_lookup_file"
    if [[ $3 == *archive-child-1.0.0.tgz ]]; then
      cat <<'VALUES'
archiveSetting: enabled
VALUES
    elif [[ $3 == sample/remote-chart ]]; then
      cat <<'VALUES'
remoteLookup:
  setting: true
VALUES
    else
      print -r -- 'fallbackOnly: true'
    fi
    return 0
  fi
  return 1
}

awk() {
  (( awk_calls++ ))
  return 127
}

compdef() { :; }
_message() { completion_messages+=("$*"); }

compset() {
  [[ $1 == -P && $2 == '--set=' && $PREFIX == --set=* ]] || return 1
  IPREFIX+="${PREFIX%%=*}="
  PREFIX=${PREFIX#--set=}
  return 0
}

compadd() {
  local after_separator=0 arg
  compadd_prefix=$PREFIX
  compadd_iprefix=$IPREFIX
  for arg in "$@"; do
    [[ $arg == -Q ]] && compadd_quote_disabled=1
    if [[ $arg == -- ]]; then
      after_separator=1
      continue
    fi
    (( after_separator )) && offered_completions+=("$arg")
  done
  return 0
}

source "${0:A:h:h}/helm-set-completion.zsh"

assert_contains() {
  local expected=$1 description=$2 item
  for item in $offered_completions; do
    [[ $item == "$expected" ]] && return 0
  done
  print -u2 -- "FAIL: $description; expected '$expected'; got: ${(j:, :)offered_completions}"
  (( failures++ ))
}

assert_not_contains() {
  local unexpected=$1 item
  for item in $offered_completions; do
    if [[ $item == "$unexpected" ]]; then
      print -u2 -- "FAIL: did not expect completion '$unexpected'"
      (( failures++ ))
      return 0
    fi
  done
  return 0
}

assert_equal() {
  local expected=$1 actual=$2 description=$3
  if [[ $actual != $expected ]]; then
    print -u2 -- "FAIL: $description (expected '$expected', got '$actual')"
    (( failures++ ))
  fi
}

remote_lookup_count() {
  local line count=0
  while IFS= read -r line; do
    (( count++ ))
  done < "$remote_lookup_file"
  REPLY=$count
}

reset_completion() {
  offered_completions=()
  completion_messages=()
  compadd_quote_disabled=0
}

run_completion() {
  words=("$@")
  CURRENT=${#words}
  PREFIX=${words[-1]}
  IPREFIX=''
  SUFFIX=''
  _helm_with_values
}

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/helm-set-completion.XXXXXX")
trap 'rm -rf -- "$tmp_dir"' EXIT INT TERM
help_calls_file="$tmp_dir/help-calls"
: > "$help_calls_file"
remote_lookup_file="$tmp_dir/remote-lookups"
: > "$remote_lookup_file"

chart="$tmp_dir/chart"
mkdir -p "$chart/charts/child"
cat > "$chart/Chart.yaml" <<'YAML'
apiVersion: v2
name: test-chart
version: 0.1.0
dependencies:
  - name: child
    alias: monitoring
    version: 1.0.0
YAML
cat > "$chart/values.yaml" <<'YAML'
metricsEnabled: false
global:
  enabled: true
nodeSelector:
  kubernetes.io/role: infra
  prometheus.io/scrape.enabled: true
  kubernetes:
    io/role: nested
tolerations:
  - key: dedicated
    operator: Equal
YAML
cat > "$chart/charts/child/values.yaml" <<'YAML'
metrics:
  enabled: false
collector:
  image:
    tag: test
YAML
values_file="$tmp_dir/extra-values.yaml"
cat > "$values_file" <<'YAML'
custom:
  setting: value
YAML

archive_chart="$tmp_dir/archive-chart"
mkdir -p "$archive_chart/charts"
cat > "$archive_chart/Chart.yaml" <<'YAML'
apiVersion: v2
name: archive-chart
version: 0.1.0
dependencies:
  - name: archive-child
    alias: archived
    version: 1.0.0
YAML
cat > "$archive_chart/values.yaml" <<'YAML'
localSetting: original
YAML
archive_dependency="$archive_chart/charts/archive-child-1.0.0.tgz"
print -- 'fake archive contents' > "$archive_dependency"

print -- 'Test: normal Helm completion delegates to the original function'
reset_completion
run_completion helm template release "$chart" --ver
assert_equal 1 "$original_completion_calls" 'normal completion fallback call count'

print -- 'Test: --set suggests keys from the local chart defaults'
reset_completion
run_completion helm template release "$chart" --set ''
assert_contains 'global.enabled=' 'local chart key'
assert_contains 'metricsEnabled=' 'local chart key'

print -- 'Test: dotted YAML keys are escaped without escaping true nesting'
reset_completion
run_completion helm template release "$chart" --set ''
assert_contains 'nodeSelector.kubernetes\.io/role=' 'literal dotted key is escaped'
assert_contains 'nodeSelector.prometheus\.io/scrape\.enabled=' 'all literal dots in a YAML key are escaped'
assert_contains 'nodeSelector.kubernetes.io/role=' 'nested keys remain separated by dots'
assert_equal 0 "$compadd_quote_disabled" 'zsh must quote escaped key characters when inserting completions'

print -- 'Test: array-of-map values preserve their Helm indices'
reset_completion
run_completion helm template release "$chart" --set ''
assert_contains 'tolerations[0].key=' 'first array element key'
assert_contains 'tolerations[0].operator=' 'first array element operator'
assert_not_contains 'tolerations[1].key='

print -- 'Test: repeated --set suggests existing and next array indices'
reset_completion
run_completion helm template release "$chart" \
  --set 'tolerations[0].key=dedicated' --set ''
assert_contains 'tolerations[0].operator=' 'another field on the existing array element'
assert_contains 'tolerations[1].key=' 'next array element key'

print -- 'Test: array-index prefix narrows suggestions to that element'
reset_completion
run_completion helm template release "$chart" \
  --set 'tolerations[0].key=dedicated' --set 'tolerations[1].'
assert_contains 'tolerations[1].key=' 'typed next-index key prefix'
assert_contains 'tolerations[1].operator=' 'typed next-index operator prefix'
assert_not_contains 'tolerations[0].operator='

print -- 'Test: sparse prior array indices suggest the next maximum index'
reset_completion
run_completion helm template release "$chart" \
  --set 'tolerations[2].key=dedicated' --set ''
assert_contains 'tolerations[0].operator=' 'chart-provided array element remains suggested'
assert_contains 'tolerations[3].key=' 'key at the next index after a sparse prior index'
assert_contains 'tolerations[3].operator=' 'operator at the next index after a sparse prior index'

print -- 'Test: escaped array brackets in prior --set arguments are recognized'
reset_completion
run_completion helm template release "$chart" \
  --set 'tolerations\[0\].key=dedicated' --set ''
assert_contains 'tolerations[0].operator=' 'existing array element with escaped brackets'
assert_contains 'tolerations[1].key=' 'next array index after escaped brackets'

print -- 'Test: --set includes explicit local values files'
reset_completion
run_completion helm template release "$chart" -f "$values_file" --set ''
assert_contains 'custom.setting=' 'explicit values-file key'
cat >> "$values_file" <<'YAML'
  refreshed: true
YAML
reset_completion
run_completion helm template release "$chart" -f "$values_file" --set ''
assert_contains 'custom.refreshed=' 'values files are reread after edits'

print -- 'Test: values files supplied with equals syntax are included'
for values_option in --values= -f=; do
  reset_completion
  run_completion helm template release "$chart" "${values_option}${values_file}" --set ''
  assert_contains 'custom.setting=' "values-file key from ${values_option}FILE"
done

print -- 'Test: remote chart lookup receives the selected repository and version'
reset_completion
: > "$remote_lookup_file"
run_completion helm install release sample/remote-chart \
  --repo https://charts.example.invalid/public \
  --version 2.3.4 --set ''
assert_contains 'remoteLookup.setting=' 'remote chart value key'
IFS= read -r remote_lookup_args < "$remote_lookup_file"
assert_equal \
  'show values sample/remote-chart --repo https://charts.example.invalid/public --version 2.3.4' \
  "$remote_lookup_args" \
  'remote values lookup arguments'
remote_lookup_count
assert_equal 1 "$REPLY" 'initial remote lookup count'
reset_completion
run_completion helm install release sample/remote-chart \
  --repo https://charts.example.invalid/public \
  --version 2.3.4 --set ''
remote_lookup_count
assert_equal 1 "$REPLY" 'repeated remote lookup uses the in-memory cache'
reset_completion
run_completion helm install release sample/remote-chart \
  --repo=https://charts.example.invalid/public --version=2.3.4 --set ''
assert_contains 'remoteLookup.setting=' 'remote chart value key with inline options'
remote_lookup_count
assert_equal 1 "$REPLY" 'inline options share the semantic cache entry'
reset_completion
run_completion helm install release sample/remote-chart \
  --repo https://charts.example.invalid/public \
  --version 2.3.5 --set ''
remote_lookup_count
assert_equal 2 "$REPLY" 'different chart versions use separate cache entries'

print -- 'Test: --set includes dependency defaults under the dependency alias'
reset_completion
run_completion helm template release "$chart" --set ''
assert_contains 'monitoring.collector.image.tag=' 'aliased subchart key'

print -- 'Test: local chart defaults cache until source files change'
reset_completion
run_completion helm template release "$archive_chart" --set ''
assert_contains 'archived.archiveSetting=' 'archived dependency default'
assert_equal 1 "$(grep -c '^show:.*archive-child-1.0.0.tgz$' "$help_calls_file")" \
  'initial archive values lookup count'

reset_completion
run_completion helm template release "$archive_chart" --set ''
assert_equal 1 "$(grep -c '^show:.*archive-child-1.0.0.tgz$' "$help_calls_file")" \
  'repeated completion reuses local chart cache'

cat >> "$archive_chart/values.yaml" <<'YAML'
changedByChart:
  enabled: true
YAML
reset_completion
run_completion helm template release "$archive_chart" --set ''
assert_contains 'changedByChart.enabled=' 'chart values changes invalidate local cache'
assert_equal 2 "$(grep -c '^show:.*archive-child-1.0.0.tgz$' "$help_calls_file")" \
  'values file change reloads dependency defaults'

print -- 'archive contents changed' >> "$archive_dependency"
reset_completion
run_completion helm template release "$archive_chart" --set ''
assert_equal 3 "$(grep -c '^show:.*archive-child-1.0.0.tgz$' "$help_calls_file")" \
  'dependency archive change invalidates local cache'

print -- 'Test: option arguments do not get mistaken for the chart'
for option_args in \
  '-n production' \
  '--name-template generated-release' \
  '--kube-token dummy' \
  '--generated-option dynamic-value' \
  '--chart-channel stable' \
  '--namespace production'; do
  reset_completion
  run_completion helm install release "$chart" ${(z)option_args} --set ''
  assert_contains 'global.enabled=' "chart key after options: $option_args"
  assert_not_contains 'fallbackOnly='
done

print -- 'Test: dynamically discovered boolean flags do not consume chart arguments'
reset_completion
run_completion helm install release --custom-switch "$chart" --set ''
assert_contains 'global.enabled=' 'chart key after boolean option'

print -- 'Test: dynamic flag metadata is cached per Helm subcommand'
assert_equal 1 "$(grep -c '^template$' "$help_calls_file")" 'template help invocation count'
assert_equal 1 "$(grep -c '^install$' "$help_calls_file")" 'install help invocation count'
reset_completion
run_completion helm upgrade release "$chart" --set ''
assert_contains 'global.enabled=' 'upgrade chart key'
assert_equal 1 "$(grep -c '^upgrade$' "$help_calls_file")" 'upgrade help invocation count'

print -- 'Test: case-insensitive prefix matching is retained'
reset_completion
run_completion helm template release "$chart" --set METR
assert_contains 'metricsEnabled=' 'case-insensitive key'

print -- 'Test: fuzzy key matches are retained'
reset_completion
run_completion helm template release "$chart" --set mene
assert_contains 'monitoring.metrics.enabled=' 'fuzzy subchart key'
assert_contains 'metricsEnabled=' 'fuzzy root key'

print -- 'Test: --set=KEY preserves and matches the inline flag prefix'
reset_completion
run_completion helm template release "$chart" --set=global.en
assert_contains 'global.enabled=' 'inline --set key'
assert_equal 'global.en' "$compadd_prefix" 'inline --set completion prefix passed to compadd'
assert_equal '--set=' "$compadd_iprefix" 'inline --set flag prefix retained by compadd'
assert_equal 0 "$awk_calls" 'runtime awk invocation count'

if (( failures )); then
  print -u2 -- "FAILED: $failures test assertion(s)"
  exit 1
fi

print -- 'PASS: all Helm completion tests passed'
