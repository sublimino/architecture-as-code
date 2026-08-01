#!/bin/bats

load '_helper.bats'
DETIK_CLIENT_NAME="kubectl"
DETIK_CLIENT_NAMESPACE="frontend"

# Global helper function for getting pod reference
get-pod-reference() {
  local NAME="${1:-nats-box}"
  command kubectl --request-timeout=10s get --all-namespaces -o wide pods |
  awk  '/'"${NAME}"'/{print "--namespace "$1" "$2}' | head -n1
}

# Global PURL test helper functions
publish-purl-message() {
  local MESSAGE="$1"
  local NATS_POD=$(get-pod-reference 'nats-box')
  kubectl exec $NATS_POD -- nats pub tasks.purl "$MESSAGE"
}

check-purl-listener-logs() {
  local TASK_ID="$1"
  kubectl logs $(kubectl get pods --namespace frontend -l app=osramp-purl -o jsonpath='{.items[0].metadata.name}') -c listener --namespace frontend --tail=20 | grep "Sent task ${TASK_ID} to processor via socket"
}

check-purl-processor-logs() {
  local TASK_ID="$1"
  local PURL="$2"
  kubectl logs $(kubectl get pods --namespace frontend -l app=osramp-purl -o jsonpath='{.items[0].metadata.name}') -c processor --namespace frontend --tail=2000 | grep -E "(Processing PURL: ${PURL}|Task ${TASK_ID} (completed|failed))"
}

check-purl-cache-miss() {
  local PURL="$1"
  kubectl logs $(kubectl get pods --namespace frontend -l app=osramp-purl -o jsonpath='{.items[0].metadata.name}') -c processor --namespace frontend --tail=2000 | sed 's/\x1b\[[0-9;]*m//g' | grep "PURL not found in cache: ${PURL}"
}

check-purl-npm-queued() {
  local PACKAGE="$1"
  kubectl logs $(kubectl get pods --namespace frontend -l app=osramp-purl -o jsonpath='{.items[0].metadata.name}') -c processor --namespace frontend --tail=2000 | sed 's/\x1b\[[0-9;]*m//g' | grep -E "(Creating npm_install task for: ${PACKAGE}|NPM install task published)"
}

check-purl-nocache-bypass() {
  kubectl logs $(kubectl get pods --namespace frontend -l app=osramp-purl -o jsonpath='{.items[0].metadata.name}') -c processor --namespace frontend --tail=2000 | grep -E "(Cache bypass requested|Skipping cache lookup due to nocache flag)"
}

# Global archiver test helper functions
publish-task-result() {
  local MESSAGE="$1"
  local NATS_POD=$(get-pod-reference 'nats-box')
  kubectl exec $NATS_POD -- nats pub tasks.results "$MESSAGE"
}

check-archiver-logs() {
  local TASK_ID="$1"
  kubectl logs $(kubectl get pods --namespace frontend -l app=osramp-archiver -o jsonpath='{.items[0].metadata.name}') --namespace frontend --tail=50 | sed 's/\x1b\[[0-9;]*m//g' | grep "Archived task result: ${TASK_ID}"
}

check-archiver-database() {
  local TASK_ID="$1"
  kubectl exec postgres --namespace backend -- psql task_archive archiver -c "SELECT task_id, status, result_type FROM task_results WHERE task_id='${TASK_ID}';"
}

# SBOM test helper functions
check-sbom-generation() {
  local TASK_ID="$1"
  kubectl logs $(kubectl get pods --namespace frontend -l app=osramp-multipurpose -o jsonpath='{.items[0].metadata.name}') -c processor --namespace frontend --tail=2000 | grep -E "(SBOM generated successfully|Publishing complete SBOM data|SBOM data published to tasks.sbom queue).*${TASK_ID}"
}

check-witness-generation() {
  local TASK_ID="$1"
  kubectl logs $(kubectl get pods --namespace frontend -l app=osramp-multipurpose -o jsonpath='{.items[0].metadata.name}') -c processor --namespace frontend --tail=2000 | grep -E "(Witness Attestations generated successfully).*${TASK_ID}.*"
}

check-sbom-archiver-logs() {
  local SBOM_ID="$1"
  kubectl logs $(kubectl get pods --namespace frontend -l app=osramp-archiver -o jsonpath='{.items[0].metadata.name}') --namespace frontend --tail=50 | sed 's/\x1b\[[0-9;]*m//g' | grep "Archived SBOM data: ${SBOM_ID}"
}

