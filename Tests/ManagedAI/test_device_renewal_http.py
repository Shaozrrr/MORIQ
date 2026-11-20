import hashlib,http.server,json,pathlib,socket,subprocess,sys,tempfile,threading,unittest

ROOT=pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'Services/DeviceActivationCandidate'))
sys.path.insert(0,str(ROOT/'Services/ManagedGatewayCandidate'))
from account_store import AccountStore
from activation import Activation
class Tests(unittest.TestCase):
 def test_retry_uses_identical_request(self):
  requests=[]
  temp=tempfile.TemporaryDirectory()
  store=AccountStore(str(pathlib.Path(temp.name)/'accounts.db'));store.put_global_limits(20,60);store.put_account('friend',10);store.put_speech_limit('friend',30)
  activation=Activation(store);self.assertTrue(activation.activate(activation.issue('friend'),'d'*64,'a'*64))
  class Handler(http.server.BaseHTTPRequestHandler):
   def do_POST(self):
    requests.append(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
    p=requests[-1];result=activation.devices.renew_versioned(p['device'],p['access'],p['operation_id'],p['generation'])
    if len(requests)==1:
     self.connection.shutdown(socket.SHUT_RDWR);self.connection.close();return
    body=json.dumps({'ok':result,'expires_in':604800} if result else {'ok':False}).encode()
    self.send_response(200 if result else 400);self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
   def log_message(self,*args):pass
  server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler);thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
  try:
   with tempfile.TemporaryDirectory() as tmp:
    binary=str(pathlib.Path(tmp)/'test')
    subprocess.run(['swiftc','-DDEBUG',str(ROOT/'MORIQ/DeviceRenewalCandidate.swift'),str(ROOT/'Tests/ManagedAI/device_renewal_http.swift'),'-o',binary],check=True)
    subprocess.run([binary,f'http://127.0.0.1:{server.server_port}/v1/devices/renew'],check=True,timeout=20)
   self.assertEqual(len(requests),2);self.assertEqual(requests[0],requests[1])
   self.assertIsNotNone(store.authenticate(hashlib.sha256(requests[-1]['access'].encode()).hexdigest()))
  finally:server.shutdown();server.server_close();thread.join();temp.cleanup()

if __name__=='__main__':unittest.main()
