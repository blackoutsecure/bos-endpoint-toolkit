# shellcheck shell=bash
# >>> devbox:configuration-data >>>
DEVBOX_DEFAULTS_JSON=''
DEVBOX_CONFIGURATION_FIELDS=''
export DEVBOX_RELEASE_VERSION=''
# <<< devbox:configuration-data <<<

config_error(){ /usr/bin/printf 'ERROR: Configuration: %s\n' "$1" >&2; return 1; }

# The sentinel keeps command substitution from trimming value-owned line feeds.
capture_config_value(){
  local captured
  captured="$("$@" && /usr/bin/printf '.')" || return 1
  CONFIG_VALUE="${captured%.}"
}

validate_config_json(){
  local document="$1" remaining="$1" key type minimum maximum pattern min_items env_key value count index entry seen object
  # Scalar plist values cannot be serialized as top-level JSON.
  /usr/bin/plutil -extract schemaVersion xml1 -o - - <<< "$document" >/dev/null \
    || { config_error 'schemaVersion: 1 is required'; return 1; }
  while IFS='|' read -r key type minimum maximum pattern min_items env_key; do
    if ! value="$(/usr/bin/plutil -extract "$key" xml1 -o - - <<< "$document" 2>/dev/null)"; then continue; fi
    if [[ "$type" == integer ]]; then
      if ! capture_config_value /usr/bin/plutil -extract "$key" raw -expect integer -n -o - - <<< "$document" 2>/dev/null; then
        capture_config_value /usr/bin/plutil -extract "$key" raw -expect float -n -o - - <<< "$document" \
          || { config_error "Invalid type for $key (expected an integer number)"; return 1; }
      fi
      value="$CONFIG_VALUE"
      [[ "$value" =~ ^[0-9]+([.]0+)?$ ]] || { config_error "$key must be a whole number"; return 1; }
      value="${value%%.*}"
    else
      capture_config_value /usr/bin/plutil -extract "$key" raw -expect "$type" -n -o - - <<< "$document" \
        || { config_error "Invalid type for $key (expected $type)"; return 1; }
      value="$CONFIG_VALUE"
    fi
    case "$type" in
      integer)
        if [[ ! "$value" =~ ^[0-9]+$ || ${#value} -gt 10 ]]; then
          config_error "$key must be an integer from $minimum through $maximum"; return 1
        fi
        if (( value < minimum || value > maximum )); then
          config_error "$key must be an integer from $minimum through $maximum"; return 1
        fi
        ;;
      string) [[ "$value" =~ $pattern ]] || { config_error "Invalid value for $key"; return 1; } ;;
      array)
        count="$value"; seen=$'\n'
        (( count >= min_items )) || { config_error "Empty array: $key"; return 1; }
        for (( index=0; index<count; index++ )); do
          capture_config_value /usr/bin/plutil -extract "$key.$index" raw -expect string -n -o - - <<< "$document" || return 1
          entry="$CONFIG_VALUE"
          [[ "$entry" =~ $pattern && "$seen" != *$'\n'"$entry"$'\n'* ]] \
            || { config_error "Invalid or duplicate entry in $key"; return 1; }
          seen+="$entry"$'\n'
        done
        ;;
      bool) ;;
      *) config_error "Unsupported type $type"; return 1 ;;
    esac
    remaining="$(/usr/bin/plutil -remove "$key" -o - - <<< "$remaining")" || return 1
  done <<< "$DEVBOX_CONFIGURATION_FIELDS"
  for object in windows macos; do
    if /usr/bin/plutil -extract "$object" xml1 -o - - <<< "$remaining" >/dev/null 2>&1; then
      value="$(/usr/bin/plutil -extract "$object" json -expect dictionary -o - - <<< "$remaining" | /usr/bin/tr -d '[:space:]')" || return 1
      [[ "$value" == '{}' ]] || { config_error "Unknown keys in $object"; return 1; }
      remaining="$(/usr/bin/plutil -remove "$object" -o - - <<< "$remaining")" || return 1
    fi
  done
  remaining="$(/usr/bin/plutil -convert json -o - - <<< "$remaining" | /usr/bin/tr -d '[:space:]')" || return 1
  [[ "$remaining" == '{}' ]] || { config_error 'Unknown configuration keys or an invalid root object'; return 1; }
}

