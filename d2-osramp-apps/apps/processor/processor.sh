#!/usr/bin/env bash
#
# Task Processor Script
#
#
## Usage: %SCRIPT_NAME% [options] [task_id]
##
## Options:
##   --task-type [string]        Task type to process (purl_check, npm_install, data_processing, ml_training)
##   --work-dir [string]         Working directory for tasks (default: /tmp/tasks)
##   --results-dir [string]      Results directory (default: /tmp/results)
##   --npm-dir [string]          NPM packages directory (default: /tmp/npm-packages)
##   --max-time [number]         Maximum execution time in seconds (default: 300)
##   --cleanup                   Enable cleanup after task completion
##   --no-cleanup                Disable cleanup after task completion
##
##   --http-server               Start an HTTP server
##   --config=file               Configuration file to override flags, formatted as options without prefixed hyphens
##   --debug                     Enable debug mode
##   -v, --version               Print version
##   -h, --help                  Display this message
##

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

# sandbox our files and PWD
# TODO use mktmp?
# TODO add flag?
# Note this breaks witness watching files if the user passes flags since the user can't anticipate the random value
# unless the user overrides the RUN_DIR via env
RUN_DIR="${RUN_DIR:-/tmp/processor-${RANDOM}}"
SIGNING_KEY="${SIGNING_KEY:-"/var/run/signing/signing-private.pem"}"
SIGNING_PUBLIC_KEY="${SIGNING_PUBLIC_KEY:-"/var/run/signing/signing-public.pem"}"
ARCHIVISTA_SERVER="${ARCHIVISTA_SERVER:-"http://osramp-archivista.backend:8082"}"

# user defaults
TASK_TYPE=""
WORK_DIR="${WORK_DIR:-${RUN_DIR}/tasks}"
RESULTS_DIR="${RESULTS_DIR:-${RUN_DIR}/results}"
NPM_INSTALL_DIR="${NPM_INSTALL_DIR:-${RUN_DIR}/npm-packages}"
MAX_EXECUTION_TIME="${MAX_EXECUTION_TIME:-300}"
CLEANUP_AFTER_TASK="${CLEANUP_AFTER_TASK:-true}"
CONFIG_FILE=""
PORT="${PORT:-8080}"
IS_HTTP_SERVER=0
DEBUG=0
DRY_RUN=0

# required defaults
declare -a ARGUMENTS
EXPECTED_NUM_ARGUMENTS=0
ARGUMENTS=()
TASK_ID=''
TEMP_FILE=

# Task processing globals
CORRELATION_ID=""
WORKER_ID=""

main() {
  handle_arguments "$@"
  trap cleanup_task EXIT

  if [[ "${IS_HTTP_SERVER}" == 1 ]]; then
    http_server
  fi

  # Setup environment for task processing
  setup_environment

  # Parse task from environment variables
  parse_task

  # Process the task
  if process_task; then
    success "Task ${TASK_ID} completed successfully"
    cleanup_task
    exit 0
  else
    warning "Task ${TASK_ID} failed"
    # Task result already generated in process_task function
    cleanup_task
    exit 1
  fi
}

cleanup_task() {
  if [[ "${CLEANUP_AFTER_TASK}" == "true" && -n "${TASK_ID:-}" ]]; then
    info "Cleaning up task artifacts..."

    # Remove task-specific directories older than 1 hour
    find "${WORK_DIR}" -maxdepth 1 -type d -name "*${TASK_ID}*" -mmin +60 -exec rm -rf {} \; 2>/dev/null || true
    find "${NPM_INSTALL_DIR}" -maxdepth 1 -type d -name "*${TASK_ID}*" -mmin +60 -exec rm -rf {} \; 2>/dev/null || true

    # Keep results for longer (24 hours)
    find "${RESULTS_DIR}" -name "*result.json" -mmin +1440 -delete 2>/dev/null || true
  fi
  [[ -f "${TEMP_FILE}" ]] && rm -rf "${TEMP_FILE}"
  true
}

# ---

handle_arguments() {
  parse_arguments "${@:-}"
  parse_config_file "${@:-}"
  validate_arguments "${@:-}"
}

