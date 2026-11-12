import hashlib, importlib.util, json, os, sys, threading, time, unittest, urllib.error, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
root=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('gateway',root/'Services/ManagedAI/server.py')
gateway=importlib.util.module_from_spec(spec); spec.loader.exec_module(gateway)
TOKEN='account-' + 'x'*40
SECRET='upstream-test-secret'
seen=[]
class Upstream(BaseHTTPRequestHandler):
 def log_message(self,*_): pass
 def do_POST(self):
  data=self.rfile.read(int(self.headers['Content-Length']))
  payload=json.loads(data)
  seen.append((self.headers.get('Authorization'),payload))
  if self.path == '/redirect':
   self.send_response(302); self.send_header('Location',f'http://127.0.0.1:{self.server.server_port}/redirect-target'); self.send_header('Content-Length','0'); self.end_headers(); return
  first=payload.get('messages',[{}])[0].get('content')
  if first == '__fail__':
   self.send_response(503); self.send_header('Content-Length','0'); self.end_headers(); return
  if first == '__slow__':
   initial=b'data: {"choices":[{"delta":{"content":"hello"}}]}\n\n'
   final=b'data: [DONE]\n\n'
   self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.send_header('Content-Length',str(len(initial)+len(final))); self.end_headers()
   self.wfile.write(initial); self.wfile.flush(); time.sleep(3)
   try:self.wfile.write(final)
   except OSError:pass
   return
  stream=b'data: {"choices":[{"delta":{"content":"hello"}}]}\n\ndata: [DONE]\n\n'
  self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.send_header('Content-Length',str(len(stream))); self.end_headers(); self.wfile.write(stream)
class Tests(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  cls.up=ThreadingHTTPServer(('127.0.0.1',0),Upstream); threading.Thread(target=cls.up.serve_forever,daemon=True).start()
  cls.state=gateway.Gateway(f'http://127.0.0.1:{cls.up.server_port}/chat','model-in-server',SECRET,{hashlib.sha256(TOKEN.encode()).hexdigest():'account-a'},test_mode=True)
  cls.server=gateway.Server(('127.0.0.1',0),cls.state); threading.Thread(target=cls.server.serve_forever,daemon=True).start()
  cls.url=f'http://127.0.0.1:{cls.server.server_port}/v1/chat/completions'
 @classmethod
 def tearDownClass(cls): cls.server.shutdown(); cls.server.server_close(); cls.up.shutdown(); cls.up.server_close()
 def setUp(self): self.state.history.clear(); seen.clear()
 def request(self,payload,token=TOKEN):
  req=urllib.request.Request(self.url,data=json.dumps(payload).encode(),headers={'Authorization':'Bearer '+token,'Content-Type':'application/json'},method='POST')
  try:
   with urllib.request.urlopen(req,timeout=3) as r:return r.status,r.read()
  except urllib.error.HTTPError as e:return e.code,e.read()
 def test_stream_and_secret_boundary(self):
  status,body=self.request({'model':'attacker-model','messages':[{'role':'user','content':'hello'}]})
  self.assertEqual(status,200); self.assertIn(b'[DONE]',body); self.assertNotIn(SECRET.encode(),body)
  self.assertEqual(seen[0][0],'Bearer '+SECRET); self.assertEqual(seen[0][1]['model'],'model-in-server')
 def test_unauthorized(self):
  status,_=self.request({'messages':[{'role':'user','content':'hello'}]},'not-a-valid-token')
  self.assertEqual(status,401); self.assertFalse(seen)
 def test_no_remote_images(self):
  status,_=self.request({'messages':[{'role':'user','content':[{'type':'image_url','image_url':{'url':'https://private.example/file'}}]}]})
  self.assertEqual(status,400); self.assertFalse(seen)
 def test_rate_limit(self):
  for _ in range(12): self.assertTrue(self.state.allow('b'))
  self.assertFalse(self.state.allow('b')); self.assertTrue(self.state.allow('c'))
 def test_no_provider_secret_on_redirect(self):
  original=self.state.upstream
  self.state.upstream=f'http://127.0.0.1:{self.up.server_port}/redirect'
  try:
   status,_=self.request({'messages':[{'role':'user','content':'hello'}]})
   self.assertEqual(status,502); self.assertEqual(len(seen),1)
  finally:self.state.upstream=original
 def test_production_defaults_fail_closed(self):
  with self.assertRaises(ValueError):gateway.Gateway('http://127.0.0.1:1','m',SECRET,{'a'*64:'a'})
  with self.assertRaises(ValueError):gateway.Server(('0.0.0.0',0),self.state)
if __name__=='__main__':unittest.main()