resolve_devbox_config(){
  local path="$1" override='' key type minimum maximum pattern min_items env_key value count index legacy='' mapping old_key namespace
  [[ -n "$DEVBOX_DEFAULTS_JSON" ]] || { config_error 'Use npm run build and deploy the standalone output, not authoring templates'; return 1; }
  EFFECTIVE_CONFIG="$DEVBOX_DEFAULTS_JSON"
  export CONFIGURATION_SOURCE='packaged defaults'
  if [[ -z "$path" ]]; then
    capture_config_value /usr/bin/plutil -extract name raw -expect string -n -o - - <<< "$DEVBOX_DEFAULTS_JSON" || return 1
    namespace="$CONFIG_VALUE"
    if [[ -f "$SCRIPT_DIRECTORY/desired-config.json" ]]; then path="$SCRIPT_DIRECTORY/desired-config.json"
    elif [[ -f "$HOME/Library/Application Support/$namespace/desired-config.json" ]]; then
      path="$HOME/Library/Application Support/$namespace/desired-config.json"
    fi
  fi
  if [[ -n "$path" ]]; then
    [[ -f "$path" ]] || { config_error "File is missing: $path"; return 1; }
    override="$(/bin/cat "$path")" || return 1
    validate_config_json "$override" || return 1
    CONFIGURATION_SOURCE="$path"
  else
    if [[ -f "$SCRIPT_DIRECTORY/config.plist" ]]; then legacy="$SCRIPT_DIRECTORY/config.plist"
    elif [[ -f "$HOME/Library/Application Support/$namespace/config.plist" ]]; then
      legacy="$HOME/Library/Application Support/$namespace/config.plist"
    fi
    if [[ -n "$legacy" ]]; then
      capture_config_value /usr/bin/plutil -extract schemaVersion raw -expect integer -n -o - "$legacy" || return 1
      value="$CONFIG_VALUE"
      [[ "$value" == 3 ]] || { config_error "Unsupported legacy state schema: $value"; return 1; }
      for mapping in name:name retention:retention backupHour:backupHour backupMinute:backupMinute \
        hideVolume:macos.hideVolume autoRestore:macos.autoRestore \
        conditionalInstallBackup:macos.conditionalInstallBackup backupAfterRestore:macos.backupAfterRestore; do
        old_key="${mapping%%:*}"; key="${mapping#*:}"
        if value="$(/usr/bin/plutil -extract "$old_key" xml1 -o - "$legacy" 2>/dev/null)"; then
          EFFECTIVE_CONFIG="$(/usr/bin/plutil -replace "$key" -xml "$value" -o - - <<< "$EFFECTIVE_CONFIG")" || return 1
        fi
      done
      if /usr/bin/plutil -extract mountPoint xml1 -o - "$legacy" >/dev/null 2>&1; then
        capture_config_value /usr/bin/plutil -extract mountPoint raw -expect string -n -o - "$legacy" \
          || { config_error 'Legacy mountPoint must be a string'; return 1; }
        value="$CONFIG_VALUE"
        [[ "$value" == /Volumes/* ]] || { config_error 'Unexpected legacy mount point'; return 1; }
        EFFECTIVE_CONFIG="$(/usr/bin/plutil -replace macos.volumeLabel -string "${value#/Volumes/}" -o - - <<< "$EFFECTIVE_CONFIG")" || return 1
      fi
      CONFIGURATION_SOURCE="$legacy (available legacy settings)"
      /usr/bin/printf 'Loading legacy Devbox settings; settings not recorded in the old state use packaged defaults. Inspect config before repair.\n' >&2
    fi
  fi
  while IFS='|' read -r key type minimum maximum pattern min_items env_key; do
    if [[ -n "$override" ]] && value="$(/usr/bin/plutil -extract "$key" xml1 -o - - <<< "$override" 2>/dev/null)"; then
      EFFECTIVE_CONFIG="$(/usr/bin/plutil -replace "$key" -xml "$value" -o - - <<< "$EFFECTIVE_CONFIG")" || return 1
    fi
    if [[ -n "$env_key" ]] && capture_config_value /usr/bin/printenv "$env_key"; then
      value="${CONFIG_VALUE%$'\n'}"
      case "$type" in
        integer)
          [[ "$value" =~ ^[0-9]+$ && ${#value} -le 10 ]] || { config_error "$env_key must be an integer"; return 1; }
          value=$((10#$value))
          ;;
        bool) [[ "$value" == true || "$value" == false ]] || { config_error "$env_key must be true or false"; return 1; } ;;
        string) ;;
        *) config_error "Environment overrides are unsupported for $key"; return 1 ;;
      esac
      EFFECTIVE_CONFIG="$(/usr/bin/plutil -replace "$key" "-$type" "$value" -o - - <<< "$EFFECTIVE_CONFIG")" || return 1
    fi
  done <<< "$DEVBOX_CONFIGURATION_FIELDS"
  validate_config_json "$EFFECTIVE_CONFIG" || return 1
  while IFS='|' read -r key type minimum maximum pattern min_items env_key; do
    if [[ "$type" == integer ]]; then
      capture_config_value /usr/bin/plutil -extract "$key" raw -n -o - - <<< "$EFFECTIVE_CONFIG" || return 1
      value="$CONFIG_VALUE"
      EFFECTIVE_CONFIG="$(/usr/bin/plutil -replace "$key" -integer "${value%%.*}" -o - - <<< "$EFFECTIVE_CONFIG")" || return 1
    fi
    if [[ -n "$env_key" ]]; then
      capture_config_value /usr/bin/plutil -extract "$key" raw -n -o - - <<< "$EFFECTIVE_CONFIG" || return 1
      printf -v "$env_key" '%s' "$CONFIG_VALUE"
    fi
  done <<< "$DEVBOX_CONFIGURATION_FIELDS"
  WORKSPACE_DIRECTORIES=()
  capture_config_value /usr/bin/plutil -extract workspaceDirectories raw -expect array -n -o - - <<< "$EFFECTIVE_CONFIG" || return 1
  count="$CONFIG_VALUE"
  for (( index=0; index<count; index++ )); do
    capture_config_value /usr/bin/plutil -extract "workspaceDirectories.$index" raw -expect string -n -o - - <<< "$EFFECTIVE_CONFIG" || return 1
    WORKSPACE_DIRECTORIES+=("$CONFIG_VALUE")
  done
}