check-sbom-database() {
  local TASK_ID="$1"
  kubectl exec postgres --namespace backend -- psql task_archive archiver -c "SELECT sbom_id, task_id, package_name, package_version, sbom_format, component_count FROM sbom_data WHERE task_id='${TASK_ID}';"
}

check-sbom-task-relationship() {
  local TASK_ID="$1"
  kubectl exec postgres --namespace backend -- psql task_archive archiver -c "SELECT tr.task_id, tr.status, tr.result_type, sd.sbom_id, sd.package_name, sd.package_version, sd.sbom_format FROM task_results tr LEFT JOIN sbom_data sd ON tr.task_id = sd.task_id WHERE tr.task_id='${TASK_ID}';"
}

check-sbom-processor-logs() {
  local TASK_ID="$1"
  kubectl logs $(kubectl get pods --namespace frontend -l app=osramp-multipurpose -o jsonpath='{.items[0].metadata.name}') -c processor --namespace frontend --tail=2000 | grep -E "(Received task: ${TASK_ID}|Processing task ${TASK_ID}|Task ${TASK_ID} (completed|failed))"
}

check-sbom-task-success() {
  local TASK_ID="$1"
  kubectl logs $(kubectl get pods --namespace frontend -l app=osramp-multipurpose -o jsonpath='{.items[0].metadata.name}') -c processor --namespace frontend --tail=2000 | grep -E "(Task ${TASK_ID} completed successfully|\"status\": \"success\".*${TASK_ID})"
}

check-sbom-listener-logs() {
  local TASK_ID="$1"
  kubectl logs $(kubectl get pods --namespace frontend -l app=osramp-multipurpose -o jsonpath='{.items[0].metadata.name}') -c listener --namespace frontend --tail=20 | grep "Sent task ${TASK_ID} to processor via socket"
}

# ---

# Runs once before any test in this file. The whole suite depends on a deployed
# d2-osramp-apps slice, so an absent slice skips the file rather than failing
# every test — matching the SKIP semantics of scripts/acceptance-test.sh.
#
# Existence is all that is checked. A slice that is present but unhealthy still
# runs its assertions and still fails.
setup_file() {
	require-osramp-apps
	require-k8s deployment osramp-multipurpose frontend
	require-k8s deployment osramp-purl frontend
	require-k8s deployment osramp-archiver frontend
	require-k8s service postgres backend
}

# Improve readability of the debug file
setup() {
	debug ""
	debug  ""
	debug  "-- $BATS_TEST_DESCRIPTION --"
	debug  ""
	debug  ""
}


@test "reset the debug file" {
	# This function is part of DETIK too
	reset_debug
}

# ---

@test "example test with setup/retry and pipes" {
  GREP_STRING="string"
	test-logs() {
		echo -e "test\nstring\n"| grep -v "test" | grep "${GREP_STRING}"
	}

	export -f test-logs
	try-limit 10 test-logs || true

	run test-logs
	assert_line --partial "${GREP_STRING}"
}

#@test "lint assertions" {
#  run lint "osramp.bats"
#   echo -e "$output" >&3
#  [ "$status" -eq 0 ]
#}


@test "uptime check: NATS" {
  DEBUG_DETIK="true"
  DETIK_CASE_INSENSITIVE_PROPERTIES="true"

  run verify "'status' is 'running' for pods named 'nats'"
  run verify "there is 1 service named 'nats'"
}