parse_arguments() {
  local CURRENT_ARG
  local NEXT_ARG
  local SPLIT_ARG
  local COUNT=0

  if [[ "${#}" == 1 && "${1:-}" == "" ]]; then
    return 0
  fi

  while [[ "${#}" -gt 0 ]]; do
    CURRENT_ARG="${1}"

    COUNT=$((COUNT + 1))
    if [[ "${COUNT}" -gt 100 ]]; then
      error "Too many arguments or '${CURRENT_ARG}' is unknown"
    fi

    IFS='=' read -ra SPLIT_ARG <<<"${CURRENT_ARG}"
    if [[ ${#SPLIT_ARG[@]} -gt 1 ]]; then
      CURRENT_ARG="${SPLIT_ARG[0]}"
      unset 'SPLIT_ARG[0]'
      NEXT_ARG="$(printf "%s=" "${SPLIT_ARG[@]}")"
      NEXT_ARG="${NEXT_ARG%?}"
    else
      shift
      NEXT_ARG="${1:-}"
    fi

    case ${CURRENT_ARG} in
    --task-type)
      not_empty_or_usage "${NEXT_ARG:-}"
      TASK_TYPE="${NEXT_ARG}"
      shift
      ;;
    --work-dir)
      not_empty_or_usage "${NEXT_ARG:-}"
      WORK_DIR="${NEXT_ARG}"
      shift
      ;;
    --results-dir)
      not_empty_or_usage "${NEXT_ARG:-}"
      RESULTS_DIR="${NEXT_ARG}"
      shift
      ;;
    --npm-dir)
      not_empty_or_usage "${NEXT_ARG:-}"
      NPM_INSTALL_DIR="${NEXT_ARG}"
      shift
      ;;
    --max-time)
      not_empty_or_usage "${NEXT_ARG:-}"
      MAX_EXECUTION_TIME="${NEXT_ARG}"
      shift
      ;;
    --cleanup)
      CLEANUP_AFTER_TASK="true"
      ;;
    --no-cleanup)
      CLEANUP_AFTER_TASK="false"
      ;;
    # ---
    --http-server)
      IS_HTTP_SERVER=1
      ;;
    --config)
      not_empty_or_usage "${NEXT_ARG:-}"
      CONFIG_FILE="${NEXT_ARG}"
      shift
      ;;
    -h | --help) usage ;;
    -v | --version)
      get_version
      exit 0
      ;;
    --debug)
      DEBUG=1
      set -xe
      ;;
    --dry-run) DRY_RUN=1 ;;
    --)
      EXTENDED_ARGS="${@}"
      break
      ;;
    -*) usage "${CURRENT_ARG}: unknown option" ;;
    *) ARGUMENTS+=("${CURRENT_ARG}") ;;
    esac
  done
}

parse_config_file() {
  if [[ -n ${CONFIG_FILE:-} && -r ${CONFIG_FILE} ]]; then
    local PREVIOUS_ARGUMENTS="${@}"
    local ARGS_FROM_FILE
    local SPLIT_ARG
    local LINE

    while read -r LINE; do
      LINE="--${LINE}"
      IFS='=' read -ra SPLIT_ARG <<<"${LINE}"
      if ! grep -q -- "${SPLIT_ARG[0]}" <<<"${PREVIOUS_ARGUMENTS}" >/dev/null; then
        set -- "${LINE}"
        parse_arguments "${@}"
      fi
    done < <(cat "${CONFIG_FILE}")
  fi
}

validate_arguments() {
  TASK_ID="${ARGUMENTS[0]:-${TASK_ID:-unknown}}" || true
  check_number_of_expected_arguments
}

# Task processing functions

setup_environment() {
  info "Setting up task processor environment..."

  # Enter sandboxed runtime dir for witness
  mkdir -p "${RUN_DIR}"
  cd "${RUN_DIR}"

  # Create working directories
  mkdir -p "${WORK_DIR}" "${RESULTS_DIR}" "${NPM_INSTALL_DIR}"

  # Set restrictive permissions
  chmod 700 "${WORK_DIR}" "${RESULTS_DIR}" "${NPM_INSTALL_DIR}"

  # Validate required tools
  local required_tools=("jq" "npm" "node" "timeout" "find" "curl")
  for tool in "${required_tools[@]}"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      error "Required tool not found: $tool"
    fi
  done

  success "Environment setup complete"
}

