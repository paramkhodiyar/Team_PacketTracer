# Scenario 5: Wrong Destination Port on the Client

- **Overview & Symptom:** The client attempts to establish a connection to a non-existent or unbound port (e.g., port 9999) on a reachable host IP address (Mac 2 at 10.7.19.241). The network layer successfully routes the packets, but the transport layer responds with a refusal because no service is actively listening on that port.
- **Affected OSI Layer:** Layer 4 / Transport Layer.
- **Step-by-Step Reproduction:** Use `curl` on the client (Mac 1) to explicitly target an incorrect port on the proxy domain:
  ```bash
  curl -v https://app.packettracers.test:9999
  ```
- **System Evidence:** The terminal outputs a connection refused error. From a network capture perspective, Wireshark would show a TCP RST (reset) packet sent from Mac 2 back to Mac 1:
  ```text
  * Trying 10.7.19.241:9999...
  * connect to 10.7.19.241 port 9999 failed: Connection refused
  * Failed to connect to app.packettracers.test port 9999: Connection refused
  ```
- **Resolution Steps:** Update the client request URL or command to target the correct well-known service port (port 443 for HTTPS edge proxy traffic, or 3001 for direct backend access):
  ```bash
  curl -v https://app.packettracers.test
  ```
