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
  self.assertEqual(rendered.count('runAsUser: 65532'),4)
  self.assertEqual(rendered.count('automountServiceAccountToken: false'),4)
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
   for path in ('/.well-known/agent-card.json','/.well-known/agent.json'): self.assertEqual(wanted,urllib.request.urlopen(f'http://127.0.0.1:{s.server_port}{path}').read())
   self.assertEqual(self.instance,json.loads(urllib.request.urlopen(f'http://127.0.0.1:{s.server_port}/challenge').read())['instanceNonce'])
  finally: s.shutdown(); th.join(); s.server_close()
 def test_http_uses_validator_not_claimed_identity_header(self):
  def validator(token):
   if token != 'good-svid': raise PermissionError('bad identity')
   return PLANNER
  s=serve(self.public,0,identity_validator=validator,receiver_instance=self.instance); th=threading.Thread(target=s.serve_forever); th.start()
  try:
   url=f'http://127.0.0.1:{s.server_port}/a2a'; now=int(time.time()); c=self.context(nbf=now-1,exp=now+30,jti='http')
   req=urllib.request.Request(url,data=json.dumps(self.request).encode(),headers={'Authorization':'Bearer '+c,'X-SPIFFE-JWT-SVID':'good-svid','X-Authenticated-SPIFFE-ID':'spiffe://spoof'},method='POST')
   self.assertEqual('allow',json.loads(urllib.request.urlopen(req).read())['decision'])
   bad=urllib.request.Request(url,data=json.dumps(self.request).encode(),headers={'Authorization':'Bearer '+self.context(nbf=now-1,exp=now+30,jti='bad'),'X-SPIFFE-JWT-SVID':'bad-svid','X-Authenticated-SPIFFE-ID':PLANNER},method='POST')
   with self.assertRaises(urllib.error.HTTPError) as denied: urllib.request.urlopen(bad)
   denied.exception.close()
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

class Adapter(unittest.TestCase):
 def test_fetches_one_svid_and_fails_closed(self):
  result=subprocess.CompletedProcess([],0,json.dumps({'svids':[{'spiffeID':PLANNER,'svid':'a.b.c'}]}),'')
  with patch('adapters.spire_workload_api.os.path.exists',return_value=True): self.assertEqual(PLANNER,fetch_jwt_svid('openbao-supercredential',runner=lambda *_args,**_kw:result).spiffe_id)
  with patch('adapters.spire_workload_api.os.path.exists',return_value=True):
   with self.assertRaises(RuntimeError): fetch_jwt_svid('a',runner=lambda *_args,**_kw:subprocess.CompletedProcess([],1,'','bad'))
   with self.assertRaises(RuntimeError): fetch_jwt_svid('a',runner=lambda *_args,**_kw:subprocess.CompletedProcess([],0,'{bad',''))
   with self.assertRaises(RuntimeError): fetch_jwt_svid('a',runner=lambda *_args,**_kw:subprocess.CompletedProcess([],0,json.dumps({'svids':[{},{}]}),''))
  with self.assertRaises(ValueError): fetch_jwt_svid('bad audience')