parse_task() {
    if [[ -z "${TASK_JSON:-}" ]]; then
        log_error "TASK_JSON environment variable not set"
        exit 1
    fi

  # Validate JSON structure
  if ! echo "$TASK_JSON" | jq empty >/dev/null 2>&1; then
    error "Invalid JSON in TASK_JSON"
  fi

  # Extract task details
  TASK_ID=$(echo "$TASK_JSON" | jq -r '.id // "unknown"')
  TASK_TYPE=$(echo "$TASK_JSON" | jq -r '.type // "npm_install"')
  CORRELATION_ID=$(echo "$TASK_JSON" | jq -r '.correlation_id // "unknown"')
  WORKER_ID=$(echo "$TASK_JSON" | jq -r '.worker_id // "unknown"')

  info "Processing task: ${TASK_ID} (type: ${TASK_TYPE}, correlation: ${CORRELATION_ID}, worker: ${WORKER_ID})"
}

execute_npm_task() {
    local package_name=$(echo "$TASK_JSON" | jq -r '.payload.package_name // empty')
    local package_version=$(echo "$TASK_JSON" | jq -r '.payload.package_version // "latest"')
    local install_path="${NPM_INSTALL_DIR}/${TASK_ID}"

  if [[ -z "$package_name" ]]; then
    error "No package_name specified in payload"
  fi

  info "Installing npm package: ${package_name}@${package_version}"

  # Create isolated installation directory
  mkdir -p "$install_path"
  cd "$install_path"

  # Initialize minimal package.json
  cat > package.json << EOF
{
  "name": "task-${TASK_ID}",
  "version": "1.0.0",
  "description": "Isolated package installation for task ${TASK_ID}",
  "private": true
}
EOF

  # Install package
  info "Running: npm install ${package_name}@${package_version} --no-deps --no-package-lock --no-audit --no-fund"

  local start_time=$(date +%s)
  if timeout "${MAX_EXECUTION_TIME}" npm install "${package_name}@${package_version}" \
      --no-deps \
      --no-package-lock \
      --no-audit \
      --no-fund \
      --loglevel=warn; then

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    success "Package installed successfully in ${duration}s"
    analyze_npm_installation "$install_path" "$package_name" "$package_version"
    return 0
  else
    error "Package installation failed or timed out"
    return 1
  fi
}

publish_sbom_data() {
  local sbom_file_path="$1"
  local package_name="$2"
  local package_version="$3"
  local component_count="$4"
  
  if [[ ! -f "$sbom_file_path" ]]; then
    warning "SBOM file not found: $sbom_file_path"
    return 1
  fi
  
  info "Publishing complete SBOM data to tasks.sbom queue..."
  
  # Read the complete SBOM JSON content
  local sbom_json_content
  if ! sbom_json_content=$(cat "$sbom_file_path"); then
    error "Failed to read SBOM file: $sbom_file_path"
    return 1
  fi
  
  # Generate unique SBOM ID
  local sbom_id="${TASK_ID}_sbom_$(date +%s)"
  
  # Create SBOM message for archival
  local sbom_message=$(jq -n \
    --arg sbom_id "$sbom_id" \
    --arg task_id "$TASK_ID" \
    --arg package_name "$package_name" \
    --arg package_version "$package_version" \
    --arg sbom_format "spdx-json" \
    --argjson component_count "$component_count" \
    --arg file_path "$sbom_file_path" \
    --argjson sbom_json "$sbom_json_content" \
    --arg correlation_id "$CORRELATION_ID" \
    --arg worker_id "$WORKER_ID" \
    --argjson timestamp "$(date +%s)" \
    '{
      sbom_id: $sbom_id,
      task_id: $task_id,
      package_name: $package_name,
      package_version: $package_version,
      sbom_format: $sbom_format,
      component_count: $component_count,
      file_path: $file_path,
      sbom_json: $sbom_json,
      correlation_id: $correlation_id,
      worker_id: $worker_id,
      timestamp: $timestamp,
      created_at: $timestamp
    }')
  
  # Publish SBOM data to dedicated tasks.sbom queue
  if echo "$sbom_message" | nats pub tasks.sbom --force-stdin; then
    success "SBOM data published to tasks.sbom queue (SBOM ID: $sbom_id)"
    info "  Package: ${package_name}@${package_version}"
    info "  Components: ${component_count}"
    info "  Format: spdx-json"
    return 0
  else
    error "Failed to publish SBOM data to tasks.sbom queue"
    return 1
  fi
}