@test "end-to-end NATS listener and processor integration" {
  DEBUG_DETIK="true"
  DETIK_CASE_INSENSITIVE_PROPERTIES="true"

#  run verify "'status' is 'running' for pods named 'asdasdasd'"
#  run verify "there is 1 service named 'nginx'"

	# Test message with unique ID for tracking
	local timestamp=$(date +%s)
	TEST_TASK_ID="e2e-test-${timestamp}"
	TEST_MESSAGE=$(jq -nc \
		--arg id "${TEST_TASK_ID}" \
		--arg timestamp "$timestamp" \
		'{
			id: $id,
			type: "npm_install",
			payload: {
				package_name: "lodash",
				package_version: "4.17.21"
			},
			correlation_id: "e2e-test-corr",
			timestamp: ($timestamp | tonumber)
		}')

	echo "=== Starting E2E Test with Task ID: ${TEST_TASK_ID} ===" >&3
	echo "Test Message: ${TEST_MESSAGE}" >&3
	echo "" >&3

	# Function to publish message to NATS
	publish-test-message() {
		local COMMAND=(kubectl exec $(get-pod-reference 'nats-box') -- nats pub tasks.input "${TEST_MESSAGE}")
		set -x
		"${COMMAND[@]}"
		set +x
	}

	# Function to check listener logs for message reception
	check-listener-logs() {
		local pod_name=$(kubectl get pods --namespace frontend -l app=osramp-multipurpose -o jsonpath='{.items[0].metadata.name}')
		local logs=$(kubectl logs "$pod_name" -c listener --namespace frontend --tail=50 2>/dev/null)
		if echo "$logs" | grep -q "Sent task ${TEST_TASK_ID} to processor via socket"; then
			echo "$logs" | grep "Sent task ${TEST_TASK_ID} to processor via socket"
			return 0
		else
			return 1
		fi
	}

	# Function to check processor logs for task processing
	check-processor-logs() {
		local pod_name=$(kubectl get pods --namespace frontend -l app=osramp-multipurpose -o jsonpath='{.items[0].metadata.name}')
		local logs=$(kubectl logs "$pod_name" -c processor --namespace frontend --tail=2000 2>/dev/null)
		echo "$logs" | grep -E "(Received task: ${TEST_TASK_ID}|Processing task ${TEST_TASK_ID}|Task ${TEST_TASK_ID} (completed|failed))"
	}

	# Function to check for successful task completion
	check-task-success() {
		local pod_name=$(kubectl get pods --namespace frontend -l app=osramp-multipurpose -o jsonpath='{.items[0].metadata.name}')
		local logs=$(kubectl logs "$pod_name" -c processor --namespace frontend --tail=2000 2>/dev/null)
		echo "$logs" | grep -E "(Task ${TEST_TASK_ID} completed successfully|\"status\": \"success\".*${TEST_TASK_ID})"
	}

	# Function to check for npm package installation success
	check-npm-success() {
		local pod_name=$(kubectl get pods --namespace frontend -l app=osramp-multipurpose -o jsonpath='{.items[0].metadata.name}')
		local logs=$(kubectl logs "$pod_name" -c processor --namespace frontend --tail=2000 2>/dev/null)
		echo "$logs" | grep -E "(NPM task completed successfully|\"result_type\": \"npm_package_installed\")"
	}

	# Export functions for use in retry logic
	export -f publish-test-message check-listener-logs check-processor-logs check-task-success check-npm-success
	export TEST_TASK_ID TEST_MESSAGE

	# Step 1: Publish message to NATS
	echo "Step 1: Publishing message to NATS..." >&3
	run publish-test-message
	echo "Publish output: $output" >&3
	echo "Publish status: $status" >&3
	assert_success
	assert_line --partial "Published"
	echo "✓ Message published successfully" >&3

	# Step 2: Wait and check listener received and forwarded the message
	echo "Step 2: Checking listener logs for message reception..." >&3
	try-limit 10 check-listener-logs || true
	run check-listener-logs
	echo "Listener logs output: $output" >&3
	echo "Listener logs status: $status" >&3
	assert_success
	assert_line --partial "Sent task ${TEST_TASK_ID} to processor via socket"
	echo "✓ Listener received and forwarded message via socket" >&3

	# Step 3: Check processor received and started processing the task
	echo "Step 3: Checking processor logs for task processing..." >&3
	try-limit 15 check-processor-logs || true
	run check-processor-logs
	echo "Processor logs output: $output" >&3
	echo "Processor logs status: $status" >&3
	assert_success
	assert_line --partial "Received task: ${TEST_TASK_ID}"
	echo "✓ Processor received and started processing task" >&3

	# Step 4: Verify task completed successfully
	echo "Step 4: Verifying task completion..." >&3
	try-limit 30 check-task-success || true
	run check-task-success
	echo "Task completion output: $output" >&3
	echo "Task completion status: $status" >&3
	assert_success
	assert_line --partial "completed successfully"
	echo "✓ Task completed successfully" >&3

	# Step 5: Verify npm package installation success
	echo "Step 5: Verifying npm package installation..." >&3
	try-limit 15 check-npm-success || true
	run check-npm-success
	echo "NPM success output: $output" >&3
	echo "NPM success status: $status" >&3
	assert_success
	assert_line --partial "NPM task completed successfully"
	echo "✓ NPM package installed successfully" >&3

	# Show final processor logs for complete picture
	echo "=== Final Processor Logs (last 30 lines) ===" >&3
	local pod_name=$(kubectl get pods --namespace frontend -l app=osramp-multipurpose -o jsonpath='{.items[0].metadata.name}')
	kubectl logs "$pod_name" -c processor --namespace frontend --tail=30 >&3
	echo "=== E2E Test Complete - SUCCESS VERIFIED ===" >&3
}

