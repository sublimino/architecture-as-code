#!/bin/bash
set -euo pipefail

# Configuration
NATS_URL="${NATS_URL:-nats://nats.backend.svc.cluster.local:4222}"
SUBJECT="${SUBJECT:-tasks.input}"
STREAM_NAME="${STREAM_NAME:-TASKS}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to generate correlation ID
generate_correlation_id() {
    echo "task_$(date +%s)_$(shuf -i 1000-9999 -n 1)"
}

# Function to generate task ID
generate_task_id() {
    echo "$(uuidgen 2>/dev/null || echo "task_$(date +%s%N)")"
}

# Function to check if NATS is available
check_nats_connection() {
    log_info "Checking NATS connection..."
    if nats --server="$NATS_URL" server ping >/dev/null 2>&1; then
        log_success "NATS server is reachable"
        return 0
    else
        log_error "Cannot reach NATS server at $NATS_URL"
        return 1
    fi
}

# Function to ensure JetStream is enabled
ensure_jetstream() {
    log_info "Checking JetStream availability..."
    if nats --server="$NATS_URL" stream list >/dev/null 2>&1; then
        log_success "JetStream is available"
    else
        log_error "JetStream is not available or not enabled"
        exit 1
    fi
}

# Function to create or verify stream exists
setup_stream() {
    log_info "Setting up stream: $STREAM_NAME"

    # Check if stream exists
    if nats --server="$NATS_URL" stream info "$STREAM_NAME" >/dev/null 2>&1; then
        log_success "Stream $STREAM_NAME already exists"
    else
        log_info "Creating stream $STREAM_NAME..."
        nats --server="$NATS_URL" stream create "$STREAM_NAME" \
            --subjects="tasks.*" \
            --storage=memory \
            --retention=limits \
            --max-age=1h \
            --replicas=1 \
            --discard=old
        log_success "Stream $STREAM_NAME created"
    fi
}

# Function to publish a single message
publish_message() {
    local task_type="$1"
    local payload="$2"
    local correlation_id="${3:-$(generate_correlation_id)}"

    local task_id=$(generate_task_id)
    local timestamp=$(date +%s)

    # Build JSON message
    local message=$(cat <<EOF
{
  "id": "$task_id",
  "type": "$task_type",
  "correlation_id": "$correlation_id",
  "timestamp": $timestamp,
  "payload": $payload
}
EOF
)

    log_info "Publishing message with ID: $task_id"
    log_info "Correlation ID: $correlation_id"
    log_info "Task Type: $task_type"

    # Publish to NATS JetStream
    if echo "$message" | nats --server="$NATS_URL" pub "$SUBJECT" --wait; then
        log_success "Message published successfully"
        echo "$correlation_id"  # Return correlation ID for tracking
    else
        log_error "Failed to publish message"
        return 1
    fi
}

# Function to publish test message
publish_test_message() {
    local test_payload='{"action": "process_data", "data": {"input": "test-input-123", "config": {"timeout": 30, "retries": 3}}}'
    publish_message "data_processing" "$test_payload"
}

# Function to publish batch of messages
publish_batch() {
    local count="$1"
    local task_type="$2"
    local base_payload="$3"

    log_info "Publishing batch of $count messages..."

    local correlation_id=$(generate_correlation_id)

    for ((i=1; i<=count; i++)); do
        # Modify payload with batch info
        local payload=$(echo "$base_payload" | jq --arg batch_id "$correlation_id" --arg item_num "$i" \
            '. + {"batch_id": $batch_id, "item_number": ($item_num | tonumber)}')

        echo -n "[$i/$count] "
        publish_message "$task_type" "$payload" "$correlation_id"

        # Small delay between messages
        sleep 0.1
    done

    log_success "Batch publishing completed. Correlation ID: $correlation_id"
}

# Function to monitor stream
monitor_stream() {
    log_info "Monitoring stream $STREAM_NAME..."
    nats --server="$NATS_URL" stream info "$STREAM_NAME" --json | jq '{
        name: .config.name,
        messages: .state.messages,
        bytes: .state.bytes,
        first_seq: .state.first_seq,
        last_seq: .state.last_seq,
        consumers: .state.consumer_count
    }'
}

# Function to show usage
show_usage() {
    cat << EOF
Usage: $0 [COMMAND] [OPTIONS]

Commands:
    test                    Publish a single test message
    single <type> <json>    Publish a single message with custom type and payload
    batch <count> <type> <json>  Publish a batch of messages
    monitor                 Show stream information
    setup                   Setup stream and verify connection

Examples:
    $0 test
    $0 single "ml_training" '{"model": "bert", "dataset": "imdb"}'
    $0 batch 5 "data_processing" '{"input": "sample", "config": {}}'
    $0 monitor
    $0 setup

Environment Variables:
    NATS_URL      NATS server URL (default: nats://nats.backend.svc.cluster.local:4222)
    SUBJECT       Subject to publish to (default: tasks.input)
    STREAM_NAME   JetStream stream name (default: TASKS)

EOF
}

# Main script logic
main() {
    # Check dependencies
    if ! command -v nats >/dev/null 2>&1; then
        log_error "nats CLI tool is required. Install from: https://github.com/nats-io/natscli"
        exit 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        log_error "jq is required for JSON processing"
        exit 1
    fi

    local command="${1:-}"

    case "$command" in
        "test")
            check_nats_connection || exit 1
            ensure_jetstream
            setup_stream
            publish_test_message
            ;;
        "single")
            if [[ $# -ne 3 ]]; then
                log_error "Usage: $0 single <type> <json_payload>"
                exit 1
            fi
            check_nats_connection || exit 1
            ensure_jetstream
            setup_stream
            publish_message "$2" "$3"
            ;;
        "batch")
            if [[ $# -ne 4 ]]; then
                log_error "Usage: $0 batch <count> <type> <json_payload>"
                exit 1
            fi
            check_nats_connection || exit 1
            ensure_jetstream
            setup_stream
            publish_batch "$2" "$3" "$4"
            ;;
        "monitor")
            check_nats_connection || exit 1
            monitor_stream
            ;;
        "setup")
            check_nats_connection || exit 1
            ensure_jetstream
            setup_stream
            log_success "Setup completed successfully"
            ;;
        "help"|"--help"|"-h"|"")
            show_usage
            ;;
        *)
            log_error "Unknown command: $command"
            show_usage
            exit 1
            ;;
    esac
}

# Run main function with all arguments
main "$@"
