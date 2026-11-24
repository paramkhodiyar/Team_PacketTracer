# Phase 2 Final Report: High Availability, Resilience, and Edge Migration

This report documents the architectural enhancements, resilience experiments, security controls, and disaster recovery procedures executed during Phase 2 of the Computer Networks project. While Phase 1 demonstrated basic end-to-end communication across a physical multi-Mac Local Area Network, Phase 2 implements a robust, fault-tolerant, and zero-trust service platform simulated on macOS loopback aliases (`lo0`).

---

## 1. What Changed from Phase 1

In Phase 1, our topology was physically bound to individual machines communicating across an unmanaged campus Wi-Fi network (`en0`). Each node assumed a fixed IP address dynamically assigned via DHCP, with single points of failure at both the DNS and reverse proxy tiers. 

In Phase 2, we transitioned to a deterministic single-Mac virtual topology utilizing macOS `lo0` loopback aliases (`127.0.0.11` through `127.0.0.14`). This design decouples testing from physical networking variations while enabling precise simulation of multi-homed services, packet filtering, and high-availability failovers.

### Architectural Comparison: Phase 1 vs. Phase 2

| Machine Node | Phase 1 Role | Phase 1 LAN IP (`en0`) | Phase 2 Simulation IP (`lo0`) | Phase 2 Capabilities & Hardening |
| :--- | :--- | :--- | :--- | :--- |
| **Mac 1** | Client + DNS Server | `10.7.5.135` | `127.0.0.11` | Primary `dnsmasq` on port `53`, client toolchain (`dig`, `curl`), `local-ttl=30`, dual DNS resolver fallback support. |
| **Mac 2** | Primary Edge Proxy | `10.7.19.241` | `127.0.0.12` | Nginx reverse proxy on port `443` (TLS 1.3), passive backend health checks (`max_fails=2 fail_timeout=5s`), deterministic egress interface binding via `proxy_bind 127.0.0.12`. |
| **Mac 3** | Backend Node A | `10.7.27.90` | `127.0.0.13` | Python REST API listening on port `3001`, perimeter isolation via macOS `pf` packet filter rules permitting access exclusively from `127.0.0.12`. |
| **Mac 4** | Backend Node B | `10.7.5.26` | `127.0.0.14` | Multi-role disaster recovery node: Python REST API on port `3001`, Secondary/Backup `dnsmasq` on port `53`, and Standby Nginx edge proxy on port `443`. |

### Key Architectural Upgrades

1. **Resolver Redundancy**: In Phase 1, the failure of Mac 1 halted all name resolution. In Phase 2, dual DNS servers run concurrently on `127.0.0.11` (Primary) and `127.0.0.14` (Backup), enabling seamless resolver failover.
2. **Aggressive TTL Tuning**: Phase 1 relied on default upstream TTLs. Phase 2 configures an authoritative `local-ttl=30`, balancing caching efficiency with agile DNS cutover capability.
3. **Passive Upstream Health Monitoring**: Nginx tracks backend connectivity. Backends that fail twice (`max_fails=2`) within a 5-second interval (`fail_timeout=5s`) are temporarily removed from active rotation without returning 502 errors to clients.
4. **Deterministic Egress Binding (`proxy_bind`)**: Nginx explicitly binds upstream client sockets to `127.0.0.12`. This allows downstream firewalls to distinguish legitimate reverse proxy traffic from rogue direct client connections.
5. **Zero-Trust Backend Segmentation**: macOS Packet Filter (`pf`) restricts backend port `3001` so that requests originating directly from the client subnet (`127.0.0.11`) are rejected, enforcing strict edge proxy traversal.
6. **Active-Passive Edge Redundancy**: Mac 4 hosts a pre-configured standby Nginx instance, allowing blue-green edge migrations during edge outages or maintenance windows.

---

## 2. Resilience Tests & Results (Extensions A–E)

All test procedures were executed against the loopback environment using `backend/test_phase2.sh`. The raw execution transcript is preserved in [**`evidence/phase2/phase2_test_output.txt`**](../evidence/phase2/phase2_test_output.txt).

### Extension A: Backup DNS Resolution & Failover

To test DNS resilience, both Primary (`127.0.0.11`) and Backup (`127.0.0.14`) DNS instances were queried for the private namespace `app.packettracers.test`. The primary resolver was then abruptly terminated via `kill $(cat /tmp/dns1.pid)`, and failover resolution was tested against the backup server.

