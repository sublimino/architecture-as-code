# Signal Ingest Observations API

This page describes the `GET /api/v1/observations` endpoint in `signal-ingest`.
The endpoint returns signal observations from the columnar store with deterministic
ordering, opaque cursor pagination, and tenant isolation.

## Endpoint overview

`GET /api/v1/observations` lists ingested observations. The response body is a
bare JSON array. Paging metadata is delivered via HTTP headers.

| Property | Value |
| :--- | :--- |
| Method | `GET` |
| Path | `/api/v1/observations` |
| Authentication | Bearer token (`Authorization: Bearer <token>`) |
| Permission | `observations:read` |
| Default limit | `100` |
| Maximum limit | `100` (or configured `MaxPageSize`) |

## Query parameters

| Parameter | Type | Description |
| :--- | :--- | :--- |
| `limit` | integer | Maximum number of observations to return per page (`0` means no limit). |
| `cursor` | string | Opaque cursor string returned in `X-Next-Cursor` from the previous response. |
| `layer` | string | Filter observations by architecture layer (for example, `endpoint_host`, `network_egress`). |
| `after` | string | RFC3339 timestamp. Keep only observations with timestamp at or after this time. |
| `before` | string | RFC3339 timestamp. Keep only observations with timestamp before this time. |
| `actor_id` | string | Filter by actor identifier hint. |
| `subject_id` | string | Filter by subject identifier across actor, principal, and impersonated user fields. |

## Deterministic ordering

Observations are ordered deterministically by:

```
(timestamp DESC, id DESC)
```

The sorting is applied before pagination limits. If two observations share the exact same
nanosecond timestamp, ties are broken by `id` descending.

## Cursor pagination and headers

Pagination uses an opaque, tenant-scoped cursor passed via the `cursor` query parameter.

The server inspects one additional row (`limit + 1`) to determine if more pages exist.

### Response headers

| Header | Description |
| :--- | :--- |
| `X-Next-Cursor` | Opaque string to pass to the `cursor` query parameter on the next request. Present only when more rows exist. |
| `Link` | Standard RFC 5988 link header with `rel="next"`, containing the full URL for the next page. |
| `X-Result-Truncated` | `true` if more observations exist after this page; `false` when the last page is reached. |

### Cursor format and security

The cursor is a base64url-encoded JSON object:

```json
{"v":1,"t":"2026-10-06T12:00:00.000000000Z","id":"obs-00123","scope":"67855919754893ca2e453ba92d8c38aa"}
```

- `v`: Cursor schema version (currently `1`).
- `t`: RFC3339Nano timestamp of the last observation in the current page.
- `id`: Unique identifier of the last observation in the current page.
- `scope`: SHA-256 digest of the caller's resolved tenant scope.

### Error response (400 Bad Request)

If a client sends an invalid, expired, modified, or foreign-tenant cursor, the server returns HTTP 400 Bad Request:

```json
{"error":"invalid 'cursor': pass the X-Next-Cursor value from the previous response unchanged"}
```

## Worked curl example

The following bash script demonstrates how to walk all observation pages using `curl`, `jq`, and the `X-Next-Cursor` response header:

```bash
#!/usr/bin/env bash
set -euo pipefail

API_URL="http://127.0.0.1:8082/api/v1/observations"
TOKEN="your-bearer-token"
PAGE_SIZE=100

CURSOR=""
PAGE_NUM=1
ALL_OBSERVATIONS="all-observations.json"
echo "[]" > "$ALL_OBSERVATIONS"

while :; do
    echo "Fetching page ${PAGE_NUM}..."
    HEADER_FILE=$(mktemp)
    PAGE_FILE=$(mktemp)

    URL="${API_URL}?limit=${PAGE_SIZE}"
    if [ -n "$CURSOR" ]; then
        URL="${URL}&cursor=${CURSOR}"
    fi

    HTTP_CODE=$(curl -s -D "$HEADER_FILE" -o "$PAGE_FILE" -w '%{http_code}' \
        -H "Authorization: Bearer ${TOKEN}" \
        "$URL")

    if [ "$HTTP_CODE" -ne 200 ]; then
        echo "Error fetching page: HTTP ${HTTP_CODE}" >&2
        cat "$PAGE_FILE" >&2
        rm -f "$HEADER_FILE" "$PAGE_FILE"
        exit 1
    fi

    # Append page results into combined file
    jq -s '.[0] + .[1]' "$ALL_OBSERVATIONS" "$PAGE_FILE" > "${ALL_OBSERVATIONS}.tmp"
    mv "${ALL_OBSERVATIONS}.tmp" "$ALL_OBSERVATIONS"

    # Extract truncation flag and next cursor
    TRUNCATED=$(grep -i '^x-result-truncated:' "$HEADER_FILE" | tr -d '\r' | awk '{print $2}' | tr '[:upper:]' '[:lower:]' || true)
    NEXT_CURSOR=$(grep -i '^x-next-cursor:' "$HEADER_FILE" | tr -d '\r' | awk '{print $2}' || true)

    rm -f "$HEADER_FILE" "$PAGE_FILE"

    if [ "$TRUNCATED" = "false" ] || [ -z "$NEXT_CURSOR" ]; then
        echo "Reached end of results."
        break
    fi

    CURSOR="$NEXT_CURSOR"
    PAGE_NUM=$((PAGE_NUM + 1))
done

TOTAL=$(jq length "$ALL_OBSERVATIONS")
echo "Successfully fetched ${TOTAL} observations across ${PAGE_NUM} page(s)."
```
