# Scenario 1: Wrong DNS Server Configured on Client

- **Overview & Symptom:** The client machine is misconfigured to use a public internet resolver (e.g., Google's 8.8.8.8) rather than the local team DNS server (Mac 1 at 10.7.5.135). Name lookup fails with an NXDOMAIN error because public servers have no record of the private `.test` namespace.
- **Affected OSI Layer:** Layer 7 / Application Layer (DNS).
- **Step-by-Step Reproduction:** Intentionally bypass the local DNS server by querying a public resolver directly from Mac 1:
  ```bash
  dig @8.8.8.8 app.packettracers.test
  ```
- **System Evidence:** The terminal outputs an `NXDOMAIN` error status in the DNS response header, indicating the domain does not exist on the public internet:
  ```text
  ;; ->>HEADER<<- opcode: QUERY, status: NXDOMAIN
  ```
- **Resolution Steps:** Revert the client's network DNS settings to point explicitly to Mac 1 (`10.7.5.135`), flush the local DNS cache, and re-verify resolution:
  ```bash
  sudo dscacheutil -flushcache
  sudo killall -HUP mDNSResponder
  dig app.packettracers.test
  ```
