#!/usr/bin/env bash
# slaws-live-lab.sh — run the D13 live collector lab against real AWS or prove configuration.
#
# Usage:
#   scripts/slaws-live-lab.sh [OPTIONS]
#
# Options:
#   --profile PROFILE    AWS CLI profile to use (default: $AWS_PROFILE)
#   --region REGION      AWS region (default: $AWS_REGION or us-east-1)
#   --dry-run            Validate configuration without applying or running signal-ingest
#   --apply              Apply terraform without running signal-ingest
#   --destroy            Destroy lab infrastructure and exit
#   --keep               Keep lab resources up after running (default: destroy on exit)
#   -h, --help           Show this help

set -euo pipefail
ZSH_VERSION=${ZSH_VERSION:-}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$ROOT/infra/aws/slaws-lab"

PROFILE="${AWS_PROFILE:-}"
REGION="${AWS_REGION:-us-east-1}"
DRY_RUN=false
APPLY_ONLY=false
DESTROY_ONLY=false
KEEP=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      PROFILE="${2:?--profile requires an argument}"
      shift 2
      ;;
    --region)
      REGION="${2:?--region requires an argument}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --apply)
      APPLY_ONLY=true
      shift
      ;;
    --destroy)
      DESTROY_ONLY=true
      shift
      ;;
    --keep)
      KEEP=true
      shift
      ;;
    -h|--help)
      cat <<'EOF'
Usage:
  scripts/slaws-live-lab.sh [OPTIONS]

Options:
  --profile PROFILE    AWS CLI profile to use (default: $AWS_PROFILE)
  --region REGION      AWS region (default: $AWS_REGION or us-east-1)
  --dry-run            Validate configuration without applying or running signal-ingest
  --apply              Apply terraform without running signal-ingest
  --destroy            Destroy lab infrastructure and exit
  --keep               Keep lab resources up after running (default: destroy on exit)
  -h, --help           Show this help
EOF
      exit 0
      ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      echo "Run 'scripts/slaws-live-lab.sh --help' for usage." >&2
      exit 2
      ;;
  esac
done

if [ "$DRY_RUN" = true ]; then
  echo "=== SLAWS Live Lab Dry Run ==="
  echo "Validating Terraform configuration in $TF_DIR..."
  # validate needs the providers from .terraform/; a fresh checkout has none, so
  # initialise without a backend first (served from TF_PLUGIN_CACHE_DIR when set).
  if [ ! -d "$TF_DIR/.terraform/providers" ]; then
    terraform -chdir="$TF_DIR" init -backend=false -input=false -no-color >/dev/null
  fi
  terraform -chdir="$TF_DIR" validate
  echo "dry-run: Terraform configuration in $TF_DIR is valid (region=$REGION)."
  exit 0
fi

# Credential Gate (D13 requirement)
AWS_ARGS=()
if [ -n "$PROFILE" ]; then
  AWS_ARGS+=(--profile "$PROFILE")
fi
if [ -n "$REGION" ]; then
  AWS_ARGS+=(--region "$REGION")
fi

if ! aws "${AWS_ARGS[@]}" sts get-caller-identity >/dev/null 2>&1; then
  echo "ERROR: AWS credentials are missing, expired, or invalid." >&2
  echo "Refusing live lab execution without verified credentials." >&2
  echo "To run the live lab with an active AWS profile:" >&2
  echo "  AWS_PROFILE=${PROFILE:-<profile>} scripts/slaws-live-lab.sh --region ${REGION}" >&2
  exit 3
fi

if [ "$DESTROY_ONLY" = true ]; then
  echo "Destroying SLAWS live lab resources in $TF_DIR..."
  terraform -chdir="$TF_DIR" destroy -auto-approve -var="region=$REGION"
  echo "Lab resources destroyed."
  exit 0
fi

TMP_DIR="$(mktemp -d)"
CLEANED_UP=false