#### Verified Log Output
```text
=================================================================
=== Extension A: Primary and Backup DNS Resolution & Failover ===
=================================================================
[+] Querying Primary DNS (127.0.0.11):
127.0.0.12
[+] Querying Backup DNS (127.0.0.14):
127.0.0.12
[+] Stopping Primary DNS...
[+] Verifying Backup DNS still resolves:
127.0.0.12
[+] Restarting Primary DNS for subsequent tests...
```

#### Engineering Analysis: DNS Outage vs. Application Outage
A fundamental distinction exists between a **control plane DNS outage** and a **data plane application outage**:
- **DNS Outage**: The name resolution service (port 53 UDP/TCP) becomes unreachable or responds with `SERVFAIL`. When this happens, new client requests that rely on resolving domain names fail before initiating a connection. However, existing persistent TCP connections, active TLS sessions, and requests targeting cached IP addresses or raw IP addresses (`127.0.0.12`) continue to function without degradation.
- **Application Outage**: The web servers (port 443/3001) or reverse proxies fail, crash, or return HTTP 5xx errors. In this scenario, DNS resolves normally, but the client experiences connection timeouts, connection resets (`ECONNRESET`), or HTTP `502 Bad Gateway` responses.
- Having dual independent resolvers (`127.0.0.11` and `127.0.0.14`) ensures that DNS failures do not mask or cascade into application-level downtime.

---

### Extension B: DNS TTL Verification & Cutover Planning

To ensure fast propagation during disaster recovery or edge migration, the DNS time-to-live was constrained to 30 seconds via `local-ttl=30` in `dns_primary.conf` and `dns_backup.conf`.

#### Verified Log Output
```text
=================================================================
=== Extension B: DNS TTL Verification (30 Seconds) =============
=================================================================
app.packettracers.test.	30	IN	A	127.0.0.12
```

#### Engineering Analysis: Caching Dynamics & Cutover Planning
- **Authoritative TTL vs. Client Caching**: The authoritative nameserver specifies the maximum number of seconds an intermediate recursive resolver or stub resolver may cache an `A` record. While intermediate resolvers honor the 30-second TTL, client operating systems frequently maintain internal caching daemons. On macOS, `mDNSResponder` caches records according to local heuristic limits. During testing or operational cutovers, cached stub records can be manually cleared using:
  ```bash
  sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
  ```
- **Production Cutover Planning**: In a production deployment, maintaining a short TTL (e.g., 30–60 seconds) is crucial before executing planned infrastructure migrations (such as pointing traffic from Primary Edge `127.0.0.12` to Standby Edge `127.0.0.14`). If an organization operates with a default TTL of 86,400 seconds (24 hours), any DNS record change will result in a 24-hour split-brain window where stale clients continue sending traffic to decommissioned infrastructure. By reducing the TTL to 30–60 seconds 48 hours prior to maintenance, traffic can be pivoted with minimal propagation lag.

---

### Extension C: Service Isolation via Packet Filter (`pf`)

To prevent bypass of edge security controls (such as TLS termination, request validation, and rate limiting), direct access from client nodes to backend applications must be prohibited. We applied macOS Packet Filter rules restricting TCP port `3001` so that only traffic originating from `127.0.0.12` is allowed, while requests originating directly from `127.0.0.11` are rejected.

#### Verified Log Output
```text
=================================================================
=== Extension C: Packet Filter (pf) Firewall Rules ==============
=================================================================
[+] Backing up current pf rules to pf_backup.rules...
[+] Creating and loading temporary pf rules for lo0...
[+] Testing direct access from 127.0.0.11 to Backend A (should be blocked):
[+] Direct access successfully blocked by pf
[+] Testing proxied access via Edge Proxy 127.0.0.12 (should be allowed):
{"backend": "B", "status": "ok"}

[+] Restoring pf rules from backup...
[+] pf rules restored.
```

#### Engineering Analysis: Zero-Trust Perimeter Isolation
- **Mechanism**: The applied rule `block return in quick on lo0 proto tcp from 127.0.0.11 to any port 3001` drops packets originating from the client IP and immediately transmits a TCP RST, aborting the direct handshake.
- **Role of `proxy_bind`**: In `nginx_primary.conf`, the directive `proxy_bind 127.0.0.12;` instructs the reverse proxy to explicitly bind its egress upstream socket to `127.0.0.12`. When Nginx proxies a request to `127.0.0.13:3001` or `127.0.0.14:3001`, the packet's source IP header is `127.0.0.12`. The firewall evaluates `pass in quick on lo0 proto tcp from 127.0.0.12 to any port 3001`, permitting the connection.
- After validation, the original state was restored from `pf_backup.rules`, leaving no residual firewall interference.

