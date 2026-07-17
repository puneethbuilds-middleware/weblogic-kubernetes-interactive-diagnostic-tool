#!/usr/bin/env bash
#
# wkid.sh
#
# WKID - WebLogic Kubernetes Interactive Diagnostic Tool
# Version: 4.20
# Maintainer: Puneeth Prakash
#
# Interactive, read-only troubleshooting helper for WebLogic Kubernetes
# Operator (WKO) domains. The script lets the user choose a namespace, choose a
# WebLogic domain, run one diagnostic operation at a time, display the output,
# and optionally save that output into a timestamped report folder.

if ! (eval 'test -n "${BASH_VERSINFO[0]:-}"') 2>/dev/null; then
  echo "ERROR: WKID must be run with Bash. Use: bash wkid.sh" >&2
  exit 2
fi

set -u
set -o pipefail

SCRIPT_NAME="${0##*/}"
SCRIPT_VERSION="4.20"
START_TIME="$(date '+%Y-%m-%d %H:%M:%S %Z')"
OUTPUT_ROOT=""
REPORT_DIR=""
MANIFEST_FILE=""
SAVE_COUNT=0
LOG_TAIL_LINES=200
EVENT_LIMIT=50
WLST_PATH_DEFAULT="/u01/ora""cle/ora""cle_common/common/bin/wlst.sh"
USE_COLOR=1
C_RESET=""
C_BOLD=""
C_DIM=""
C_BLUE=""
C_GREEN=""
C_YELLOW=""
C_RED=""
C_CYAN=""

SELECTED_NAMESPACE=""
SELECTED_DOMAIN_RESOURCE=""
SELECTED_DOMAIN_UID=""
OPERATOR_ONLY_MODE=0
SELECTED_OPERATOR_NAMESPACE=""
WEBLOGIC_SERVER_VERSION="N/A"
WEBLOGIC_OPERATOR_VERSION="N/A"
JDK_VERSION="N/A"

usage() {
  printf '%s\n' \
    'Usage:' \
    '  wkid.sh [options]' \
    '' \
    'Description:' \
    '  WKID - WebLogic Kubernetes Interactive Diagnostic Tool.' \
    '  Interactive read-only WebLogic Kubernetes troubleshooting menu.' \
    '' \
    'Flow:' \
    '  1. Lists Kubernetes namespaces and asks you to choose one.' \
    '  2. Lists WebLogic Domain resources in that namespace and asks you to choose one.' \
    '  3. Shows a runtime summary when available: WebLogic Server, operator, and JDK versions.' \
    '  4. Shows a recommended consolidated diagnostic-archive option and individual troubleshooting options.' \
    '  5. Option 1 collects a standard diagnostic archive, creates an archive when possible, and exits.' \
    '  6. Other options display output and can optionally save it into a timestamped report folder.' \
    '' \
    'Options:' \
    '  --output-dir DIR      Parent directory for saved output. Default: ./wko_diagnostic_reports' \
    '  --log-tail N          Log lines to show for log operations. Default: 200' \
    '  --event-limit N       Event rows to show for event operations. Default: 50' \
    '  --no-color            Disable terminal colors.' \
    '  --plain               Alias for --no-color.' \
    '  --help                Show this help.' \
    '' \
    'Examples:' \
    '  ./wkid.sh' \
    '  ./wkid.sh --log-tail 500' \
    '  ./wkid.sh --output-dir /tmp/wko-diagnostics' \
    '' \
    'Safety:' \
    '  Default inspection operations are read-only for Kubernetes and host state. It does not run apply,' \
    '  patch, edit, delete, scale, rollout restart, kill, port-forward, package installs,' \
    '  or service restarts. Shell exec, JFR, and thread dumps are explicit menu choices.' \
    '  Optional saves write diagnostic output into a local report folder.'
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --output-dir) OUTPUT_ROOT="${2:-}"; shift 2 ;;
      --log-tail) LOG_TAIL_LINES="${2:-}"; shift 2 ;;
      --event-limit) EVENT_LIMIT="${2:-}"; shift 2 ;;
      --no-color|--plain) USE_COLOR=0; shift ;;
      --help|-h) usage; exit 0 ;;
      *) printf 'ERROR: Unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
  done

  case "$LOG_TAIL_LINES" in ''|*[!0-9]*) echo "ERROR: --log-tail must be a non-negative integer" >&2; exit 2 ;; esac
  case "$EVENT_LIMIT" in ''|*[!0-9]*) echo "ERROR: --event-limit must be a non-negative integer" >&2; exit 2 ;; esac
}

now() { date '+%Y-%m-%d %H:%M:%S %Z'; }

init_colors() {
  if [ "$USE_COLOR" -ne 1 ] || [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
    USE_COLOR=0
    return 0
  fi
  C_RESET="$(printf '\033[0m' 2>/dev/null)" || USE_COLOR=0
  C_BOLD="$(printf '\033[1m' 2>/dev/null)" || USE_COLOR=0
  C_DIM="$(printf '\033[2m' 2>/dev/null)" || USE_COLOR=0
  C_BLUE="$(printf '\033[34m' 2>/dev/null)" || USE_COLOR=0
  C_GREEN="$(printf '\033[32m' 2>/dev/null)" || USE_COLOR=0
  C_YELLOW="$(printf '\033[33m' 2>/dev/null)" || USE_COLOR=0
  C_RED="$(printf '\033[31m' 2>/dev/null)" || USE_COLOR=0
  C_CYAN="$(printf '\033[36m' 2>/dev/null)" || USE_COLOR=0
  if [ "$USE_COLOR" -ne 1 ]; then
    C_RESET=""
    C_BOLD=""
    C_DIM=""
    C_BLUE=""
    C_GREEN=""
    C_YELLOW=""
    C_RED=""
    C_CYAN=""
  fi
  return 0
}

hr() {
  printf '\n%s================================================================================%s\n' "$C_DIM" "$C_RESET"
}

print_header() {
  hr
  printf '%s%s%s\n' "$C_BOLD$C_CYAN" "$1" "$C_RESET"
  printf '%s================================================================================%s\n' "$C_DIM" "$C_RESET"
}

print_note() {
  printf '%s%s%s\n' "$C_DIM" "$1" "$C_RESET"
}

print_menu_section() {
  printf '\n%s=========================================================%s\n' "$C_DIM" "$C_RESET"
  printf '%s%s%s\n' "$C_CYAN" "$1" "$C_RESET"
  printf '%s=========================================================%s\n' "$C_DIM" "$C_RESET"
}

sanitize_name() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's#[^a-z0-9._-]+#_#g; s#^_+##; s#_+$##'
}

redact() {
  sed -E \
    -e 's#([Pp]assword|[Tt]oken|[Ss]ecret|[Aa]pi[_-]?[Kk]ey|[Aa]ccess[_-]?[Kk]ey|[Pp]rivate[_-]?[Kk]ey)([=:][[:space:]]*)[^[:space:],;]+#\1\2[REDACTED]#g' \
    -e 's#(Bearer[[:space:]]+)[A-Za-z0-9._~+/=-]+#\1[REDACTED]#g' \
    -e 's#(/[Uu]sers|/home)/[^/[:space:]]+#\1/[REDACTED_USER]#g'
}

print_intro() {
  print_header 'WKID - WebLogic Kubernetes Interactive Diagnostic Tool'
  printf '%s\n' \
    "Version: $SCRIPT_VERSION" \
    "Started: $START_TIME" \
    '' \
    'Before any checks run, here is what this script will do:' \
    '' \
    '1) It will list namespaces and ask you to choose one.' \
    '2) It will list WebLogic domains in that namespace and ask you to choose one.' \
    '3) It will show a menu of read-only troubleshooting operations.' \
    '4) For each selected operation, it will display output first.' \
    '5) After displaying output, it will ask whether to save that output.' \
    '' \
    'Areas it can inspect:' \
    '  Kubernetes namespace/domain inventory, WebLogic pods, logs, events, describes,' \
    '  resource requests/limits, live metrics when available, probes, services,' \
    '  storage, operator pods/logs, OPatch inventory, Java process listings, JFR,' \
    '  thread dumps, and optional interactive pod shells.' \
    '' \
    'Safety statement:' \
    '  WKID is designed as a read-only diagnostic collector for Kubernetes resources.' \
    '  It does not run kubectl apply, patch, edit, delete, scale, rollout restart,' \
    '  port-forward, package installs, service restarts, or kill commands.' \
    '  The only local filesystem changes are creating the report folder, saved output' \
    '  files, manifest, and optional archive. Pod shell, WLST, JFR, and thread dump' \
    '  collection are explicit advanced choices.'
  hr
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    printf '%sERROR:%s Required command not found: %s\n' "$C_RED" "$C_RESET" "$1" >&2
    exit 1
  }
}

check_prereqs() {
  need_cmd kubectl
  need_cmd awk
  need_cmd basename
  need_cmd cat
  need_cmd cut
  need_cmd date
  need_cmd grep
  need_cmd mkdir
  need_cmd pwd
  need_cmd sed
  need_cmd sh
  need_cmd sleep
  need_cmd sort
  need_cmd tail
  need_cmd tr

  if ! kubectl cluster-info >/dev/null 2>&1; then
    printf '%sERROR:%s kubectl cannot reach the configured cluster. Check kubeconfig, RBAC, and network access.\n' "$C_RED" "$C_RESET" >&2
    exit 1
  fi

  if ! command -v jq >/dev/null 2>&1; then
    printf '%sWARN:%s jq not found. Some JSON summaries will use simpler kubectl output.\n' "$C_YELLOW" "$C_RESET"
  fi
}

init_report_dir_if_needed() {
  local timestamp parent
  [ -n "$REPORT_DIR" ] && return 0

  timestamp="$(date '+%Y%m%d_%H%M%S')"
  if [ -n "$OUTPUT_ROOT" ]; then
    parent="${OUTPUT_ROOT%/}"
  else
    parent="$(pwd)/wko_diagnostic_reports"
  fi
  REPORT_DIR="$parent/wko_diag_${timestamp}_$(sanitize_name "$SELECTED_NAMESPACE")_$(sanitize_name "$SELECTED_DOMAIN_UID")"
  mkdir -p "$REPORT_DIR" || {
    printf '%sERROR:%s Unable to create report folder: %s\n' "$C_RED" "$C_RESET" "$REPORT_DIR" >&2
    return 1
  }

  MANIFEST_FILE="$REPORT_DIR/000_manifest.txt"
  {
    printf 'WKID - WebLogic Kubernetes Interactive Diagnostic Report\n'
    printf 'Started: %s\n' "$START_TIME"
    printf 'Namespace: %s\n' "$SELECTED_NAMESPACE"
    printf 'Domain resource: %s\n' "$SELECTED_DOMAIN_RESOURCE"
    printf 'Domain UID: %s\n' "$SELECTED_DOMAIN_UID"
    printf 'Folder: %s\n' "$REPORT_DIR"
    printf 'Safety: WKID does not run mutating kubectl verbs or restart/kill/edit operations. Local writes are limited to this report folder, manifest, saved outputs, and optional archive.\n'
    printf '\nSaved outputs:\n'
  } > "$MANIFEST_FILE"
}

save_output_prompt() {
  local operation_key="$1" operation_title="$2" output="$3" answer file safe_key
  printf '\n%sSave this output to a file?%s (y/N): ' "$C_BOLD" "$C_RESET"
  read -r answer || answer=""
  case "$answer" in
    y|Y|yes|YES|Yes)
      init_report_dir_if_needed || return 0
      SAVE_COUNT=$((SAVE_COUNT + 1))
      safe_key="$(sanitize_name "$operation_key")"
      file="$REPORT_DIR/$(printf '%03d_%s_%s_%s.txt' "$SAVE_COUNT" "$(sanitize_name "$SELECTED_NAMESPACE")" "$(sanitize_name "$SELECTED_DOMAIN_UID")" "$safe_key")"
      {
        printf 'Operation: %s\n' "$operation_title"
        printf 'Namespace: %s\n' "$SELECTED_NAMESPACE"
        printf 'Domain resource: %s\n' "$SELECTED_DOMAIN_RESOURCE"
        printf 'Domain UID: %s\n' "$SELECTED_DOMAIN_UID"
        printf 'Captured: %s\n' "$(now)"
        printf 'Safety: Read-only diagnostic output. WKID does not modify Kubernetes resources; local writes are limited to diagnostic report files.\n'
        printf '%s\n' '--------------------------------------------------------------------------------'
        printf '%s\n' "$output" | redact
      } > "$file"
      printf '[%s] %s - %s\n' "$(now)" "$(basename "$file")" "$operation_title" >> "$MANIFEST_FILE"
      printf '\n%sSaved:%s %s\n' "$C_GREEN" "$C_RESET" "$file"
      ;;
    *) printf '%sNot saved.%s\n' "$C_DIM" "$C_RESET" ;;
  esac
}

save_text_to_file() {
  local operation_key="$1" operation_title="$2" output="$3" file safe_key
  init_report_dir_if_needed || return 1
  SAVE_COUNT=$((SAVE_COUNT + 1))
  safe_key="$(sanitize_name "$operation_key")"
  file="$REPORT_DIR/$(printf '%03d_%s_%s_%s.txt' "$SAVE_COUNT" "$(sanitize_name "$SELECTED_NAMESPACE")" "$(sanitize_name "$SELECTED_DOMAIN_UID")" "$safe_key")"
  {
    printf 'Operation: %s\n' "$operation_title"
    printf 'Namespace: %s\n' "$SELECTED_NAMESPACE"
    printf 'Domain resource: %s\n' "$SELECTED_DOMAIN_RESOURCE"
    printf 'Domain UID: %s\n' "$SELECTED_DOMAIN_UID"
    printf 'Captured: %s\n' "$(now)"
    printf 'Safety: Read-only diagnostic output. WKID does not modify Kubernetes resources; local writes are limited to diagnostic report files.\n'
    printf '%s\n' '--------------------------------------------------------------------------------'
    printf '%s\n' "$output" | redact
  } > "$file"
  printf '[%s] %s - %s\n' "$(now)" "$(basename "$file")" "$operation_title" >> "$MANIFEST_FILE"
  printf '\n%sSaved:%s %s\n' "$C_GREEN" "$C_RESET" "$file"
}

save_archive_text() {
  local operation_key="$1" operation_title="$2" output="$3"
  printf '\n%sCollecting:%s %s\n' "$C_CYAN" "$C_RESET" "$operation_title"
  save_text_to_file "$operation_key" "$operation_title" "$output"
}

create_report_archive() {
  local parent base archive
  [ -n "$REPORT_DIR" ] || return 1
  parent="$(dirname "$REPORT_DIR")"
  base="$(basename "$REPORT_DIR")"

  if command -v zip >/dev/null 2>&1; then
    archive="$REPORT_DIR.zip"
    (cd "$parent" && zip -qr "$archive" "$base") 2>/dev/null || {
      printf '%sWARN:%s Failed to create zip archive. Report folder is still available: %s\n' "$C_YELLOW" "$C_RESET" "$REPORT_DIR"
      return 1
    }
    printf '[%s] %s - Diagnostic archive\n' "$(now)" "$(basename "$archive")" >> "$MANIFEST_FILE"
    printf '\n%sDiagnostic archive:%s %s\n' "$C_GREEN" "$C_RESET" "$archive"
    return 0
  fi

  if command -v tar >/dev/null 2>&1; then
    archive="$REPORT_DIR.tar.gz"
    (cd "$parent" && tar -czf "$archive" "$base") 2>/dev/null || {
      printf '%sWARN:%s Failed to create tar.gz archive. Report folder is still available: %s\n' "$C_YELLOW" "$C_RESET" "$REPORT_DIR"
      return 1
    }
    printf '[%s] %s - Diagnostic archive\n' "$(now)" "$(basename "$archive")" >> "$MANIFEST_FILE"
    printf '\n%sDiagnostic archive:%s %s\n' "$C_GREEN" "$C_RESET" "$archive"
    return 0
  fi

  printf '%sWARN:%s Neither zip nor tar is available. Upload the report folder instead: %s\n' "$C_YELLOW" "$C_RESET" "$REPORT_DIR"
  return 1
}

