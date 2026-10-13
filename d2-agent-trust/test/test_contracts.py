import base64, json, os, subprocess, sys, tempfile, threading, time, unittest, urllib.error, urllib.request
from pathlib import Path
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[1]; sys.path.insert(0,str(ROOT))
from a2a.service import *
from adapters.spire_workload_api import fetch_jwt_svid

class Contracts(unittest.TestCase):
 def test_topology_external_and_registrations(self):
  t=json.loads((ROOT/'contracts/topology.v1.json').read_text()); e=json.loads((ROOT/'contracts/external-enrollment.v1.json').read_text()); r=json.loads((ROOT/'contracts/spire-registrations.v1.json').read_text())
  self.assertEqual(t['contractVersion'],'1.0.0'); self.assertEqual(len(t['tenants']),2); self.assertTrue(all(x['evidence'] in t['evidenceStates'] for x in t['edges']))
  self.assertEqual(e['state'],'modeled'); self.assertEqual(len(e['workloads']),3); self.assertIn('k8s:sa:agent-trust-planner',r['registrations'][0]['selectors'])
 def test_rendered_manifest_security_and_halves(self):
  rendered=subprocess.run(['kubectl','kustomize','manifests'],cwd=ROOT,capture_output=True,text=True,check=True).stdout
  for n in ('agent-trust-platform','agent-trust-tenant-acme-control','agent-trust-tenant-northstar-control','agent-trust-acme-payments','agent-trust-acme-risk','agent-trust-northstar-investigations'): self.assertIn(f'namespace: {n}',rendered)
  for v in ('name: allow-planner-to-triage','name: allow-planner-to-triage-egress','name: allow-planner-openbao-egress','name: allow-triage-openbao-egress','name: agent-trust-triage','targetPort: 8080','agent-trust-risk-reader','agent-trust-investigator','automountServiceAccountToken: false','runAsNonRoot: true','readOnlyRootFilesystem: true','allowPrivilegeEscalation: false','openbao-ingress-intent'): self.assertIn(v,rendered)
  documents=[json.loads(line) for line in subprocess.run(['yq','-o=json','-I=0'],input=rendered,capture_output=True,text=True,check=True).stdout.splitlines()]
  workloads=[document for document in documents if document.get('kind') == 'Deployment']
  self.assertEqual(len(workloads),4)
  self.assertTrue(all(workload['spec']['template']['spec']['securityContext']['runAsUser'] == 65532 for workload in workloads))
  self.assertTrue(all(workload['spec']['template']['spec']['automountServiceAccountToken'] is False for workload in workloads))
  self.assertNotIn('kind: Job',rendered); self.assertEqual(rendered.count('name: default-deny'),6)
 def test_openbao_intent_is_exact_and_lifecycle_applies_it(self):
  intent=(ROOT/'contracts/openbao-role-intent.sh').read_text(); lifecycle=(ROOT.parent/'scripts/agent-trust-local.sh').read_text()
  self.assertIn('bound_audiences=openbao-supercredential',intent); self.assertIn('token_type=batch',intent); self.assertNotIn('token_renewable',intent)
  self.assertIn('bao write "auth/jwt/role/agent-trust-${agent}"',lifecycle); self.assertIn('configure_identity_plane',lifecycle)
  self.assertIn('token_type=batch',lifecycle)
  self.assertNotIn('token_renewable',lifecycle)

