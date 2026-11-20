import hashlib,http.server,json,pathlib,socket,subprocess,sys,tempfile,threading,unittest
ROOT=pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'Services/DeviceActivationCandidate'));sys.path.insert(0,str(ROOT/'Services/ManagedGatewayCandidate'))
from account_store import AccountStore
from activation import Activation

class Tests(unittest.TestCase):
 def test_activation_commit_then_disconnect(self):
  calls=[]
  with tempfile.TemporaryDirectory() as tmp:
   store=AccountStore(str(pathlib.Path(tmp)/'db'));store.put_global_limits(20,60);store.put_account('friend',10);store.put_speech_limit('friend',30)
   activation=Activation(store);invite=activation.issue('friend')
   class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
     self.assert_path=self.path;p=json.loads(self.rfile.read(int(self.headers['Content-Length'])));calls.append((self.path,p))
     result=activation.activate(p['invite'],p['device'],p['access'])
     if len(calls)==1:self.connection.shutdown(socket.SHUT_RDWR);self.connection.close();return
     body=json.dumps({'ok':result,'expires_in':604800} if result else {'ok':False}).encode();self.send_response(200 if result else 400);self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
    def log_message(self,*args):pass
   server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler);thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
   try:
    binary=str(pathlib.Path(tmp)/'client')
    subprocess.run(['swiftc','-DDEBUG',str(ROOT/'MORIQ/DeviceRenewalCandidate.swift'),str(ROOT/'Tests/ManagedAI/device_activation_http.swift'),'-o',binary],check=True)
    subprocess.run([binary,f'http://127.0.0.1:{server.server_port}/v1/devices/renew',invite],check=True,timeout=20)
    self.assertEqual(len(calls),2);self.assertEqual(calls[0],calls[1]);self.assertEqual(calls[0][0],'/v1/devices/activate')
    self.assertIsNotNone(store.authenticate(hashlib.sha256(calls[0][1]['access'].encode()).hexdigest()))
   finally:server.shutdown();server.server_close();thread.join()

if __name__=='__main__':unittest.main()