cleanup() {
  if [ "$CLEANED_UP" = true ]; then
    return
  fi
  CLEANED_UP=true
  if [ -n "${INGEST_PID:-}" ] && kill -0 "$INGEST_PID" 2>/dev/null; then
    echo "Stopping signal-ingest (PID $INGEST_PID)..."
    kill "$INGEST_PID" 2>/dev/null || true
    wait "$INGEST_PID" 2>/dev/null || true
  fi
  if [ "$KEEP" = false ]; then
    echo "Tearing down lab resources in $TF_DIR..."
    terraform -chdir="$TF_DIR" destroy -auto-approve -var="region=$REGION" >/dev/null 2>&1 || true
  else
    echo "Lab resources kept (--keep active)."
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

echo "=== SLAWS Live Lab Provisioning ==="
terraform -chdir="$TF_DIR" apply -auto-approve -var="region=$REGION"

TF_OUT="$(terraform -chdir="$TF_DIR" output -json)"
ROLE_ARN="$(echo "$TF_OUT" | jq -r .role_arn.value)"
QUEUE_URL="$(echo "$TF_OUT" | jq -r .queue_url.value)"
BUCKET="$(echo "$TF_OUT" | jq -r .bucket.value)"
EXT_ID="$(echo "$TF_OUT" | jq -r .external_id.value)"
OUT_REGION="$(echo "$TF_OUT" | jq -r .region.value)"

echo "Lab resources ready:"
echo "  Role ARN:    $ROLE_ARN"
echo "  Queue URL:   $QUEUE_URL"
echo "  S3 Bucket:   $BUCKET"
echo "  Region:      $OUT_REGION"
echo "  External ID: $EXT_ID"

if [ "$APPLY_ONLY" = true ]; then
  echo "Apply complete (--apply active). Exiting."
  exit 0
fi

echo "=== Building signal-ingest ==="
export GOCACHE="${GOCACHE:-/tmp/gocache}"
export GOMODCACHE="${GOMODCACHE:-/tmp/gomodcache}"
mkdir -p "$GOCACHE" "$GOMODCACHE"

(
  cd "$ROOT/d2-signalloom/apps/signal-ingest"
  CGO_ENABLED=0 go build -tags frostdb -o "$TMP_DIR/signal-ingest" .
)

READER_KEY="sk_live_$(openssl rand -hex 16)"
PSEUDO_KEY="$(openssl rand -hex 32)"
STATIC_KEYS_CONFIG="{\"keys\":[{\"id\":\"lab-reader\",\"key\":\"${READER_KEY}\",\"tenant\":\"kusari\",\"scopes\":[\"observations:read\"]}]}"
PORT=28095

echo "Starting signal-ingest on port $PORT..."
STORE_DIR="$TMP_DIR/store"
mkdir -p "$STORE_DIR"

COLLECTOR_AWSLOGS_MODE=live \
AWSLOGS_TENANT_ID=kusari \
AWSLOGS_ROLE_ARN="$ROLE_ARN" \
AWSLOGS_EXTERNAL_ID="$EXT_ID" \
AWSLOGS_QUEUE_URL="$QUEUE_URL" \
AWSLOGS_REGION="$OUT_REGION" \
SIGNAL_STORE=frostdb \
SIGNAL_STORE_DIR="$STORE_DIR" \
SIGNAL_SEGMENT_PSEUDONYM_KEY="$PSEUDO_KEY" \
SIGNAL_SEGMENT_PSEUDONYM_EPOCH=1 \
SIGNAL_SEGMENT_PSEUDONYM_TENANT=kusari \
SIGNAL_AUTH_STATIC_KEYS="$STATIC_KEYS_CONFIG" \
SIGNAL_AUDIT_FILE="$TMP_DIR/audit.log" \
POLICY_BUNDLES_DIR="$ROOT/policy/bundles" \
PORT="$PORT" \
"$TMP_DIR/signal-ingest" > "$TMP_DIR/ingest.log" 2>&1 &
INGEST_PID=$!

echo "signal-ingest started with PID $INGEST_PID. Polling observations..."

MAX_ATTEMPTS=30
FOUND=false
for i in $(seq 1 $MAX_ATTEMPTS); do
  if ! kill -0 "$INGEST_PID" 2>/dev/null; then
    echo "ERROR: signal-ingest died unexpectedly:" >&2
    cat "$TMP_DIR/ingest.log" >&2
    exit 1
  fi

  HTTP_RESP="$(curl -s -H "Authorization: Bearer $READER_KEY" "http://127.0.0.1:$PORT/api/v1/observations" || true)"
  if [ -n "$HTTP_RESP" ] && echo "$HTTP_RESP" | jq -e '.observations | length > 0' >/dev/null 2>&1; then
    COUNT="$(echo "$HTTP_RESP" | jq '.observations | length')"
    # Check that rows have labels.provider=aws and raw_evidence_ref prefixed s3://<bucket>/
    AWS_COUNT="$(echo "$HTTP_RESP" | jq --arg b "s3://$BUCKET/" '[.observations[] | select(.labels.provider == "aws" and (.raw_evidence_ref | startswith($b)))] | length')"
    if [ "$AWS_COUNT" -gt 0 ]; then
      echo "Found $AWS_COUNT projected AWS observations from s3://$BUCKET/ (total: $COUNT observations)."
      FOUND=true
      break
    fi
  fi
  sleep 2
done

if [ "$FOUND" = false ]; then
  echo "ERROR: Timed out waiting for projected observations." >&2
  cat "$TMP_DIR/ingest.log" >&2
  exit 1
fi

echo "=== Verifying SQS Queue Drained ==="
ATTRS="$(aws "${AWS_ARGS[@]}" sqs get-queue-attributes --queue-url "$QUEUE_URL" --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible)"
VISIBLE="$(echo "$ATTRS" | jq -r '.Attributes.ApproximateNumberOfMessages // "0"')"
NOT_VISIBLE="$(echo "$ATTRS" | jq -r '.Attributes.ApproximateNumberOfMessagesNotVisible // "0"')"

echo "Queue attributes: visible=$VISIBLE in-flight=$NOT_VISIBLE"
if [ "$VISIBLE" != "0" ] || [ "$NOT_VISIBLE" != "0" ]; then
  echo "ERROR: Queue was not fully acknowledged and drained." >&2
  exit 1
fi

echo "=== SLAWS Live Lab Verification PASSED ==="