confirm_read_only_operation() {
  local title="$1"
  shift 2

  print_header "Command Preview: $title"
  printf 'This option may run read-only commands such as:\n'
  while [ "$#" -gt 0 ]; do
    printf '  %s\n' "$1"
    shift
  done
  printf '\nNo Kubernetes resources are modified by WKID.\n'
  printf 'Local writes, if any, are limited to the diagnostic report folder and archive.\n'
  printf 'Continuing with read-only collection.\n\n'
  return 0
}

display_tail_and_save_full_logs() {
  local operation_key="$1" operation_title="$2" tail_output="$3" full_command="$4" answer full_output
  print_header "$operation_title"
  if [ -n "$tail_output" ]; then
    printf '%s\n' "$tail_output" | redact
  else
    printf '(no output)\n'
  fi

  printf '\n%sSave COMPLETE logs to a file?%s Screen showed only last %s lines. (y/N): ' "$C_BOLD" "$C_RESET" "$LOG_TAIL_LINES"
  read -r answer || answer=""
  case "$answer" in
    y|Y|yes|YES|Yes)
      full_output="$(sh -c "$full_command" 2>&1)"
      save_text_to_file "$operation_key" "$operation_title - complete logs" "$full_output"
      ;;
    *) printf '%sNot saved.%s\n' "$C_DIM" "$C_RESET" ;;
  esac
  printf '\n'
}

display_and_maybe_save() {
  local operation_key="$1" operation_title="$2" output="$3"
  print_header "$operation_title"
  if [ -n "$output" ]; then
    printf '%s\n' "$output" | redact
  else
    printf '(no output)\n'
  fi
  save_output_prompt "$operation_key" "$operation_title" "$output"
  printf '\n'
}

run_command_output() {
  "$@" 2>&1
}

choose_from_array() {
  local prompt="$1" item count choice
  shift
  count="$#"
  while :; do
    printf '\n%s%s%s\n' "$C_BOLD" "$prompt" "$C_RESET" >&2
    local i=1
    for item in "$@"; do
      printf '  %2d) %s\n' "$i" "$item" >&2
      i=$((i + 1))
    done
    printf '%sEnter choice [1-%s]:%s ' "$C_YELLOW" "$count" "$C_RESET" >&2
    read -r choice || choice=""
    if [ "$choice" -ge 1 ] 2>/dev/null && [ "$choice" -le "$count" ] 2>/dev/null; then
      eval "printf '%s\n' \"\${$choice}\""
      return 0
    fi
    printf '%sInvalid selection. Try again.%s\n' "$C_RED" "$C_RESET" >&2
  done
}

select_namespace() {
  local namespaces selected
  namespaces="$(kubectl get namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | sort)"
  if [ -z "$namespaces" ]; then
    printf 'ERROR: No namespaces found or insufficient RBAC.\n' >&2
    exit 1
  fi
  # shellcheck disable=SC2206
  set -- $namespaces
  selected="$(choose_from_array "Select a Kubernetes namespace:" "$@")"
  SELECTED_NAMESPACE="$selected"
}

select_domain() {
  local domains selected domain_uid operator_like_pods answer
  domains="$(kubectl get domains -n "$SELECTED_NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | sort)"
  OPERATOR_ONLY_MODE=0
  if [ -z "$domains" ]; then
    operator_like_pods="$(operator_pods_in_namespace "$SELECTED_NAMESPACE")"
    if [ -n "$operator_like_pods" ]; then
      printf '\nNo WebLogic Domain resources were found in namespace %s.\n' "$SELECTED_NAMESPACE"
      printf 'This namespace appears to contain WebLogic Operator/webhook pods:\n'
      printf '%s\n' "$operator_like_pods" | awk 'BEGIN{printf "%-25s %-45s\n","NAMESPACE","POD"} {printf "%-25s %-45s\n",$1,$2}'
      printf '\nRun WebLogic Operator / webhook diagnostics for this namespace instead? (Y/n): '
      read -r answer || answer=""
      case "$answer" in
        n|N|no|NO|No)
          printf 'Operator diagnostics cancelled.\n'
          exit 0
          ;;
      esac
      SELECTED_DOMAIN_RESOURCE="operator-diagnostics"
      SELECTED_DOMAIN_UID="operator-diagnostics"
      WEBLOGIC_SERVER_VERSION="N/A"
      JDK_VERSION="N/A"
      refresh_operator_version
      SELECTED_OPERATOR_NAMESPACE="$SELECTED_NAMESPACE"
      OPERATOR_ONLY_MODE=1
      return 0
    fi
    printf 'ERROR: No WebLogic Domain resources found in namespace %s.\n' "$SELECTED_NAMESPACE" >&2
    printf 'Tip: verify the WKO Domain CRD exists and your user has access to list domains.\n' >&2
    exit 1
  fi
  # shellcheck disable=SC2206
  set -- $domains
  selected="$(choose_from_array "Select a WebLogic domain in namespace '$SELECTED_NAMESPACE':" "$@")"
  SELECTED_DOMAIN_RESOURCE="$selected"
  domain_uid="$(kubectl get domain "$SELECTED_DOMAIN_RESOURCE" -n "$SELECTED_NAMESPACE" -o jsonpath='{.spec.domainUID}' 2>/dev/null || true)"
  SELECTED_DOMAIN_UID="${domain_uid:-$SELECTED_DOMAIN_RESOURCE}"
  refresh_runtime_summary
}

select_domain_context_for_operator_namespace() {
  local domains count choice ns domain uid i
  local old_namespace="$SELECTED_NAMESPACE"
  local old_domain_resource="$SELECTED_DOMAIN_RESOURCE"
  local old_domain_uid="$SELECTED_DOMAIN_UID"
  local old_operator_only="$OPERATOR_ONLY_MODE"

  domains="$(kubectl get domains --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.spec.domainUID}{"\n"}{end}' 2>/dev/null | sort)"
  if [ -z "$domains" ]; then
    printf '\nNo WebLogic Domain resources are visible to this user across namespaces.\n'
    printf 'WKID can collect operator/webhook diagnostics only, but a complete introspection RCA archive needs a WebLogic Domain namespace too.\n'
    return 1
  fi

  printf '\nA complete diagnostic archive needs both operator diagnostics and a WebLogic Domain context.\n'
  printf 'Select the managed WebLogic Domain that you want WKID to use for option 1.\n'
  printf 'The diagnostic archive will still include detected operator/webhook diagnostics.\n'
  printf '\n%sSelect a WebLogic Domain for the diagnostic archive:%s\n' "$C_BOLD" "$C_RESET"

  count=0
  while IFS="$(printf '\t')" read -r ns domain uid; do
    [ -n "$ns" ] && [ -n "$domain" ] || continue
    count=$((count + 1))
    eval "DOMAIN_CONTEXT_NS_$count=\$ns"
    eval "DOMAIN_CONTEXT_NAME_$count=\$domain"
    eval "DOMAIN_CONTEXT_UID_$count=\${uid:-\$domain}"
    printf '  %2d) %s/%s (Domain UID: %s)\n' "$count" "$ns" "$domain" "${uid:-$domain}"
  done <<EOF
$domains
EOF

  if [ "$count" -eq 0 ]; then
    printf '\nNo selectable WebLogic Domain resources were found.\n'
    return 1
  fi

  while :; do
    printf '%sEnter choice [1-%s], or q to collect operator diagnostics only:%s ' "$C_YELLOW" "$count" "$C_RESET"
    read -r choice || choice="q"
    case "$choice" in
      q|Q|quit|exit)
        SELECTED_NAMESPACE="$old_namespace"
        SELECTED_DOMAIN_RESOURCE="$old_domain_resource"
        SELECTED_DOMAIN_UID="$old_domain_uid"
        OPERATOR_ONLY_MODE="$old_operator_only"
        WEBLOGIC_SERVER_VERSION="N/A"
        JDK_VERSION="N/A"
        refresh_operator_version
        return 1
        ;;
    esac
    if [ "$choice" -ge 1 ] 2>/dev/null && [ "$choice" -le "$count" ] 2>/dev/null; then
      i="$choice"
      eval "SELECTED_NAMESPACE=\$DOMAIN_CONTEXT_NS_$i"
      eval "SELECTED_DOMAIN_RESOURCE=\$DOMAIN_CONTEXT_NAME_$i"
      eval "SELECTED_DOMAIN_UID=\$DOMAIN_CONTEXT_UID_$i"
      OPERATOR_ONLY_MODE=0
      refresh_runtime_summary
      printf '\nSelected domain context: %s/%s (Domain UID: %s)\n' "$SELECTED_NAMESPACE" "$SELECTED_DOMAIN_RESOURCE" "$SELECTED_DOMAIN_UID"
      return 0
    fi
    printf '%sInvalid selection. Try again.%s\n' "$C_RED" "$C_RESET"
  done
}

domain_pod_names() {
  kubectl get pods -n "$SELECTED_NAMESPACE" -l "weblogic.domainUID=$SELECTED_DOMAIN_UID" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | sort
}

operator_pods() {
  {
    kubectl get pods --all-namespaces -l 'weblogic.operatorName' \
      -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\n"}{end}' 2>/dev/null
    kubectl get pods --all-namespaces -l 'weblogic.webhookName' \
      -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\n"}{end}' 2>/dev/null
    kubectl get pods --all-namespaces -l 'app.kubernetes.io/name=weblogic-operator' \
      -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\n"}{end}' 2>/dev/null
  } | awk 'NF && $2 ~ /weblogic-operator/ && !seen[$1 FS $2]++'
}

operator_pods_in_namespace() {
  local namespace="$1"
  {
    kubectl get pods -n "$namespace" -l 'weblogic.operatorName' \
      -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\n"}{end}' 2>/dev/null
    kubectl get pods -n "$namespace" -l 'weblogic.webhookName' \
      -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\n"}{end}' 2>/dev/null
    kubectl get pods -n "$namespace" -l 'app.kubernetes.io/name=weblogic-operator' \
      -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\n"}{end}' 2>/dev/null
    kubectl get pods -n "$namespace" -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\n"}{end}' 2>/dev/null |
      awk -v ns="$namespace" '$1 == ns && $2 ~ /weblogic-operator/'
  } | awk 'NF && $2 ~ /weblogic-operator/ && !seen[$1 FS $2]++'
}

refresh_operator_version() {
  local operator_image
  WEBLOGIC_OPERATOR_VERSION="N/A"
  operator_image="$(
    kubectl get pods --all-namespaces -l 'weblogic.operatorName' \
      -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null ||
    kubectl get pods --all-namespaces -l 'app.kubernetes.io/name=weblogic-operator' \
      -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null ||
    true
  )"
  if [ -n "$operator_image" ]; then
    case "$operator_image" in
      *@*) WEBLOGIC_OPERATOR_VERSION="$operator_image" ;;
      *:*) WEBLOGIC_OPERATOR_VERSION="${operator_image##*:}" ;;
      *) WEBLOGIC_OPERATOR_VERSION="$operator_image" ;;
    esac
  fi
}

refresh_runtime_summary() {
  local first_pod runtime_output wls_line jdk_line
  WEBLOGIC_SERVER_VERSION="N/A"
  JDK_VERSION="N/A"

  first_pod="$(domain_pod_names | sed -n '1p')"
  if [ -n "$first_pod" ]; then
    runtime_output="$(
      kubectl exec -n "$SELECTED_NAMESPACE" "$first_pod" -- sh -c '
        printf "JDK_VERSION="
        if command -v java >/dev/null 2>&1; then
          java -version 2>&1 | sed -n "1p"
        else
          printf "N/A\n"
        fi
        printf "WEBLOGIC_VERSION="
        wls_env=/u01/ora"cle"/wlserver/server/bin/setWLSEnv.sh
        if [ -f "$wls_env" ]; then
          . "$wls_env" >/dev/null 2>&1
        fi
        if command -v java >/dev/null 2>&1; then
          java weblogic.version 2>&1 | grep -Ei "WebLogic Server|Version:" | sed -n "1p"
        else
          printf "N/A\n"
        fi
      ' 2>/dev/null
    )"
    jdk_line="$(printf '%s\n' "$runtime_output" | sed -n 's/^JDK_VERSION=//p' | sed -n '1p')"
    wls_line="$(printf '%s\n' "$runtime_output" | sed -n 's/^WEBLOGIC_VERSION=//p' | sed -n '1p')"
    [ -n "$jdk_line" ] && JDK_VERSION="$jdk_line"
    [ -n "$wls_line" ] && WEBLOGIC_SERVER_VERSION="$wls_line"
  fi

  refresh_operator_version
}

domain_cluster_names() {
  if command -v jq >/dev/null 2>&1; then
    kubectl get domain "$SELECTED_DOMAIN_RESOURCE" -n "$SELECTED_NAMESPACE" -o json 2>/dev/null |
      jq -r '(.spec.clusters // [])[]? | (.name // .clusterName // empty)' | sort -u
  else
    kubectl get clusters -n "$SELECTED_NAMESPACE" -l "weblogic.domainUID=$SELECTED_DOMAIN_UID" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | sort -u
  fi
}

domain_introspector_names() {
  {
    kubectl get jobs -n "$SELECTED_NAMESPACE" -l "weblogic.domainUID=$SELECTED_DOMAIN_UID" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -Ei 'introspect|introspector' || true
    kubectl get pods -n "$SELECTED_NAMESPACE" -l "weblogic.domainUID=$SELECTED_DOMAIN_UID" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -Ei 'introspect|introspector' || true
  } | sort -u
}

domain_introspector_job_names() {
  {
    kubectl get jobs -n "$SELECTED_NAMESPACE" -l "weblogic.domainUID=$SELECTED_DOMAIN_UID" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null
    kubectl get jobs -n "$SELECTED_NAMESPACE" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null |
      grep -Ei "^${SELECTED_DOMAIN_UID}.*introspect|introspector" || true
  } | grep -Ei 'introspect|introspector' | sort -u
}

domain_introspector_pod_names() {
  {
    kubectl get pods -n "$SELECTED_NAMESPACE" -l "weblogic.domainUID=$SELECTED_DOMAIN_UID" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null
    kubectl get pods -n "$SELECTED_NAMESPACE" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null |
      grep -Ei "^${SELECTED_DOMAIN_UID}.*introspect|introspector" || true
  } | grep -Ei 'introspect|introspector' | sort -u
}

introspector_pods_for_job() {
  local job_name="$1"
  kubectl get pods -n "$SELECTED_NAMESPACE" -l "job-name=$job_name" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | sort -u
}

domain_model_configmap_names() {
  if command -v jq >/dev/null 2>&1; then
    kubectl get domain "$SELECTED_DOMAIN_RESOURCE" -n "$SELECTED_NAMESPACE" -o json 2>/dev/null |
      jq -r '
        [
          .spec.configuration.model.configMap,
          .spec.configuration.model.configMapName,
          (.spec.configuration.model.configMaps[]?.name)
        ] | .[]? | select(. != null and . != "")
      ' | sort -u
  else
    kubectl get domain "$SELECTED_DOMAIN_RESOURCE" -n "$SELECTED_NAMESPACE" -o yaml 2>/dev/null |
      sed -n 's/^[[:space:]]*configMapName:[[:space:]]*//p; s/^[[:space:]]*configMap:[[:space:]]*//p' | sort -u
  fi
}

