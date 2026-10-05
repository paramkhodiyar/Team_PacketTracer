# Scenario 4: Both Backends are Stopped

- **Overview & Symptom:** Both backend servers (Mac 3 at 10.7.27.90 and Mac 4 at 10.7.5.26) are taken offline simultaneously while the Nginx edge proxy (Mac 2) remains running. Clients successfully complete the TCP and TLS handshakes with Nginx, but the proxy returns an error because no upstream servers are available to process the request.
- **Affected OSI Layer:** Layer 7 / Application Layer (HTTP Reverse Proxy).
- **Step-by-Step Reproduction:** Terminate the Python backend processes on both Mac 3 and Mac 4. Then, attempt to access the API endpoint from the client:
  ```bash
  # On Mac 1
  curl -I https://app.packettracers.test/api/status
  ```
- **System Evidence:** Nginx handles the secure connection successfully but returns an HTTP `502 Bad Gateway` status code in the response headers, signifying all upstream routes are dead:
  ```text
  HTTP/1.1 502 Bad Gateway
  Server: nginx
  ```
- **Resolution Steps:** Launch the backend server scripts on both Mac 3 and Mac 4, then verify that the service has fully recovered:
  ```bash
  # On Mac 3 and Mac 4
  python3 server.py

  # On Mac 1
  curl -I https://app.packettracers.test/api/status
  ```