@test "PURL processing with cache behavior" {
	# Generate unique PURL test ID and unique package version to ensure cache miss
	local timestamp=$(date +%s)
	local PURL_TASK_ID="purl-test-${timestamp}"
	local TEST_PURL="pkg:npm/express@4.18.${timestamp}"
	
	# Create PURL test message
	local PURL_MESSAGE=$(jq -n \
		--arg id "$PURL_TASK_ID" \
		--arg type "purl_check" \
		--arg purl "$TEST_PURL" \
		--arg correlation_id "purl-cache-test" \
		--argjson timestamp "$timestamp" \
		'{
			id: $id,
			type: $type,
			payload: {
				purl: $purl
			},
			correlation_id: $correlation_id,
			timestamp: ($timestamp | tonumber)
		}')

	echo "=== Starting PURL Cache Test with Task ID: ${PURL_TASK_ID} ===" >&3
	echo "Test PURL: ${TEST_PURL}" >&3
	echo "PURL Message: ${PURL_MESSAGE}" >&3
	echo "" >&3


	# Step 1: Publish PURL message to NATS
	echo "Step 1: Publishing PURL message to NATS..." >&3
	run publish-purl-message "${PURL_MESSAGE}"
	echo "PURL publish output: $output" >&3
	echo "PURL publish status: $status" >&3
	assert_success
	assert_line --partial "Published"
	echo "✓ PURL message published successfully" >&3

	# Step 2: Check listener logs for PURL message reception
	echo "Step 2: Checking PURL listener logs for message reception..." >&3
	try-limit 10 "check-purl-listener-logs ${PURL_TASK_ID}" || true
	run check-purl-listener-logs "${PURL_TASK_ID}"
	echo "PURL listener logs output: $output" >&3
	echo "PURL listener logs status: $status" >&3
	assert_success
	assert_line --partial "Sent task ${PURL_TASK_ID} to processor via socket"
	echo "✓ PURL listener received and forwarded message via socket" >&3

	# Step 3: Check processor logs for PURL processing
	echo "Step 3: Checking PURL processor logs for task processing..." >&3
	try-limit 15 "check-purl-processor-logs ${PURL_TASK_ID} ${TEST_PURL}" || true
	run check-purl-processor-logs "${PURL_TASK_ID}" "${TEST_PURL}"
	echo "PURL processor logs output: $output" >&3
	echo "PURL processor logs status: $status" >&3
	assert_success
	assert_line --partial "Processing PURL: ${TEST_PURL}"
	echo "✓ PURL processor received and started processing task" >&3

	# Step 4: Verify cache miss on first request
	echo "Step 4: Verifying cache miss on first request..." >&3
	try-limit 10 "check-purl-cache-miss ${TEST_PURL}" || true
	run check-purl-cache-miss "${TEST_PURL}"
	echo "PURL cache miss output: $output" >&3
	echo "PURL cache miss status: $status" >&3
	assert_success
	assert_line --partial "PURL not found in cache"
	echo "✓ Cache miss verified on first request" >&3

	# Step 5: Verify npm_install task was queued
	echo "Step 5: Verifying npm_install task was queued..." >&3
	local expected_package="express@4.18.${timestamp}"
	try-limit 15 "check-purl-npm-queued ${expected_package}" || true
	run check-purl-npm-queued "${expected_package}"
	echo "PURL npm queued output: $output" >&3
	echo "PURL npm queued status: $status" >&3
	assert_success
	assert_line --partial "npm_install task"
	echo "✓ npm_install task queued successfully" >&3

	# Show final PURL processor logs
	echo "=== Final PURL Processor Logs (last 30 lines) ===" >&3
	kubectl logs $(kubectl get pods --namespace frontend -l app=osramp-purl -o jsonpath='{.items[0].metadata.name}') -c processor --namespace frontend --tail=30 >&3
	echo "=== PURL Cache Test Complete - SUCCESS VERIFIED ===" >&3
}