print_pod_yaml_and_image_identity() {
  local namespace="$1" pod="$2"
  printf 'Pod YAML and image identity for %s/%s\n' "$namespace" "$pod"
  printf '\nImage identity:\n'
  kubectl get pod "$pod" -n "$namespace" -o jsonpath='{range .status.containerStatuses[*]}container={.name} image={.image} imageID={.imageID} containerID={.containerID} restartCount={.restartCount} ready={.ready} lastStateTerminatedReason={.lastState.terminated.reason} lastStateTerminatedExitCode={.lastState.terminated.exitCode} lastStateTerminatedFinishedAt={.lastState.terminated.finishedAt}{"\n"}{end}' 2>&1
  printf '\nInit container image identity:\n'
  kubectl get pod "$pod" -n "$namespace" -o jsonpath='{range .status.initContainerStatuses[*]}container={.name} image={.image} imageID={.imageID} containerID={.containerID} restartCount={.restartCount} ready={.ready} lastStateTerminatedReason={.lastState.terminated.reason} lastStateTerminatedExitCode={.lastState.terminated.exitCode} lastStateTerminatedFinishedAt={.lastState.terminated.finishedAt}{"\n"}{end}' 2>&1
  printf '\nService account and scheduling:\n'
  kubectl get pod "$pod" -n "$namespace" -o jsonpath='serviceAccount={.spec.serviceAccountName} nodeName={.spec.nodeName} hostIP={.status.hostIP} podIP={.status.podIP} qosClass={.status.qosClass}{"\n"}' 2>&1
  printf '\nFull pod YAML:\n'
  kubectl get pod "$pod" -n "$namespace" -o yaml 2>&1
}

java_process_discovery_script() {
  printf '%s\n' 'if command -v jps >/dev/null 2>&1; then jps -lv; elif command -v ps >/dev/null 2>&1; then ps -ef | awk '\''tolower($0) ~ /java/ && $0 !~ /awk/ {pid=$2; $1=""; $2=""; sub(/^[[:space:]]+/, ""); print pid " " $0}'\''; else echo "No jps or ps available"; fi'
}

opatch_inventory_script() {
  printf '%s\n' 'for op in /u01/ora"cle"/weblogic12213/OPatch/opatch /u01/ora"cle"/OPatch/opatch /u01/ora"cle"/ora"cle"_common/OPatch/opatch; do if [ -x "$op" ]; then "$op" lspatches; exit 0; fi; done; echo "OPatch executable not found in common locations"'
}

