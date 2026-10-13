# Helm `--set` Completion for zsh

This project extends Helm's existing zsh completion with chart value-key suggestions for `--set`. Press **Tab** to complete paths from chart defaults and values files instead of having to remember them. In other contexts, completion is delegated to Helm's existing completion.

## Demo

The animation shows zsh completing `image.re` from the included local demo chart:

![Helm --set completion suggests image.registry and image.repository](assets/helm-set-completion.gif)

## Prerequisites

- **zsh** with programmable completion enabled (`compinit`).
- **Helm** and its zsh completion function installed and loaded before this script is sourced.
- **Mike Farah `yq` v4** on `PATH`. It parses YAML values and chart metadata. Other `yq` implementations or major versions are not tested and may not work.

Remote chart completion does require Helm to be able to retrieve that chart, and may use Helm's configured repository or registry authentication.

## Installation

Install the script where you keep your zsh customizations, then source it during shell initialization—for example, from `~/.zshrc`. Add a `source` command that points to the installed script **after** zsh completion has been initialized and Helm's completion is available:

```zsh
source "/path/to/helm-set-completion.zsh"
```

Replace `/path/to/helm-set-completion.zsh` with the actual location where you installed the file. Reload the shell or source your initialization file to enable it. The script wraps Helm's completion and delegates to the original completion for contexts it does not handle.

If `yq` is missing when completing `--set`, the script displays a message with an installation hint and does not attempt to parse values.

## Examples

The local-chart examples assume a chart at `./my-chart`.

### Complete a nested key

For example, if `./my-chart/values.yaml` contains:

```yaml
image:
  repository: nginx
  tag: latest
```

Type a partial path and press **Tab**:

```zsh
helm template my-release ./my-chart --set image.rep<Tab>
```

The completion offers:

```text
image.repository=
```

To see available root keys, start a new `--set` value and press **Tab**:

```zsh
helm template my-release ./my-chart --set <Tab>
```

### Find a key with fuzzy matching

Fuzzy matching can find a key when you type a subsequence of its characters, leaving out parts of the path. For example, with these values:

```yaml
resources:
  requests:
    cpu: 100m
    memory: 128Mi
```

Type `resreqcpu` and press **Tab**:

```zsh
helm template my-release ./my-chart --set resreqcpu<Tab>
```

The matching suggestion is:

```text
resources.requests.cpu=
```

### Complete array entries

Given chart defaults such as an array of maps, completion retains Helm's indexed path syntax:

```yaml
tolerations:
  - key: dedicated
    operator: Equal
```

With no earlier array assignments, completion offers:

```text
tolerations[0].key=
tolerations[0].operator=
```

If an earlier `--set` in the same command refers to index `0`, completion also offers paths at index `1`, while keeping suggestions for the existing entry. For example:

```zsh
helm template my-release ./my-chart \
  --set 'tolerations[0].key=dedicated' \
  --set <Tab>
```

Among the suggestions are:

```text
tolerations[0].operator=
tolerations[1].key=
tolerations[1].operator=
```

### Complete from a remote chart or values file

Remote chart defaults can be looked up with Helm's `--repo` and `--version` options. This example uses the Prometheus Community `kube-state-metrics` chart:

```zsh
helm template my-release kube-state-metrics \
  --repo https://prometheus-community.github.io/helm-charts \
  --version 8.4.1 \
  --set image.re<Tab>
```

For that chart version, matching suggestions include:

```text
image.registry=
image.repository=
```

Additional local values files are also included in key suggestions:

```zsh
helm template my-release ./my-chart -f extra-values.yaml --set <Tab>
```

## Features

