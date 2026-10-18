# NetScope 2.1: Network Health Console

NetScope is a Bash script that checks every link between your computer and the internet and reports the result in plain language. It first shows a friendly summary. If you press **A**, it then shows a technical report with the raw numbers.

> NetScope is a **local, read-only check-up**. It never scans other devices, tests open ports, or changes any configuration. The score is not an official speed rating.

---

## Contents

1. [Quick start](#quick-start)
2. [How a run works](#how-a-run-works)
3. [Part 1: The summary screen](#part-1-the-summary-screen)
4. [Part 2: Advanced diagnostics](#part-2-advanced-diagnostics)
5. [How the score is calculated](#how-the-score-is-calculated)
6. [Reading the results: troubleshooting guide](#reading-the-results-troubleshooting-guide)
7. [Glossary](#glossary)
8. [Limitations and notes](#limitations-and-notes)
9. [FAQ](#faq)

---

## Quick start

```bash
chmod +x netscope.sh
./netscope.sh            # standard check-up
./netscope.sh --speed    # also measure download/upload speed
./netscope.sh --live     # live monitor
./netscope.sh --json     # machine-readable output
```

| Option | What it does |
|---|---|
| *(none)* | Runs the check-up (about 5 seconds), shows the summary, then offers the advanced report. |
| `--advanced`, `-a` | Shows the summary and then the full technical report without asking. |
| `--speed`, `-s` | Measures download and upload speed. Without it, streaming shows "speed not measured". |
| `--live`, `-l` | Opens a live monitor instead of a one-off report (press `q` to quit). |
| `--json`, `-j` | Prints the results as JSON. No colours, no questions, no banner. |
| `--no-prompt`, `-n` | Never asks questions (useful in scripts). |
| `--no-color` | Turns colours off. |
| `--ascii` | Uses plain ASCII instead of special symbols. |
| `--version`, `--help` | Show the version or the help text. |

### Exit status

NetScope's exit code reflects the health score, so other scripts can react to it.

| Code | Meaning |
|---|---|
| `0` | Healthy (score 75 or more). |
| `10` | Needs attention (score 55 to 74). |
| `20` | Poor (score below 55). |
| `1` | NetScope could not run (for example `ip` is missing). |
| `2` | Bad command-line option. |

### What's new in 2.1

- Wi-Fi signal and link rate fall back to NetworkManager and `iwconfig`, so drivers such as Broadcom `wl` no longer show `n/a`. Estimated values are marked with `~`.
- Error counters now include CRC errors and drops. NetScope also checks whether they **grew during the scan**, so old totals from hours ago no longer cost points.
- The direct DNS test uses `dig`'s own query time, which removes process start-up noise.
- New `--json` output and exit codes.

At the end of the summary, press **A** for the advanced details or **Enter** to finish.

### Tools the script uses

NetScope uses whichever of these tools are installed. The "Tools found" line in the report lists what it found.

`ip` · `ping` · `curl` · `iw` · `iwconfig` · `nmcli` · `ethtool` · `resolvectl` · `dig` · `tracepath` · `traceroute` · `ss`

If a tool is missing, the related checks may be skipped or show `n/a`.

---

## How a run works

```
Scan (~5 s)  →  Summary screen  →  [A] Advanced diagnostics  →  Done
```

1. **Scan.** NetScope pings the router and public DNS servers, resolves a few domains, makes an HTTPS request, reads the interface counters, and traces the route.
2. **Summary.** The results are translated into a journey diagram, a few key metrics, a "what you can do" table, and one health score.
3. **Advanced (optional).** The same data is shown in full technical detail.

---

## Part 1: The summary screen

### 1.1 The journey of your data

```
  YOU           WI-FI         ROUTER        INTERNET       WEBSITES
   ●━━━━━━━━━━━━━━●━━━━━━━━━━━━━━●━━━━━━━━━━━━━━●━━━━━━━━━━━━━━●
 Ready        Connected      Replying        Online         Working
```

A web page travels through five stages. Each stage is a dot with a status label underneath. **The first red dot shows where the chain breaks.**

| Stage | Healthy label | What is being tested |
|---|---|---|
| **You** | Ready | Your network adapter exists and is up. |
| **Wi-Fi** | Connected | The adapter is associated with an access point and has an IP address. |
| **Router** | Replying | The default gateway answers pings. |
| **Internet** | Online | Traffic reaches the public internet (ping to 1.1.1.1 / 8.8.8.8). |
| **Websites** | Working | DNS lookups and an HTTPS request succeed. |

Because the chain is checked in order, a problem at "Router" means the later stages cannot be trusted either. Fix the first red dot first.

### 1.2 Right now

| Metric | Example | Meaning |
|---|---|---|
| **Reply speed** | `6.6 ms` | Average round-trip time (latency) to an internet server. Lower is better. The sparkline has one bar per test, and a taller bar means a slower reply. |
| **Lost data** | `0%` | Share of test packets that never came back (packet loss). Anything above 0% is worth noticing. |
| **Downloading** | `↓ 26 kbps` | Current receive rate on **this computer's interface**, not your provider's maximum. |
| **Uploading** | `↑ 19 kbps` | Current send rate on this interface. |
| **Wi-Fi network** | `Juice (5 GHz)` | The network name (SSID) and frequency band. |

> The download and upload figures here show **current traffic**, not capacity. They are low when you are idle. Use `--speed` for a real speed test.

### 1.3 What you can do right now

Star ratings translate the technical numbers into everyday activities:

| Activity | Mostly depends on |
|---|---|
| Browsing websites | DNS speed, latency, packet loss |
| Video calls | Latency, jitter, packet loss |
| Streaming video | Bandwidth (needs `--speed`, otherwise "speed not measured") |
| Online gaming | Latency, jitter, packet loss |

Ratings run from ★ to ★★★★★ (Great), with a short word label beside each.

### 1.4 Overall network health

```
  ┃  \(^o^)/   Everything looks great!
  ┃  ████████████████████  100/100  EXCELLENT
  ┃  No problems found.
```

A single score from 0 to 100 with a face, a progress bar, a rating word, and a short list of any problems found. See [How the score is calculated](#how-the-score-is-calculated).

---

## Part 2: Advanced diagnostics

Shown after pressing **A**. The sections appear in this order.

### 2.1 System

| Field | Meaning |
|---|---|
| Host | Computer name. |
| OS / kernel | Distribution and kernel version. |
| Report time | When the scan ran (local time zone). |
| Tools found | Which diagnostic tools were available (see [Quick start](#quick-start)). |

### 2.2 Check results

A pass/fail list. Each line has a status tag:

| Tag | Meaning |
|---|---|
| `✓ OK` | Check passed. |
| `• INFO` | Informational. Not a fault. |
| `! WARN` | Something is degraded and worth looking at. |
| `✗ FAIL` | Check failed and affects connectivity. |

The checks:

| Check | What it verifies |
|---|---|
| **Network adapter** | The active interface (here `wlp3s0`), its type (wifi/ethernet), and its state (`up`). |
| **Device address** | The IPv4 address with prefix length, and the IPv6 address if any. |
| **Default route** | Which gateway and interface carry your internet traffic. |
| **Router (gateway)** | 20 pings to the router. Shows replies received and the average time. |
| **DNS lookups** | Resolves several domains through the system resolver. Shows success count, average time and slowest time. |
| **Internet (HTTPS)** | A real HTTPS request. Shows the HTTP status and total time. |
| **Latency / jitter / loss** | Summary of the ping test to a public server (8.8.8.8). |
| **Sign-in page check** | Detects a captive portal (hotel or airport Wi-Fi login). `none (HTTP 204)` means no login page is intercepting traffic. |
| **IPv6** | Whether IPv6 reaches the internet. "Not available" is common and not a fault. |

### 2.3 All network interfaces

| Column | Meaning |
|---|---|
| NAME | Interface name. `lo` is the loopback (the computer talking to itself). |
| STATE | `up`, `down`, or `unknown` (normal for loopback). |
| IPV4 | Address and prefix. |
| MTU | Largest packet size (bytes) the interface sends without splitting. 1500 is standard. |
| RX / TX | Total data received and sent **since boot**. |
| ERR | Errors reported by the interface. |
| DROP | Packets dropped by the interface. |

The `▸` marker shows the interface that carries your default route.

### 2.4 Active adapter and counters

**Adapter details:** type and driver (e.g. `wifi / wl`), MAC address, MTU, and interface flags.

**Counters since boot:**

| Counter | Meaning |
|---|---|
| `rx_packets` / `tx_packets` | Packets received / sent. |
| `rx_errors` / `tx_errors` | Packets that arrived or left damaged. |
| `rx_dropped` / `tx_dropped` | Packets discarded (full buffers, filtered, unwanted protocols). |
| `rx_crc_errors` | Frames that failed an integrity check, often a sign of a noisy radio link. |
| `rx_missed_errors` | Packets the hardware missed because it was overloaded. |
| `tx_carrier_errors`, `collisions` | Mostly relevant to wired links. Usually 0 on Wi-Fi. |
| **Error rate** | Errors (including CRC errors) as a percentage of all packets. |
| **Drop rate** | Dropped packets as a percentage of all packets. |
| **During this scan** | New errors and drops that appeared while NetScope was running. |

> **Counters are cumulative since boot.** A number like 2298 dropped packets could have happened hours ago. NetScope reads the counters before and after the scan. If nothing grew, it says the errors are historical and does not lower your score.

### 2.5 Wi-Fi link

| Field | Meaning |
|---|---|
| Network (SSID) | Wi-Fi network name. |
| Access point (BSSID) | MAC address of the specific access point you are connected to. Useful in mesh setups. |
| Band / channel | e.g. `5 GHz / ch 36 (5180 MHz)`. 5 GHz is faster but shorter range than 2.4 GHz. |
| Signal | Received signal strength in dBm. Closer to 0 is stronger: about -50 is excellent, -67 is good, -70 or lower is weak. |
| Link rate (tx / rx) | Negotiated speed between your device and the access point. This is the link speed, not your internet speed. |
| Power saving | Whether the Wi-Fi card is allowed to sleep between packets. Turning it off can reduce latency spikes on some systems. |
| Security | Encryption type (e.g. WPA2). |
| Neighbours on channel | How many other networks share your channel. More neighbours means more interference. This comes from a cached scan, so it can be out of date. |

> **Estimated values (`~`):** Some drivers do not expose signal and link rate to `iw`. The proprietary Broadcom `wl` driver is a known example. NetScope then tries `/proc/net/wireless`, `iwconfig` and NetworkManager's cached scan list. NetworkManager only reports a 0 to 100 quality figure, so the dBm value is estimated as quality / 2 - 100. If every source is silent, the line shows `n/a`. This is a driver limitation, not a network fault.

### 2.6 Routing and neighbours

- **Routing table.** Shows where traffic goes. The `default via ...` line is the path to the internet. The `192.168.x.x/24` line is your local network. `fd..` and `fe80::` lines are IPv6.
- **Gateway / Gateway MAC.** Your router's IP and hardware address.
- **Neighbour cache.** Devices this computer talked to recently, with their state (`REACHABLE` is active, `STALE` is not used lately). **It is not a network scan.**

### 2.7 DNS

DNS turns names such as `example.com` into IP addresses.

| Item | Meaning |
|---|---|
| Servers in use | Which DNS server(s) your computer asks. Often your router. |
| Protocol flags | `+` or `-` for DefaultRoute, LLMNR, mDNS, DNSOverTLS, and DNSSEC support. |
| **System resolver lookups** | Real lookups of several well-known sites with timing. Repeat lookups may come from a local cache, so they look faster than they are. |
| **Direct resolver test** | Asks each server directly (your router, 1.1.1.1, 8.8.8.8) to compare them. Times are `dig`'s own query time. A cold first query can still be a little slower. |

> If your router's DNS is much slower than 1.1.1.1 or 8.8.8.8, consider changing DNS servers.

### 2.8 Latency, jitter and packet loss

Each target gets 20 pings:

| Column | Meaning |
|---|---|
| SENT / RECV | Packets sent and received. |
| LOSS | Percentage lost. |
| MIN / AVG / MAX | Fastest, average and slowest reply. |
| JITTER | Average change between consecutive pings. Lower is steadier. |

Three targets show where a problem sits:

| Target | Shows |
|---|---|
| **Router** | Quality of your local Wi-Fi link. |
| **Cloudflare 1.1.1.1** | Path to the internet, via your ISP. |
| **Google 8.8.8.8** | A second internet reference point. |

If the router is fast and the others are slow, the issue is outside your home. If the router itself is slow or lossy, the issue is your Wi-Fi.

**Rough guide:**

| | Good | Acceptable | Poor |
|---|---|---|---|
| Latency to internet | under 30 ms | 30 to 100 ms | over 100 ms |
| Jitter | under 5 ms | 5 to 20 ms | over 20 ms |
| Packet loss | 0% | under 1% | over 2% |

### 2.9 Web / TLS timing and public address

One HTTPS request is broken into stages. Each time is **cumulative**, so every row includes the ones above it.

| Stage | Meaning |
|---|---|
| DNS lookup | Time to resolve the name. |
| TCP connect | Time until a connection to the server opens. |
| TLS handshake | Time until encryption is set up. |
| First byte | Time until the server starts replying. |
| Total | Whole request. |

Also shown:

- **Your public IP** and country: the address websites see.
- **Negotiated TLS / edge**: the encryption version (e.g. TLSv1.3) and the Cloudflare data center that answered (e.g. `MXP` = Milan).
- **IPv6**: `0 = not reachable`.

Your public IP is shown on screen. Remove it before sharing a report publicly.

### 2.10 Route to 1.1.1.1 (tracepath)

Lists each router hop between you and the destination, with timing. It also shows the path MTU (`pmtu`).

- Hop 1 is your router.
- A drop in `pmtu` (e.g. 1500 to 1492) is normal on PPPoE and many DSL/fiber connections.
- Hops in private ranges (`172.16-31.x.x`, `10.x.x.x`) are usually your ISP's internal network.
- **`no reply` hops are common**, because many routers hide themselves. Only the last hops matter for reachability.

### 2.11 TCP / UDP / IP statistics

System-wide totals since boot:

| Item | Meaning |
|---|---|
| TCP segments sent / in | Overall TCP traffic volume. |
| **TCP retransmits** | Segments that had to be resent. Under ~1% is normal. Consistently above 2-3% suggests a lossy path. |
| TCP connections | Currently established, failed attempts, and resets. |
| UDP in / out / errors | UDP datagram counts. |
| IP in / discards | IP packets received, and discarded. |
| Socket summary (`ss`) | Totals for open sockets by protocol. |

### 2.12 NetworkManager

NetworkManager's own view: the list of connection profiles, the **overall state** (`connected`), and **connectivity** (`full` means internet access was confirmed; `limited` or `portal` indicates a problem or a login page).

---

## How the score is calculated

The score starts at **100** and points are deducted for each problem found. The "How the score was calculated" section lists each deduction. If nothing is wrong, it says *"100 points, nothing deducted."*

| Score | Rating |
|---|---|
| 90 to 100 | Excellent |
| 75 to 89 | Good |
| 55 to 74 | Needs attention |
| below 55 | Poor |

Typical deductions (all defined in the script):

| Problem | Points |
|---|---|
| No adapter / no IP address / no default route | 30 / 25 / 25 |
| Internet unreachable | 25 |
| Wi-Fi not connected, cable unplugged, or link down | 20 |
| Captive portal (sign-in page) suspected | 20 |
| DNS not working / partly failing / slow | 20 / 8 / 4 |
| Router dropping 50% or more / 10% or more of pings | 15 / 8 |
| Packet loss 15% or more / 5% or more / 1% or more | 12 / 5 / 2 |
| Latency over 300 ms / 150 ms / 80 ms | 12 / 6 / 2 |
| Jitter over 50 ms / 25 ms / 10 ms | 6 / 3 / 1 |
| Wi-Fi signal below -80 dBm / below -70 dBm | 10 / 5 |
| Adapter still reporting new errors (0.5% or more of packets) | 3 |
| Adapter drop rate 5% or more, with new drops | 2 |
| `--speed`: download under 3 / 10 Mbps | 10 / 4 |

Each exit code (see [Exit status](#exit-status)) follows the same bands.

---

## Reading the results: troubleshooting guide

| Symptom | Likely area | What to try |
|---|---|---|
| Red dot at **Wi-Fi** | Not connected to an access point | Reconnect, check the password, restart the Wi-Fi adapter. |
| Red dot at **Router** | Local link or router | Move closer, restart the router, check the cable if wired. |
| Router OK, red at **Internet** | ISP or router uplink | Restart the router or modem, contact your ISP. |
| Internet OK, red at **Websites** | DNS or blocked HTTPS | Change DNS servers, check the captive portal line. |
| High router latency or loss | Weak Wi-Fi | Move closer, change channel or band, check interference. |
| Router fast, internet slow | ISP | Run again at another time, test with `--speed`. |
| High jitter, bad video calls | Wi-Fi interference or congestion | Use 5 GHz or Ethernet, reduce other traffic. |
| Many `rx_crc_errors` / `rx_dropped` | Noisy radio link, or just old totals | Look at "During this scan" in the advanced report. If new errors appear, it is a link-quality issue (interference or weak signal). |
| Sign-in page check not `none` | Captive portal | Open a browser and log in to the network. |
| Slow DNS | DNS server | Try 1.1.1.1 or 8.8.8.8 and compare. |

### About the example report

The sample run (made with NetScope 2.0) scored 100/100. Two details were worth noting, and version 2.1 handles both:

- `rx_dropped` (2298) and `rx_crc_errors` (2355) were non-zero but cumulative since boot. Version 2.0 only counted `rx_errors` and showed 0.00%. Version 2.1 counts CRC errors (about 0.5% of packets here), shows the drop rate, and tells you whether anything new appeared during the scan. Historical errors do not lower the score.
- Signal and link rate showed `n/a` because the `wl` driver does not expose them to `iw`. Version 2.1 falls back to NetworkManager and `iwconfig` and shows estimates marked with `~`.

---

## Glossary

| Term | Plain-language meaning |
|---|---|
| **Latency / ping** | How long a small message takes to go and come back. |
| **Jitter** | How much that time varies from one message to the next. |
| **Packet loss** | Messages that never arrived. |
| **Gateway** | Your router: the door to the internet. |
| **DNS** | The internet's phone book, translating names to addresses. |
| **SSID / BSSID** | Wi-Fi network name / the specific access point's hardware address. |
| **dBm** | Unit of Wi-Fi signal strength. Closer to 0 is stronger. |
| **MTU / PMTU** | Maximum packet size for the interface / for the whole path. |
| **TLS** | The encryption behind HTTPS. |
| **Captive portal** | A login page that some public networks force you through. |
| **Retransmit** | A TCP segment that had to be sent again. |
| **CRC error** | A received frame that failed its integrity check. |
| **Hop** | One router along the path to a destination. |

---

## Limitations and notes

- Ping failures alone do not prove a fault: routers and servers may ignore ICMP.
- Counters (bytes, errors, drops, retransmits) are **cumulative since boot**, not per-second.
- Traffic rates describe this computer's interface, not your provider's maximum speed.
- NetScope never scans other devices, tests open ports, or changes any configuration.
- The neighbouring-networks count comes from a cached scan and may be stale.
- Results are a snapshot. Run it a few times, at different moments, before drawing conclusions.
- Targets (1.1.1.1, 8.8.8.8, Cloudflare) need outbound access. A firewall or restricted network can make them look like failures.

---

## FAQ

**Why is my download only 26 kbps?**
That is current traffic through your interface while idle, not your connection speed. Run `./netscope.sh --speed`.

**Why does it say 100/100 when there are dropped packets?**
Drops are counted since boot and are a very small share of traffic. The score is based on live tests (latency, loss, DNS, HTTPS, routing) and on errors that appear **during** the scan. Old totals are shown in the report but do not cost points.

**Can I use NetScope in another script?**
Yes. Use `./netscope.sh --json` for the data and check the exit code (0, 10 or 20) for a quick verdict. The JSON does not include your public IP.

**Is IPv6 "not available" a problem?**
No. Many networks are IPv4-only and everything still works.

**Why do some tracepath hops say "no reply"?**
Routers often ignore these probes. It does not mean traffic is blocked.

**Does it send my data anywhere?**
It only contacts standard test targets (the router, public DNS servers, and a Cloudflare test URL). Nothing is uploaded, but your public IP is displayed in the report, so remove it before sharing.

---

*NetScope 2.1 · Page last updated 2026-10-18*
