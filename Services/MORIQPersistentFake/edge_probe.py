"""Temporary synthetic edge-header diagnostic. Does not log or disclose IPs."""
import http.server, json, os, threading

if os.geteuid() == 0:
    os.setgroups([]); os.setgid(65534); os.setuid(65534)
if os.geteuid() == 0:
    raise SystemExit('privilege drop failed')

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != '/probe':
            self.send_error(404); return
        real=self.headers.get_all('X-Real-IP', [])
        forwarded=self.headers.get_all('X-Forwarded-For', [])
        payload=json.dumps({'real_ip_present':bool(real),
          'real_ip_contains_test_sentinel':any('198.51.100.231' in v for v in real),
          'real_ip_header_count':len(real),
          'forwarded_contains_test_sentinel':any('198.51.100.231' in v for v in forwarded)}).encode()
        self.send_response(200);self.send_header('Content-Type','application/json')
        self.send_header('Cache-Control','no-store');self.send_header('Content-Length',str(len(payload)))
        self.end_headers();self.wfile.write(payload)
    def log_message(self,*args): pass

server=http.server.ThreadingHTTPServer(('0.0.0.0',int(os.environ.get('PORT','8080'))),Handler)
timer=threading.Timer(300,server.shutdown);timer.daemon=True;timer.start()
try: server.serve_forever()
finally: server.server_close()