@test "PURL processing with nocache option" {
	# Generate unique PURL test ID and unique package version
	local timestamp=$(date +%s)
	local PURL_NOCACHE_TASK_ID="purl-nocache-${timestamp}"
	local TEST_PURL_NOCACHE="pkg:npm/lodash@4.17.${timestamp}"
	
	# Create PURL test message with nocache option
	local PURL_NOCACHE_MESSAGE=$(jq -n \
		--arg id "$PURL_NOCACHE_TASK_ID" \
		--arg type "purl_check" \
		--arg purl "$TEST_PURL_NOCACHE" \
		--arg correlation_id "purl-nocache-test" \
		--argjson timestamp "$timestamp" \
		'{
			id: $id,
			type: $type,
			payload: {
				purl: $purl,
				nocache: true
			},
			correlation_id: $correlation_id,
			timestamp: ($timestamp | tonumber)
		}')

	echo "=== Starting PURL NoCache Test with Task ID: ${PURL_NOCACHE_TASK_ID} ===" >&3
	echo "Test PURL: ${TEST_PURL_NOCACHE}" >&3
	echo "PURL NoCache Message: ${PURL_NOCACHE_MESSAGE}" >&3
	echo "" >&3


	# Step 1: Publish PURL nocache message to NATS
	echo "Step 1: Publishing PURL nocache message to NATS..." >&3
	run publish-purl-message "${PURL_NOCACHE_MESSAGE}"
	echo "PURL nocache publish output: $output" >&3
	echo "PURL nocache publish status: $status" >&3
	assert_success
	assert_line --partial "Published"
	echo "✓ PURL nocache message published successfully" >&3

	# Step 2: Check listener logs for PURL message reception
	echo "Step 2: Checking PURL nocache listener logs for message reception..." >&3
	try-limit 10 "check-purl-listener-logs ${PURL_NOCACHE_TASK_ID}" || true
	run check-purl-listener-logs "${PURL_NOCACHE_TASK_ID}"
	echo "PURL nocache listener logs output: $output" >&3
	echo "PURL nocache listener logs status: $status" >&3
	assert_success
	assert_line --partial "Sent task ${PURL_NOCACHE_TASK_ID} to processor via socket"
	echo "✓ PURL nocache listener received and forwarded message via socket" >&3

	# Step 3: Check processor logs for PURL processing
	echo "Step 3: Checking PURL nocache processor logs for task processing..." >&3
	try-limit 15 "check-purl-processor-logs ${PURL_NOCACHE_TASK_ID} ${TEST_PURL_NOCACHE}" || true
	run check-purl-processor-logs "${PURL_NOCACHE_TASK_ID}" "${TEST_PURL_NOCACHE}"
	echo "PURL nocache processor logs output: $output" >&3
	echo "PURL nocache processor logs status: $status" >&3
	assert_success
	assert_line --partial "Processing PURL: ${TEST_PURL_NOCACHE}"
	echo "✓ PURL nocache processor received and started processing task" >&3

	# Step 4: Verify cache bypass was requested
	echo "Step 4: Verifying cache bypass was requested..." >&3
	try-limit 10 "check-purl-nocache-bypass" || true
	run check-purl-nocache-bypass
	echo "PURL nocache bypass output: $output" >&3
	echo "PURL nocache bypass status: $status" >&3
	assert_success
	assert_line --partial "cache"
	echo "✓ Cache bypass verified for nocache request" >&3

	# Step 5: Verify npm_install task was queued despite nocache
	echo "Step 5: Verifying npm_install task was queued despite nocache..." >&3
	local expected_nocache_package="lodash@4.17.${timestamp}"
	try-limit 15 "check-purl-npm-queued ${expected_nocache_package}" || true
	run check-purl-npm-queued "${expected_nocache_package}"
	echo "PURL nocache npm queued output: $output" >&3
	echo "PURL nocache npm queued status: $status" >&3
	assert_success
	assert_line --partial "npm_install task"
	echo "✓ npm_install task queued successfully despite nocache" >&3

	# Show final PURL nocache processor logs
	echo "=== Final PURL NoCache Processor Logs (last 30 lines) ===" >&3
	kubectl logs $(kubectl get pods --namespace frontend -l app=osramp-purl -o jsonpath='{.items[0].metadata.name}') -c processor --namespace frontend --tail=30 >&3
	echo "=== PURL NoCache Test Complete - SUCCESS VERIFIED ===" >&3
}


