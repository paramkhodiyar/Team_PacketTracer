# Scenario 2: DNS Record Points to a Wrong IP Address

- **Overview & Symptom:** The authoritative DNS server (`dnsmasq` on Mac 1) contains an incorrect mapping that directs domain queries to an invalid or unresponsive IP address instead of the Nginx edge proxy (Mac 2 at 10.7.19.241).
- **Affected OSI Layer:** Layer 7 / Application Layer (DNS mapping).
- **Step-by-Step Reproduction:** Edit the configuration file on Mac 1 to point to a non-existent proxy IP (e.g., `10.7.19.99`), restart the DNS service, and flush the client cache:
  ```bash
  # On Mac 1
  # Modify address=/app.packettracers.test/10.7.19.241 to point to 10.7.19.99 in dnsmasq.conf
  sudo brew services restart dnsmasq
  sudo dscacheutil -flushcache
  curl -v https://app.packettracers.test
  ```
- **System Evidence:** DNS resolves to the wrong IP address (`10.7.19.99`). The `curl` command eventually times out or throws a connection error because there is no server listening at that IP:
  ```text
  * Trying 10.7.19.99:443...
  * connect to 10.7.19.99 port 443 failed: Operation timed out
  ```
- **Resolution Steps:** Edit the `dnsmasq.conf` file on Mac 1 (typically located at `/opt/homebrew/etc/dnsmasq.conf`) to correct the `address=/app.packettracers.test/10.7.19.241` directive, restart the service, and flush the cache again:
  ```bash
  # Edit dnsmasq.conf to correct the IP
  sudo brew services restart dnsmasq
  sudo dscacheutil -flushcache
  ```
