# Add chart value-key completion to Helm's existing zsh completion.
# This file is sourced after compinit; Helm's original completion is retained
# and used for every completion except a supported --set argument.

if (( $+functions[_helm] )) && (( ! $+functions[_helm_with_values] )); then
  typeset -gA _helm_value_arg_flags _helm_value_arg_flags_loaded
  typeset -gA _helm_remote_value_keys_cache _helm_remote_value_cache_loaded
  typeset -gA _helm_local_value_keys_cache _helm_local_value_cache_fingerprint _helm_local_value_cache_loaded

  _helm_load_value_arg_flags() {
    emulate -L zsh
    local subcommand=$1 help line short_flag long_flag
    local -a match

    [[ ${_helm_value_arg_flags_loaded[$subcommand]-} == 1 ]] && return 0
    help=$(helm "$subcommand" --help 2>/dev/null) || return 1
    while IFS= read -r line; do
      # Helm aligns a value type before a wide gap and description. Match only
      # declarations with that type field; boolean flags lack it.
      if [[ $line =~ '^[[:space:]]+(-[[:alnum:]],)?[[:space:]]*(--[[:alnum:]][[:alnum:]-]*)[[:space:]]+([^[:space:]]+)[[:space:]]{2,}' ]]; then
        short_flag=${match[1]%,}
        long_flag=${match[2]}
        [[ -n $short_flag ]] && _helm_value_arg_flags["$subcommand:$short_flag"]=1
        _helm_value_arg_flags["$subcommand:$long_flag"]=1
      fi
    done <<< "$help"
    _helm_value_arg_flags_loaded[$subcommand]=1
    return 0
  }

  _helm_collect_prior_set_values() {
    emulate -L zsh
    local i=1 token

    reply=()
    while (( i < CURRENT )); do
      token=${words[i]}
      if [[ $token == --set=* ]]; then
        reply+=("${token#--set=}")
      elif [[ $token == --set ]] && (( i + 1 < CURRENT )); then
        reply+=("${words[i+1]}")
        (( i++ ))
      fi
      (( i++ ))
    done
  }

  # Add next-index paths for arrays referenced by prior assignments. The two
  # arguments are names of caller-local arrays; results are returned in reply.
  _helm_next_array_keys() {
    emulate -L zsh
    local keys_array_name=$1 assignments_array_name=$2
    local key path_prefix path_rest array_prefix array_suffix array_index
    local set_value assigned_key remainder assigned_index max_index array_used next_index
    local -a source_keys prior_assignments next_keys

    source_keys=("${(@P)keys_array_name}")
    prior_assignments=("${(@P)assignments_array_name}")
    for key in $source_keys; do
      path_prefix=''
      path_rest=$key
      while [[ $path_rest =~ '^([^[]*)\[([0-9]+)\](.*)$' ]]; do
        array_prefix="$path_prefix${match[1]}"
        array_index=${match[2]}
        array_suffix=${match[3]}
        max_index=$array_index
        array_used=0

        for set_value in $prior_assignments; do
          assigned_key=${set_value%%=*}
          # Zsh words may retain shell-escaping backslashes around brackets;
          # normalize those for index detection without changing the command.
          assigned_key=${assigned_key//\\\[/[}
          assigned_key=${assigned_key//\\\]/]}
          if (( ${#assigned_key} <= ${#array_prefix} )); then
            continue
          fi
          [[ ${assigned_key[1,${#array_prefix}]} == "$array_prefix" ]] || continue
          remainder=${assigned_key[$(( ${#array_prefix} + 1 )),-1]}
          [[ $remainder == \[* ]] || continue
          assigned_index=${remainder#\[}
          assigned_index=${assigned_index%%]*}
          [[ $assigned_index == <-> ]] || continue
          array_used=1
          (( assigned_index > max_index )) && max_index=$assigned_index
        done

        if (( array_used )); then
          next_index=$((max_index + 1))
          next_keys+=("${array_prefix}[${next_index}]${array_suffix}")
        fi

        path_prefix="${array_prefix}[${array_index}]"
        path_rest=$array_suffix
      done
    done

    reply=("${next_keys[@]}")
  }

  # Build a lightweight freshness signature from chart metadata, root values,
  # and files under charts/. zstat avoids spawning stat once per dependency.
  _helm_local_chart_fingerprint() {
    emulate -L zsh
    setopt localoptions extendedglob
    local chart=${1:A} path fingerprint=''
    local -A file_info
    local -a source_files

    zmodload zsh/stat 2>/dev/null || return 1
    source_files=("$chart/Chart.yaml" "$chart/values.yaml" "$chart"/charts/**/*(.DN))
    for path in $source_files; do
      zstat -H file_info -- "$path" || return 1
      fingerprint+="${#path}:$path:${file_info[mtime]}:${file_info[ctime]}:${file_info[size]}:${file_info[inode]};"
    done

    reply=$fingerprint
  }

  # Load paths from a local chart (including dependencies) or a remote chart.
  # lookup_options is passed by name because it is a caller-local zsh array.
  _helm_load_chart_default_keys() {
    emulate -L zsh
    local chart=$1 repo=$2 version=$3 lookup_options_name=$4
    local cache_key cached_keys values local_cache_key local_fingerprint
    local use_local_cache=0
    local dependency_name dependency_alias dependency_dir dependency_archive
    local -a chart_lookup_options keys

    chart_lookup_options=("${(@P)lookup_options_name}")
    if [[ -f "$chart/Chart.yaml" && -f "$chart/values.yaml" ]]; then
      local_cache_key=${chart:A}
      if _helm_local_chart_fingerprint "$chart"; then
        local_fingerprint=$reply
        use_local_cache=1
      fi

      if (( use_local_cache )) &&
         [[ ${_helm_local_value_cache_loaded[$local_cache_key]-} == 1 &&
            ${_helm_local_value_cache_fingerprint[$local_cache_key]-} == $local_fingerprint ]]; then
        cached_keys=${_helm_local_value_keys_cache[$local_cache_key]-}
        keys=(${(f)cached_keys})
      else
        keys+=(${(f)"$(<"$chart/values.yaml" _helm_yaml_to_keys '')"})

        # Helm exposes dependency values under their alias (or name when no
        # alias is configured). Read defaults from unpacked charts or archives.
        while IFS=$'\t' read -r dependency_name dependency_alias; do
          [[ -n $dependency_name && -n $dependency_alias ]] || continue
          dependency_dir=''
          if [[ -f "$chart/charts/$dependency_name/values.yaml" ]]; then
            dependency_dir="$chart/charts/$dependency_name"
          elif [[ -f "$chart/charts/$dependency_alias/values.yaml" ]]; then
            dependency_dir="$chart/charts/$dependency_alias"
          fi

          if [[ -n $dependency_dir ]]; then
            keys+=(${(f)"$(<"$dependency_dir/values.yaml" _helm_yaml_to_keys "$dependency_alias")"})
            continue
          fi

          for dependency_archive in "$chart"/charts/"$dependency_name"-*.tgz(N); do
            [[ -f $dependency_archive ]] || continue
            values=$(helm show values "$dependency_archive" 2>/dev/null) || continue
            keys+=(${(f)"$(print -r -- "$values" | _helm_yaml_to_keys "$dependency_alias")"})
            break
          done
        done < <(yq -r '.dependencies[]? | [.name, (.alias // .name)] | @tsv' "$chart/Chart.yaml" 2>/dev/null)

        if (( use_local_cache )); then
          _helm_local_value_keys_cache[$local_cache_key]="${(F)keys}"
          _helm_local_value_cache_fingerprint[$local_cache_key]=$local_fingerprint
          _helm_local_value_cache_loaded[$local_cache_key]=1
        fi
      fi
    else
      # Keep cache identity tied to semantic values, not option spelling/order.
      cache_key="${#chart}:$chart${#repo}:$repo${#version}:$version"
      if [[ ${_helm_remote_value_cache_loaded["$cache_key"]-} == 1 ]]; then
        cached_keys=${_helm_remote_value_keys_cache["$cache_key"]-}
      else
        values=$(helm show values "$chart" "${chart_lookup_options[@]}" 2>/dev/null) || return 1
        cached_keys=$(print -r -- "$values" | _helm_yaml_to_keys '')
        _helm_remote_value_keys_cache["$cache_key"]=$cached_keys
        _helm_remote_value_cache_loaded["$cache_key"]=1
      fi
      keys+=(${(f)cached_keys})
    fi

    reply=("${keys[@]}")
  }

  _helm_set_value_keys() {
    emulate -L zsh
    setopt localoptions no_aliases

    local subcommand chart token prefix values key value_file flag_name flag_key inline_value
    local repo_value version_value pending_option
    local -a before_set positional keys values_files lookup_options prior_set_values
    subcommand=''
    chart=''

    # Find the Helm operation and chart argument. The chart is the last
    # positional argument before --set, ignoring options and their values.
    before_set=()
    local i=1
    while (( i < CURRENT )); do
      token=${words[i]}
      if [[ $token == --set || $token == --set=* ]]; then
        break
      fi
      before_set+=("$token")
      (( i++ ))
    done

    # Remember completed assignments so array suggestions can offer the next
    # index without assuming that each --set targets a new element.
    _helm_collect_prior_set_values
    prior_set_values=("${reply[@]}")

    for token in $before_set; do
      case $token in
        template|install|upgrade) subcommand=$token ;;
      esac
    done
    [[ -n $subcommand ]] || return 1
    _helm_load_value_arg_flags "$subcommand" || return 1

    # These operations take NAME CHART (template also permits CHART alone).
    # Skip known option arguments while collecting positional operands.
    repo_value=''
    version_value=''
    pending_option=''
    for token in $before_set; do
      if [[ -n $pending_option ]]; then
        case $pending_option in
          values) values_files+=("$token") ;;
          --repo)
            lookup_options+=("$token")
            repo_value=$token
            ;;
          --version)
            lookup_options+=("$token")
            version_value=$token
            ;;
          argument) ;;
        esac
        pending_option=''
        continue
      fi
      case $token in
        -*)
          flag_name=$token
          inline_value=''
          if [[ $token == *=* ]]; then
            flag_name=${token%%=*}
            inline_value=${token#*=}
          fi
          flag_key="$subcommand:$flag_name"
          if [[ -n ${_helm_value_arg_flags["$flag_key"]-} ]]; then
            case $flag_name in
              --values|-f)
                if [[ $token == *=* ]]; then
                  values_files+=("$inline_value")
                else
                  pending_option=values
                fi
                ;;
              --repo|--version)
                if [[ $token == *=* ]]; then
                  lookup_options+=("$token")
                  case $flag_name in
                    --repo) repo_value=$inline_value ;;
                    --version) version_value=$inline_value ;;
                  esac
                else
                  lookup_options+=("$flag_name")
                  pending_option=$flag_name
                fi
                ;;
              *)
                [[ $token == *=* ]] || pending_option=argument
                ;;
            esac
          fi
          ;;
        template|install|upgrade) ;;
        *) positional+=("$token") ;;
      esac
    done
    (( ${#positional} )) || return 1
    chart=${positional[-1]}

    _helm_load_chart_default_keys "$chart" "$repo_value" "$version_value" lookup_options || return 1
    keys=("${reply[@]}")

    for value_file in $values_files; do
      [[ -r $value_file ]] || continue
      values=$(<"$value_file") || continue
      keys+=(${(f)"$(print -r -- "$values" | _helm_yaml_to_keys '')"})
    done

    # Add the next index for arrays already referenced by --set, while keeping
    # all paths discovered from chart defaults and values files.
    _helm_next_array_keys keys prior_set_values
    keys+=("${reply[@]}")
    typeset -U keys
    (( ${#keys} )) || return 1

    if [[ $words[CURRENT] == --set ]]; then
      prefix=''
    elif [[ $words[CURRENT] == --set=* ]]; then
      prefix=${words[CURRENT]#--set=}
      prefix=${prefix%%=*}
      # Keep the option prefix as IPREFIX, but let compadd match only the key
      # portion. This also ensures selecting a completion preserves --set=.
      if [[ $PREFIX == --set=* ]]; then
        compset -P '--set='
      fi
    elif (( CURRENT > 1 )) && [[ $words[CURRENT-1] == --set ]]; then
      prefix=${PREFIX%%=*}
    else
      return 1
    fi

    local -a matches fuzzy_matches
    for key in $keys; do
      if [[ ${key:l} == ${prefix:l}* ]]; then
        matches+=("${key}=")
      elif _helm_value_fuzzy_match "$prefix" "$key"; then
        fuzzy_matches+=("${key}=")
      fi
    done
    if (( ${#matches} )); then
      # Keep compadd's normal prefix insertion behavior while making its match
      # comparison case-insensitive.
      # Let zsh quote shell metacharacters (notably the backslashes used to
      # escape literal dots in Helm value paths).
      compadd -S '' -M 'm:{a-zA-Z}={A-Za-z}' -- $matches
    elif (( ${#fuzzy_matches} )); then
      # These candidates were filtered by our subsequence matcher. Temporarily
      # clear PREFIX so compadd replaces the typed abbreviation with the full
      # key instead of trying to match it as a literal prefix. Start menu
      # completion for ambiguous results so zsh does not insert only their
      # unrelated common prefix.
      local saved_prefix=$PREFIX
      PREFIX=''
      if (( ${#fuzzy_matches} > 1 && $+parameters[compstate] )); then
        compstate[insert]=menu
      fi
      compadd -S '' -- $fuzzy_matches
      local completion_status=$?
      PREFIX=$saved_prefix
      return $completion_status
    else
      return 1
    fi
    return 0
  }

  _helm_yaml_to_keys() {
    emulate -L zsh
    local prefix=$1
    local encoded_path component key_path
    local IFS=$'\t'
    local -a components
    while IFS= read -r encoded_path; do
      [[ -n $encoded_path ]] || continue
      read -r -A components <<< "$encoded_path"
      key_path=''
      for component in $components; do
        case $component in
          I:*) key_path+="[${component#I:}]" ;;
          K:*)
            component=${component#K:}
            [[ -n $key_path ]] && key_path+='.'
            key_path+=$component
            ;;
        esac
      done
      [[ -n $key_path ]] || continue
      if [[ -n $prefix ]]; then
        print -r -- "$prefix.$key_path"
      else
        print -r -- "$key_path"
      fi
    done < <(yq -r '.. | path | map(if tag == "!!int" then "I:" + tostring else "K:" + sub("\\."; "\\\\.") end) | join("\t")' 2>/dev/null)
  }

  _helm_value_fuzzy_match() {
    emulate -L zsh
    local needle=${1:l} haystack=${2:l} character
    needle=${needle//[._-]/}
    haystack=${haystack//[._-]/}
    while [[ -n $needle ]]; do
      character=${needle[1]}
      needle=${needle[2,-1]}
      [[ $haystack == *${character}* ]] || return 1
      haystack=${haystack#*${character}}
    done
    return 0
  }

  _helm_with_values() {
    if [[ ${words[CURRENT]} == --set || ${words[CURRENT]} == --set=* ]] ||
       { (( CURRENT > 1 )) && [[ ${words[CURRENT-1]} == --set ]]; }; then
      if (( ! $+commands[yq] )); then
        _message 'Helm value completion requires yq v4 (Mike Farah)'
        return 0
      fi
      # Do not let Helm's generic file completion leak into --set values when
      # a chart or values file cannot be parsed; an empty result is clearer.
      _helm_set_value_keys
      compdef _helm_with_values helm
      return 0
    fi
    # Delegate by calling Helm's real completion function under its original
    # name. It may be autoloaded here and re-register itself, so restore our
    # dispatcher after it returns.
    _helm "$@"
    local completion_status=$?
    compdef _helm_with_values helm
    return $completion_status
  }
  compdef _helm_with_values helm
fi
