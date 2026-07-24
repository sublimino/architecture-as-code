#!/usr/bin/env bash
#
# Task Processor Script
#
# Leigh Capili, @stealthybox
#
# exit on error or pipe failure
set -eo pipefail
# propagate ERR traps to subshells
set -o errtrace
# error on unset variable
if test "${BASH}" = "" || "${BASH}" -uc 'a=();true "${a[@]}"' 2>/dev/null; then
  set -o nounset
fi
# error on clobber
set -o noclobber
# disable passglob
shopt -s nullglob globstar

_error_handler() {
  local ERR=$?
  set +o xtrace
  error "Error in ${BASH_SOURCE[1]}:${BASH_LINENO[0]}: '${BASH_COMMAND}' exited with status ${ERR} in ${FUNCNAME[1]}()"
  if [ ${#FUNCNAME[@]} -gt 2 ]; then
    error "Call tree:"
    for ((i = 1; i < ${#FUNCNAME[@]} - 1; i++)); do
      error " $i: ${BASH_SOURCE[$i + 1]}:${BASH_LINENO[$i]} ${FUNCNAME[$i]}(...)"
    done
  fi
  cleanup_task
  exit "${ERR}"
}
trap _error_handler ERR

# resolved directory and self
declare -r DIR=$(cd "$(dirname "${0}")" && pwd)
declare -r THIS_SCRIPT="${DIR}/$(basename "${0}")"
declare -r SERVICE="${SERVICE:-$(basename "${THIS_SCRIPT}" | sed 's/\.[^.]*$//')}"
declare -r SCRIPT_UUID="task-processor-$(date +%s)"

enhance_sbom_with_dependencies() {
  local target_path="$1"
  local package_name="$2"
  local sbom_path="$3"
  
  info "Enhancing SBOM with dependency information..."
  
  # Find the installed package's package.json file
  local package_json_path="${target_path}/node_modules/${package_name}/package.json"
  
  if [[ -f "$package_json_path" ]]; then
    info "Reading dependency information from: $package_json_path"
    
    # Extract dependency information
    local dependencies=$(jq -r '.dependencies // {}' "$package_json_path" 2>/dev/null || echo '{}')
    local dev_dependencies=$(jq -r '.devDependencies // {}' "$package_json_path" 2>/dev/null || echo '{}')
    local peer_dependencies=$(jq -r '.peerDependencies // {}' "$package_json_path" 2>/dev/null || echo '{}')
    local optional_dependencies=$(jq -r '.optionalDependencies // {}' "$package_json_path" 2>/dev/null || echo '{}')
    
    # Count dependencies
    local dep_count=$(echo "$dependencies" | jq 'keys | length' 2>/dev/null || echo 0)
    local dev_dep_count=$(echo "$dev_dependencies" | jq 'keys | length' 2>/dev/null || echo 0)
    local peer_dep_count=$(echo "$peer_dependencies" | jq 'keys | length' 2>/dev/null || echo 0)
    local opt_dep_count=$(echo "$optional_dependencies" | jq 'keys | length' 2>/dev/null || echo 0)
    
    info "  Dependencies: $dep_count"
    info "  Dev Dependencies: $dev_dep_count" 
    info "  Peer Dependencies: $peer_dep_count"
    info "  Optional Dependencies: $opt_dep_count"
    
    # Create a temporary enhanced SBOM with dependency metadata
    local temp_sbom="${sbom_path}.tmp"
    
    # Add dependency information to the SBOM as annotations
    jq --argjson deps "$dependencies" \
       --argjson devDeps "$dev_dependencies" \
       --argjson peerDeps "$peer_dependencies" \
       --argjson optDeps "$optional_dependencies" \
       --arg depCount "$dep_count" \
       --arg devDepCount "$dev_dep_count" \
       --arg peerDepCount "$peer_dep_count" \
       --arg optDepCount "$opt_dep_count" \
       '.annotationComment = "Enhanced with npm dependency information" |
        .annotations = [
          {
            "annotationType": "OTHER",
            "annotationComment": "npm-dependencies",
            "annotationValue": ($deps | tostring)
          },
          {
            "annotationType": "OTHER", 
            "annotationComment": "npm-dev-dependencies",
            "annotationValue": ($devDeps | tostring)
          },
          {
            "annotationType": "OTHER",
            "annotationComment": "npm-peer-dependencies", 
            "annotationValue": ($peerDeps | tostring)
          },
          {
            "annotationType": "OTHER",
            "annotationComment": "npm-optional-dependencies",
            "annotationValue": ($optDeps | tostring)
          },
          {
            "annotationType": "OTHER",
            "annotationComment": "dependency-counts",
            "annotationValue": ("deps:" + $depCount + ",dev:" + $devDepCount + ",peer:" + $peerDepCount + ",opt:" + $optDepCount)
          }
        ]' "$sbom_path" > "$temp_sbom"
    
    # Replace original SBOM with enhanced version
    if [[ -f "$temp_sbom" ]] && [[ -s "$temp_sbom" ]]; then
      mv "$temp_sbom" "$sbom_path"
      success "SBOM enhanced with dependency information"
    else
      warning "Failed to enhance SBOM with dependency information"
      rm -f "$temp_sbom"
    fi
  else
    warning "Package.json not found at: $package_json_path"
  fi
}

# helper functions

usage() {
  [ "${*}" ] && echo "${THIS_SCRIPT}: ${COLOUR_RED}${*}${COLOUR_RESET}" && echo
  sed -n '/^##/,/^$/s/^## \{0,1\}//p' "${THIS_SCRIPT}" | sed "s/%SCRIPT_NAME%/$(basename "${THIS_SCRIPT}")/g"
  exit 2
} 2>/dev/null

success() {
  [ "${*:-}" ] && RESPONSE="${*}" || RESPONSE="Unknown Success"
  printf "%s\\n" "$(log_message_prefix)${COLOUR_GREEN}${RESPONSE}${COLOUR_RESET}"
} 1>&2

info() {
  [ "${*:-}" ] && INFO="${*}" || INFO="Unknown Info"
  printf "%s\\n" "$(log_message_prefix)${COLOUR_WHITE}${INFO}${COLOUR_RESET}"
} 1>&2

warning() {
  [ "${*:-}" ] && ERROR="${*}" || ERROR="Unknown Warning"
  printf "%s\\n" "$(log_message_prefix)${COLOUR_YELLOW}${ERROR}${COLOUR_RESET}"
} 1>&2

error() {
  [ "${*:-}" ] && ERROR="${*}" || ERROR="Unknown Error"
  printf "%s\\n" "$(log_message_prefix)${COLOUR_RED}${ERROR}${COLOUR_RESET}"
  exit 3
} 1>&2

error_env_var() {
  error "${1} environment variable required"
}

log_message_prefix() {
  local TIMESTAMP
  local THIS_SCRIPT_SHORT=${THIS_SCRIPT/${DIR}/.}
  TIMESTAMP="[$(date +'%Y-%m-%dT%H:%M:%SZ')]"
  tput bold 2>/dev/null
  echo -n "${TIMESTAMP} ${THIS_SCRIPT_SHORT}: "
}

is_empty() {
  [[ -z ${1-} ]] && return 0 || return 1
}

not_empty_or_error() {
  if is_empty "${1-}"; then
    warning "${2:-Non-empty value required}"
    if [[ "${3:-}" =~ ^[0-9]+$ ]]; then
      exit "${3}"
    fi
    exit 1
  fi
  return 0
}

not_empty_or_usage() {
  if is_empty "${1-}"; then
    shift
    usage "Non-empty value required ${@:-}"
  fi
  return 0
}

check_number_of_expected_arguments() {
  [[ "${EXPECTED_NUM_ARGUMENTS}" != "${#ARGUMENTS[@]}" ]] && {
    ARGUMENTS_STRING="argument"
    [[ "${EXPECTED_NUM_ARGUMENTS}" -gt 1 ]] && ARGUMENTS_STRING="${ARGUMENTS_STRING}"s
    usage "${EXPECTED_NUM_ARGUMENTS} ${ARGUMENTS_STRING} expected, ${#ARGUMENTS[@]} found"
  }
  return 0
}

get_version() {
  echo "Task Processor v1.0.0"
}

hr() {
  printf '=%.0s' "$(seq "$(tput cols)")"
  echo
}

wait_safe() {
  local PIDS="${1}"
  for JOB in ${PIDS}; do
    wait "${JOB}"
  done
}

try() {
  try-limit 0 "${@}"
}

try-limit() {
  local LIMIT=$1
  local COUNT=1
  local RETURN_CODE
  shift
  local COMMAND="${@:-}"
  if [[ "${COMMAND}" == "" ]]; then
    echo "At least two arguments required (limit, command)" 1>&2
    return 1
  fi
  function _try-limit-output() {
    printf "\n$(date) (${COUNT}): %s - " "${COMMAND}" 1>&2
  }
  echo "Limit: ${LIMIT}. Trying command: ${COMMAND}"
  _try-limit-output
  local oldopt=$-
  set +E
  until echo "${COMMAND}" | source /dev/stdin; do
    RETURN_CODE=$?
    echo "Return code: ${RETURN_CODE}"
    if [[ "${LIMIT}" -gt 0 && "${COUNT}" -ge "${LIMIT}" ]]; then
      printf "\nFailed \`${COMMAND}\` after ${COUNT} iterations\n" 1>&2
      return 1
    fi
    COUNT=$((COUNT + 1))
    _try-limit-output
    if [[ "${_TRY_LIMIT_BACKOFF:-}" != "" ]]; then
      sleep $(((COUNT * _TRY_LIMIT_BACKOFF) / 10))
    else
      sleep ${_TRY_LIMIT_SLEEP:-0.3}
    fi
  done
  RETURN_CODE=$?
  if [[ "${COUNT}" == 1 ]]; then
    echo
  fi
  echo "Completed \`${COMMAND}\` after ${COUNT} iterations" 1>&2
  unset _TRY_LIMIT_SLEEP _TRY_LIMIT_BACKOFF
  set -$oldopt
  return ${RETURN_CODE}
}

pushbullet() {
  local URL="https://hooks.zapier.com/hooks/catch/92255/22htupm/"
  local TITLE="${1:-Hello}"
  local MESSAGE="${2:-World}"
  curl --compressed --connect-timeout 5 -X POST -H "Content-Type: application/json" \
    -d "{\"title\":\"$TITLE\",\"message\":\"$MESSAGE\"}" "${URL}"
}

_do_sudo() {
  if [[ "$(id -u)" != 0 ]]; then
    echo "sudo"
  fi
}

http_server() {
  if pgrep -f "shell2http.*${SCRIPT_UUID}" >/dev/null; then
    error "shell2http already running for ${SCRIPT_UUID}"
  fi

  echo "Starting ${SERVICE} on ${PORT} for ${SCRIPT_UUID}..."

  shell2http \
    -port="${PORT}" \
    -form \
    -500 \
    -no-index \
    -shell="bash" \
    -export-all-vars \
    \
    "/${SCRIPT_UUID}" "echo Hello, ${SCRIPT_UUID}" \
    "/healthz" "echo OK" "/fail" "echo Fail; exit 1" "/" "echo Hello, World" \
    \
    "/${SCRIPT_UUID}/help" "${THIS_SCRIPT} --help || true"

  exit $?
}

export CLICOLOR=1
export TERM="xterm-color"
export COLOUR_BLACK=$(tput setaf 0 2>/dev/null)
export COLOUR_RED=$(tput setaf 1 2>/dev/null)
export COLOUR_GREEN=$(tput setaf 2 2>/dev/null)
export COLOUR_YELLOW=$(tput setaf 3 2>/dev/null)
export COLOUR_BLUE=$(tput setaf 4 2>/dev/null)
export COLOUR_MAGENTA=$(tput setaf 5 2>/dev/null)
export COLOUR_CYAN=$(tput setaf 6 2>/dev/null)
export COLOUR_WHITE=$(tput setaf 7 2>/dev/null)
export COLOUR_RESET=$(tput sgr0 2>/dev/null)

enhance_sbom_with_dependencies "${@}"