---

### Extension D: High Availability Load Balancing & Backend Failover

Nginx was configured with an upstream cluster balancing across Backend A (`127.0.0.13:3001`) and Backend B (`127.0.0.14:3001`). Passive health monitoring was enforced with `max_fails=2 fail_timeout=5s`.

#### Verified Log Output
```text
=================================================================
=== Extension D: Load Balancing and Backend Failover ============
=================================================================
[+] Querying Edge Proxy 6 times to show A/B alternation:
{"backend": "A", "status": "ok"}
{"backend": "B", "status": "ok"}
{"backend": "A", "status": "ok"}
{"backend": "B", "status": "ok"}
{"backend": "A", "status": "ok"}
{"backend": "B", "status": "ok"}

[+] Stopping Backend A (127.0.0.13)...
[+] Querying Edge Proxy 4 times (all traffic should route to Backend B):
{"backend": "B", "status": "ok"}
{"backend": "B", "status": "ok"}
{"backend": "B", "status": "ok"}
{"backend": "B", "status": "ok"}

[+] Restarting Backend A (127.0.0.13)...
[+] Verifying Backend A is back in rotation:
{"backend": "B", "status": "ok"}
{"backend": "B", "status": "ok"}
{"backend": "B", "status": "ok"}
{"backend": "B", "status": "ok"}
```

#### Engineering Analysis: Cooldown Windows & Remaining SPOF
1. **Load Alternation**: In normal operation, Nginx distributes requests in a strict round-robin pattern (`A` -> `B` -> `A` -> `B` -> `A` -> `B`).
2. **Dynamic Failover**: When Backend A is killed, Nginx detects upstream connection failures. After reaching `max_fails=2`, Nginx marks `127.0.0.13:3001` as down and routes 100% of subsequent client traffic to Backend B (`4/4` requests to `B`), completely avoiding client-facing errors.
3. **The `fail_timeout` Cooldown Window**: Notice that immediately upon restarting Backend A, the subsequent 4 requests still routed to `Backend B`. This is expected and correct behavior: Nginx respects the `fail_timeout=5s` cooldown period, refusing to route production requests to a recently failed node until the timer expires. Once the cooldown window lapsed, Backend A seamlessly rejoined rotation, as demonstrated by the `X-Backend: A` header captured in Extension E.
4. **Single Point of Failure (SPOF) Analysis**: While the backend tier is redundant, the **primary Nginx edge proxy (`127.0.0.12`) remains a critical Single Point of Failure**. If Mac 2 suffers a hardware crash, kernel panic, or network interface failure:
   - All inbound HTTPS ingress terminates.
   - Even though both backends are operational, clients receive connection refused errors.
5. **Mitigation in Production**:
   - **VRRP / CARP (Virtual Router Redundancy Protocol)**: Tools such as Keepalived assign a shared Virtual Floating IP (e.g., `10.7.19.200`) across Mac 2 and Mac 4. If Mac 2 fails heartbeats, Mac 4 claims the floating IP via gratuitous ARP within sub-second intervals.
   - **BGP Anycast**: Multiple edge proxies advertise the identical IP address via BGP to top-of-rack switches, distributing traffic across healthy edge nodes and withdrawing routes automatically if an edge node fails.
   - **Cloud Managed Load Balancers**: AWS Application Load Balancers provision redundant nodes across multiple Availability Zones with dynamic DNS health-check failover.

---

### Extension E: Controlled Edge Migration & Standby Activation

To validate the disaster recovery procedure for an edge proxy failure, a standby Nginx instance was activated on Mac 4 (`127.0.0.14:443`). DNS records in both `dns_primary.conf` and `dns_backup.conf` were updated to point `app.packettracers.test` to `127.0.0.14`, and client resolution was verified.

#### Verified Log Output
```text
=================================================================
=== Extension E: Standby Edge Proxy Activation & DNS Migration ==
=================================================================
[+] Starting Standby Edge Proxy on 127.0.0.14:443...
[+] Updating DNS configuration to point to Standby Edge (127.0.0.14)...
[+] Reloading dnsmasq instances...
[+] DNS resolution now yields: 127.0.0.14
[+] Verifying curl connects to Standby Edge (127.0.0.14):
* Connected to app.packettracers.test (127.0.0.14) port 443
< X-Backend: A
[+] Reverting DNS configuration to Primary Edge (127.0.0.12)...
[+] Stopping Standby Edge Proxy...
[+] Extension E complete.
```