print_domain_status_summary() {
  printf 'Selected namespace:      %s\n' "$SELECTED_NAMESPACE"
  printf 'Domain resource name:    %s\n' "$SELECTED_DOMAIN_RESOURCE"
  printf 'Domain UID:              %s\n\n' "$SELECTED_DOMAIN_UID"

  if command -v jq >/dev/null 2>&1; then
    kubectl get domain "$SELECTED_DOMAIN_RESOURCE" -n "$SELECTED_NAMESPACE" -o json 2>/dev/null |
      jq -r '
        "Domain home source summary:",
        ("  domainHomeSourceType: " + (.spec.domainHomeSourceType // "N/A")),
        ("  inferred source: " + (
          if (.spec.domainHomeSourceType // "") == "Image" then
            "Image-based domain home"
          elif (.spec.domainHomeSourceType // "") == "PersistentVolume" then
            "PersistentVolume-based domain home"
          elif (.spec.domainHomeSourceType // "") == "FromModel" then
            "FromModel / WDT model-based domain home"
          else
            "N/A"
          end
        )),
        ("  domainHome: " + (.spec.domainHome // "N/A")),
        ("  image: " + (.spec.image // "N/A")),
        ("  modelHome: " + (.spec.configuration.model.modelHome // "N/A")),
        ("  model configMap: " + (.spec.configuration.model.configMap // "N/A")),
        ("  runtimeEncryptionSecretName: " + (.spec.configuration.model.runtimeEncryptionSecret // "N/A")),
        ("  domainType: " + (.spec.configuration.model.domainType // "N/A")),
        "",
        "Generation freshness:",
        ("  metadata.generation: " + ((.metadata.generation // "N/A")|tostring)),
        ("  status.observedGeneration: " + ((.status.observedGeneration // "N/A")|tostring)),
        ("  freshness: " + (if (.metadata.generation // 0) == (.status.observedGeneration // -1) then "PASS observedGeneration is current" else "WARN observedGeneration is behind metadata.generation" end)),
        "",
        "Domain conditions:",
        (if ((.status.conditions // []) | length) == 0 then "  INFO no status.conditions reported" else
          (.status.conditions[] | "  " + (.type // "Unknown") + "=" + (.status // "Unknown") + " reason=" + (.reason // "N/A") + " lastTransition=" + (.lastTransitionTime // "N/A") + " message=" + ((.message // "") | gsub("[\r\n]+"; " ")))
        end),
        "",
        "Cluster status from Domain resource:",
        (if ((.status.clusters // []) | length) == 0 then "  INFO no status.clusters reported" else
          (.status.clusters[] | "  " + (.clusterName // .name // "unknown") + " replicas=" + ((.replicas // "N/A")|tostring) + " ready=" + ((.readyReplicas // "N/A")|tostring) + " available=" + ((.availableReplicas // "N/A")|tostring) + " maximumReplicas=" + ((.maximumReplicas // "N/A")|tostring))
        end),
        "",
        "Log home configuration:",
        ("  logHomeEnabled: " + ((.spec.logHomeEnabled // "N/A")|tostring)),
        ("  logHome: " + (.spec.logHome // "N/A")),
        ("  logHomeLayout: " + (.spec.logHomeLayout // "N/A")),
        ("  domainHome: " + (.spec.domainHome // "N/A"))
      '
  else
    printf 'jq not found. Showing compact domain source and describe status lines instead.\n\n'
    printf 'Domain home source summary:\n'
    kubectl get domain "$SELECTED_DOMAIN_RESOURCE" -n "$SELECTED_NAMESPACE" -o yaml 2>/dev/null |
      grep -E 'domainHomeSourceType:|domainHome:|image:|modelHome:|configMap:|runtimeEncryptionSecret:|domainType:' || true
    printf '\n'
    kubectl describe domain "$SELECTED_DOMAIN_RESOURCE" -n "$SELECTED_NAMESPACE" 2>&1 |
      sed -n '/Status:/,$p' | sed -n '1,180p'
  fi
}

print_cluster_resource_diagnostics() {
  local clusters cluster
  clusters="$(domain_cluster_names)"
  printf 'Cluster resources referenced by domain or labelled for domain UID:\n'
  if [ -z "$clusters" ]; then
    printf '  INFO no Cluster resources detected for domain UID %s.\n' "$SELECTED_DOMAIN_UID"
    printf '\nAll Cluster resources in namespace for context:\n'
    kubectl get clusters -n "$SELECTED_NAMESPACE" -o wide 2>&1
    return 0
  fi
  for cluster in $clusters; do
    printf '\n================================================================================\n'
    printf 'Cluster resource: %s\n' "$cluster"
    printf '================================================================================\n'
    kubectl get cluster "$cluster" -n "$SELECTED_NAMESPACE" -o wide 2>&1
    printf '\nDescribe cluster/%s:\n' "$cluster"
    kubectl describe cluster "$cluster" -n "$SELECTED_NAMESPACE" 2>&1
  done
}

print_introspector_diagnostics() {
  local jobs pods name cm
  printf 'Introspector diagnostics for domain UID %s:\n' "$SELECTED_DOMAIN_UID"
  jobs="$(domain_introspector_job_names)"
  pods="$(domain_introspector_pod_names)"
  if [ -z "$jobs" ] && [ -z "$pods" ]; then
    printf '  INFO no active introspector jobs or pods found. This can be normal when introspection is not currently running or after failed pods are garbage-collected.\n'
  fi

  for name in $jobs; do
    printf '\n================================================================================\n'
    printf 'Introspector job: %s\n' "$name"
    printf '================================================================================\n'
    kubectl get job "$name" -n "$SELECTED_NAMESPACE" -o wide 2>&1
    printf '\nJob status:\n'
    kubectl get job "$name" -n "$SELECTED_NAMESPACE" -o jsonpath='active={.status.active} succeeded={.status.succeeded} failed={.status.failed} startTime={.status.startTime} completionTime={.status.completionTime}{"\n"}' 2>&1
    printf '\nDescribe job/%s:\n' "$name"
    kubectl describe job "$name" -n "$SELECTED_NAMESPACE" 2>&1
    printf '\nJob logs for %s, last %s lines:\n' "$name" "$LOG_TAIL_LINES"
    kubectl logs job/"$name" -n "$SELECTED_NAMESPACE" --tail="$LOG_TAIL_LINES" 2>&1
  done

  for name in $pods; do
    printf '\n================================================================================\n'
    printf 'Introspector pod: %s\n' "$name"
    printf '================================================================================\n'
    kubectl get pod "$name" -n "$SELECTED_NAMESPACE" -o wide 2>&1
    printf '\nDescribe pod/%s:\n' "$name"
    kubectl describe pod "$name" -n "$SELECTED_NAMESPACE" 2>&1
    printf '\nCurrent logs for %s, last %s lines:\n' "$name" "$LOG_TAIL_LINES"
    kubectl logs "$name" -n "$SELECTED_NAMESPACE" --all-containers=true --tail="$LOG_TAIL_LINES" 2>&1
    printf '\nPrevious logs for %s, last %s lines if available:\n' "$name" "$LOG_TAIL_LINES"
    kubectl logs "$name" -n "$SELECTED_NAMESPACE" --all-containers=true --previous --tail="$LOG_TAIL_LINES" 2>&1 || true
  done

  cm="${SELECTED_DOMAIN_UID}-weblogic-domain-introspect-cm"
  printf '\nIntrospect ConfigMap metadata: %s\n' "$cm"
  kubectl get configmap "$cm" -n "$SELECTED_NAMESPACE" -o wide 2>&1
}

introspector_artifact_script() {
  cat <<'EOF_INTROSPECTOR_ARTIFACTS'
printf 'Candidate introspector/WDT files under /tmp:\n'
find /tmp -maxdepth 5 -type f \( -iname '*introspect*' -o -iname '*createDomain*' -o -iname '*wdt*' -o -iname '*model*' -o -iname '*deploy*' -o -iname '*.log' -o -iname '*.out' \) -print 2>/dev/null | sort
printf '\nModel files under /aux/models:\n'
find /aux/models -maxdepth 5 -type f -print 2>/dev/null | sort
printf '\nModel archive listings under /aux/models:\n'
find /aux/models -maxdepth 5 -type f \( -iname '*.zip' -o -iname '*.jar' \) -print 2>/dev/null | sort | while read -r archive; do
  [ -f "$archive" ] || continue
  printf '\n================================================================================\n'
  printf '%s\n' "$archive"
  printf '================================================================================\n'
  if command -v unzip >/dev/null 2>&1; then
    unzip -l "$archive" 2>&1
  elif command -v jar >/dev/null 2>&1; then
    jar tf "$archive" 2>&1
  else
    ls -l "$archive" 2>&1
    printf 'No unzip or jar command available to list archive contents.\n'
  fi
done
printf '\nSelected /aux/models text file contents when present:\n'
find /aux/models -maxdepth 5 -type f \( -iname '*.yaml' -o -iname '*.yml' -o -iname '*.properties' -o -iname '*.json' -o -iname '*.txt' \) -size -2m -print 2>/dev/null | sort | while read -r file; do
  [ -f "$file" ] || continue
  printf '\n================================================================================\n'
  printf '%s\n' "$file"
  printf '================================================================================\n'
  printf '--- first 2000 lines ---\n'
  sed -n '1,2000p' "$file" 2>&1
  printf '\n--- last 500 lines ---\n'
  tail -n 500 "$file" 2>&1
done
printf '\nSelected file contents when present:\n'
for file in /tmp/introspector_script.out /tmp/createDomain.sh /tmp/createDomain.log /tmp/wdt.log /tmp/weblogic-deploy.log /tmp/model.yaml /tmp/model.yml /tmp/model.properties /tmp/weblogic-deploy/logs/weblogic-deploy.log; do
  if [ -f "$file" ]; then
    printf '\n================================================================================\n'
    printf '%s\n' "$file"
    printf '================================================================================\n'
    printf '--- first 2000 lines ---\n'
    sed -n '1,2000p' "$file" 2>&1
    printf '\n--- last 500 lines ---\n'
    tail -n 500 "$file" 2>&1
  fi
done
printf '\nAdditional matching text artifacts, first 400 and last 200 lines each:\n'
find /tmp -maxdepth 5 -type f \( -iname '*introspect*' -o -iname '*createDomain*' -o -iname '*wdt*' -o -iname '*deploy*' -o -iname '*.log' -o -iname '*.out' \) -size -5m -print 2>/dev/null | sort | while read -r file; do
  [ -f "$file" ] || continue
  case "$file" in
    /tmp/introspector_script.out|/tmp/createDomain.sh|/tmp/createDomain.log|/tmp/wdt.log|/tmp/weblogic-deploy.log|/tmp/model.yaml|/tmp/model.yml|/tmp/model.properties|/tmp/weblogic-deploy/logs/weblogic-deploy.log) continue ;;
  esac
  printf '\n================================================================================\n'
  printf '%s\n' "$file"
  printf '================================================================================\n'
  sed -n '1,400p' "$file" 2>&1
  printf '\n--- last 200 lines ---\n'
  tail -n 200 "$file" 2>&1
done
EOF_INTROSPECTOR_ARTIFACTS
}

print_weblogic_loghome_summary() {
  printf 'WebLogic log file summary:\n'
  printf '  kubectl logs shows container stdout/stderr only.\n'
  printf '  WebLogic server, domain, and Node Manager logs can also exist inside domainHome or logHome.\n\n'
  if command -v jq >/dev/null 2>&1; then
    kubectl get domain "$SELECTED_DOMAIN_RESOURCE" -n "$SELECTED_NAMESPACE" -o json 2>/dev/null |
      jq -r '
        "Domain log configuration:",
        ("  logHomeEnabled: " + ((.spec.logHomeEnabled // "N/A")|tostring)),
        ("  logHome: " + (.spec.logHome // "N/A")),
        ("  logHomeLayout: " + (.spec.logHomeLayout // "N/A")),
        ("  domainHome: " + (.spec.domainHome // "N/A")),
        "",
        "Common in-container log patterns:",
        "  <domainHome>/servers/<serverName>/logs/<serverName>.log",
        "  <domainHome>/servers/<serverName>/logs/<serverName>.out",
        "  <domainHome>/servers/<serverName>/logs/<serverName>_nodemanager.log",
        "  <logHome>/<domainUID>/servers/<serverName>/logs/* when logHomeEnabled is true"
      '
  else
    kubectl get domain "$SELECTED_DOMAIN_RESOURCE" -n "$SELECTED_NAMESPACE" -o yaml 2>/dev/null |
      grep -E 'logHomeEnabled|logHome:|logHomeLayout|domainHome:' || true
  fi
}

choose_domain_pod() {
  local prompt="$1" pods selected
  pods="$(domain_pod_names)"
  if [ -z "$pods" ]; then
    printf '%sWARN:%s No WebLogic pods found for domain UID %s in namespace %s.\n' "$C_YELLOW" "$C_RESET" "$SELECTED_DOMAIN_UID" "$SELECTED_NAMESPACE" >&2
    return 1
  fi
  # shellcheck disable=SC2206
  set -- $pods
  selected="$(choose_from_array "$prompt" "$@")"
  printf '%s\n' "$selected"
}

choose_any_pod_in_namespace() {
  local pods selected
  pods="$(kubectl get pods -n "$SELECTED_NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | sort)"
  if [ -z "$pods" ]; then
    printf '%sWARN:%s No pods found in namespace %s.\n' "$C_YELLOW" "$C_RESET" "$SELECTED_NAMESPACE" >&2
    return 1
  fi
  # shellcheck disable=SC2206
  set -- $pods
  selected="$(choose_from_array "Select pod in namespace '$SELECTED_NAMESPACE':" "$@")"
  printf '%s\n' "$selected"
}

choose_java_process_in_pod() {
  local pod="$1" processes candidates selected line pid command_summary
  processes="$(kubectl exec -n "$SELECTED_NAMESPACE" "$pod" -- sh -c "$(java_process_discovery_script)" 2>&1)"
  if printf '%s\n' "$processes" | grep -qi 'Error from server\|No jps or ps available'; then
    printf '\n%sJava process discovery failed in %s/%s:%s\n' "$C_YELLOW" "$SELECTED_NAMESPACE" "$pod" "$C_RESET" >&2
    printf '%s\n' "$processes" >&2
    return 1
  fi

  candidates="$(printf '%s\n' "$processes" | awk 'NF && $1 ~ /^[0-9]+$/ && $0 !~ /Jps/ {print}')"
  if [ -z "$candidates" ]; then
    candidates="$(printf '%s\n' "$processes" | awk 'NF && $1 ~ /^[0-9]+$/ {print}')"
  fi
  if [ -z "$candidates" ]; then
    printf '\nRaw Java process output from %s/%s:\n' "$SELECTED_NAMESPACE" "$pod" >&2
    printf '%s\n' "$processes" >&2
    printf '%sUnable to parse Java PIDs from process output.%s\n' "$C_RED" "$C_RESET" >&2
    return 1
  fi

  printf '\n%sJava processes in %s/%s:%s\n' "$C_BOLD" "$SELECTED_NAMESPACE" "$pod" "$C_RESET" >&2
  printf '%sYou can enter either the row number or the actual PID.%s\n\n' "$C_DIM" "$C_RESET" >&2
  printf '  %-4s %-8s %s\n' "No." "PID" "Command" >&2
  printf '  %-4s %-8s %s\n' "----" "--------" "-------" >&2
  local i=1
  printf '%s\n' "$candidates" | while IFS= read -r line; do
    pid="$(printf '%s\n' "$line" | awk '{print $1}')"
    command_summary="$(printf '%s\n' "$line" | cut -d' ' -f2- | sed -E 's/[[:space:]]+/ /g')"
    if [ "${#command_summary}" -gt 120 ]; then
      command_summary="$(printf '%s' "$command_summary" | cut -c1-117)..."
    fi
    printf '  %-4s %-8s %s\n' "$i" "$pid" "$command_summary" >&2
    i=$((i + 1))
  done

  while :; do
    printf 'Select Java process row number or PID: ' >&2
    read -r selected || selected=""
    line=""
    if [ "$selected" -ge 1 ] 2>/dev/null; then
      line="$(printf '%s\n' "$candidates" | sed -n "${selected}p" 2>/dev/null || true)"
      if [ -z "$line" ]; then
        line="$(printf '%s\n' "$candidates" | awk -v wanted="$selected" '$1 == wanted {print; exit}')"
      fi
    fi
    if [ -n "$line" ]; then
      pid="$(printf '%s\n' "$line" | awk '{print $1}')"
      printf '%sSelected PID:%s %s\n' "$C_GREEN" "$C_RESET" "$pid" >&2
      printf '%s\n' "$pid"
      return 0
    fi
    printf '%sInvalid selection.%s Enter the row number shown in the No. column or the PID value.\n' "$C_RED" "$C_RESET" >&2
  done
}

metrics_server_hint_prompt() {
  local answer
  if kubectl top pods -n "$SELECTED_NAMESPACE" >/dev/null 2>&1; then
    return 0
  fi

  printf '\nMetrics API is not available, so live CPU/memory usage will show as N/A.\n'
  printf 'This script will not install metrics-server because that would modify the cluster.\n'
  printf 'Show read-only guidance for installing/verifying metrics-server outside this script? (y/N): '
  read -r answer || answer=""
  case "$answer" in
    y|Y|yes|YES|Yes)
      printf '%s\n' \
        '' \
        'Metrics-server guidance:' \
        '  - Check cluster/provider documentation first; managed clusters often have a diagnosticed add-on path.' \
        '  - Ask the cluster administrator to enable metrics-server through the approved production change process.' \
        '  - After metrics-server is enabled, verify with:' \
        '      kubectl top nodes' \
        '      kubectl top pods -A' \
        '  - Some clusters require provider-specific TLS/RBAC/network settings.' \
        ''
      ;;
  esac
}

op_domain_summary() {
  local output
  output="$(
    print_domain_status_summary
    printf '\n================================================================================\n'
    printf 'Domain resource overview\n'
    printf '================================================================================\n'
    kubectl get domain "$SELECTED_DOMAIN_RESOURCE" -n "$SELECTED_NAMESPACE" -o wide 2>&1
    printf '\nDescribe domain/%s:\n' "$SELECTED_DOMAIN_RESOURCE"
    kubectl describe domain "$SELECTED_DOMAIN_RESOURCE" -n "$SELECTED_NAMESPACE" 2>&1
    printf '\n================================================================================\n'
    printf 'Cluster resource diagnostics\n'
    printf '================================================================================\n'
    print_cluster_resource_diagnostics
    printf '\n================================================================================\n'
    printf 'Introspector diagnostics\n'
    printf '================================================================================\n'
    print_introspector_diagnostics
    printf '\n================================================================================\n'
    printf 'Domain YAML preview\n'
    printf '================================================================================\n'
    kubectl get domain "$SELECTED_DOMAIN_RESOURCE" -n "$SELECTED_NAMESPACE" -o yaml 2>&1 | sed -n '1,260p'
  )"
  display_and_maybe_save "domain-summary" "WKO Domain and Cluster Status Summary" "$output"
}

op_pod_summary() {
  local output pods
  pods="$(domain_pod_names)"
  output="$(
    if [ -z "$pods" ]; then
      printf 'No pods found for label weblogic.domainUID=%s in namespace %s.\n' "$SELECTED_DOMAIN_UID" "$SELECTED_NAMESPACE"
    else
      kubectl get pods -n "$SELECTED_NAMESPACE" -l "weblogic.domainUID=$SELECTED_DOMAIN_UID" -o wide 2>&1
      printf '\nRestart and container status summary:\n'
      if command -v jq >/dev/null 2>&1; then
        kubectl get pods -n "$SELECTED_NAMESPACE" -l "weblogic.domainUID=$SELECTED_DOMAIN_UID" -o json 2>/dev/null |
          jq -r '.items[] | [.metadata.name, (.status.phase // "N/A"), (((.status.containerStatuses // []) | map(.restartCount // 0) | add) // 0), (.spec.nodeName // "N/A")] | @tsv' |
          awk 'BEGIN{printf "%-45s %-12s %-10s %-25s\n","POD","PHASE","RESTARTS","NODE"} {printf "%-45s %-12s %-10s %-25s\n",$1,$2,$3,$4}'
      else
        for pod in $pods; do
          printf '%s\n' "$pod"
          kubectl get pod "$pod" -n "$SELECTED_NAMESPACE" -o jsonpath='{.status.phase}{" restarts="}{.status.containerStatuses[*].restartCount}{" node="}{.spec.nodeName}{"\n"}' 2>/dev/null
        done
      fi
    fi
  )"
  display_and_maybe_save "pod-summary" "WebLogic Pod Summary" "$output"
}

op_pod_resources() {
  local output pods
  metrics_server_hint_prompt
  pods="$(domain_pod_names)"
  output="$(
    if [ -z "$pods" ]; then
      printf 'No pods found for domain UID %s.\n' "$SELECTED_DOMAIN_UID"
    else
      printf '%-42s %-12s %-14s %-14s %-14s %-14s %-16s\n' "POD" "PHASE" "CPU_REQ" "CPU_LIM" "MEM_REQ" "MEM_LIM" "CPU/MEM_USAGE"
      for pod in $pods; do
        phase="$(kubectl get pod "$pod" -n "$SELECTED_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)"
        cpu_req="$(kubectl get pod "$pod" -n "$SELECTED_NAMESPACE" -o jsonpath='{.spec.containers[*].resources.requests.cpu}' 2>/dev/null)"
        cpu_lim="$(kubectl get pod "$pod" -n "$SELECTED_NAMESPACE" -o jsonpath='{.spec.containers[*].resources.limits.cpu}' 2>/dev/null)"
        mem_req="$(kubectl get pod "$pod" -n "$SELECTED_NAMESPACE" -o jsonpath='{.spec.containers[*].resources.requests.memory}' 2>/dev/null)"
        mem_lim="$(kubectl get pod "$pod" -n "$SELECTED_NAMESPACE" -o jsonpath='{.spec.containers[*].resources.limits.memory}' 2>/dev/null)"
        usage="$(kubectl top pod "$pod" -n "$SELECTED_NAMESPACE" 2>/dev/null | awk 'NR==2 {print $2"/"$3}')"
        [ -n "$usage" ] || usage="N/A"
        printf '%-42s %-12s %-14s %-14s %-14s %-14s %-16s\n' "$pod" "${phase:-N/A}" "${cpu_req:-N/A}" "${cpu_lim:-N/A}" "${mem_req:-N/A}" "${mem_lim:-N/A}" "$usage"
      done

      printf '\nNode CPU and memory context for nodes hosting this domain:\n'
      printf '%-32s %-12s %-12s %-16s %-16s %-18s\n' "NODE" "CPU_CAP" "CPU_ALLOC" "MEM_CAP" "MEM_ALLOC" "CPU/MEM_USAGE"
      kubectl get pods -n "$SELECTED_NAMESPACE" -l "weblogic.domainUID=$SELECTED_DOMAIN_UID" -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' 2>/dev/null | sort -u |
      while read -r node; do
        [ -n "$node" ] || continue
        cpu_cap="$(kubectl get node "$node" -o jsonpath='{.status.capacity.cpu}' 2>/dev/null)"
        cpu_alloc="$(kubectl get node "$node" -o jsonpath='{.status.allocatable.cpu}' 2>/dev/null)"
        mem_cap="$(kubectl get node "$node" -o jsonpath='{.status.capacity.memory}' 2>/dev/null)"
        mem_alloc="$(kubectl get node "$node" -o jsonpath='{.status.allocatable.memory}' 2>/dev/null)"
        node_usage="$(kubectl top node "$node" 2>/dev/null | awk 'NR==2 {print $2"/"$4}')"
        [ -n "$node_usage" ] || node_usage="N/A"
        printf '%-32s %-12s %-12s %-16s %-16s %-18s\n' "$node" "${cpu_cap:-N/A}" "${cpu_alloc:-N/A}" "${mem_cap:-N/A}" "${mem_alloc:-N/A}" "$node_usage"
      done

      printf '\nAllocated resource summary from node describe:\n'
      kubectl get pods -n "$SELECTED_NAMESPACE" -l "weblogic.domainUID=$SELECTED_DOMAIN_UID" -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' 2>/dev/null | sort -u |
      while read -r node; do
        [ -n "$node" ] || continue
        printf '\n--- Node: %s ---\n' "$node"
        kubectl describe node "$node" 2>/dev/null | sed -n '/Allocated resources:/,/Events:/p' | sed '/Events:/,$d'
      done
    fi
  )"
  display_and_maybe_save "pod-resources" "Pod Resource Requests, Limits, and Usage" "$output"
}

op_probe_summary() {
  local output scope selected_pod title
  printf '\nProbe summary scope:\n'
  printf '  1) All WebLogic pods in this domain\n'
  printf '  2) One selected WebLogic pod\n'
  printf 'Enter choice [1-2, default 1]: '
  read -r scope || scope=""
  case "${scope:-1}" in
    2)
      selected_pod="$(choose_domain_pod "Select WebLogic pod for probe summary:")" || return 0
      title="Liveness and Readiness Probe Summary: $selected_pod"
      ;;
    *)
      selected_pod=""
      title="Liveness and Readiness Probe Summary"
      ;;
  esac

  output="$(
    if command -v jq >/dev/null 2>&1; then
      printf 'Probe status interpretation:\n'
      printf '  - Kubernetes does not store a timestamp for every successful probe.\n'
      printf '  - If PodReady/ContainerReady are true and no recent Unhealthy probe events exist, probes are currently inferred healthy.\n'
      printf '  - Recent Unhealthy/Killing/BackOff events below indicate probe failures or restart impact.\n\n'

      kubectl get pods -n "$SELECTED_NAMESPACE" -l "weblogic.domainUID=$SELECTED_DOMAIN_UID" -o json 2>/dev/null |
        jq -r --arg selected_pod "$selected_pod" '
          def probe_detail($p):
            if $p == null then
              "not configured"
            else
              (
                if $p.httpGet then
                  "type=httpGet path=" + (($p.httpGet.path // "/")|tostring) + " port=" + (($p.httpGet.port // "")|tostring)
                elif $p.tcpSocket then
                  "type=tcpSocket port=" + (($p.tcpSocket.port // "")|tostring)
                elif $p.exec then
                  "type=exec command=\"" + (($p.exec.command // []) | join(" ")) + "\""
                else
                  "type=other"
                end
              )
              + " initialDelaySeconds=" + (($p.initialDelaySeconds // 0)|tostring)
              + " periodSeconds=" + (($p.periodSeconds // 10)|tostring)
              + " timeoutSeconds=" + (($p.timeoutSeconds // 1)|tostring)
              + " successThreshold=" + (($p.successThreshold // 1)|tostring)
              + " failureThreshold=" + (($p.failureThreshold // 3)|tostring)
            end;
          .items[] as $pod
          | select(($selected_pod // "") == "" or $pod.metadata.name == $selected_pod)
          | "================================================================================",
            ("Pod: " + $pod.metadata.name),
            ("Phase: " + ($pod.status.phase // "N/A")),
            ("PodReady: " + (((($pod.status.conditions // [])[]? | select(.type == "Ready") | .status) // "Unknown")|tostring)),
            (
              $pod.spec.containers[] as $c
              | ($pod.status.containerStatuses // [])[]? as $s
              | select($s.name == $c.name)
              | "--------------------------------------------------------------------------------",
                ("Container: " + $c.name),
                ("ContainerReady: " + (($s.ready // false)|tostring)),
                ("RestartCount: " + (($s.restartCount // 0)|tostring)),
                ("State: " + (if $s.state.running then "running since " + ($s.state.running.startedAt // "unknown")
                              elif $s.state.waiting then "waiting reason=" + ($s.state.waiting.reason // "unknown") + " message=" + ($s.state.waiting.message // "")
                              elif $s.state.terminated then "terminated reason=" + ($s.state.terminated.reason // "unknown") + " exitCode=" + (($s.state.terminated.exitCode // "")|tostring)
                              else "unknown" end)),
                ("LastState: " + (if $s.lastState.terminated then "terminated reason=" + ($s.lastState.terminated.reason // "unknown") + " exitCode=" + (($s.lastState.terminated.exitCode // "")|tostring) + " finishedAt=" + ($s.lastState.terminated.finishedAt // "")
                                  elif $s.lastState.waiting then "waiting reason=" + ($s.lastState.waiting.reason // "unknown")
                                  else "none" end)),
                ("LivenessProbe: " + probe_detail($c.livenessProbe)),
                ("ReadinessProbe: " + probe_detail($c.readinessProbe)),
                ("StartupProbe: " + probe_detail($c.startupProbe))
            ),
            ""
        '

      printf '\nRecent probe-related events by pod:\n'
      if [ -n "$selected_pod" ]; then
        probe_pods="$selected_pod"
      else
        probe_pods="$(domain_pod_names)"
      fi
      for pod in $probe_pods; do
        printf '\n--------------------------------------------------------------------------------\n'
        printf 'Events for pod: %s\n' "$pod"
        probe_events="$(kubectl get events -n "$SELECTED_NAMESPACE" --field-selector "involvedObject.name=$pod" --sort-by='.metadata.creationTimestamp' 2>/dev/null | grep -Ei 'probe|Unhealthy|Killing|BackOff|Started|Readiness|Liveness' | tail -n "$EVENT_LIMIT" || true)"
        if [ -n "$probe_events" ]; then
          printf '%s\n' "$probe_events"
        else
          printf 'No recent probe-related events found. If PodReady and ContainerReady are true, probes are currently inferred healthy.\n'
        fi
      done
    else
      printf 'jq is required for detailed probe JSON parsing. Showing describe probe-related lines instead.\n\n'
      if [ -n "$selected_pod" ]; then
        probe_pods="$selected_pod"
      else
        probe_pods="$(domain_pod_names)"
      fi
      for pod in $probe_pods; do
        printf '\n--- %s ---\n' "$pod"
        kubectl describe pod "$pod" -n "$SELECTED_NAMESPACE" 2>/dev/null | grep -Ei 'Liveness|Readiness|Startup|Probe|Unhealthy' || true
      done
    fi
  )"
  display_and_maybe_save "probe-summary${selected_pod:+-$(sanitize_name "$selected_pod")}" "$title" "$output"
}

op_events() {
  local output ops
  ops="$(operator_pods)"
  output="$(
    printf 'Recent namespace events for %s, newest last:\n\n' "$SELECTED_NAMESPACE"
    kubectl get events -n "$SELECTED_NAMESPACE" --sort-by='.metadata.creationTimestamp' 2>&1 | tail -n "$EVENT_LIMIT"
    printf '\n\nEvents for WebLogic domain object %s:\n\n' "$SELECTED_DOMAIN_RESOURCE"
    kubectl get events -n "$SELECTED_NAMESPACE" --field-selector "involvedObject.name=$SELECTED_DOMAIN_RESOURCE" --sort-by='.metadata.creationTimestamp' 2>&1 | tail -n "$EVENT_LIMIT"
    printf '\n\nWKO-created domain events for domain UID %s:\n\n' "$SELECTED_DOMAIN_UID"
    kubectl get events -n "$SELECTED_NAMESPACE" --selector="weblogic.domainUID=$SELECTED_DOMAIN_UID,weblogic.createdByOperator=true" --sort-by='.metadata.creationTimestamp' 2>&1 | tail -n "$EVENT_LIMIT"
    printf '\n\nEvents for domain pods:\n'
    for pod in $(domain_pod_names); do
      printf '\n--- %s ---\n' "$pod"
      kubectl get events -n "$SELECTED_NAMESPACE" --field-selector "involvedObject.name=$pod" --sort-by='.metadata.creationTimestamp' 2>&1 | tail -n "$EVENT_LIMIT"
    done
    if [ -n "$ops" ]; then
      printf '\n\nOperator/webhook namespace events:\n'
      printf '%s\n' "$ops" | awk '{print $1}' | sort -u | while read -r opns; do
        [ -n "$opns" ] || continue
        printf '\n--- Operator namespace: %s ---\n' "$opns"
        kubectl get events -n "$opns" --sort-by='.metadata.creationTimestamp' 2>&1 | tail -n "$EVENT_LIMIT"
      done
    fi
  )"
  display_and_maybe_save "events" "Recent Events" "$output"
}

op_describe_pods() {
  local output
  output="$(
    for pod in $(domain_pod_names); do
      printf '\n================================================================================\n'
      printf 'kubectl describe pod %s -n %s\n' "$pod" "$SELECTED_NAMESPACE"
      printf '================================================================================\n'
      kubectl describe pod "$pod" -n "$SELECTED_NAMESPACE" 2>&1
    done
  )"
  display_and_maybe_save "describe-pods" "Describe WebLogic Server Pods" "$output"
}

op_pod_logs() {
  local pods pod output selected scope full_command save_key title
  pods="$(domain_pod_names)"
  if [ -z "$pods" ]; then
    display_and_maybe_save "pod-logs" "WebLogic Server Pod Logs" "No pods found for domain UID $SELECTED_DOMAIN_UID."
    return 0
  fi

  printf '\nPod log scope:\n'
  printf '   1) One selected WebLogic pod\n'
  printf '   2) All WebLogic pods in this domain\n'
  printf 'Enter choice [1-2, default 1]: '
  read -r scope || scope=""
  scope="${scope:-1}"

  if [ "$scope" = "2" ]; then
    selected="ALL_DOMAIN_PODS"
    save_key="pod-logs-all-domain-pods"
    title="WebLogic Server Pod Logs: all domain pods"
  else
    selected="$(choose_domain_pod "Select WebLogic pod for logs:")" || return 0
    save_key="pod-logs-$(sanitize_name "$selected")"
    title="WebLogic Server Pod Logs: $selected"
  fi

  output="$(
    if [ "$selected" = "ALL_DOMAIN_PODS" ]; then
      for pod in $pods; do
        printf '\n================================================================================\n'
        printf 'Logs for %s/%s, last %s lines\n' "$SELECTED_NAMESPACE" "$pod" "$LOG_TAIL_LINES"
        printf '================================================================================\n'
        kubectl logs -n "$SELECTED_NAMESPACE" "$pod" --tail="$LOG_TAIL_LINES" 2>&1
      done
    else
      kubectl logs -n "$SELECTED_NAMESPACE" "$selected" --tail="$LOG_TAIL_LINES" 2>&1
    fi
  )"
  if [ "$selected" = "ALL_DOMAIN_PODS" ]; then
    full_command="for pod in $pods; do printf '\\n================================================================================\\n'; printf 'Complete logs for %s/%s\\n' '$SELECTED_NAMESPACE' \"\$pod\"; printf '================================================================================\\n'; kubectl logs -n '$SELECTED_NAMESPACE' \"\$pod\"; done"
  else
    full_command="kubectl logs -n '$SELECTED_NAMESPACE' '$selected'"
  fi
  display_tail_and_save_full_logs "$save_key" "$title" "$output" "$full_command"
}

build_operator_summary() {
  local ops="$1"
  local ns pod operator_status webhook_status pod_ready ready_values managed_namespaces warning_count error_count introspector_summary

  printf 'Summary:\n'
  if [ -z "$ops" ]; then
    printf '  Operator deployment: Not detected\n'
    printf '  Webhook deployment: Not detected\n'
    printf '  Recent warnings: N/A\n'
    printf '  Critical errors: N/A\n'
    return 0
  fi

  operator_status="Not detected"
  webhook_status="Not detected"
  while read -r ns pod; do
    [ -n "$pod" ] || continue
    pod_ready="NotReady"
    ready_values="$(kubectl get pod "$pod" -n "$ns" -o jsonpath='{.status.containerStatuses[*].ready}' 2>/dev/null || true)"
    if [ -n "$ready_values" ] && ! printf '%s\n' "$ready_values" | grep -q 'false'; then
      pod_ready="Ready"
    fi
    case "$pod" in
      *webhook*)
        if [ "$pod_ready" = "NotReady" ] || [ "$webhook_status" = "Not detected" ]; then
          webhook_status="$pod_ready"
        fi
        ;;
      *)
        if [ "$pod_ready" = "NotReady" ] || [ "$operator_status" = "Not detected" ]; then
          operator_status="$pod_ready"
        fi
        ;;
    esac
  done < <(printf '%s\n' "$ops")
  printf '  Operator deployment: %s\n' "$operator_status"
  printf '  Webhook deployment: %s\n' "$webhook_status"

  printf '  Operator namespace(s): '
  printf '%s\n' "$ops" | cut -f1 | sort -u | paste -sd ',' - | sed 's/,/, /g'

  managed_namespaces="$(
    kubectl get domains -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null |
      sort -u |
      paste -sd ',' - |
      sed 's/,/, /g'
  )" || managed_namespaces=""
  [ -n "$managed_namespaces" ] || managed_namespaces="N/A"
  printf '  Managed namespace(s): %s\n' "$managed_namespaces"
  introspector_summary="$(domain_introspector_summary "$managed_namespaces")"
  printf '  Introspector: %s\n' "$introspector_summary"

  warning_count="$(
    printf '%s\n' "$ops" | cut -f1 | sort -u | while read -r ns; do
      [ -n "$ns" ] || continue
      kubectl get events -n "$ns" --field-selector type=Warning --sort-by='.metadata.creationTimestamp' 2>/dev/null
    done | awk 'NR > 1 {count++} END{print count+0}'
  )" || warning_count=0
  if [ "${warning_count:-0}" -gt 0 ] 2>/dev/null; then
    printf '  Recent warnings: %s warning event(s) found in operator namespace(s)\n' "${warning_count:-0}"
  else
    printf '  Recent warnings: none detected in operator namespace events\n'
  fi

  error_count="$(
    printf '%s\n' "$ops" | while read -r ns pod; do
      [ -n "$pod" ] || continue
      kubectl logs -n "$ns" "$pod" --tail="$LOG_TAIL_LINES" 2>/dev/null
    done | grep -Eic 'error|exception|failed|fatal' || true
  )" || error_count=0
  if [ "${error_count:-0}" -gt 0 ] 2>/dev/null; then
    printf '  Critical errors: review logs, %s error-like line(s) detected\n' "${error_count:-0}"
  else
    printf '  Critical errors: none detected in tailed operator/webhook logs\n'
  fi
}

domain_introspector_summary() {
  local managed_namespaces="${1:-}"
  local target_ns target_domain target_uid domain_rows row_count names name job_status pod_phase recent_event

  target_ns="$SELECTED_NAMESPACE"
  target_domain="$SELECTED_DOMAIN_RESOURCE"
  target_uid="$SELECTED_DOMAIN_UID"

  if [ "$target_domain" = "operator-diagnostics" ]; then
    domain_rows="$(kubectl get domains -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.spec.domainUID}{"\n"}{end}' 2>/dev/null || true)"
    row_count="$(printf '%s\n' "$domain_rows" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
    if [ "$row_count" = "1" ]; then
      target_ns="$(printf '%s\n' "$domain_rows" | sed -n '1s/[[:space:]].*$//p')"
      target_domain="$(printf '%s\n' "$domain_rows" | sed -n '1s/^[^[:space:]]*[[:space:]]*//; s/[[:space:]].*$//p')"
      target_uid="$(printf '%s\n' "$domain_rows" | sed -n '1s/^.*[[:space:]]//p')"
      [ -n "$target_uid" ] || target_uid="$target_domain"
    elif [ -n "$managed_namespaces" ] && [ "$managed_namespaces" != "N/A" ]; then
      printf 'N/A from operator namespace; managed namespace(s): %s' "$managed_namespaces"
      return 0
    else
      printf 'N/A in operator namespace; select a WebLogic domain namespace for domain introspection status'
      return 0
    fi
  fi

  names="$(
    {
      kubectl get jobs -n "$target_ns" -l "weblogic.domainUID=$target_uid" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -Ei 'introspect|introspector' || true
      kubectl get pods -n "$target_ns" -l "weblogic.domainUID=$target_uid" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -Ei 'introspect|introspector' || true
    } | sort -u
  )"

  for name in $names; do
    if kubectl get job "$name" -n "$target_ns" >/dev/null 2>&1; then
      job_status="$(kubectl get job "$name" -n "$target_ns" -o jsonpath='active={.status.active} succeeded={.status.succeeded} failed={.status.failed}' 2>/dev/null || true)"
      printf '%s/%s job %s (%s)' "$target_ns" "$target_domain" "$name" "$job_status"
      return 0
    fi
    if kubectl get pod "$name" -n "$target_ns" >/dev/null 2>&1; then
      pod_phase="$(kubectl get pod "$name" -n "$target_ns" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
      printf '%s/%s pod %s (%s)' "$target_ns" "$target_domain" "$name" "${pod_phase:-phase unknown}"
      return 0
    fi
  done

  recent_event="$(
    kubectl get events -n "$target_ns" --selector="weblogic.domainUID=$target_uid,weblogic.createdByOperator=true" --sort-by='.metadata.creationTimestamp' 2>/dev/null |
      grep -Ei 'introspect|introspection' |
      tail -n 1 || true
  )"
  if printf '%s\n' "$recent_event" | grep -Eiq 'complete|completed|succeed|succeeded|success'; then
    printf '%s/%s not currently running; recent event indicates completion' "$target_ns" "$target_domain"
  elif [ -n "$recent_event" ]; then
    printf '%s/%s not currently running; recent introspection event found' "$target_ns" "$target_domain"
  else
    printf '%s/%s not currently running; this can be normal after introspection completes' "$target_ns" "$target_domain"
  fi
}

op_operator_info_logs() {
  local output ops ns pod manual_ns answer include_logs full_command
  local summary
  ops="$(operator_pods)"
  if [ -z "$ops" ]; then
    ops="$(kubectl get pods --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\n"}{end}' 2>/dev/null | awk '/weblogic-operator/')"
  fi
  if [ -z "$ops" ]; then
    printf 'Unable to auto-detect WKO operator pods.\n'
    printf 'Enter WKO operator namespace to inspect, or press Enter to cancel: '
    read -r manual_ns || manual_ns=""
    if [ -z "$manual_ns" ]; then
      display_and_maybe_save "operator-info-logs" "WebLogic Operator / Webhook Pod Logs" "Operator namespace not supplied; operation cancelled."
      return 0
    fi
    ops="$(kubectl get pods -n "$manual_ns" -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\n"}{end}' 2>/dev/null | awk '/weblogic-operator/')"
  fi

  include_logs=1
  summary="$(build_operator_summary "$ops")"

  output="$(
    printf 'Operator pods:\n'
    if [ -n "$ops" ]; then
      printf '%-25s %-45s\n' "NAMESPACE" "POD"
      printf '%s\n' "$ops" | while read -r ns pod; do
        [ -n "$pod" ] || continue
        printf '%-25s %-45s\n' "$ns" "$pod"
      done
      printf '\nDetected pods include operator and conversion webhook pods when present.\n'
      printf '\nOperator/webhook deployments and configmaps:\n'
      printf '%s\n' "$ops" | cut -f1 | sort -u | while read -r ns; do
        [ -n "$ns" ] || continue
        printf '\n================================================================================\n'
        printf 'Namespace: %s\n' "$ns"
        printf '================================================================================\n'
        printf '\nDeployments with weblogic.operatorName label:\n'
        kubectl get deployments -n "$ns" -l 'weblogic.operatorName' -o wide 2>&1
        printf '\nDeployments with weblogic.webhookName label:\n'
        kubectl get deployments -n "$ns" -l 'weblogic.webhookName' -o wide 2>&1
        printf '\nOperator/webhook configmaps:\n'
        kubectl get configmap -n "$ns" 2>&1 | grep -Ei 'operator|webhook|weblogic' || true
        printf '\nOperator namespace events:\n'
        kubectl get events -n "$ns" --sort-by='.metadata.creationTimestamp' 2>&1 | tail -n "$EVENT_LIMIT"
      done
      printf '\nOperator/webhook pod descriptions:\n'
      printf '%s\n' "$ops" | while IFS="$(printf '\t')" read -r ns pod; do
        [ -n "$pod" ] || continue
        printf '\n================================================================================\n'
        printf 'Describe pod %s/%s\n' "$ns" "$pod"
        printf '================================================================================\n'
        kubectl describe pod "$pod" -n "$ns" 2>&1
      done
      if [ "$include_logs" -eq 1 ]; then
        printf '\nOperator/webhook logs, last %s lines each:\n' "$LOG_TAIL_LINES"
        printf '%s\n' "$ops" | while IFS="$(printf '\t')" read -r ns pod; do
          [ -n "$pod" ] || continue
          printf '\n================================================================================\n'
          printf 'Logs for %s/%s\n' "$ns" "$pod"
          printf '================================================================================\n'
          kubectl logs -n "$ns" "$pod" --tail="$LOG_TAIL_LINES" 2>&1
        done
      else
        printf '\nLog capture skipped by user.\n'
      fi
    else
      printf 'No operator or webhook pods found.\n'
    fi
    printf '\n================================================================================\n'
    printf 'Operator Diagnostic Summary\n'
    printf '================================================================================\n'
    printf '%s\n' "$summary"
  )"
  if [ "$include_logs" -eq 1 ] 2>/dev/null && [ -n "$ops" ]; then
    full_command="printf '%s\n' '$ops' | while IFS=\"$(printf '\t')\" read -r ns pod; do [ -n \"\$pod\" ] || continue; printf '\\n================================================================================\\n'; printf 'Complete logs for %s/%s\\n' \"\$ns\" \"\$pod\"; printf '================================================================================\\n'; kubectl logs -n \"\$ns\" \"\$pod\"; done"
    display_tail_and_save_full_logs "operator-info-logs" "WebLogic Operator / Webhook Pod Logs" "$output" "$full_command"
  else
    display_and_maybe_save "operator-info-logs" "WebLogic Operator / Webhook Pod Logs" "$output"
  fi
}

op_services_network() {
  local output
  output="$(
    printf 'Services in namespace %s:\n\n' "$SELECTED_NAMESPACE"
    kubectl get services -n "$SELECTED_NAMESPACE" -o wide 2>&1
    if kubectl get endpointslices.discovery.k8s.io -n "$SELECTED_NAMESPACE" -o wide >/dev/null 2>&1; then
      printf '\nEndpointSlices in namespace %s:\n\n' "$SELECTED_NAMESPACE"
      kubectl get endpointslices.discovery.k8s.io -n "$SELECTED_NAMESPACE" -o wide 2>&1
    else
      printf '\nEndpoints in namespace %s (legacy fallback):\n\n' "$SELECTED_NAMESPACE"
      kubectl get endpoints -n "$SELECTED_NAMESPACE" -o wide 2>&1 | grep -v '^Warning: v1 Endpoints is deprecated' || true
    fi
    printf '\nIngresses in namespace %s:\n\n' "$SELECTED_NAMESPACE"
    kubectl get ingress -n "$SELECTED_NAMESPACE" -o wide 2>&1
    printf '\nNetworkPolicies in namespace %s:\n\n' "$SELECTED_NAMESPACE"
    kubectl get networkpolicy -n "$SELECTED_NAMESPACE" -o wide 2>&1
  )"
  display_and_maybe_save "services-network" "Services, Endpoints, Ingress, and Network Policies" "$output"
}

op_storage() {
  local output
  output="$(
    printf 'PVCs in namespace %s:\n\n' "$SELECTED_NAMESPACE"
    kubectl get pvc -n "$SELECTED_NAMESPACE" -o wide 2>&1
    printf '\nPVs visible to current user:\n\n'
    kubectl get pv -o wide 2>&1
    printf '\nStorageClasses visible to current user:\n\n'
    kubectl get storageclass -o wide 2>&1
  )"
  display_and_maybe_save "storage" "Persistent Storage Summary (PVCs, PVs, StorageClasses)" "$output"
}

op_cluster_overview() {
  local output
  output="$(
    printf 'Current context:\n'
    kubectl config current-context 2>&1
    printf '\nCluster info:\n'
    kubectl cluster-info 2>&1
    printf '\nVersion:\n'
    kubectl version 2>&1
    printf '\nNodes:\n'
    kubectl get nodes -o wide 2>&1
    printf '\nNode metrics:\n'
    kubectl top nodes 2>&1
  )"
  display_and_maybe_save "cluster-overview" "Kubernetes Cluster Overview" "$output"
}

op_java_processes() {
  local output selected_pod
  selected_pod="$(choose_domain_pod "Select WebLogic pod for Java process listing:")" || return 0
  output="$(
    printf '\n================================================================================\n'
    printf 'Java processes in %s/%s\n' "$SELECTED_NAMESPACE" "$selected_pod"
    printf '================================================================================\n'
    kubectl exec -n "$SELECTED_NAMESPACE" "$selected_pod" -- sh -c "$(java_process_discovery_script)" 2>&1
  )"
  display_and_maybe_save "java-processes-$(sanitize_name "$selected_pod")" "Read-only Java Process Listing: $selected_pod" "$output"
}

op_opatch_inventory() {
  local output selected_pod
  selected_pod="$(choose_domain_pod "Select WebLogic pod for OPatch inventory:")" || return 0
  output="$(
    printf '\n================================================================================\n'
    printf 'OPatch inventory in %s/%s\n' "$SELECTED_NAMESPACE" "$selected_pod"
    printf '================================================================================\n'
    kubectl exec -n "$SELECTED_NAMESPACE" "$selected_pod" -- sh -c "$(opatch_inventory_script)" 2>&1
  )"
  display_and_maybe_save "opatch-inventory-$(sanitize_name "$selected_pod")" "Read-only OPatch Inventory: $selected_pod" "$output"
}

op_exec_into_pod() {
  local pod
  pod="$(choose_any_pod_in_namespace)" || return 0
  printf '\n================================================================================\n'
  printf 'Interactive shell into %s/%s\n' "$SELECTED_NAMESPACE" "$pod"
  printf '================================================================================\n'
  printf 'Type exit or press Ctrl-D inside the pod shell to return to this menu.\n'
  printf 'Trying bash first, then sh.\n\n'
  kubectl exec -it -n "$SELECTED_NAMESPACE" "$pod" -- bash 2>/dev/null || \
    kubectl exec -it -n "$SELECTED_NAMESPACE" "$pod" -- sh
  printf '\nReturned from pod shell.\n'
}

op_open_wlst() {
  local pod wlst_path answer remote_cmd rc container_names container_arg
  pod="$(choose_domain_pod "Select WebLogic pod for WLST:")" || return 0
  printf '\nWLST is interactive. This script only opens WLST; commands typed inside WLST are controlled by you.\n'
  printf 'Default WLST path: %s\n' "$WLST_PATH_DEFAULT"
  printf 'Use this path? (Y/n): '
  read -r answer || answer=""
  case "$answer" in
    n|N|no|NO|No)
      printf 'Enter WLST path inside the container: '
      read -r wlst_path || wlst_path=""
      wlst_path="${wlst_path:-$WLST_PATH_DEFAULT}"
      ;;
    *) wlst_path="$WLST_PATH_DEFAULT" ;;
  esac

  printf '\n================================================================================\n'
  printf 'Opening WLST in %s/%s\n' "$SELECTED_NAMESPACE" "$pod"
  printf '================================================================================\n'
  printf 'When finished, type exit() or press Ctrl-D to return to this menu.\n\n'

  container_names="$(kubectl get pod "$pod" -n "$SELECTED_NAMESPACE" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null || true)"
  container_arg=""
  if printf '%s\n' "$container_names" | grep -qw 'weblogic-server'; then
    container_arg="-c weblogic-server"
    printf 'Using container: weblogic-server\n'
  fi
  printf 'Using WLST memory default: USER_MEM_ARGS="-Xms64m -Xmx256m" unless already set in the container.\n\n'

  remote_cmd="export USER_MEM_ARGS=\"\${USER_MEM_ARGS:--Xms64m -Xmx256m}\"; exec \"$wlst_path\""
  if [ -n "$container_arg" ]; then
    # shellcheck disable=SC2086
    kubectl exec -it -n "$SELECTED_NAMESPACE" "$pod" $container_arg -- sh -lc "$remote_cmd"
  else
    kubectl exec -it -n "$SELECTED_NAMESPACE" "$pod" -- sh -lc "$remote_cmd"
  fi
  rc=$?

  if [ "$rc" -eq 137 ]; then
    printf '\n%sWLST exited with code 137.%s\n' "$C_YELLOW" "$C_RESET"
    printf 'This usually means the WLST JVM was killed, commonly due to container memory pressure/OOM.\n'
    printf 'Check pod events, container last state, and memory limits before retrying.\n'
  elif [ "$rc" -ne 0 ]; then
    printf '\n%sWLST exited with code %s.%s\n' "$C_YELLOW" "$rc" "$C_RESET"
  fi

  printf '\nReturned from WLST.\n'
}

op_collect_jfr() {
  local pod pid duration answer remote_file local_file output
  pod="$(choose_domain_pod "Select WebLogic pod for JFR collection:")" || return 0
  pid="$(choose_java_process_in_pod "$pod")" || return 0

  printf 'JFR collection starts a short Java Flight Recorder recording in the selected JVM.\n'
  printf 'Duration in seconds [60]: '
  read -r duration || duration=""
  duration="${duration:-60}"
  case "$duration" in ''|*[!0-9]*) printf 'Invalid duration.\n'; return 0 ;; esac

  printf 'Proceed with JFR collection for PID %s in pod %s for %s seconds? (y/N): ' "$pid" "$pod" "$duration"
  read -r answer || answer=""
  case "$answer" in
    y|Y|yes|YES|Yes) ;;
    *) printf 'JFR collection cancelled.\n'; return 0 ;;
  esac

  init_report_dir_if_needed || return 0
  SAVE_COUNT=$((SAVE_COUNT + 1))
  remote_file="/tmp/wko_${SELECTED_DOMAIN_RESOURCE}_${pod}_${pid}_$(date '+%Y%m%d_%H%M%S').jfr"
  local_file="$REPORT_DIR/$(printf '%03d_%s_%s_jfr_%s_pid_%s.jfr' "$SAVE_COUNT" "$(sanitize_name "$SELECTED_NAMESPACE")" "$(sanitize_name "$SELECTED_DOMAIN_RESOURCE")" "$(sanitize_name "$pod")" "$pid")"

  output="$(
    printf 'Starting JFR in %s/%s for PID %s, duration %s seconds.\n' "$SELECTED_NAMESPACE" "$pod" "$pid" "$duration"
    kubectl exec -n "$SELECTED_NAMESPACE" "$pod" -- sh -c "jcmd $pid JFR.start name=wko_diagnostic settings=profile duration=${duration}s filename=$remote_file" 2>&1
    printf '\nWaiting %s seconds for recording to complete...\n' "$duration"
  )"
  printf '%s\n' "$output"
  sleep "$duration"
  printf 'Downloading JFR from pod path %s ...\n' "$remote_file"
  if kubectl exec -n "$SELECTED_NAMESPACE" "$pod" -- cat "$remote_file" > "$local_file" 2>/dev/null; then
    printf '[%s] %s - JFR recording for %s/%s PID %s\n' "$(now)" "$(basename "$local_file")" "$SELECTED_NAMESPACE" "$pod" "$pid" >> "$MANIFEST_FILE"
    printf 'Saved JFR: %s\n' "$local_file"
    printf 'Note: remote JFR file remains in the pod at %s; this script does not delete files from pods.\n' "$remote_file"
  else
    printf 'Failed to download JFR. The JVM may not diagnostic JFR or jcmd may be unavailable.\n'
  fi
}

op_collect_thread_dumps() {
  local pod pid count interval answer output i dump
  pod="$(choose_domain_pod "Select WebLogic pod for thread dump collection:")" || return 0
  pid="$(choose_java_process_in_pod "$pod")" || return 0

  printf 'Number of thread dumps [3]: '
  read -r count || count=""
  count="${count:-3}"
  case "$count" in ''|*[!0-9]*) printf 'Invalid count.\n'; return 0 ;; esac

  printf 'Interval between dumps in seconds [10]: '
  read -r interval || interval=""
  interval="${interval:-10}"
  case "$interval" in ''|*[!0-9]*) printf 'Invalid interval.\n'; return 0 ;; esac

  printf 'Collect %s thread dump(s) for PID %s in pod %s? (y/N): ' "$count" "$pid" "$pod"
  read -r answer || answer=""
  case "$answer" in
    y|Y|yes|YES|Yes) ;;
    *) printf 'Thread dump collection cancelled.\n'; return 0 ;;
  esac

  output=""
  i=1
  while [ "$i" -le "$count" ]; do
    printf 'Collecting thread dump %s of %s...\n' "$i" "$count"
    dump="$(
      printf '\n================================================================================\n'
      printf 'Thread dump %s of %s for %s/%s PID %s at %s\n' "$i" "$count" "$SELECTED_NAMESPACE" "$pod" "$pid" "$(now)"
      printf '================================================================================\n'
      kubectl exec -n "$SELECTED_NAMESPACE" "$pod" -- sh -c "if command -v jcmd >/dev/null 2>&1; then jcmd $pid Thread.print -l; elif command -v jstack >/dev/null 2>&1; then jstack -l $pid; else echo 'Neither jcmd nor jstack is available in the container'; exit 1; fi" 2>&1
    )"
    output="${output}
${dump}"
    if [ "$i" -lt "$count" ]; then
      sleep "$interval"
    fi
    i=$((i + 1))
  done

  display_and_maybe_save "thread-dumps-$(sanitize_name "$pod")-pid-$pid" "Thread Dumps: $pod PID $pid" "$output"
}

op_collect_diagnostic_archive() {
  local answer pods ops pod ns opod output pid duration remote_file local_file count interval i dump selected_pod name introspector_jobs introspector_pods job_pods cm
  printf '\nThis will collect standard diagnostics and complete logs into separate files.\n'
  printf 'At the end, it will create one archive file for diagnostic review when zip or tar is available.\n'
  printf 'It will not collect JFR or thread dumps unless you opt in when prompted.\n'

  init_report_dir_if_needed || return 0
  pods="$(domain_pod_names)"

  if [ -n "$SELECTED_OPERATOR_NAMESPACE" ]; then
    output="$(
      printf 'WKID diagnostic archive selection context\n'
      printf 'Initial operator namespace selected: %s\n' "$SELECTED_OPERATOR_NAMESPACE"
      printf 'Domain namespace used for archive: %s\n' "$SELECTED_NAMESPACE"
      printf 'Domain resource used for archive: %s\n' "$SELECTED_DOMAIN_RESOURCE"
      printf 'Domain UID used for archive: %s\n' "$SELECTED_DOMAIN_UID"
      printf '\nNote: WKID uses the selected domain context for domain, introspector, pod, and service diagnostics.\n'
      printf 'Detected operator/webhook diagnostics are collected separately in the same archive when RBAC permits.\n'
    )"
    save_archive_text "archive-selection-context" "Archive - Selection Context" "$output"
  fi

  output="$(
    print_domain_status_summary
    printf '\nDomain resource overview:\n'
    kubectl get domain "$SELECTED_DOMAIN_RESOURCE" -n "$SELECTED_NAMESPACE" -o wide 2>&1
    printf '\nDescribe domain/%s:\n' "$SELECTED_DOMAIN_RESOURCE"
    kubectl describe domain "$SELECTED_DOMAIN_RESOURCE" -n "$SELECTED_NAMESPACE" 2>&1
    printf '\nDomain YAML:\n'
    kubectl get domain "$SELECTED_DOMAIN_RESOURCE" -n "$SELECTED_NAMESPACE" -o yaml 2>&1
  )"
  save_archive_text "archive-wko-domain-status" "Archive - WKO Domain Status and YAML" "$output"

  output="$(print_cluster_resource_diagnostics)"
  save_archive_text "archive-cluster-resources" "Archive - WKO Cluster Resource Diagnostics" "$output"

  output="$(print_introspector_diagnostics)"
  save_archive_text "archive-introspector" "Archive - Introspector Diagnostics" "$output"

  introspector_pods="$(domain_introspector_pod_names)"
  introspector_jobs="$(domain_introspector_job_names)"
  for name in $introspector_jobs; do
    output="$(kubectl get job "$name" -n "$SELECTED_NAMESPACE" -o yaml 2>&1)"
    save_archive_text "archive-introspector-job-yaml-$(sanitize_name "$name")" "Archive - Introspector Job YAML - $name" "$output"

    output="$(kubectl logs job/"$name" -n "$SELECTED_NAMESPACE" 2>&1)"
    save_archive_text "archive-introspector-job-logs-$(sanitize_name "$name")" "Archive - Complete Introspector Job Logs - $name" "$output"

    job_pods="$(introspector_pods_for_job "$name")"
    for pod in $job_pods; do
      introspector_pods="$(printf '%s\n%s\n' "$introspector_pods" "$pod" | sed '/^[[:space:]]*$/d' | sort -u)"
    done
  done

  for pod in $introspector_pods; do
    output="$(print_pod_yaml_and_image_identity "$SELECTED_NAMESPACE" "$pod")"
    save_archive_text "archive-introspector-pod-yaml-$(sanitize_name "$pod")" "Archive - Introspector Pod YAML and Image Identity - $pod" "$output"

    output="$(kubectl logs "$pod" -n "$SELECTED_NAMESPACE" --all-containers=true 2>&1)"
    save_archive_text "archive-introspector-pod-current-logs-$(sanitize_name "$pod")" "Archive - Complete Introspector Pod Current Logs - $pod" "$output"

    output="$(kubectl logs "$pod" -n "$SELECTED_NAMESPACE" --all-containers=true --previous 2>&1 || true)"
    save_archive_text "archive-introspector-pod-previous-logs-$(sanitize_name "$pod")" "Archive - Introspector Pod Previous Logs - $pod" "$output"

    output="$(kubectl exec -n "$SELECTED_NAMESPACE" "$pod" -- sh -c "$(introspector_artifact_script)" 2>&1 || true)"
    save_archive_text "archive-introspector-artifacts-$(sanitize_name "$pod")" "Archive - Introspector WDT and Temporary Artifacts - $pod" "$output"
  done

  output="$(print_weblogic_loghome_summary)"
  save_archive_text "archive-weblogic-loghome-summary" "Archive - WebLogic Log Home Summary" "$output"

  output="$(kubectl get pods -n "$SELECTED_NAMESPACE" -l "weblogic.domainUID=$SELECTED_DOMAIN_UID" -o wide 2>&1)"
  save_archive_text "archive-pod-summary" "Archive - WebLogic Pod Summary" "$output"

  output="$(
    printf 'Model ConfigMap details referenced by Domain %s/%s\n' "$SELECTED_NAMESPACE" "$SELECTED_DOMAIN_RESOURCE"
    printf 'Note: ConfigMaps may contain environment configuration. Secrets are not collected by WKID.\n'
    for cm in $(domain_model_configmap_names); do
      printf '\n================================================================================\n'
      printf 'Model ConfigMap: %s\n' "$cm"
      printf '================================================================================\n'
      printf '\nMetadata and keys:\n'
      kubectl get configmap "$cm" -n "$SELECTED_NAMESPACE" -o jsonpath='name={.metadata.name} created={.metadata.creationTimestamp}{"\n"}' 2>&1
      printf 'keys='
      kubectl get configmap "$cm" -n "$SELECTED_NAMESPACE" -o yaml 2>/dev/null | sed -n '/^data:/,/^[^[:space:]]/p' | sed -n 's/^  \([^:]*\):.*/\1/p' | paste -sd ' ' -
      printf '\n'
      printf '\nFull ConfigMap YAML:\n'
      kubectl get configmap "$cm" -n "$SELECTED_NAMESPACE" -o yaml 2>&1
    done
  )"
  save_archive_text "archive-model-configmaps" "Archive - Model ConfigMaps Referenced by Domain" "$output"

  output="$(
    printf 'Pod resources:\n'
    for pod in $pods; do
      printf '\n--- %s ---\n' "$pod"
      kubectl get pod "$pod" -n "$SELECTED_NAMESPACE" -o jsonpath='phase={.status.phase} node={.spec.nodeName} cpuReq={.spec.containers[*].resources.requests.cpu} cpuLim={.spec.containers[*].resources.limits.cpu} memReq={.spec.containers[*].resources.requests.memory} memLim={.spec.containers[*].resources.limits.memory}{"\n"}' 2>&1
      kubectl top pod "$pod" -n "$SELECTED_NAMESPACE" 2>&1 || true
    done
    printf '\nNode context:\n'
    kubectl get pods -n "$SELECTED_NAMESPACE" -l "weblogic.domainUID=$SELECTED_DOMAIN_UID" -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' 2>/dev/null | sort -u |
    while read -r node; do
      [ -n "$node" ] || continue
      printf '\n--- Node: %s ---\n' "$node"
      kubectl get node "$node" -o wide 2>&1
      kubectl top node "$node" 2>&1 || true
      kubectl describe node "$node" 2>/dev/null | sed -n '/Allocated resources:/,/Events:/p' | sed '/Events:/,$d'
    done
  )"
  save_archive_text "archive-resources" "Archive - Pod and Node Resource Context" "$output"

  output="$(
    printf 'Events for namespace/domain/pods:\n'
    kubectl get events -n "$SELECTED_NAMESPACE" --sort-by='.metadata.creationTimestamp' 2>&1
    printf '\nDomain events:\n'
    kubectl get events -n "$SELECTED_NAMESPACE" --field-selector "involvedObject.name=$SELECTED_DOMAIN_RESOURCE" --sort-by='.metadata.creationTimestamp' 2>&1
    printf '\nWKO-created domain events:\n'
    kubectl get events -n "$SELECTED_NAMESPACE" --selector="weblogic.domainUID=$SELECTED_DOMAIN_UID,weblogic.createdByOperator=true" --sort-by='.metadata.creationTimestamp' 2>&1
    for pod in $pods; do
      printf '\n--- Pod events: %s ---\n' "$pod"
      kubectl get events -n "$SELECTED_NAMESPACE" --field-selector "involvedObject.name=$pod" --sort-by='.metadata.creationTimestamp' 2>&1
    done
  )"
  save_archive_text "archive-events" "Archive - Events" "$output"

  output="$(
    for pod in $pods; do
      printf '\n================================================================================\n'
      printf 'Describe pod %s/%s\n' "$SELECTED_NAMESPACE" "$pod"
      printf '================================================================================\n'
      kubectl describe pod "$pod" -n "$SELECTED_NAMESPACE" 2>&1
    done
  )"
  save_archive_text "archive-describe-pods" "Archive - Describe WebLogic Server Pods" "$output"

  for pod in $pods; do
    output="$(print_pod_yaml_and_image_identity "$SELECTED_NAMESPACE" "$pod")"
    save_archive_text "archive-pod-yaml-$(sanitize_name "$pod")" "Archive - Pod YAML and Image Identity - $pod" "$output"
  done

  output="$(
    printf 'Services:\n'
    kubectl get services -n "$SELECTED_NAMESPACE" -o wide 2>&1
    if kubectl get endpointslices.discovery.k8s.io -n "$SELECTED_NAMESPACE" -o wide >/dev/null 2>&1; then
      printf '\nEndpointSlices:\n'
      kubectl get endpointslices.discovery.k8s.io -n "$SELECTED_NAMESPACE" -o wide 2>&1
    else
      printf '\nEndpoints (legacy fallback):\n'
      kubectl get endpoints -n "$SELECTED_NAMESPACE" -o wide 2>&1 | grep -v '^Warning: v1 Endpoints is deprecated' || true
    fi
    printf '\nIngress:\n'
    kubectl get ingress -n "$SELECTED_NAMESPACE" -o wide 2>&1
    printf '\nNetworkPolicies:\n'
    kubectl get networkpolicy -n "$SELECTED_NAMESPACE" -o wide 2>&1
  )"
  save_archive_text "archive-network" "Archive - Services and Network" "$output"

  output="$(
    printf 'PVCs:\n'
    kubectl get pvc -n "$SELECTED_NAMESPACE" -o wide 2>&1
    printf '\nPVs:\n'
    kubectl get pv -o wide 2>&1
    printf '\nStorageClasses:\n'
    kubectl get storageclass -o wide 2>&1
  )"
  save_archive_text "archive-storage" "Archive - Storage" "$output"

  for pod in $pods; do
    output="$(kubectl logs -n "$SELECTED_NAMESPACE" "$pod" --all-containers=true 2>&1)"
    save_archive_text "archive-pod-logs-$(sanitize_name "$pod")" "Archive - Complete Pod Logs - $pod" "$output"

    output="$(kubectl logs -n "$SELECTED_NAMESPACE" "$pod" --all-containers=true --previous 2>&1 || true)"
    save_archive_text "archive-pod-previous-logs-$(sanitize_name "$pod")" "Archive - Previous Pod Logs - $pod" "$output"
  done

  ops="$(operator_pods)"
  if [ -z "$ops" ]; then
    ops="$(kubectl get pods --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\n"}{end}' 2>/dev/null | awk '/weblogic-operator/')"
  fi
  if [ -n "$ops" ]; then
    output="$(
      printf 'Detected operator/webhook pods:\n'
      printf '%s\n' "$ops" | awk 'BEGIN{printf "%-25s %-45s\n","NAMESPACE","POD"} {printf "%-25s %-45s\n",$1,$2}'
      printf '%s\n' "$ops" | awk '{print $1}' | sort -u | while read -r ns; do
        [ -n "$ns" ] || continue
        printf '\n================================================================================\n'
        printf 'Operator namespace diagnostics: %s\n' "$ns"
        printf '================================================================================\n'
        printf '\nOperator deployments:\n'
        kubectl get deployments -n "$ns" -l 'weblogic.operatorName' -o wide 2>&1
        kubectl describe deployments -n "$ns" -l 'weblogic.operatorName' 2>&1
        printf '\nWebhook deployments:\n'
        kubectl get deployments -n "$ns" -l 'weblogic.webhookName' -o wide 2>&1
        kubectl describe deployments -n "$ns" -l 'weblogic.webhookName' 2>&1
        printf '\nOperator/webhook configmaps:\n'
        kubectl get configmap -n "$ns" 2>&1 | grep -Ei 'operator|webhook|weblogic' || true
        printf '\nOperator namespace events:\n'
        kubectl get events -n "$ns" --sort-by='.metadata.creationTimestamp' 2>&1
      done
      printf '%s\n' "$ops" | while IFS="$(printf '\t')" read -r ns opod; do
        [ -n "$opod" ] || continue
        printf '\n================================================================================\n'
        printf 'Describe operator/webhook pod %s/%s\n' "$ns" "$opod"
        printf '================================================================================\n'
        kubectl describe pod "$opod" -n "$ns" 2>&1
      done
    )"
    save_archive_text "archive-operator-webhook-health" "Archive - Operator and Webhook Health" "$output"

    printf '%s\n' "$ops" | while IFS="$(printf '\t')" read -r ns opod; do
      [ -n "$opod" ] || continue
      output="$(kubectl logs -n "$ns" "$opod" --all-containers=true 2>&1)"
      save_archive_text "archive-operator-logs-$(sanitize_name "$ns")-$(sanitize_name "$opod")" "Archive - Complete Operator/Webhook Logs - $ns/$opod" "$output"

      output="$(kubectl logs -n "$ns" "$opod" --all-containers=true --previous 2>&1 || true)"
      save_archive_text "archive-operator-previous-logs-$(sanitize_name "$ns")-$(sanitize_name "$opod")" "Archive - Previous Operator/Webhook Logs - $ns/$opod" "$output"

      output="$(print_pod_yaml_and_image_identity "$ns" "$opod")"
      save_archive_text "archive-operator-pod-yaml-$(sanitize_name "$ns")-$(sanitize_name "$opod")" "Archive - Operator/Webhook Pod YAML and Image Identity - $ns/$opod" "$output"
    done
  fi

  output="$(
    for pod in $pods; do
      printf '\n--- Java processes: %s ---\n' "$pod"
      kubectl exec -n "$SELECTED_NAMESPACE" "$pod" -- sh -c "$(java_process_discovery_script)" 2>&1
    done
  )"
  save_archive_text "archive-java-processes" "Archive - Java Process Listings" "$output"

  for pod in $pods; do
    output="$(
      printf '\n================================================================================\n'
      printf 'OPatch lspatches in %s/%s\n' "$SELECTED_NAMESPACE" "$pod"
      printf '================================================================================\n'
      kubectl exec -n "$SELECTED_NAMESPACE" "$pod" -- sh -c "$(opatch_inventory_script)" 2>&1
    )"
    save_archive_text "archive-opatch-lspatches-$(sanitize_name "$pod")" "Archive - OPatch lspatches - $pod" "$output"
  done

  printf '\nCollect thread dumps as part of archive? Defaults: 5 dumps, 5 seconds apart. (y/N): '
  read -r answer || answer=""
  case "$answer" in
    y|Y|yes|YES|Yes)
      selected_pod="$(choose_domain_pod "Select WebLogic pod for archive thread dumps:")" || selected_pod=""
      if [ -n "$selected_pod" ]; then
        pid="$(choose_java_process_in_pod "$selected_pod")" || pid=""
        if [ -n "$pid" ]; then
          count=5
          interval=5
          output=""
          i=1
          while [ "$i" -le "$count" ]; do
            printf 'Collecting archive thread dump %s of %s...\n' "$i" "$count"
            dump="$(kubectl exec -n "$SELECTED_NAMESPACE" "$selected_pod" -- sh -c "if command -v jcmd >/dev/null 2>&1; then jcmd $pid Thread.print -l; elif command -v jstack >/dev/null 2>&1; then jstack -l $pid; else echo 'Neither jcmd nor jstack is available in the container'; exit 1; fi" 2>&1)"
            output="${output}
================================================================================
Thread dump $i of $count for $selected_pod PID $pid at $(now)
================================================================================
${dump}
"
            [ "$i" -lt "$count" ] && sleep "$interval"
            i=$((i + 1))
          done
          save_archive_text "archive-thread-dumps-$(sanitize_name "$selected_pod")-pid-$pid" "Archive - Thread Dumps - $selected_pod PID $pid" "$output"
        fi
      fi
      ;;
  esac

  printf '\nCollect 15-second JFR as part of archive? (y/N): '
  read -r answer || answer=""
  case "$answer" in
    y|Y|yes|YES|Yes)
      selected_pod="$(choose_domain_pod "Select WebLogic pod for archive JFR:")" || selected_pod=""
      if [ -n "$selected_pod" ]; then
        pid="$(choose_java_process_in_pod "$selected_pod")" || pid=""
        if [ -n "$pid" ]; then
          duration=15
          SAVE_COUNT=$((SAVE_COUNT + 1))
          remote_file="/tmp/wko_${SELECTED_DOMAIN_RESOURCE}_${selected_pod}_${pid}_$(date '+%Y%m%d_%H%M%S').jfr"
          local_file="$REPORT_DIR/$(printf '%03d_%s_%s_archive_jfr_%s_pid_%s.jfr' "$SAVE_COUNT" "$(sanitize_name "$SELECTED_NAMESPACE")" "$(sanitize_name "$SELECTED_DOMAIN_RESOURCE")" "$(sanitize_name "$selected_pod")" "$pid")"
          kubectl exec -n "$SELECTED_NAMESPACE" "$selected_pod" -- sh -c "jcmd $pid JFR.start name=wkid_archive settings=profile duration=${duration}s filename=$remote_file" 2>&1
          printf 'Waiting %s seconds for JFR...\n' "$duration"
          sleep "$duration"
          if kubectl exec -n "$SELECTED_NAMESPACE" "$selected_pod" -- cat "$remote_file" > "$local_file" 2>/dev/null; then
            printf '[%s] %s - Archive JFR for %s/%s PID %s\n' "$(now)" "$(basename "$local_file")" "$SELECTED_NAMESPACE" "$selected_pod" "$pid" >> "$MANIFEST_FILE"
            printf '%sSaved:%s %s\n' "$C_GREEN" "$C_RESET" "$local_file"
          else
            printf '%sWARN:%s Failed to download archive JFR.\n' "$C_YELLOW" "$C_RESET"
          fi
        fi
      fi
      ;;
  esac

  create_report_archive || true
  printf '\n%sDiagnostic archive folder:%s %s\n' "$C_GREEN" "$C_RESET" "$REPORT_DIR"
  printf 'Use the archive file when one was created. Otherwise use the full folder.\n'
  return 0
}

op_change_selection() {
  select_namespace
  select_domain
  if [ "$OPERATOR_ONLY_MODE" -eq 1 ]; then
    if select_domain_context_for_operator_namespace; then
      return 0
    fi
    confirm_menu_choice 12 && op_operator_info_logs
    return 2
  fi
  return 0
}

confirm_menu_choice() {
  case "$1" in
    1)
      confirm_read_only_operation "Generate Diagnostic Archive" "no" \
        "kubectl get/describe domain, clusters, pods, jobs, configmaps, services, EndpointSlices, events, storage" \
        "kubectl logs for WebLogic server pods, operator pods, and webhook pods" \
        "kubectl top when metrics-server is available" \
        "kubectl exec only for Java process discovery unless you opt into thread dumps or JFR" \
        "zip or tar to create the local diagnostic archive"
      ;;
    2)
      confirm_read_only_operation "WKO Domain, Cluster, and Introspector Status" "yes" \
        "kubectl get domain $SELECTED_DOMAIN_RESOURCE -n $SELECTED_NAMESPACE -o json|wide|yaml" \
        "kubectl describe domain $SELECTED_DOMAIN_RESOURCE -n $SELECTED_NAMESPACE" \
        "kubectl get/describe cluster resources referenced by the Domain" \
        "kubectl get/describe/logs introspector jobs and pods when present"
      ;;
    3)
      confirm_read_only_operation "Kubernetes Cluster Overview" "yes" \
        "kubectl config current-context" \
        "kubectl cluster-info and version" \
        "kubectl get/top nodes"
      ;;
    4)
      confirm_read_only_operation "WebLogic Server Pod Status" "yes" \
        "kubectl get pods -n $SELECTED_NAMESPACE -l weblogic.domainUID=$SELECTED_DOMAIN_UID -o wide|json"
      ;;
    5)
      confirm_read_only_operation "Pod CPU/Memory Requests, Limits, and Usage" "yes" \
        "kubectl get pod details for WebLogic pods" \
        "kubectl top pod/node when metrics-server is available" \
        "kubectl describe node for allocated resource summary"
      ;;
    6)
      confirm_read_only_operation "Readiness and Liveness Probe Summary" "yes" \
        "kubectl get pods -n $SELECTED_NAMESPACE -l weblogic.domainUID=$SELECTED_DOMAIN_UID -o json" \
        "kubectl get events for selected/domain pods" \
        "kubectl describe pod fallback when jq is unavailable"
      ;;
    7)
      confirm_read_only_operation "Services, Endpoints, Ingress, and Network Policies" "yes" \
        "kubectl get services -n $SELECTED_NAMESPACE -o wide" \
        "kubectl get endpointslices.discovery.k8s.io -n $SELECTED_NAMESPACE -o wide" \
        "kubectl get ingress, networkpolicy -n $SELECTED_NAMESPACE -o wide"
      ;;
    8)
      confirm_read_only_operation "Persistent Storage Summary (PVCs, PVs, StorageClasses)" "yes" \
        "kubectl get pvc -n $SELECTED_NAMESPACE -o wide" \
        "kubectl get pv -o wide" \
        "kubectl get storageclass -o wide"
      ;;
    9)
      confirm_read_only_operation "Recent Events" "yes" \
        "kubectl get events -n $SELECTED_NAMESPACE" \
        "kubectl get events with domain UID and createdByOperator selectors" \
        "kubectl get events for operator/webhook namespaces when detected"
      ;;
    10)
      confirm_read_only_operation "Describe WebLogic Server Pods" "yes" \
        "kubectl describe pod for each WebLogic pod with weblogic.domainUID=$SELECTED_DOMAIN_UID"
      ;;
    11)
      confirm_read_only_operation "WebLogic Server Pod Logs" "yes" \
        "kubectl logs -n $SELECTED_NAMESPACE <selected-pod> --tail=$LOG_TAIL_LINES" \
        "kubectl logs without --tail only if you choose to save complete logs"
      ;;
    12)
      confirm_read_only_operation "WebLogic Operator / Webhook Pod Logs" "yes" \
        "kubectl get/describe operator and webhook pods/deployments/configmaps/events" \
        "kubectl logs for operator/webhook pods when log capture is selected"
      ;;
    13)
      confirm_read_only_operation "Java Process Listing" "yes" \
        "kubectl exec -n $SELECTED_NAMESPACE <selected-pod> -- jps -lv or ps -ef"
      ;;
    14)
      confirm_read_only_operation "OPatch Inventory" "yes" \
        "kubectl exec -n $SELECTED_NAMESPACE <selected-pod> -- opatch lspatches"
      ;;
    15)
      confirm_read_only_operation "Collect JFR" "no" \
        "kubectl exec to run jcmd <pid> JFR.start for the selected JVM" \
        "kubectl exec cat to download the generated .jfr file" \
        "local write of the downloaded .jfr file into the report folder"
      ;;
    16)
      confirm_read_only_operation "Collect Thread Dumps" "no" \
        "kubectl exec to run jcmd <pid> Thread.print -l or jstack -l" \
        "local write only if you choose to save the output"
      ;;
    17)
      confirm_read_only_operation "Exec Into Pod" "no" \
        "kubectl exec -it -n $SELECTED_NAMESPACE <selected-pod> -- bash or sh" \
        "commands typed inside the shell are controlled by the user, not WKID"
      ;;
    18)
      confirm_read_only_operation "Open WLST Session" "no" \
        "kubectl exec -it -n $SELECTED_NAMESPACE <selected-pod> -- wlst.sh" \
        "WLST commands typed after it opens are controlled by the user, not WKID"
      ;;
    *) return 0 ;;
  esac
}

print_menu() {
  print_header "WKID v$SCRIPT_VERSION"
  printf 'WebLogic Kubernetes Interactive Diagnostics\n\n'
  printf '%sSelected namespace :%s %s\n' "$C_BOLD" "$C_RESET" "$SELECTED_NAMESPACE"
  printf '%sDomain             :%s %s\n' "$C_BOLD" "$C_RESET" "$SELECTED_DOMAIN_RESOURCE"
  printf '%sDomain UID         :%s %s\n' "$C_BOLD" "$C_RESET" "$SELECTED_DOMAIN_UID"
  printf '%sWebLogic Server version:%s   %s\n' "$C_BOLD" "$C_RESET" "$WEBLOGIC_SERVER_VERSION"
  printf '%sWebLogic Operator version:%s %s\n' "$C_BOLD" "$C_RESET" "$WEBLOGIC_OPERATOR_VERSION"
  printf '%sJDK version:%s               %s\n\n' "$C_BOLD" "$C_RESET" "$JDK_VERSION"
  printf '%sSafety:%s WKID does not modify Kubernetes resources or restart/kill/edit anything.\n' "$C_BOLD" "$C_RESET"
  printf '        Local writes are limited to the diagnostic report folder and archive.\n\n'
  printf '%sTip:%s Option 1 is the best starting point for most troubleshooting.\n' "$C_BOLD" "$C_RESET"
  printf '     Use the remaining options for focused interactive diagnostics.\n\n'
  printf '%sChoose an operation:%s\n' "$C_BOLD" "$C_RESET"
  print_menu_section 'Quick Start'
  printf '  %s1%s)  Generate diagnostic archive (Recommended)\n' "$C_YELLOW" "$C_RESET"
  printf '      Creates a diagnostic archive and exits.\n'
  print_menu_section 'Interactive Diagnostics'
  printf '  %s2%s)  WKO domain, Cluster, and introspector status\n' "$C_YELLOW" "$C_RESET"
  printf '  %s3%s)  Kubernetes cluster overview\n' "$C_YELLOW" "$C_RESET"
  printf '  %s4%s)  WebLogic server pod status\n' "$C_YELLOW" "$C_RESET"
  printf '  %s5%s)  Pod CPU/Memory requests, limits, and usage\n' "$C_YELLOW" "$C_RESET"
  printf '  %s6%s)  Readiness/liveness probe summary\n' "$C_YELLOW" "$C_RESET"
  printf '  %s7%s)  Services, Endpoints, Ingress, and Network Policies\n' "$C_YELLOW" "$C_RESET"
  printf '  %s8%s)  Persistent storage summary (PVCs, PVs, StorageClasses)\n' "$C_YELLOW" "$C_RESET"
  printf '\n%sLogs and events:%s\n' "$C_CYAN" "$C_RESET"
  printf '  %s9%s)  Recent namespace/domain/pod events\n' "$C_YELLOW" "$C_RESET"
  printf '  %s10%s) Describe WebLogic server pods\n' "$C_YELLOW" "$C_RESET"
  printf '  %s11%s) WebLogic server pod logs\n' "$C_YELLOW" "$C_RESET"
  printf '  %s12%s) WebLogic Operator / webhook pod logs\n' "$C_YELLOW" "$C_RESET"
  printf '\n%sJVM Diagnostics:%s\n' "$C_CYAN" "$C_RESET"
  printf '  %s13%s) List Java processes\n' "$C_YELLOW" "$C_RESET"
  printf '  %s14%s) List OPatch inventory\n' "$C_YELLOW" "$C_RESET"
  printf '  %s15%s) Collect JFR from selected WebLogic JVM\n' "$C_YELLOW" "$C_RESET"
  printf '  %s16%s) Collect thread dumps from selected WebLogic JVM\n' "$C_YELLOW" "$C_RESET"
  printf '\n%sAdvanced Interactive Access:%s\n' "$C_CYAN" "$C_RESET"
  printf '  %s17%s) List all pods and exec into a pod\n' "$C_YELLOW" "$C_RESET"
  printf '  %s18%s) Open WLST session in a WebLogic pod (no commands run by default)\n' "$C_YELLOW" "$C_RESET"
  printf '\n%sNavigation:%s\n' "$C_CYAN" "$C_RESET"
  printf '  %s19%s) Change namespace/domain\n' "$C_YELLOW" "$C_RESET"
  printf '  %sq%s)  Quit\n' "$C_YELLOW" "$C_RESET"
}

main_loop() {
  local choice
  while :; do
    print_menu
    printf '\n%sEnter choice:%s ' "$C_YELLOW" "$C_RESET"
    read -r choice || choice="q"
    case "$choice" in
      1|2|3|4|5|6|7|8|9|10|11|12|13|14|15|16|17|18)
        confirm_menu_choice "$choice" || continue
        ;;
    esac
    case "$choice" in
      1)
        if op_collect_diagnostic_archive; then
          break
        fi
        ;;
      2) op_domain_summary ;;
      3) op_cluster_overview ;;
      4) op_pod_summary ;;
      5) op_pod_resources ;;
      6) op_probe_summary ;;
      7) op_services_network ;;
      8) op_storage ;;
      9) op_events ;;
      10) op_describe_pods ;;
      11) op_pod_logs ;;
      12) op_operator_info_logs ;;
      13) op_java_processes ;;
      14) op_opatch_inventory ;;
      15) op_collect_jfr ;;
      16) op_collect_thread_dumps ;;
      17) op_exec_into_pod ;;
      18) op_open_wlst ;;
      19) op_change_selection; [ "$?" -eq 2 ] && break ;;
      q|Q|quit|exit) break ;;
      *) printf '%sInvalid choice. Try again.%s\n' "$C_RED" "$C_RESET" ;;
    esac
  done
}