class A2A(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory(); self.private=f'{self.tmp.name}/key'; self.public=f'{self.tmp.name}/pub'; self.now=1000; self.instance='test-instance'
  subprocess.run(['openssl','genrsa','-out',self.private,'2048'],check=True,capture_output=True); subprocess.run(['openssl','rsa','-in',self.private,'-pubout','-out',self.public],check=True,capture_output=True)
  self.request={'action':'triage.analyze','resource':'case/123'}
 def tearDown(self): self.tmp.cleanup()
 def context(self,**change):
  c={'iss':ISSUER,'aud':AUDIENCE,'actor':PLANNER,'receiver':TRIAGE,'instance':self.instance,'tenant':'acme','project':'payments','action':self.request['action'],'resource':self.request['resource'],'requestHash':request_hash(self.request),'nbf':999,'exp':1001,'jti':'one'}; c.update(change); return mint_authorization_context_fixture(self.private,c)
 def test_positive_and_all_mutation_denials(self):
  self.assertEqual('allow',verify_and_authorize(self.context(),self.public,self.request,PLANNER,ReplayStore(),self.now,receiver_instance=self.instance)['decision'])
  cases=[{'action':'other'},{'resource':'case/other'},{'receiver':'bad'},{'instance':'pre-restart'},{'iss':'bad'},{'actor':'bad'},{'jti':''},{'exp':999},{'nbf':1001},{'aud':'bad'},{'project':'risk'}]
  for change in cases:
    with self.assertRaises(PermissionError): verify_and_authorize(self.context(**change),self.public,self.request,PLANNER,ReplayStore(),self.now,receiver_instance=self.instance)
  with self.assertRaises(PermissionError): verify_and_authorize(self.context(),self.public,{'action':'triage.analyze','resource':'case/mutated'},PLANNER,ReplayStore(),self.now,receiver_instance=self.instance)
  with self.assertRaises(PermissionError): verify_and_authorize(self.context(),self.public,"not-a-dict",PLANNER,ReplayStore(),self.now,receiver_instance=self.instance)
  with self.assertRaises(PermissionError): verify_and_authorize(self.context(),self.public,[1,2,3],PLANNER,ReplayStore(),self.now,receiver_instance=self.instance)
  with self.assertRaises(PermissionError): verify_and_authorize(self.context(),self.public,self.request,'spiffe://bad',ReplayStore(),self.now,receiver_instance=self.instance)
  replay=ReplayStore(); verify_and_authorize(self.context(),self.public,self.request,PLANNER,replay,self.now,receiver_instance=self.instance)
  with self.assertRaises(PermissionError): verify_and_authorize(self.context(),self.public,self.request,PLANNER,replay,self.now,receiver_instance=self.instance)
  for resource in ('case/alpha_2','case/Z-9'):
    self.request={'action':'triage.analyze','resource':resource}; self.assertEqual('allow',verify_and_authorize(self.context(jti=resource),self.public,self.request,PLANNER,ReplayStore(),self.now,receiver_instance=self.instance)['decision'])
  for resource in ('case/../x','case/a\n','case/'+('a'*129)):
   self.request={'action':'triage.analyze','resource':resource}
   with self.assertRaises(PermissionError): verify_and_authorize(self.context(),self.public,self.request,PLANNER,ReplayStore(),self.now,receiver_instance=self.instance)
  replay=ReplayStore(max_entries=1); self.assertTrue(replay.consume('first',1001,1000)); self.assertFalse(replay.consume('second',1001,1000)); self.assertTrue(replay.consume('second',1003,1002))
 def test_card_bytes_at_standard_metadata_paths(self):
  s=serve(self.public,0,receiver_instance=self.instance); th=threading.Thread(target=s.serve_forever); th.start()
  try:
   wanted=(ROOT/'a2a/agent-card.json').read_bytes()
   for path in ('/.well-known/agent-card.json','/.well-known/agent.json'):
    resp=urllib.request.urlopen(f'http://127.0.0.1:{s.server_port}{path}')
    self.assertEqual(resp.headers.get("Content-Length"), str(len(wanted)))
    self.assertEqual(resp.headers.get("Content-Type"), "application/json")
    self.assertEqual(wanted, resp.read())
   for probe in ('/health','/healthz','/readyz'):
    resp=urllib.request.urlopen(f'http://127.0.0.1:{s.server_port}{probe}')
    self.assertEqual(200, resp.status)
    self.assertEqual({'status':'ok'}, json.loads(resp.read()))
    head_req=urllib.request.Request(f'http://127.0.0.1:{s.server_port}{probe}', method='HEAD')
    head_resp=urllib.request.urlopen(head_req)
    self.assertEqual(200, head_resp.status)
    self.assertEqual(b'', head_resp.read())
    self.assertEqual('15', head_resp.headers.get("Content-Length"))
   self.assertEqual(self.instance,json.loads(urllib.request.urlopen(f'http://127.0.0.1:{s.server_port}/challenge?extra=1').read())['instanceNonce'])
   head_chal=urllib.request.Request(f'http://127.0.0.1:{s.server_port}/challenge', method='HEAD')
   head_chal_resp=urllib.request.urlopen(head_chal)
   self.assertEqual(200, head_chal_resp.status)
   self.assertEqual(b'', head_chal_resp.read())
   self.assertTrue(getattr(s, 'allow_reuse_address', False))
   for probe in ('/health','/healthz','/readyz','/challenge','/.well-known/agent-card.json'):
    for m in ('POST', 'PUT', 'DELETE', 'PATCH', 'TRACE'):
     m_req=urllib.request.Request(f'http://127.0.0.1:{s.server_port}{probe}', data=b'{}' if m in ('POST','PUT','PATCH') else None, method=m)
     with self.assertRaises(urllib.error.HTTPError) as m_err: urllib.request.urlopen(m_req)
     self.assertEqual(405, m_err.exception.code)
     self.assertEqual('GET, HEAD, OPTIONS', m_err.exception.headers.get('Allow'))
     self.assertEqual('application/json', m_err.exception.headers.get('Content-Type'))
     m_err.exception.close()
    opt_req=urllib.request.Request(f'http://127.0.0.1:{s.server_port}{probe}', method='OPTIONS')
    opt_resp=urllib.request.urlopen(opt_req)
    self.assertEqual(204, opt_resp.status)
    self.assertEqual('GET, HEAD, OPTIONS', opt_resp.headers.get('Allow'))
    self.assertEqual('0', opt_resp.headers.get('Content-Length'))
    self.assertEqual(b'', opt_resp.read())
   for method in ('GET','HEAD','PUT','DELETE','PATCH','TRACE'):
    a2a_req=urllib.request.Request(f'http://127.0.0.1:{s.server_port}/a2a', method=method)
    with self.assertRaises(urllib.error.HTTPError) as a2a_err: urllib.request.urlopen(a2a_req)
    self.assertEqual(405, a2a_err.exception.code)
    self.assertEqual('POST, OPTIONS', a2a_err.exception.headers.get('Allow'))
    self.assertEqual('application/json', a2a_err.exception.headers.get('Content-Type'))
    if method == 'HEAD':
     self.assertEqual(b'', a2a_err.exception.read())
    a2a_err.exception.close()
   a2a_opt_req=urllib.request.Request(f'http://127.0.0.1:{s.server_port}/a2a', method='OPTIONS')
   a2a_opt_resp=urllib.request.urlopen(a2a_opt_req)
   self.assertEqual(204, a2a_opt_resp.status)
   self.assertEqual('POST, OPTIONS', a2a_opt_resp.headers.get('Allow'))
   self.assertEqual('0', a2a_opt_resp.headers.get('Content-Length'))
   self.assertEqual(b'', a2a_opt_resp.read())
   for unknown in ('/unknown', '/api/v1/invalid', '/health/subpath'):
    u_req=urllib.request.Request(f'http://127.0.0.1:{s.server_port}{unknown}', method='HEAD')
    with self.assertRaises(urllib.error.HTTPError) as u_err: urllib.request.urlopen(u_req)
    self.assertEqual(404, u_err.exception.code)
    self.assertEqual('application/json', u_err.exception.headers.get('Content-Type'))
    self.assertEqual(b'', u_err.exception.read())
    u_err.exception.close()
  finally: s.shutdown(); th.join(); s.server_close()
 def test_http_uses_validator_not_claimed_identity_header(self):
  def validator(token):
   if token != 'good-svid': raise PermissionError('bad identity')
   return PLANNER
  s=serve(self.public,0,identity_validator=validator,receiver_instance=self.instance); th=threading.Thread(target=s.serve_forever); th.start()
  try:
   url=f'http://127.0.0.1:{s.server_port}/a2a'; now=int(time.time()); c=self.context(nbf=now-1,exp=now+30,jti='http')
   req=urllib.request.Request(url,data=json.dumps(self.request).encode(),headers={'Authorization':'Bearer   '+c+'  ','X-SPIFFE-JWT-SVID':'good-svid','X-Authenticated-SPIFFE-ID':'spiffe://spoof'},method='POST')
   resp=urllib.request.urlopen(req)
   self.assertIsNotNone(resp.headers.get("Content-Length"))
   self.assertEqual(resp.headers.get("Content-Type"), "application/json")
   self.assertEqual('allow',json.loads(resp.read())['decision'])
   bad=urllib.request.Request(url,data=json.dumps(self.request).encode(),headers={'Authorization':'Bearer '+self.context(nbf=now-1,exp=now+30,jti='bad'),'X-SPIFFE-JWT-SVID':'bad-svid','X-Authenticated-SPIFFE-ID':PLANNER},method='POST')
   with self.assertRaises(urllib.error.HTTPError) as denied: urllib.request.urlopen(bad)
   denied.exception.close()
   bad_body=urllib.request.Request(url,data=b'[]',headers={'Authorization':'Bearer '+c,'X-SPIFFE-JWT-SVID':'good-svid'},method='POST')
   with self.assertRaises(urllib.error.HTTPError) as err_body: urllib.request.urlopen(bad_body)
   self.assertEqual(400,err_body.exception.code); err_body.exception.close()
   malformed_json=urllib.request.Request(url,data=b'{not json',headers={'Authorization':'Bearer '+c,'X-SPIFFE-JWT-SVID':'good-svid'},method='POST')
   with self.assertRaises(urllib.error.HTTPError) as err_malformed: urllib.request.urlopen(malformed_json)
   self.assertEqual(400,err_malformed.exception.code); err_malformed.exception.close()
   bad_len=urllib.request.Request(url,data=b'{}',headers={'Authorization':'Bearer '+c,'X-SPIFFE-JWT-SVID':'good-svid','Content-Length':'invalid'},method='POST')
   with self.assertRaises(urllib.error.HTTPError) as err_len: urllib.request.urlopen(bad_len)
   self.assertEqual(400,err_len.exception.code); err_len.exception.close()
  finally: s.shutdown(); th.join(); s.server_close()
  restarted=serve(self.public,0,identity_validator=validator,receiver_instance='post-restart'); restarted_thread=threading.Thread(target=restarted.serve_forever); restarted_thread.start()
  try:
   replay=urllib.request.Request(f'http://127.0.0.1:{restarted.server_port}/a2a',data=json.dumps(self.request).encode(),headers={'Authorization':'Bearer '+c,'X-SPIFFE-JWT-SVID':'good-svid'},method='POST')
   with self.assertRaises(urllib.error.HTTPError) as denied_after_restart: urllib.request.urlopen(replay)
   self.assertEqual(403,denied_after_restart.exception.code); denied_after_restart.exception.close()
  finally: restarted.shutdown(); restarted_thread.join(); restarted.server_close()
 def test_openbao_identity_seam(self):
  class R:
   def read(self): return json.dumps({'auth':{'client_token':'ephemeral'}}).encode()
  svid='x.'+base64.urlsafe_b64encode(json.dumps({'sub':PLANNER}).encode()).rstrip(b'=').decode()+'.z'
  self.assertEqual(PLANNER,validate_openbao_identity('http://bao',svid,'agent-trust-planner',PLANNER,lambda *_args,**_kw:R()))
  class S: spiffe_id=PLANNER; token=svid
  self.assertEqual(PLANNER,authenticate_spiffe_via_openbao('openbao-supercredential','http://bao','agent-trust-planner',PLANNER,fetcher=lambda _aud:S(),opener=lambda *_args,**_kw:R()))

 def test_adversarial_timestamp_and_replay_attacks(self):
  cases = [
    {'exp': float('inf')}, {'exp': float('nan')}, {'exp': True}, {'exp': False},
    {'nbf': float('nan')}, {'nbf': True}, {'nbf': False}, {'nbf': -1}, {'nbf': 1002, 'exp': 1001},
    {'exp': 1000, 'nbf': 1000}, {'exp': self.now + 86401, 'nbf': self.now - 1},
    {'tenant': 'invalid tenant spaces'}, {'project': 'invalid/project'},
    {'actor': 'not-a-spiffe'}, {'receiver': 'not-a-spiffe'},
    {'jti': 'x' * 513},
  ]
  for change in cases:
   with self.assertRaises(PermissionError):
    verify_and_authorize(self.context(**change), self.public, self.request, PLANNER, ReplayStore(), self.now, receiver_instance=self.instance)
  replay = ReplayStore(max_entries=10)
  for bad_exp in (float('inf'), float('nan'), True, False, 999, -1):
   self.assertFalse(replay.consume('token-1', expires_at=bad_exp, now=1000))
  for bad_now in (float('inf'), float('nan'), True, False, -1, 0):
   self.assertFalse(replay.consume('token-2', expires_at=1005, now=bad_now))
  self.assertFalse(replay.consume('', expires_at=1005, now=1000))
  self.assertFalse(replay.consume('a' * 513, expires_at=1005, now=1000))
  self.assertFalse(replay.consume(12345, expires_at=1005, now=1000))

 def test_openbao_identity_validation_bounds(self):
  svid = 'x.' + base64.urlsafe_b64encode(json.dumps({'sub': PLANNER}).encode()).rstrip(b'=').decode() + '.z'
  with self.assertRaises(PermissionError):
   validate_openbao_identity('file:///etc/passwd', svid, 'agent-trust-planner', PLANNER)
  with self.assertRaises(PermissionError):
   validate_openbao_identity('http://bao', 'not-a-jwt', 'agent-trust-planner', PLANNER)
  with self.assertRaises(PermissionError):
   validate_openbao_identity('http://bao', svid, 'role/injection', PLANNER)
  with self.assertRaises(PermissionError):
   validate_openbao_identity('http://bao', svid, 'agent-trust-planner', 'not-a-spiffe')
  with self.assertRaises(PermissionError):
   validate_openbao_identity('http://bao', 'x.' + base64.urlsafe_b64encode(json.dumps({'sub': 'not-a-spiffe'}).encode()).rstrip(b'=').decode() + '.z', 'agent-trust-planner', PLANNER)
  with self.assertRaises(PermissionError):
   validate_openbao_identity('http://bao\r\nInjected: true', svid, 'agent-trust-planner', PLANNER)

 def test_unmatched_route_and_empty_auth_handling(self):
  s = serve(self.public, 0, receiver_instance=self.instance)
  th = threading.Thread(target=s.serve_forever); th.start()
  try:
   for method in ('TRACE', 'OPTIONS', 'PUT', 'DELETE', 'PATCH'):
    req = urllib.request.Request(f'http://127.0.0.1:{s.server_port}/unmatched-path-404', method=method)
    with self.assertRaises(urllib.error.HTTPError) as err:
     urllib.request.urlopen(req)
    self.assertEqual(404, err.exception.code)
    self.assertIsNone(err.exception.headers.get('Allow'))
    err.exception.close()

   empty_bearer = urllib.request.Request(
    f'http://127.0.0.1:{s.server_port}/a2a',
    data=json.dumps(self.request).encode(),
    headers={'Authorization': 'Bearer   ', 'X-SPIFFE-JWT-SVID': 'good-svid'},
    method='POST'
   )
   with self.assertRaises(urllib.error.HTTPError) as empty_err:
    urllib.request.urlopen(empty_bearer)
   self.assertEqual(403, empty_err.exception.code)
   empty_err.exception.close()
  finally:
   s.shutdown(); th.join(); s.server_close()

class Adapter(unittest.TestCase):
 def test_fetches_one_svid_and_fails_closed(self):
  import stat
  class MockStat:
   st_mode = stat.S_IFSOCK | 0o666
  class MockFileStat:
   st_mode = stat.S_IFREG | 0o666
  result=subprocess.CompletedProcess([],0,json.dumps({'svids':[{'spiffeID':PLANNER,'svid':'a.b.c'}]}),'')
  with patch('adapters.spire_workload_api.os.path.exists',return_value=True), patch('adapters.spire_workload_api.os.stat',return_value=MockStat()):
   self.assertEqual(PLANNER,fetch_jwt_svid('openbao-supercredential',runner=lambda *_args,**_kw:result).spiffe_id)
  with patch('adapters.spire_workload_api.os.path.exists',return_value=True), patch('adapters.spire_workload_api.os.stat',return_value=MockFileStat()):
   with self.assertRaises(RuntimeError) as non_sock_ctx:
    fetch_jwt_svid('openbao-supercredential',runner=lambda *_args,**_kw:result)
   self.assertIn('not a socket', str(non_sock_ctx.exception))
  with patch('adapters.spire_workload_api.os.path.exists',return_value=True), patch('adapters.spire_workload_api.os.stat',return_value=MockStat()):
   with self.assertRaises(RuntimeError): fetch_jwt_svid('a',runner=lambda *_args,**_kw:subprocess.CompletedProcess([],1,'','bad'))
   with self.assertRaises(RuntimeError): fetch_jwt_svid('a',runner=lambda *_args,**_kw:subprocess.CompletedProcess([],0,'{bad',''))
   with self.assertRaises(RuntimeError): fetch_jwt_svid('a',runner=lambda *_args,**_kw:subprocess.CompletedProcess([],0,json.dumps({'svids':[{},{}]}),''))
   def mock_timeout(*_args, **_kw): raise subprocess.TimeoutExpired(cmd="spire-agent", timeout=5)
   with self.assertRaises(RuntimeError): fetch_jwt_svid('a',runner=mock_timeout)
   with self.assertRaises(RuntimeError) as err_ctx:
    fetch_jwt_svid('openbao-supercredential', runner=lambda *_a, **_k: subprocess.CompletedProcess([], 1, '', 'connection refused: /run/spire/sockets/agent.sock'))
   self.assertIn('connection refused', str(err_ctx.exception))
  with self.assertRaises(ValueError): fetch_jwt_svid('bad audience')
  for bad_timeout in (True, False, float('nan'), float('inf'), 0, -1, 31):
   with self.assertRaises(ValueError): fetch_jwt_svid('openbao-supercredential', timeout=bad_timeout)
