import concurrent.futures, hashlib, os, sqlite3, subprocess, sys, tempfile, time, unittest, urllib.request, urllib.error, json
from pathlib import Path
root = Path(__file__).resolve().parents[2]
sys.path.insert(0,str(root/'Services/ManagedAI'))
from account_store import AccountStore
from test_server import Upstream, gateway
from http.server import ThreadingHTTPServer
import threading

TOKEN='synthetic-session-'+'n'*40
HASH=hashlib.sha256(TOKEN.encode()).hexdigest()
class Tests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory(); self.file=os.path.join(self.temp.name,'accounts.db'); self.now=1780000000.0
  self.store=AccountStore(self.file,clock=lambda:self.now); self.store.put_account('a',5); self.store.add_session('a',HASH,self.now+3600)
 def tearDown(self):self.temp.cleanup()
 def test_session_expiry_revocation_and_private_database(self):
  self.assertEqual(os.stat(self.file).st_mode & 0o777,0o600)
  session=self.store.authenticate(HASH); self.assertEqual(session.account,'a')
  self.assertIsNone(self.store.authenticate('0'*64))
  self.assertNotIn(TOKEN.encode(),Path(self.file).read_bytes())
  self.now+=3601; self.assertIsNone(self.store.authenticate(HASH)); self.assertFalse(self.store.consume(session))
  self.now-=3601; self.assertTrue(self.store.revoke(HASH)); self.assertFalse(self.store.revoke(HASH)); self.assertIsNone(self.store.authenticate(HASH)); self.assertFalse(self.store.consume(session))
 def test_quota_survives_restart_and_resets_utc_day(self):
  session=self.store.authenticate(HASH)
  self.assertEqual([self.store.consume(session) for _ in range(6)],[True]*5+[False])
  reopened=AccountStore(self.file,clock=lambda:self.now)
  self.assertFalse(reopened.consume(session))
  self.now+=86400
  reopened.add_session('a','1'*64,self.now+3600)
  self.assertTrue(reopened.consume(reopened.authenticate('1'*64)))
 def test_parallel_requests_share_atomic_quota(self):
  session=self.store.authenticate(HASH)
  with concurrent.futures.ThreadPoolExecutor(max_workers=20) as pool:
   results=list(pool.map(lambda _:AccountStore(self.file,clock=lambda:self.now).consume(session),range(40)))
  self.assertEqual(sum(results),5)
 def test_multiple_processes_share_atomic_quota(self):
  code = "from account_store import AccountStore; import sys; s=AccountStore(sys.argv[1],clock=lambda:1780000000.0); print(int(s.consume(s.authenticate(sys.argv[2]))))"
  env=os.environ.copy(); env['PYTHONPATH']=str(root/'Services/ManagedAI')
  children=[subprocess.Popen([sys.executable,'-c',code,self.file,HASH],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True) for _ in range(12)]
  results=[]
  for child in children:
   out,err=child.communicate(timeout=15)
   self.assertEqual(child.returncode,0,err); results.append(int(out.strip()))
  self.assertEqual(sum(results),5)
 def test_reject_unsafe_path_and_malformed_input(self):
  alias=os.path.join(self.temp.name,'alias'); os.symlink(self.file,alias)
  with self.assertRaises(ValueError):AccountStore(alias)
  os.chmod(self.file,0o644)
  with self.assertRaises(ValueError):AccountStore(self.file)
  with self.assertRaises(ValueError):self.store.put_account('a',0)
  with self.assertRaises(ValueError):self.store.add_session('a','token-as-plaintext',self.now+10)
 def test_local_gateway_enforces_expiry_revocation_quota(self):
  upstream=ThreadingHTTPServer(('127.0.0.1',0),Upstream); threading.Thread(target=upstream.serve_forever,daemon=True).start()
  state=gateway.Gateway(f'http://127.0.0.1:{upstream.server_port}/chat','test-model','test-key',account_store=self.store,test_mode=True)
  server=gateway.Server(('127.0.0.1',0),state); threading.Thread(target=server.serve_forever,daemon=True).start()
  def send():
   req=urllib.request.Request(f'http://127.0.0.1:{server.server_port}/v1/chat/completions',data=json.dumps({'messages':[{'role':'user','content':'test'}]}).encode(),headers={'Authorization':'Bearer '+TOKEN},method='POST')
   try:
    with urllib.request.urlopen(req,timeout=3) as r:return r.status
   except urllib.error.HTTPError as e:return e.code
  try:
   self.assertEqual([send() for _ in range(6)],[200]*5+[429])
   self.store.revoke(HASH); self.assertEqual(send(),401)
   os.remove(self.file); self.assertEqual(send(),503); self.assertFalse(os.path.exists(self.file))
  finally:server.shutdown();server.server_close();upstream.shutdown();upstream.server_close()
if __name__=='__main__':unittest.main()