publish_signature() {
  local signature_file_path="$1"
  local public_key="$2"
  local algorithm="ed25519" # TODO read this dynamically

  local end_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local sig_result_file="${RESULTS_DIR}/${TASK_ID}_sig_result.json"

  if [[ ! -f "$signature_file_path" ]]; then
    warning "Signature file not found: $signature_file_path"
    return 1
  fi
  
  info "Publishing complete Signature data to tasks.signatures queue..."
  
  # Read the complete Signature JSON content
  local signature_content
  if ! signature_content=$(cat "$signature_file_path"); then
    error "Failed to read Signature file: $signature_file_path"
    return 1
  fi

  # Create result JSON
  jq -n \
    --arg task_id "$TASK_ID" \
    --rawfile signature "$signature_file_path" \
    --arg algorithm "$algorithm" \
    --arg public_key "$public_key" \
    '{
        task_id: $task_id,
        signature: $signature,
        algorithm: $algorithm,
        public_key: $public_key
    }' > "$sig_result_file"

  success "Signature result written to: ${sig_result_file}"

  # Publish result to NATS for archival
  if command -v nats >/dev/null 2>&1; then
    local nats_subject="${NATS_RESULT_SUBJECT:-tasks.results}"
    if cat "$sig_result_file" | nats pub "tasks.signatures" --force-stdin; then
      info "Signature result published to NATS subject: ${nats_subject}"
    else
      warning "Failed to publish Signature result to NATS, outputting to stdout instead"
      cat "$sig_result_file"
    fi
  else
    warning "NATS CLI not available, outputting result to stdout"
    cat "$sig_result_file"
  fi
}

generate_sbom() {
  local target_path="$1"
  local package_name="$2"
  local package_version="$3"
  local sbom_output_path="$4"

  info "Generating SBOM for ${package_name}@${package_version}..."

  # Generate SBOM in SPDX JSON format using syft
  if command -v syft >/dev/null 2>&1; then
    info "Using syft to generate SBOM..."
    cd "${RUN_DIR}"
    if witness run --step "sbom_gen" -o "sbom_gen_${TASK_ID}.intoto" -k "${SIGNING_KEY}" -a sbom \
        --enable-archivista --archivista-server="${ARCHIVISTA_SERVER}" \
        -- syft "${target_path}" -o spdx-json="${sbom_output_path}" --quiet
    then
      success "SBOM generated successfully: ${sbom_output_path}"
      
      # Validate SBOM was created and has content
      if [[ -f "$sbom_output_path" ]] && [[ -s "$sbom_output_path" ]]; then
        local sbom_size=$(du -h "$sbom_output_path" | cut -f1)
        local component_count=$(jq -r '.packages | length' "$sbom_output_path" 2>/dev/null || echo "unknown")
        info "  SBOM size: ${sbom_size}"
        info "  Components found: ${component_count}"
        
        # Enhance SBOM with dependency information from package.json
        witness run --step "sbom_enhance" -o "sbom_enhance_${TASK_ID}.intoto" -k "${SIGNING_KEY}" -a sbom \
          --enable-archivista --archivista-server="${ARCHIVISTA_SERVER}" \
          -- /app/enhance_sbom_with_dependencies "$target_path" "$package_name" "$sbom_output_path"
        
        info "Witness Attestations generated successfully: $(ls *.intoto)"
        return 0
      else
        warning "SBOM file was not created or is empty"
        return 1
      fi
    else
      warning "syft failed to generate SBOM"
      return 1
    fi
  else
    warning "syft not available, skipping SBOM generation"
    return 1
  fi
}