- Completes keys for `helm template`, `helm install`, and `helm upgrade` when the cursor is in a `--set` argument.
- Supports both `--set KEY` and `--set=KEY` forms, including matching and preserving an inline `--set=` prefix.
- Reads defaults from local unpacked charts containing `Chart.yaml` and `values.yaml`.
- Includes dependency defaults using the dependency alias (or dependency name when there is no alias), for unpacked dependencies and dependency chart archives.
- Reads additional local files supplied with `-f FILE`, `--values FILE`, `-f=FILE`, or `--values=FILE`.
- Retrieves remote chart defaults through `helm show values`, forwarding `--repo` and `--version` in separate-argument and equals forms.
- Caches local chart and dependency key paths in memory for the shell session. The cache is reused while chart source-file metadata is unchanged; explicit `-f`/`--values` files are read live.
- Caches flattened remote value keys in memory for the current shell session, keyed by chart reference, repository, and version. Separate and equals-form options with the same values share a cache entry.
- Retains array indices from YAML paths and suggests the next index after the highest index already referenced by a prior `--set` in the current command. Both escaped and unescaped square brackets in those prior arguments are recognized.
- Escapes literal dots in YAML keys so they are distinguishable from nested key separators in Helm paths.
- Supports case-insensitive prefix matching and fuzzy key matching.
- Leaves non-`--set` completion to Helm's existing completion function.

## Limitations and out of scope

- Only `template`, `install`, and `upgrade` have value-key completion; other Helm operations use the original completion behavior.
- Remote chart values must be retrievable by `helm show values`. On a cache miss, this runs synchronously during completion and can pause while Helm accesses the repository.
- Local and remote caches are memory-only and are cleared when the shell exits. Remote entries have no TTL or manual refresh command; changing chart, repository, or version selects a different entry. Local chart keys are invalidated when the metadata of `Chart.yaml`, root `values.yaml`, or files under `charts/` changes. Additional values files are not cached.
- Command-line authentication, credentials, and TLS options are not forwarded to the remote `helm show values` call. Helm may still use credentials already configured in its repository or registry settings.
- Empty arrays and arrays without map-shaped default entries do not provide nested keys from which to infer completion paths. The script does not infer a new element's schema beyond paths available in the chart defaults.
- The next-index suggestion is based on the highest numeric index found among prior `--set` assignments for the same array; it does not guess user intent or auto-increment for each `--set` flag.
- Local chart defaults are read when both `Chart.yaml` and `values.yaml` are present. This is key-path discovery, not full Helm value merging or template evaluation.
- This project only completes value keys; it does not validate assigned values, render templates, or modify/install a release.
- The completion integration relies on Helm's existing zsh completion being loaded before this script.

## Tests

Run the regression suite from this directory:

```zsh
zsh -f tests/helm-set-completion.zsh
```

The test suite requires zsh and Mike Farah `yq` v4. It stubs Helm completion and `compadd`, so Helm and a Kubernetes cluster are not needed to run the tests.

Run the optional, informational completion benchmarks with:

```zsh
zsh tests/bench-completion.zsh
```

The benchmark reports median and p95 timings for local chart cold/warm cache, an additional values file, dependency defaults, array next-index suggestions, and mock remote lookups with cold and warm completion caches. It also measures prefix and fuzzy candidate filtering separately, using preloaded local keys so YAML and chart loading do not dominate those matching measurements. It requires zsh, Helm, and Mike Farah `yq` v4. Results are informational; no performance thresholds are enforced. To measure a real local chart, set `BENCH_LOCAL_CHART` to its directory. To include real remote repository requests, pass `--real-remote`; this uses the network and may require repository access. Cold-cache samples clear this completion script's in-memory cache, not Helm's own caches. The local cold-cache case is capped at three samples and the live remote cold-cache case at five to limit expensive lookups. Set `BENCH_CHART`, `BENCH_REPO`, and `BENCH_VERSION` to select a remote chart, repository, and version. Use `--iterations N` to change the regular sample count.

Check zsh syntax with:

```zsh
zsh -n helm-set-completion.zsh tests/helm-set-completion.zsh tests/bench-completion.zsh
```
