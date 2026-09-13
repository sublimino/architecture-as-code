#!/usr/bin/env bats

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; }

@test "OpenAPI assigns operation owners and excludes body enrollment tokens" {
  run python3 - "$ROOT" <<'PY'
from pathlib import Path
import json,sys
root=Path(sys.argv[1]); text=(root/'d2-signalloom/apps/fe-signalloom/contracts/external-agent.v1.openapi.yaml').read_text()
for value in ['fastapi-registration-plane','go-signal-ingest-integrity-plane','fastapi-read-plane','fastapi-authorization-registration-plane','single-use atomic compare-and-set','replay_key equals canonical payload SHA-256']:
    assert value in text, value
schema=json.loads((root/'d2-signalloom/apps/signal-ingest/collectors/agentnono/contracts/external-agent-enrollment.v1.schema.json').read_text())
assert 'enrollment_token' not in schema['properties']
PY
  [ "$status" -eq 0 ]
}

@test "inbound schemas are tenant-free and cannot claim server integrity" {
  run python3 - "$ROOT" <<'PY'
from pathlib import Path
import json,sys
root=Path(sys.argv[1])/'d2-signalloom/apps/signal-ingest/collectors/agentnono/contracts'
for name in ['external-agent-enrollment.v1.schema.json','external-agent-upload.v1.schema.json','external-agent-evidence.v1.schema.json']:
    schema=json.loads((root/name).read_text()); assert schema['additionalProperties'] is False; assert 'tenant_id' not in json.dumps(schema)
upload=json.loads((root/'external-agent-upload.v1.schema.json').read_text())
reference=upload['$defs']['original_chain_reference']['properties']
assert 'authority' not in reference and 'state' not in reference
evidence=json.loads((root/'external-agent-evidence.v1.schema.json').read_text())
assert evidence['properties']['source']['enum'] == ['nono-0.73.0','host-sensor-v1']
assert evidence['properties']['integrity_state']['const'] == 'not-integrity-verified'
PY
  [ "$status" -eq 0 ]
}

@test "upload acknowledgement separates host signature from local chain integrity" {
  run python3 - "$ROOT" <<'PY'
from pathlib import Path
import json,sys
root=Path(sys.argv[1]); contracts=root/'d2-signalloom/apps/signal-ingest/collectors/agentnono/contracts'
server=json.loads((contracts/'external-agent-server.v1.schema.json').read_text())
ack=server['$defs']['upload_result']; props=ack['properties']
assert props['host_signature_state']['const']=='host-signature-verified'
assert props['original_chain_state']['const']=='original-chain-not-verified'
assert 'integrity' not in props
assert server['$defs']['server_evidence']['properties']['source']['enum']==['nono-0.73.0','host-sensor-v1']
assert server['$defs']['server_evidence']['properties']['integrity_state']['const']=='not-integrity-verified'
item=server['$defs']['evidence_item']['properties']
assert set(item)=={'evidence','acceptance'}
assert 'integrity_result' not in json.dumps(server['$defs']['evidence_page'])
assert server['x-signalloom-semantics']['raw-nono-exported'] is False
openapi=(root/'d2-signalloom/apps/fe-signalloom/contracts/external-agent.v1.openapi.yaml').read_text()
assert 'raw-original-chain-endpoint: absent' in openapi
assert '/original-chain' not in openapi
PY
  [ "$status" -eq 0 ]
}

@test "collector owns bounded numeric JSON schemas" {
  run python3 - "$ROOT" <<'PY'
from pathlib import Path
import json,re,sys
root=Path(sys.argv[1]); collector=root/'d2-signalloom/apps/signal-ingest/collectors/agentnono/contracts'
assert len(list(collector.glob('external-agent-*.schema.json'))) == 6
assert not list((root/'d2-signalloom/apps/fe-signalloom/contracts').glob('external-agent-*.schema.json'))
evidence=json.loads((collector/'external-agent-evidence.v1.schema.json').read_text())
assert evidence['$defs']['process']['properties']['cpu_time_ms']['maximum']==9007199254740991
mtime=evidence['$defs']['artifact']['properties']['mtime_ns']
assert mtime['type']=='string'
assert re.fullmatch(mtime['pattern'], '18446744073709551615')
assert not re.fullmatch(mtime['pattern'], '18446744073709551616')
assert not re.fullmatch(mtime['pattern'], '01')
def walk(value):
    if isinstance(value, dict):
        if value.get('type') == 'integer' or isinstance(value.get('type'), list) and 'integer' in value['type']:
            assert 'maximum' in value and value['maximum'] <= 9007199254740991, value
        for item in value.values(): walk(item)
    elif isinstance(value, list):
        for item in value: walk(item)
for schema_path in collector.glob('external-agent-*.schema.json'):
    walk(json.loads(schema_path.read_text()))
PY
  [ "$status" -eq 0 ]
}

@test "privacy schema retains frozen P1-2 boundary" {
  run python3 - "$ROOT" <<'PY'
from pathlib import Path
import json,sys
root=Path(sys.argv[1]); schema=json.loads((root/'d2-signalloom/apps/signal-ingest/collectors/agentnono/contracts/external-agent-privacy.v1.schema.json').read_text()); fixture=json.loads((root/'d2-signalloom/apps/signal-ingest/collectors/agentnono/fixtures/contracts/privacy-policy.v1.json').read_text())
for key in ['unobserved_fields','prohibited_export_fields','integrity_implies_completeness','integrity_implies_host_trust','retention_owner','deletion_owner','host_unenrollment_owner']:
    assert key in schema['required'] and key in fixture
assert fixture['raw_paths_exported'] is fixture['raw_urls_exported'] is fixture['raw_errors_exported'] is False
PY
  [ "$status" -eq 0 ]
}