analyze_npm_installation() {
  local install_path="$1"
  local package_name="$2"
  local package_version="$3"

  info "Analyzing npm package installation..."

  local node_modules_path="${install_path}/node_modules"
  local package_path="${node_modules_path}/${package_name}"

  # Check if package directory exists
  if [[ ! -d "$package_path" ]]; then
    warning "Package directory not found: ${package_path}"
    return 1
  fi

  # Gather package information
  local actual_version=""
  if [[ -f "${package_path}/package.json" ]]; then
    actual_version=$(jq -r '.version // "unknown"' "${package_path}/package.json")
  fi

  # File system analysis
  local file_count=$(find "$package_path" -type f | wc -l)
  local total_size=$(du -sh "$package_path" | cut -f1)

  # Generate SBOM for the installed package
  local sbom_path="${RESULTS_DIR}/${TASK_ID}_sbom.json"
  local sbom_generated=false
  local sbom_data="{}"
  
  # Run syft on the root directory (where package.json is) to get full npm project analysis
  if generate_sbom "$install_path" "$package_name" "$actual_version" "$sbom_path"; then
    sbom_generated=true
    # Read SBOM content for inclusion in task result
    if [[ -f "$sbom_path" ]]; then
      # Extract key SBOM metadata for the task result
      local sbom_name=$(jq -r '.name // "unknown"' "$sbom_path" 2>/dev/null || echo "unknown")
      local sbom_version=$(jq -r '.dataLicense // "unknown"' "$sbom_path" 2>/dev/null || echo "unknown")
      local component_count=$(jq -r '.packages | length' "$sbom_path" 2>/dev/null || echo 0)
      
      sbom_data=$(jq -n \
        --arg path "$sbom_path" \
        --arg name "$sbom_name" \
        --arg version "$sbom_version" \
        --argjson component_count "$component_count" \
        --arg generated "true" \
        '{
          generated: $generated,
          path: $path,
          name: $name,
          version: $version,
          component_count: $component_count,
          format: "spdx-json"
        }')
      
      info "SBOM metadata extracted for archival"
      
      # Publish complete SBOM data to dedicated queue for archival
      publish_sbom_data "$sbom_path" "$package_name" "$actual_version" "$component_count"

      publish_signature "sbom_gen_${TASK_ID}.intoto" "$(cat "${SIGNING_PUBLIC_KEY}")"
      # TODO -- this sometime generates and sometimes does not? 
      # publish_signature "sbom_enhance_${TASK_ID}.intoto" "$(cat "${SIGNING_PUBLIC_KEY}")"
    fi
  else
    warning "SBOM generation failed, continuing without SBOM"
    sbom_data=$(jq -n \
      --arg generated "false" \
      --arg reason "generation_failed" \
      '{
        generated: $generated,
        reason: $reason
      }')
  fi

  # Log analysis results
  success "Package Analysis Results:"
  info "  Package: ${package_name}@${actual_version}"
  info "  Location: ${package_path}"
  info "  Files: ${file_count} files"
  info "  Size: ${total_size}"
  info "  SBOM Generated: ${sbom_generated}"

  # Show directory structure (top level only)
  info "Directory structure:"
  ls -la "$package_path" | head -20

  # Generate comprehensive result summary including SBOM data
  local result_data=$(jq -n \
    --arg package_name "$package_name" \
    --arg version "$actual_version" \
    --arg path "$package_path" \
    --argjson files "$file_count" \
    --arg size "$total_size" \
    --argjson sbom "$sbom_data" \
    '{
      package_name: $package_name,
      version: $version,
      path: $path,
      files: $files,
      size: $size,
      sbom: $sbom,
      analysis_timestamp: now
    }')

  generate_task_result "success" "npm_package_installed" "$result_data"
}

