import http.server
import json
import sys

if len(sys.argv) < 3:
    print(f"Usage: {sys.argv[0]} <bind_ip> <backend_name>")
    sys.exit(1)

bind_ip = sys.argv[1]
backend_name = sys.argv[2]
port = 3001

class BackendHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path in ('/', '/api/status'):
            payload = json.dumps({"backend": backend_name, "status": "ok"}).encode('utf-8')
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('X-Backend', backend_name)
            self.send_header('Cache-Control', 'max-age=60')
            self.send_header('Content-Length', str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        else:
            self.send_error(404, "Not Found")

    def log_message(self, format, *args):
        pass

class ReusableHTTPServer(http.server.HTTPServer):
    allow_reuse_address = True

if __name__ == '__main__':
    server = ReusableHTTPServer((bind_ip, port), BackendHandler)
    server.serve_forever()