print_final_summary() {
  print_header 'Diagnostic Session Finished'
  printf '%sNamespace:%s     %s\n' "$C_BOLD" "$C_RESET" "${SELECTED_NAMESPACE:-N/A}"
  printf '%sDomain resource:%s %s\n' "$C_BOLD" "$C_RESET" "${SELECTED_DOMAIN_RESOURCE:-N/A}"
  printf '%sDomain UID:%s      %s\n' "$C_BOLD" "$C_RESET" "${SELECTED_DOMAIN_UID:-N/A}"
  printf '%sSaved outputs:%s %s\n' "$C_BOLD" "$C_RESET" "$SAVE_COUNT"
  printf '%sSafety:%s       No mutating kubectl verbs, restarts, kills, config edits, or service changes were performed by WKID.\n' "$C_BOLD" "$C_RESET"
  if [ -n "$REPORT_DIR" ]; then
    printf '%sFolder:%s        %s\n' "$C_BOLD" "$C_RESET" "$REPORT_DIR"
    printf '%sManifest:%s      %s\n' "$C_BOLD" "$C_RESET" "$MANIFEST_FILE"
    printf '%sLocal writes:%s  Report folder, manifest, saved diagnostic outputs, and optional archive only.\n' "$C_BOLD" "$C_RESET"
    printf '%sReminder:%s      Attach the generated archive when present; otherwise attach the full folder.\n' "$C_BOLD" "$C_RESET"
    printf '\n%sWhat was saved:%s\n' "$C_BOLD" "$C_RESET"
    sed -n '/^Saved outputs:/,$p' "$MANIFEST_FILE" | sed '1d'
  else
    printf '%sFolder:%s        No files saved in this session.\n' "$C_BOLD" "$C_RESET"
  fi
  printf '\n'
}

main() {
  parse_args "$@"
  init_colors
  print_intro
  check_prereqs
  select_namespace
  select_domain
  if [ "$OPERATOR_ONLY_MODE" -eq 1 ]; then
    if ! select_domain_context_for_operator_namespace; then
      confirm_menu_choice 12 && op_operator_info_logs
      print_final_summary
      return 0
    fi
  fi
  main_loop
  print_final_summary
}

main "$@"
