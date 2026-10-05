import http.server, json

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('X-Backend', 'B')
        self.send_header('Cache-Control', 'max-age=60')
        self.end_headers()
        data = {"backend": "B", "status": "ok"} if self.path == '/api/status' else {"msg": "Backend B running"}
        self.wfile.write(json.dumps(data).encode())

print("Starting Backend B on port 3001...")
http.server.HTTPServer(('0.0.0.0', 3001), Handler).serve_forever()
