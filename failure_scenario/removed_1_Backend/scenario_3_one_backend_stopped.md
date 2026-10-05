# Scenario 3: One Backend is Stopped

- **Overview & Symptom:** An application backend instance (e.g., Backend A on Mac 3 at 10.7.27.90) is terminated or crashes. The Nginx edge proxy (Mac 2) detects the failure and automatically fails over, routing 100% of incoming traffic to the surviving node (Backend B on Mac 4 at 10.7.5.26).
- **Affected OSI Layer:** Layer 7 / Application Layer (HTTP Reverse Proxy / Load Balancing).
- **Step-by-Step Reproduction:** Stop the Python backend service on Mac 3. Then, run multiple requests from the client (Mac 1) to the load balancer:
  ```bash
  # On Mac 1
  for i in {1..6}; do curl -s https://app.packettracers.test/api/status; echo; done
  ```
- **System Evidence:** The `curl` responses show only Backend B's identifier in the JSON payload, rather than alternating between A and B. No client-facing errors (like 502 Bad Gateway) occur, proving a transparent failover:
  ```json
  {"backend": "B", "status": "ok"}
  {"backend": "B", "status": "ok"}
  {"backend": "B", "status": "ok"}
  ```
- **Resolution Steps:** Restart the application script on the downed machine (Mac 3), which immediately allows Nginx to resume its round-robin load balancing across both nodes:
  ```bash
  # On Mac 3
  python3 server.py
  ```