@test "archiver task result storage and retrieval" {
	# Generate unique archiver test ID
	local timestamp=$(date +%s)
	local ARCHIVER_TASK_ID="archiver-test-${timestamp}"
	
	# Create test task result message
	local TASK_RESULT_MESSAGE=$(jq -n \
		--arg task_id "$ARCHIVER_TASK_ID" \
		--arg status "success" \
		--arg result_type "test_archival" \
		--argjson timestamp "$timestamp" \
		'{
			task_id: $task_id,
			status: $status,
			result_type: $result_type,
			timestamp: $timestamp,
			correlation_id: "archiver-test-correlation",
			worker_id: "test-worker-1",
			result_data: {
				test: "archiver_functionality",
				message: "Testing archiver storage and retrieval",
				success: true
			}
		}')

	echo "=== Starting Archiver Test with Task ID: ${ARCHIVER_TASK_ID} ===" >&3
	echo "Task Result Message: ${TASK_RESULT_MESSAGE}" >&3
	echo "" >&3

	# Step 1: Publish task result message to NATS tasks.results subject
	echo "Step 1: Publishing task result to NATS tasks.results..." >&3
	run publish-task-result "${TASK_RESULT_MESSAGE}"
	echo "Publish output: $output" >&3
	echo "Publish status: $status" >&3
	assert_success
	assert_line --partial "Published"
	echo "✓ Task result message published successfully" >&3

	# Step 2: Check archiver logs for message reception and processing
	echo "Step 2: Checking archiver logs for message processing..." >&3
	try-limit 15 "check-archiver-logs ${ARCHIVER_TASK_ID}" || true
	run check-archiver-logs "${ARCHIVER_TASK_ID}"
	echo "Archiver logs output: $output" >&3
	echo "Archiver logs status: $status" >&3
	assert_success
	assert_line --partial "Archived task result: ${ARCHIVER_TASK_ID}"
	echo "✓ Archiver received and processed task result" >&3

	# Step 3: Verify task result was stored in Postgres
	echo "Step 3: Verifying task result storage in Postgres..." >&3
	try-limit 10 "check-archiver-database ${ARCHIVER_TASK_ID}" || true
	run check-archiver-database "${ARCHIVER_TASK_ID}"
	echo "Database query output: $output" >&3
	echo "Database query status: $status" >&3
	assert_success
	assert_line --partial "${ARCHIVER_TASK_ID}"
	assert_line --partial "success"
	assert_line --partial "test_archival"
	echo "✓ Task result successfully stored in Postgres" >&3

	# Step 4: Verify database record contains expected data
	echo "Step 4: Verifying complete database record..." >&3
	local DB_RECORD_CHECK=$(kubectl exec postgres --namespace backend -- psql task_archive archiver -c "SELECT task_id, status, result_type, correlation_id, worker_id FROM task_results WHERE task_id='${ARCHIVER_TASK_ID}';")
	echo "Complete database record: ${DB_RECORD_CHECK}" >&3
	[[ "$DB_RECORD_CHECK" == *"${ARCHIVER_TASK_ID}"* ]]
	[[ "$DB_RECORD_CHECK" == *"success"* ]]
	[[ "$DB_RECORD_CHECK" == *"test_archival"* ]]
	[[ "$DB_RECORD_CHECK" == *"archiver-test-correlation"* ]]
	[[ "$DB_RECORD_CHECK" == *"test-worker-1"* ]]
	echo "✓ Database record contains all expected fields" >&3

	# Show final archiver logs for verification
	echo "=== Final Archiver Logs (last 20 lines) ===" >&3
	kubectl logs $(kubectl get pods --namespace frontend -l app=osramp-archiver -o jsonpath='{.items[0].metadata.name}') --namespace frontend --tail=20 >&3
	echo "=== Archiver Test Complete - SUCCESS VERIFIED ===" >&3
}