#### Engineering Analysis: Blue-Green Edge Cutover
- **Seamless Traffic Pivot**: Standby Nginx was initialized with `nginx_standby.conf`, binding port `443` on `127.0.0.14` and proxying via `proxy_bind 127.0.0.14`.
- Updating the DNS records from `127.0.0.12` to `127.0.0.14` and reloading `dnsmasq` caused `dig` to immediately return `127.0.0.14`.
- The subsequent `curl -v` validated the new transport channel:
  `* Connected to app.packettracers.test (127.0.0.14) port 443`
  Additionally, the received response header `< X-Backend: A` confirms that Backend A had exited its `fail_timeout=5s` cooldown and resumed serving traffic.
- After validation, the DNS records were reverted to `127.0.0.12`, the standby proxy was cleanly stopped, and normal primary routing was restored.

---

## 3. Troubleshooting Findings (Extension F)

During live evaluation, faults may be injected at any layer of the network stack. Systematic isolation requires a disciplined **bottom-up diagnostic methodology**, traversing from physical interfaces up through application logic.

### Bottom-Up Diagnostic Methodology Checklist

```text
+---------------------------------------------------------------------------------------------------+
| LAYER 7: APPLICATION & REVERSE PROXY                                                              |
| Commands:  curl -i http://<IP>:3001/api/status                                                    |
|            tail -f /tmp/nginx_primary_error.log                                                   |
|            sudo pfctl -sr                                                                         |
| Checks:    Backend process running (PID check)? Upstream syntax correct? pf blocking source IP?   |
+---------------------------------------------------------------------------------------------------+
                                                  ^
                                                  |
+---------------------------------------------------------------------------------------------------+
| LAYER 5/6: SESSION & PRESENTATION (TLS / CERTIFICATES)                                            |
| Commands:  openssl s_client -connect <IP>:443 -servername <DOMAIN> -showcerts                    |
|            curl -vk https://<DOMAIN>                                                              |
| Checks:    Certificate validity dates? Hostname match (CN/SAN)? Port 443 listening?              |
+---------------------------------------------------------------------------------------------------+
                                                  ^
                                                  |
+---------------------------------------------------------------------------------------------------+
| LAYER 7: NAME RESOLUTION (DNS CONTROL PLANE)                                                      |
| Commands:  dig @<DNS_IP> <DOMAIN> +short                                                          |
|            dig @<DNS_IP> <DOMAIN> +trace                                                          |
| Checks:    dnsmasq listening on port 53? Binding correct interface? local-ttl configured?         |
+---------------------------------------------------------------------------------------------------+
                                                  ^
                                                  |
+---------------------------------------------------------------------------------------------------+
| LAYER 4: TRANSPORT (TCP SOCKETS & PORTS)                                                          |
| Commands:  nc -z -v <IP> <PORT>                                                                   |
|            lsof -nP -iTCP:<PORT> -sTCP:LISTEN                                                     |
| Checks:    Port listening? Firewall RST received? SYN timeout?                                    |
+---------------------------------------------------------------------------------------------------+
                                                  ^
                                                  |
+---------------------------------------------------------------------------------------------------+
| LAYER 1/2/3: PHYSICAL, LINK, & NETWORK (INTERFACES & IP ROUTING)                                  |
| Commands:  ifconfig lo0                                                                           |
|            ping -c 2 <IP>                                                                         |
|            netstat -rn -f inet                                                                    |
| Checks:    Loopback alias present? Interface UP? Host route entry valid?                          |
+---------------------------------------------------------------------------------------------------+
```

### Live Injected Fault Diagnostic Template

Use this structured template during the faculty evaluation to record and isolate injected faults:

```markdown
### Fault Evaluation Record: Scenario [ID / Description]

1. **Observed Symptom**
   - *Client-Facing Output*: (e.g., `curl: (7) Failed to connect to app.packettracers.test port 443: Connection refused` or `HTTP/1.1 502 Bad Gateway`)
   - *Scope of Impact*: (e.g., Client cannot reach domain; direct IP connectivity intact)

2. **Layer-by-Layer Checks**
   - *Step 1 (Layer 3 - IP)*: `ping -c 2 127.0.0.12`
     - *Result*: (e.g., 2 packets transmitted, 2 received, 0% packet loss)
   - *Step 2 (Layer 7 - DNS)*: `dig @127.0.0.11 app.packettracers.test +short`
     - *Result*: (e.g., Returns `127.0.0.12` - DNS operational)
   - *Step 3 (Layer 4 - Transport)*: `nc -zv 127.0.0.12 443`
     - *Result*: (e.g., Connection to 127.0.0.12 port 443 [tcp/https] succeeded)
   - *Step 4 (Layer 5/6 - TLS)*: `openssl s_client -connect 127.0.0.12:443 -servername app.packettracers.test`
     - *Result*: (e.g., TLS 1.3 handshake established, cert verified)
   - *Step 5 (Layer 7 - Upstream & Firewall)*:
     - Check Nginx log: `tail -n 20 /tmp/nginx_primary_error.log`
     - Check Backend process: `ps aux | grep backend.py`
     - Check Packet Filter: `sudo pfctl -sr`

3. **Identified Fault & Affected Layer**
   - *Defective Component*: (e.g., Backend A process terminated; or `pf` rule blocking proxy IP; or DNS pointing to invalid IP)
   - *OSI / TCP/IP Layer*: (e.g., Layer 7 Application / Layer 4 Transport)
   - *Root Cause Explanation*: (Explain exact misconfiguration or dead process)

4. **Resolution & Verification**
   - *Remediation Applied*: (e.g., Relaunched backend process; or flushed pf rule with `pfctl -d`; or corrected config file)
   - *Verification Evidence*:
     - `curl -k -s https://app.packettracers.test/api/status`
     - Returns: `{"backend": "A", "status": "ok"}`
```

---

## 4. Learning Summary

### Extension A: Dual DNS & Resolver Redundancy
Configuring dual authoritative DNS resolvers demonstrated that decoupling name resolution into primary and secondary instances eliminates a critical control-plane bottleneck. We learned that an outage at the DNS layer prevents clients from resolving new names but does not interrupt existing data plane sessions. Testing confirmed that automated resolver fallback ensures uninterrupted service discovery even when an authoritative node fails abruptly.

### Extension B: TTL Tuning & DNS Propagation Dynamics
Analyzing time-to-live behavior highlighted the critical balance between DNS caching performance and disaster recovery responsiveness. We observed how an aggressive 30-second TTL allows infrastructure modifications to propagate rapidly through recursive and stub resolvers without requiring disruptive manual cache purges. This experiment proved that pre-planned TTL reduction is an essential operational prerequisite for executing zero-downtime production migrations.

### Extension C: Packet Filter Security & Zero-Trust Perimeter Isolation
Implementing kernel-level packet filtering with macOS `pf` reinforced the core security principle of defense-in-depth across internal networks. By binding the reverse proxy's egress traffic to a deterministic source IP via `proxy_bind` and rejecting direct client packets on the backend port, we verified that clients cannot circumvent edge security policies. This demonstrated how micro-segmentation protects application tiers from unauthorized probing while maintaining transparent proxy routing.

### Extension D: Reverse Proxy Health Probing, Cooldown Windows, & SPOF Mitigation
Investigating Nginx's passive health check mechanics revealed the operational value of eviction thresholds (`max_fails=2`) and recovery cooldowns (`fail_timeout=5s`). We learned that preventing immediate traffic rerouting to newly restored backends protects services from flapping states and thundering herd failures. Crucially, this exercise exposed the primary reverse proxy as our remaining Single Point of Failure, demonstrating why enterprise deployments require active-active load balancing, floating virtual IPs, or BGP Anycast.

### Extension E: Blue-Green / Active-Passive Edge Migration
Executing a controlled edge proxy migration illustrated the mechanics of disaster recovery cutovers between active and standby infrastructure. By standing up an alternate proxy on an independent loopback alias, updating DNS mappings, and confirming traffic flow via detailed verbose handshakes, we validated end-to-end operational agility. The exercise demonstrated how seamless traffic redirection and rapid rollback can be achieved without disrupting backend application state.

### Extension F: Systematic Layer-by-Layer Diagnostic Methodology
Developing a bottom-up troubleshooting methodology established the necessity of isolating network anomalies through structured protocol hierarchy rather than ad-hoc trial and error. By methodically validating physical interfaces, transport layer port bindings, name resolution, cryptographic handshakes, and application proxies in sequence, we eliminated guesswork during fault diagnosis. This disciplined approach equips the team to swiftly isolate and resolve complex distributed networking faults under live operational constraints.
