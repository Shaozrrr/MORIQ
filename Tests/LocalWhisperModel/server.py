from http.server import BaseHTTPRequestHandler, HTTPServer
import time
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        value = b'x' if self.path == '/bad' else b'a'
        self.send_response(200); self.send_header('Content-Length', str(1024 * 1024)); self.end_headers()
        try:
            for _ in range(128):
                self.wfile.write(value * 8192); self.wfile.flush()
                if self.path == '/slow': time.sleep(0.02)
        except (BrokenPipeError, ConnectionResetError): pass
server = HTTPServer(('127.0.0.1', 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