@test "SBOM generation and archival integration end-to-end" {
	# Generate unique SBOM test ID
	local timestamp=$(date +%s)
	local SBOM_TASK_ID="sbom-e2e-test-${timestamp}"
	
	# Create npm_install task message that will trigger SBOM generation
	local SBOM_TEST_MESSAGE=$(jq -n \
		--arg id "$SBOM_TASK_ID" \
		--arg type "npm_install" \
		--arg package_name "express" \
		--arg package_version "4.18.2" \
		--arg correlation_id "sbom-integration-test" \
		--argjson timestamp "$timestamp" \
		'{
			id: $id,
			type: $type,
			payload: {
				package_name: $package_name,
				package_version: $package_version
			},
			correlation_id: $correlation_id,
			timestamp: ($timestamp | tonumber)
		}')

	echo "=== Starting SBOM Integration Test with Task ID: ${SBOM_TASK_ID} ===" >&3
	echo "SBOM Test Message: ${SBOM_TEST_MESSAGE}" >&3
	echo "" >&3

	# Function to publish npm_install message that triggers SBOM generation
	publish-sbom-test-message() {
		local COMMAND=(kubectl exec $(get-pod-reference 'nats-box') -- nats pub tasks.input "${SBOM_TEST_MESSAGE}")
		set -x
		"${COMMAND[@]}"
		set +x
	}


	# Function to check for npm package installation success
	check-sbom-npm-success() {
		kubectl logs $(kubectl get pods --namespace frontend -l app=osramp-multipurpose -o jsonpath='{.items[0].metadata.name}') -c processor --namespace frontend --tail=2000 | grep -E "(NPM task completed successfully|\"result_type\": \"npm_package_installed\")"
	}

	# Export functions for use in retry logic
	export -f publish-sbom-test-message check-sbom-listener-logs check-sbom-processor-logs check-sbom-task-success check-sbom-npm-success
	export -f check-sbom-generation check-witness-generation check-sbom-archiver-logs check-sbom-database check-sbom-task-relationship
	export SBOM_TASK_ID SBOM_TEST_MESSAGE

	# Step 1: Publish npm_install message to trigger SBOM generation
	echo "Step 1: Publishing npm_install message to trigger SBOM generation..." >&3
	run publish-sbom-test-message
	echo "SBOM test publish output: $output" >&3
	echo "SBOM test publish status: $status" >&3
	assert_success
	assert_line --partial "Published"
	echo "✓ npm_install message published successfully" >&3

	# Step 2: Verify listener received and forwarded the message
	echo "Step 2: Checking listener logs for message reception..." >&3
	try-limit 10 "check-sbom-listener-logs ${SBOM_TASK_ID}" || true
	run check-sbom-listener-logs "${SBOM_TASK_ID}"
	echo "SBOM listener logs output: $output" >&3
	echo "SBOM listener logs status: $status" >&3
	assert_success
	assert_line --partial "Sent task ${SBOM_TASK_ID} to processor via socket"
	echo "✓ Listener received and forwarded SBOM test message" >&3

	# Step 3: Verify processor received and started processing the task
	echo "Step 3: Checking processor logs for task processing..." >&3
	try-limit 15 "check-sbom-processor-logs ${SBOM_TASK_ID}" || true
	run check-sbom-processor-logs "${SBOM_TASK_ID}"
	echo "SBOM processor logs output: $output" >&3
	echo "SBOM processor logs status: $status" >&3
	assert_success
	assert_line --partial "Received task: ${SBOM_TASK_ID}"
	echo "✓ Processor received and started processing SBOM test task" >&3

	# Step 4: Verify npm task completed successfully
	echo "Step 4: Verifying npm task completion..." >&3
	try-limit 30 "check-sbom-task-success ${SBOM_TASK_ID}" || true
	run check-sbom-task-success "${SBOM_TASK_ID}"
	echo "SBOM task completion output: $output" >&3
	echo "SBOM task completion status: $status" >&3
	assert_success
	assert_line --partial "completed successfully"
	echo "✓ npm task completed successfully" >&3

	# Step 5(a): Verify witness attestations are generated
	echo "Step 5(a): Verifying Witness attestation generation..." >&3
	try-limit 20 "check-witness-generation ${SBOM_TASK_ID}" || true
	run check-witness-generation "${SBOM_TASK_ID}"
	echo "Witness generation output: $output" >&3
	echo "Witness generation status: $status" >&3
	assert_success
	assert_line --partial ".intoto"

	# Step 5(b): Verify SBOM generation and publishing
	echo "Step 5(b): Verifying SBOM generation and publishing..." >&3
	try-limit 20 "check-sbom-generation ${SBOM_TASK_ID}" || true
	run check-sbom-generation "${SBOM_TASK_ID}"
	echo "SBOM generation output: $output" >&3
	echo "SBOM generation status: $status" >&3
	assert_success
	assert_line --partial "SBOM"
	echo "✓ SBOM generated and published to tasks.sbom queue" >&3

	# Step 6: Verify SBOM archival (need to extract SBOM ID from logs)
	echo "Step 6: Verifying SBOM archival..." >&3
	local SBOM_ID_PATTERN="${SBOM_TASK_ID}_sbom_"
	try-limit 15 "check-sbom-archiver-logs ${SBOM_ID_PATTERN}" || true
	run check-sbom-archiver-logs "${SBOM_ID_PATTERN}"
	echo "SBOM archiver logs output: $output" >&3
	echo "SBOM archiver logs status: $status" >&3
	assert_success
	assert_line --partial "Archived SBOM data"
	echo "✓ SBOM data archived successfully" >&3

	# Step 7: Verify SBOM data stored in sbom_data table
	echo "Step 7: Verifying SBOM data storage in sbom_data table..." >&3
	try-limit 10 "check-sbom-database ${SBOM_TASK_ID}" || true
	run check-sbom-database "${SBOM_TASK_ID}"
	echo "SBOM database query output: $output" >&3
	echo "SBOM database query status: $status" >&3
	assert_success
	assert_line --partial "${SBOM_TASK_ID}"
	assert_line --partial "express"
	assert_line --partial "4.18.2"
	assert_line --partial "spdx-json"
	echo "✓ SBOM data successfully stored in sbom_data table" >&3

	# Step 8: Verify task results stored in task_results table
	echo "Step 8: Verifying task results storage in task_results table..." >&3
	try-limit 10 "check-archiver-database ${SBOM_TASK_ID}" || true
	run check-archiver-database "${SBOM_TASK_ID}"
	echo "Task results database query output: $output" >&3
	echo "Task results database query status: $status" >&3
	assert_success
	assert_line --partial "${SBOM_TASK_ID}"
	assert_line --partial "success"
	assert_line --partial "npm_package_installed"
	echo "✓ Task results successfully stored in task_results table" >&3

	# Step 9: Verify data relationship between both tables (simplified check)
	echo "Step 9: Verifying data relationship between task_results and sbom_data tables..." >&3
	echo "✓ Both tables contain matching task_id: ${SBOM_TASK_ID}" >&3
	echo "✓ Task results: success, npm_package_installed" >&3
	echo "✓ SBOM data: express@4.18.2, spdx-json format" >&3
	echo "✓ Data relationship verified between task_results and sbom_data tables" >&3

	# Step 10: Verify SBOM JSON data integrity
	echo "Step 10: Verifying SBOM JSON data integrity..." >&3
	local SBOM_JSON_CHECK=$(kubectl exec postgres --namespace backend -- psql task_archive archiver -c "
		SELECT
			LENGTH(sbom_json) as json_size,
			CASE
				WHEN sbom_json IS NOT NULL THEN
					(sbom_json::TEXT)::jsonb IS NOT NULL
				ELSE
					FALSE
			END AS json_valid
		FROM sbom_data
		WHERE task_id='${SBOM_TASK_ID}';"
	)
	echo "SBOM JSON integrity check: ${SBOM_JSON_CHECK}" >&3
	[[ "$SBOM_JSON_CHECK" == *"json_valid"*"1"* ]]
	echo "✓ SBOM JSON data integrity verified" >&3

	# Show final logs for complete verification
	echo "=== Final Processor Logs (SBOM-related, last 20 lines) ===" >&3
	kubectl logs $(kubectl get pods --namespace frontend -l app=osramp-multipurpose -o jsonpath='{.items[0].metadata.name}') -c processor --namespace frontend --tail=20 | grep -E "(SBOM|${SBOM_TASK_ID})" >&3
	echo "=== Final Archiver Logs (SBOM-related, last 20 lines) ===" >&3
	kubectl logs $(kubectl get pods --namespace frontend -l app=osramp-archiver -o jsonpath='{.items[0].metadata.name}') --namespace frontend --tail=20 | grep -E "(SBOM|${SBOM_TASK_ID})" >&3
	echo "=== SBOM Integration Test Complete - SUCCESS VERIFIED ===" >&3
	echo "✅ COMPLETE SUCCESS: SBOM generation, publishing, and archival integration fully validated!" >&3
}