@test "protobuf compiles with typed oneof attribute presence" {
  run env BUF_CACHE_DIR=/tmp/opencode/buf-cache buf build "$ROOT/d2-signalloom/apps/signal-ingest/collectors/agentnono/external_contract.proto" -o /dev/null
  [ "$status" -eq 0 ]
  run python3 - "$ROOT" <<'PY'
from pathlib import Path
import sys
proto=(Path(sys.argv[1])/'d2-signalloom/apps/signal-ingest/collectors/agentnono/external_contract.proto').read_text()
assert 'oneof exit_code_value' in proto
assert 'google.protobuf.NullValue exit_code_null' in proto
assert 'optional uint64 sequence' in proto
assert 'optional string mtime_ns' in proto
assert 'SOURCE_SIGNAL_INGEST' not in proto
PY
  [ "$status" -eq 0 ]
}

@test "generated dashboard contract check is non-mutating" {
  before="$(sha256sum "$ROOT/d2-signalloom/apps/dashboard-signalloom/src/types/externalAgent.ts")"
  run env PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/d2-signalloom/apps/fe-signalloom/src/generate_external_agent_types.py" --check
  [ "$status" -eq 0 ]
  after="$(sha256sum "$ROOT/d2-signalloom/apps/dashboard-signalloom/src/types/externalAgent.ts")"
  [ "$before" = "$after" ]
}

@test "schemas freeze discriminators timestamps integrity combinations and canonical signatures" {
  run python3 - "$ROOT" <<'PY'
from pathlib import Path
import json,re,sys
root=Path(sys.argv[1])/'d2-signalloom/apps/signal-ingest/collectors/agentnono/contracts'
host=json.loads((root/'external-agent-evidence.v1.schema.json').read_text())
server=json.loads((root/'external-agent-server.v1.schema.json').read_text())
upload=json.loads((root/'external-agent-upload.v1.schema.json').read_text())
timestamps=[host['properties']['observed_at'], server['$defs']['server_evidence']['properties']['observed_at'], server['$defs']['integrity_result']['properties']['evaluated_at']]
for field in timestamps:
    pattern=field['pattern']
    assert re.fullmatch(pattern, '2026-09-13T10:00:00Z')
    assert re.fullmatch(pattern, '2026-09-13T11:00:00.123456789+01:00')
    for invalid in ['2026-09-13t10:00:00Z','2026-09-13T10:00:00z','2026-09-13 10:00:00Z','2026-09-13T10:00:00.1234567890Z']:
        assert not re.fullmatch(pattern, invalid)
assert len(host['allOf']) == 4
assert len(server['$defs']['server_evidence']['allOf']) == 4
def discriminator_map(schema):
    return {
        rule['if']['properties']['evidence_type']['const']: rule['then']['properties']
        for rule in schema['allOf']
    }
for schema in (host, server['$defs']['server_evidence']):
    mapped=discriminator_map(schema)
    assert set(mapped) == {'process','artifact','network','collection-limit'}
    for evidence_type, definition in [('process','process'),('artifact','artifact'),('network','network'),('collection-limit','limit')]:
        assert mapped[evidence_type]['attributes']['$ref'].endswith('#/$defs/'+definition)
    assert mapped['collection-limit']['observation_state']['const'] == 'unobserved'
assert len(server['$defs']['integrity_result']['oneOf']) == 3
integrity={branch['properties']['state']['const']: branch['properties'] for branch in server['$defs']['integrity_result']['oneOf']}
assert integrity['integrity-verified']['reason']['const'] == 'verified'
assert integrity['tampered']['final_digest']['type'] == 'string'
assert integrity['unavailable']['event_count']['const'] == 0
assert integrity['unavailable']['final_digest']['type'] == 'null'
signature=upload['$defs']['host_assertion_envelope']['properties']['signature']
assert re.fullmatch(signature['pattern'], 'A'*85+'Q')
assert not re.fullmatch(signature['pattern'], 'A'*85+'B')
enrollment=json.loads((root/'external-agent-enrollment.v1.schema.json').read_text())
public_key=enrollment['properties']['public_key']['pattern']
assert re.fullmatch(public_key, 'A'*42+'E')
assert not re.fullmatch(public_key, 'A'*42+'B')
PY
  [ "$status" -eq 0 ]
}

@test "OpenAPI freezes typed errors and credential lifecycle semantics" {
  run python3 - "$ROOT" <<'PY'
from pathlib import Path
import re,sys
text=(Path(sys.argv[1])/'d2-signalloom/apps/fe-signalloom/contracts/external-agent.v1.openapi.yaml').read_text()
for value in ['existing-mtls-identity','audit-upload-only','pre-provisioned-out-of-band','revocation_result','error']:
    assert value in text, value
paths={block.splitlines()[0].strip():block for block in re.split(r'(?=^  /v1/external-agents)',text,flags=re.M)[1:]}
assert "'413'" in paths['/v1/external-agents/evidence-uploads:']
for path,block in paths.items():
    if path != '/v1/external-agents/evidence-uploads:': assert "'413'" not in block
for path in ['/v1/external-agents/enroll:','/v1/external-agents/evidence-uploads:','/v1/external-agents/{agent_id}/revocations:']:
    assert "'415'" in paths[path]
PY
  [ "$status" -eq 0 ]
}