execute_data_processing_task() {
    local input_data=$(echo "$TASK_JSON" | jq -r '.payload.input // empty')
    local config=$(echo "$TASK_JSON" | jq -r '.payload.config // {}')

  info "Processing data task with input: ${input_data}"

  # Simulate data processing
  local processing_time=$((RANDOM % 10 + 5))  # 5-15 seconds

  info "Simulating data processing for ${processing_time}s..."
  sleep "$processing_time"

  # Generate mock result
  local result_data="{\"input\": \"${input_data}\", \"processed_items\": $((RANDOM % 1000 + 100)), \"processing_time\": ${processing_time}}"

  generate_task_result "success" "data_processed" "$result_data"
}

generate_task_result() {
  local status="$1"
  local result_type="$2"
  local result_data="$3"

  local end_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local result_file="${RESULTS_DIR}/${TASK_ID}_result.json"

  # Create result JSON
  jq -n \
    --arg task_id "$TASK_ID" \
    --arg correlation_id "$CORRELATION_ID" \
    --arg worker_id "$WORKER_ID" \
    --arg status "$status" \
    --arg result_type "$result_type" \
    --arg completed_at "$end_time" \
    --argjson result_data "$result_data" \
    '{
      task_id: $task_id,
      correlation_id: $correlation_id,
      worker_id: $worker_id,
      status: $status,
      result_type: $result_type,
      completed_at: $completed_at,
      result_data: $result_data
    }' > "$result_file"

  success "Task result written to: ${result_file}"

  # Publish result to NATS for archival
  if command -v nats >/dev/null 2>&1; then
    local nats_subject="${NATS_RESULT_SUBJECT:-tasks.results}"
    if nats pub "$nats_subject" "$(cat "$result_file")"; then
      info "Task result published to NATS subject: ${nats_subject}"
    else
      warning "Failed to publish task result to NATS, outputting to stdout instead"
      cat "$result_file"
    fi
  else
    warning "NATS CLI not available, outputting result to stdout"
    cat "$result_file"
  fi
}

# PURL processing functions
parse_purl() {
  local purl="$1"
  
  # Basic PURL parsing - extract type, namespace, name, version
  # Formats: pkg:type/name@version and pkg:type/namespace/name@version
  if [[ "$purl" =~ ^pkg:([^/]+)/((@?[^/@]+)/)?([^@/]+)(@(.+))?$ ]]; then
    PURL_TYPE="${BASH_REMATCH[1]}"
    PURL_NAMESPACE="${BASH_REMATCH[3]}"
    PURL_NAME="${BASH_REMATCH[4]}"
    PURL_VERSION="${BASH_REMATCH[6]:-latest}"
    return 0
  else
    error "Invalid PURL format: $purl"
    return 1
  fi
}

check_purl_cache() {
  local purl="$1"
  local cache_dir="${WORK_DIR}/purl_cache"
  local cache_file="${cache_dir}/$(echo "$purl" | sha256sum | cut -d' ' -f1).json"
  
  mkdir -p "$cache_dir"
  
  if [[ -f "$cache_file" ]]; then
    info "PURL found in cache: $purl"
    cat "$cache_file"
    return 0
  else
    info "PURL not found in cache: $purl"
    return 1
  fi
}

cache_purl_result() {
  local purl="$1"
  local result="$2"
  local cache_dir="${WORK_DIR}/purl_cache"
  local cache_file="${cache_dir}/$(echo "$purl" | sha256sum | cut -d' ' -f1).json"
  
  mkdir -p "$cache_dir"
  echo "$result" > "$cache_file"
  info "PURL result cached: $purl"
}

create_npm_install_task() {
  local package_name="$1"
  local package_version="$2"
  local correlation_id="$3"
  
  local npm_task_id="npm-$(date +%s)-$(shuf -i 1000-9999 -n 1)"
  local npm_task_json=$(jq -n \
    --arg id "$npm_task_id" \
    --arg type "npm_install" \
    --arg correlation_id "$correlation_id" \
    --arg package_name "$package_name" \
    --arg package_version "$package_version" \
    '{
      id: $id,
      type: $type,
      correlation_id: $correlation_id,
      payload: {
        package_name: $package_name,
        package_version: $package_version
      },
      timestamp: now
    }')
  
  info "Creating npm_install task for: ${package_name}@${package_version}"
  
  # Publish to NATS tasks.input queue
  if command -v nats >/dev/null 2>&1; then
    local nats_subject="${NATS_INPUT_SUBJECT:-tasks.input}"
    if nats pub "$nats_subject" "$npm_task_json"; then
      info "NPM install task published to NATS subject: ${nats_subject}"
      return 0
    else
      warning "Failed to publish NPM install task to NATS"
      return 1
    fi
  else
    warning "NATS CLI not available, cannot publish NPM install task"
    return 1
  fi
}

execute_purl_task() {
  local purl=$(echo "$TASK_JSON" | jq -r '.payload.purl // empty')
  local nocache=$(echo "$TASK_JSON" | jq -r '.payload.nocache // false')
  
  if [[ -z "$purl" ]]; then
    error "No PURL specified in payload"
    return 1
  fi
  
  info "Processing PURL: $purl"
  if [[ "$nocache" == "true" ]]; then
    info "Cache bypass requested (nocache=true)"
  fi
  
  # Parse the PURL
  if ! parse_purl "$purl"; then
    generate_task_result "failed" "purl_parse_error" "{\"error\": \"Invalid PURL format: $purl\"}"
    return 1
  fi
  
  # Check cache first (unless nocache is true)
  if [[ "$nocache" != "true" ]] && cached_result=$(check_purl_cache "$purl"); then
    info "Returning cached result for PURL: $purl"
    generate_task_result "success" "purl_cached" "$cached_result"
    return 0
  elif [[ "$nocache" == "true" ]]; then
    info "Skipping cache lookup due to nocache flag"
  fi
  
  # For npm packages, create an npm_install task
  if [[ "$PURL_TYPE" == "npm" ]]; then
    if create_npm_install_task "$PURL_NAME" "$PURL_VERSION" "$CORRELATION_ID"; then
      local result_data=$(jq -n \
        --arg purl "$purl" \
        --arg action "npm_install_queued" \
        --arg package_name "$PURL_NAME" \
        --arg package_version "$PURL_VERSION" \
        '{
          purl: $purl,
          action: $action,
          package_name: $package_name,
          package_version: $package_version,
          status: "queued_for_analysis"
        }')
      
      # Cache the queued status
      cache_purl_result "$purl" "$result_data"
      
      generate_task_result "success" "purl_queued" "$result_data"
      return 0
    else
      generate_task_result "failed" "purl_queue_error" "{\"error\": \"Failed to queue npm install task for PURL: $purl\"}"
      return 1
    fi
  else
    # For non-npm packages, return not supported for now
    local result_data=$(jq -n \
      --arg purl "$purl" \
      --arg purl_type "$PURL_TYPE" \
      '{
        purl: $purl,
        purl_type: $purl_type,
        status: "not_supported",
        message: "Only npm PURLs are currently supported"
      }')
    
    generate_task_result "success" "purl_not_supported" "$result_data"
    return 0
  fi
}

process_task() {
  case "${TASK_TYPE}" in
    "purl_check")
      if execute_purl_task; then
        success "PURL task completed successfully"
        # Task result already generated by execute_purl_task()
      else
        warning "PURL task failed"
        generate_task_result "failed" "purl_check_failed" "{\"error\": \"PURL processing failed\"}"
        return 1
      fi
      ;;
    "npm_install")
      if execute_npm_task; then
        success "NPM task completed successfully"
        # Task result already generated by analyze_npm_installation()
      else
        warning "NPM task failed"
        generate_task_result "failed" "npm_install_failed" "{\"error\": \"Package installation failed\"}"
        return 1
      fi
      ;;
    "data_processing")
      execute_data_processing_task
      ;;
    "ml_training")
      info "ML training task not implemented yet"
      generate_task_result "failed" "not_implemented" "{\"error\": \"Task type not implemented: ${TASK_TYPE}\"}"
      return 1
      ;;
    *)
      warning "Unknown task type: ${TASK_TYPE}"
      generate_task_result "failed" "unknown_task_type" "{\"error\": \"Unknown task type: ${TASK_TYPE}\"}"
      return 1
      ;;
  esac
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

main "${@}"
