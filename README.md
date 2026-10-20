# NetScope 2.5: Network Health Console

NetScope is a Bash script that checks every link between your computer and the internet and reports the result in plain language. It first shows a friendly summary. If you press **A**, it then shows a technical report with the raw numbers.

> NetScope is a **local, read-only check-up**. It never scans other devices, tests open ports, or changes any configuration. The score is not an official speed rating. A few modes send probe packets (ping, tracepath) to a host *you* name; see [Network contacts](#network-contacts).

---

## Contents

1. [Quick start](#quick-start)
2. [How a run works](#how-a-run-works)
   - [Learning tools (introduced in 2.2)](#learning-tools-introduced-in-22)
   - [Packet walk-through (`--walk`)](#packet-walk-through---walk)
   - [Routing table and longest-prefix match (`--routes`)](#routing-table-and-longest-prefix-match---routes)
   - [Explore your own network (new in 2.4)](#explore-your-own-network-new-in-24)
   - [Status, history and reports (new in 2.4)](#status-history-and-reports-new-in-24)
3. [Part 1: The summary screen](#part-1-the-summary-screen)
4. [Part 2: Advanced diagnostics](#part-2-advanced-diagnostics)
5. [How the score is calculated](#how-the-score-is-calculated)
6. [Reading the results: troubleshooting guide](#reading-the-results-troubleshooting-guide)
7. [Glossary](#glossary)
8. [Network contacts](#network-contacts)
9. [Limitations and notes](#limitations-and-notes)
10. [FAQ](#faq)

---

## Quick start

```bash
chmod +x netscope.sh
./netscope.sh            # standard check-up
./netscope.sh --speed    # also measure download/upload speed
./netscope.sh --live     # live monitor
./netscope.sh --json     # machine-readable output
./netscope.sh --walk 8.8.8.8   # follow one packet, hop by hop
```

### Installation

Run this command in your terminal to install `netscope`:

```bash
mkdir -p ~/.local/bin && curl -sSL https://raw.githubusercontent.com/Resmo94/Netscope/main/netscope.sh -o ~/.local/bin/netscope && chmod +x ~/.local/bin/netscope
```

### Options

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

**Learning tools** (read-only)

| Option | What it does |
|---|---|
| `--walk DEST` | Follows one IPv4 packet to a hostname or IP, hop by hop, with latency and status per hop. Sends one ping (only if needed) and a short tracepath toward DEST. |
| `--learn` | Adds a plain-language explanation of every step, using your own numbers. |
| `--osi` | Shows your results on the seven OSI layers. |
| `--subnet [CIDR]` | Subnet calculator. Uses your own address if you give none. |
| `--dns DOMAIN` | DNS explorer. |
| `--tls HOST[:PORT]` | TLS and certificate inspector. |
| `--mtu [HOST]` | Path MTU discovery. |
| `--glossary [TERM]` | Networking glossary, optionally filtered. |

**Explore your own network** (read-only)

| Option | What it does |
|---|---|
| `--arp` | Neighbour table, gateway MAC, subnet size. |
| `--routes [DEST]` | Routing table with every line explained; with DEST, a longest-prefix-match demonstration. |
| `--ports` | Listening ports and active TCP/UDP connections on this computer. |
| `--handshake HOST[:PORT]` | DNS, TCP and TLS handshake timed separately. |
| `--nat` | Private versus public address, and what that implies. |
| `--dhcp` | Your DHCP lease and the four-step exchange. |
| `--channels` | Wi-Fi channel congestion, from a cached scan. |
| `--topology [DEST]` | A labelled ASCII diagram of your path (default `8.8.8.8`). |
| `--quiz` | Short quiz with answers from your own network. |
| `--course` | Map of each networking topic to the command that demonstrates it. |

**Status, history, reports**

| Option | What it does |
|---|---|
| `--quick` | Two-second one-line status with an exit code. |
| `--history` | Shows the last 20 saved runs. |
| `--compare [N]` | Compares the last N saved runs (default 5). |
| `--report FILE` | Saves a sanitised Markdown report to FILE. |

### Exit status

NetScope's exit code reflects the health score, so other scripts can react to it.

| Code | Meaning |
|---|---|
| `0` | Healthy (score 75 or more). |
| `10` | Needs attention (score 55 to 74). |
| `20` | Poor (score below 55). |
| `1` | NetScope could not run (for example `ip` is missing), or a mode could not complete (for example no route to the `--walk` destination). |
| `2` | Bad command-line option or invalid argument. |

`--quick` uses the same codes: `0` = OK, `10` = DEGRADED (router answers, internet does not), `20` = FAIL.

### What's new in 2.5

**`--walk` rewritten**

- **Hop-by-hop table** with address, measured latency (and a bar), a reply badge (`OK`, `WARN`, `INFO`, `FAIL`) and a short role for each hop: gateway, private, CGNAT range, public, destination.
- **Measured versus calculated is always labelled.** Latency and addresses come from the trace. TTL per hop is calculated from the hop number and marked `*`. MAC addresses beyond your own link are shown as "not visible from here", never invented.
- **Honest next-hop MAC.** It is reported as read from the neighbour cache, learned after one ping, or "not known".
- **Graceful degradation.** The trace runs in the background behind the usual spinner with a 25-second limit. Timeouts, empty traces, partial traces, silent trailing hops and a missing `tracepath`/`traceroute` are explained instead of guessed at.
- **Hints, not verdicts.** NAT, double NAT, and a mismatch between hop 1 and your routing-table next hop are worded as hints from the addresses.
- **Stricter input checking.** IPv6 literals, a leading `-`, short numeric names such as `2001`, leading-zero IPs such as `08.8.8.8`, invalid ports and `user@` prefixes are rejected or stripped before any lookup.
- **VPN/tunnel aware.** Point-to-point addresses (`inet A peer B`) are read correctly, and a tunnel is shown as having no MAC.
- **`--advanced` details:** binary AND working, the raw `ip neigh` line, trace tool and exit status, tracepath's path MTU and its return-hop estimate (labelled as a guess).

**`--routes` upgraded**

- Every route line gets a plain-language explanation (default, network or host route, gateway or direct, where it came from, source address, metric, flags).
- With a destination, **every matching route is listed**, the winner is marked, and the reason is given (longest prefix first, then lowest metric). Routes that do not match show the first bit where they differ. NetScope compares its answer with `ip route get` and says when they disagree.

**Fixes across other modes**

- VPN-style address lines (`inet A peer B`) no longer break address parsing in `--nat`, `--dhcp`, `--arp`, `--topology`, `--quiz`, `--subnet`, the interface table or the main report.
- `--topology` numbers hops correctly and handles silent hops.
- `--handshake` reports a failed connection (with the curl exit status) instead of printing zeros, and `--handshake`/`--tls` validate the port range.
- `--nat` asks for the IPv4 address and no longer claims "single NAT", "double NAT" or "carrier-grade NAT" as fact, because that cannot be known from this computer.
- `--channels` derives the band from the frequency and sorts channels correctly.
- `--report` no longer claims to remove everything identifying: it now says that the Wi-Fi name and private IPv4 address are included.
- The help text and safety notice now state that `--walk`, `--mtu` and `--topology` send a few probe packets to the host you name.

### What's new in 2.4

- Exploration modes: `--arp`, `--routes`, `--ports`, `--handshake`, `--nat`, `--dhcp`, `--channels`, `--topology`, `--quiz`, `--course`.
- Status and record keeping: `--quick`, `--history`, `--compare` and `--report FILE`. Normal runs now save a one-line record to a history file.
- `--walk` presented the journey as a numbered story with the local/remote decision, the next-hop MAC and the "what stays and what changes" summary.

### What's new in 2.3

- New **`--walk DEST` packet walk-through** explains how Linux sends traffic to a destination, using your actual IPv4 address, netmask, route, next-hop MAC and (where available) traceroute hops.
- Improved interface selection distinguishes physical adapters, VPN interfaces and virtual/container interfaces more deliberately. Advanced Wi-Fi details can include transmit retries, failed transmissions and expected throughput when the driver exposes them.
- The advanced latency report can include a ping test to `1.1.1.1` under load. `--speed` reports download/upload results and a bufferbloat grade when those measurements are available.

### What's new in 2.2

- Seven read-only **learning tools**: `--learn`, `--osi`, `--subnet`, `--dns`, `--tls`, `--mtu` and `--glossary`.
- If the internet is unreachable the score is capped at 45 (POOR, exit code 20).
- `--ascii` produces pure ASCII everywhere, including the advanced report.
- `--subnet` recognises the documentation ranges as "documentation only".

### What's new in 2.1

- Wi-Fi signal and link rate fall back to NetworkManager and `iwconfig`. Estimated values are marked with `~`.
- Error counters include CRC errors and drops, and NetScope checks whether they **grew during the scan**.
- The direct DNS test uses `dig`'s own query time.
- New `--json` output and exit codes.

At the end of the summary, press **A** for the advanced details or **Enter** to finish.

### Tools the script uses

NetScope uses whichever of these tools are installed. The "Tools found" line in the report lists what it found.

`ip` · `ping` · `curl` · `iw` · `iwconfig` · `nmcli` · `ethtool` · `resolvectl` · `dig` · `tracepath` · `traceroute` · `ss` · `getent` · `timeout`

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

## Learning tools (introduced in 2.2)

These modes explain networking concepts using your own network. They run, print, and exit without the normal scan (except `--learn` and `--osi`, which are added to the normal report). None of them changes the score, the exit code or the `--json` output of a normal run.

| Command | Concept it teaches | What you see |
|---|---|---|
| `./netscope.sh --learn` | The path of a packet, layer by layer | After the summary, one explanation per step filled in with your IP, signal, gateway, latency and DNS time, plus the raw Linux command behind each ("Try it"). |
| `./netscope.sh --osi` | The OSI model | Seven rows from Application (7) down to Physical (1), each marked OK, WARN or FAIL. It names the lowest layer with a problem. |
| `./netscope.sh --subnet [CIDR]` | Subnetting, netmasks, local vs remote | Network and broadcast address, usable host range, number of hosts and address type, the **binary AND** of address and mask, a local/remote test for your gateway and 1.1.1.1, and a prefix cheat sheet. |
| `./netscope.sh --dns example.com` | How DNS works | The same query asked twice (cache effect), A/AAAA/CNAME/MX/NS/TXT/SOA records with TTLs, a reverse lookup, and a `dig +trace` walk. Needs `dig`. |
| `./netscope.sh --tls example.com` | TLS and certificates | Protocol, cipher, certificate subject, issuer, expiry, names, chain length and trust. Needs `openssl`. |
| `./netscope.sh --mtu [HOST]` | MTU and fragmentation | A binary search with Do-Not-Fragment pings, ending in the path MTU. Needs `ping`; the host must answer ping. |
| `./netscope.sh --glossary [TERM]` | Vocabulary | About 36 terms, each tagged with its OSI layer. |

```bash
./netscope.sh --subnet                      # your own network
./netscope.sh --subnet 172.16.5.9/20        # any network
./netscope.sh --learn --osi                 # explanations plus the layer view
./netscope.sh --dns example.com
./netscope.sh --tls example.com:443
./netscope.sh --mtu 8.8.8.8
./netscope.sh --glossary nat
```

> **Reading `--subnet`:** the number after the slash is how many leading bits are the network part. Address AND mask gives the network address. Two computers can talk directly when their results match; otherwise traffic goes through the gateway.

> **Reading `--osi`:** a FAIL at layer 3 while layers 1 and 2 are OK means the cable or Wi-Fi works and the router is reachable, but IP traffic does not get through to the internet.

---

## Packet walk-through (`--walk`)

```bash
./netscope.sh --walk 8.8.8.8
./netscope.sh --walk example.com
./netscope.sh --walk 8.8.8.8 --advanced      # adds binary working and technical details
```

This is a teaching mode, not a packet capture. NetScope asks Linux how it would route traffic to the destination and combines that with your address, netmask, neighbour table and (if installed) `tracepath` or `traceroute`. It never reads the contents of real packets.

### The steps

| Step | What happens |
|---|---|
| **1. Your computer** | Interface, IPv4 address and mask, and MAC (a tunnel shows "no MAC"). |
| **2. Local or remote?** | Your address AND the mask gives your network; the same mask applied to the destination gives its network. Equal means local; different means remote. The kernel's real route still wins, for example with a VPN. `--advanced` shows the binary working. |
| **3. First frame leaves** | The raw `ip route get` line, the next hop (marked *your default gateway* when it is), and the next-hop MAC. The frame is addressed to the router's MAC while the IP packet stays addressed to the destination. |
| **4. Routers along the way** | The hop table (below). |
| **5. What changes at each hop** | One row per link: the calculated TTL and whether the MAC pair is visible. |
| **Summary** | What stays (IP addresses, unless NAT) and what changes (MAC pair on every link, TTL minus one per router). |

If the destination is on your own network, the walk stops after step 3 with "Delivered: nothing in between". If it is one of your own addresses, a broadcast or a multicast address, NetScope explains that instead.

### Reading the hop table

```
  HOP  ADDRESS          LATENCY            REPLY    NOTE
  1    192.168.1.1      0.5 ms    #....... [+ OK]   gateway
  2    10.20.0.1        8.1 ms    #....... [+ OK]   private
  3    *                -                  [* INFO] no reply (common, not an error)
  4    72.14.1.1        240 ms    ######## [! WARN] public, slow reply
  5    8.8.8.8          12 ms     #....... [+ OK]   destination
```

| Column | Meaning |
|---|---|
| **LATENCY** | Measured round trip of the probe sent to that hop. The bar is scaled to the slowest hop. |
| **REPLY** | `OK` the router answered. `WARN` a slow answer (150 ms or more, or 80 ms or more above the previous hop). `INFO` no reply, which is common and not an error. `FAIL` the router reported the destination as unreachable (flags such as `!H`). |
| **NOTE** | Role of the address: gateway, private, CGNAT range, public or destination. |

> The REPLY badge describes how the **probe** was answered, not the health of your own traffic. Routers often answer probes slowly or not at all, so one slow hop followed by fast ones is usually harmless.

### Measured, calculated or not visible

| Item | Status |
|---|---|
| Hop addresses and latency | Measured by `tracepath`/`traceroute`. |
| Your MAC and next-hop MAC | Read from your computer (neighbour cache; after one ping if missing). |
| TTL at each hop (marked `*`) | **Calculated**: start TTL minus one per router. The start TTL is your system default (`ip_default_ttl`); a program may choose another. |
| MAC addresses on later links | **Not visible** from your computer. |
| NAT | **Inferred** from a private source and public destination; the router's rule is not observed. |

### Important limitations

- `--walk` follows **IPv4** only. IPv6 destinations are refused with an explanation.
- The trace is limited to 15 hops and 25 seconds. Firewalls and routers commonly suppress probes, so a trace that ends early does not prove the destination is unreachable.
- Trailing silent hops are trimmed and reported as "no answer", because the destination may simply ignore probes.
- A router that differs from your routing-table next hop at hop 1, or several private-range hops, are shown as hints (transparent devices, double NAT, an ISP's internal network). The cause is not determined.
- If `tracepath`/`traceroute` (or `timeout`) is missing, the local routing, subnet and next-hop steps still run and the remote hops are skipped.
- `--walk` may send **one ping** to the next hop when its MAC is not cached, and the trace sends probe packets toward the destination.

---

## Routing table and longest-prefix match (`--routes`)

```bash
./netscope.sh --routes              # your table, every line explained
./netscope.sh --routes 8.8.8.8      # plus: which route wins for this destination
```

Each line of `ip -4 route` is printed with an explanation. With a destination, NetScope:

1. Lists **every route whose range contains the destination**, best first, with a bit-by-bit view (green bits must match, bits after the bar are ignored).
2. Marks the **winner** and says why: the longest prefix wins; the metric is only a tie-breaker between equal prefix lengths.
3. Shows the routes that **do not** match and the first bit where they differ.
4. Compares the result with `ip route get`. If the kernel picked a different exit, it names the usual reasons (a `linkdown` route, policy routing rules, another routing table).

> The order of the lines in the routing table does not matter. Only the prefix length and metric decide.

---

## Explore your own network (new in 2.4)

| Command | What it shows |
|---|---|
| `--arp` | The neighbour table (IP, MAC, state, interface), what each state means (`REACHABLE`, `STALE`, `DELAY`, `PROBE`, `INCOMPLETE`, `FAILED`, `PERMANENT`), your gateway's MAC and the size of your subnet. |
| `--ports` | Listening TCP ports, established TCP connections and UDP sockets **on this computer** (needs `ss`), plus a list of common port numbers. Other devices are never scanned. |
| `--handshake HOST[:PORT]` | A cumulative timeline of DNS, TCP connect, TLS handshake and first byte, then the duration of each stage. If the connection fails, the curl exit status is reported. Needs `curl`. |
| `--nat` | Your local address next to the public address seen from the internet (via a Cloudflare trace request). It tells you whether a translation happens, but **not** how many NAT layers there are: compare with your router's WAN address for that. |
| `--dhcp` | Your address, gateway and DNS servers, the lease file if one is readable, and the four DHCP steps (Discover, Offer, Request, Acknowledge). |
| `--channels` | Wi-Fi networks per channel, from NetworkManager's **cached** scan (no new scan is triggered). Needs `nmcli` and a Wi-Fi adapter. |
| `--topology [DEST]` | A labelled diagram: you, your gateway, the routers found with `tracepath`, and the destination. Silent routers are shown as `(no reply)`. |
| `--quiz` | Five questions about your own network (address, network address, gateway, usable hosts, mask). When not run in a terminal it prints the answers instead. |
| `--course` | A map from each networking topic to the command that demonstrates it. |

---

## Status, history and reports (new in 2.4)

| Command | What it does |
|---|---|
| `--quick` | One line, about two seconds: `OK` (with latency, loss and interface), `DEGRADED` (router replies, internet does not) or `FAIL`. Exit codes `0`, `10`, `20`. |
| `--history` | The last 20 saved runs: time, score, grade, latency, loss, interface. |
| `--compare [N]` | The last N runs side by side, and whether the score improved, dropped or stayed the same since the first of them. |
| `--report FILE` | Writes a Markdown report. MAC addresses, BSSIDs and the public IP are left out. |

Normal runs append one line to `~/.local/share/netscope/history.jsonl` (or `$XDG_DATA_HOME/netscope/`). The file is trimmed to its last 1000 lines when it passes 5000. **The record includes the Wi-Fi network name.**

> A `--report` file still contains the Wi-Fi name, your private IPv4 address and the diagnosis text. Read it before sharing it publicly.

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
| **Reply speed** | `6.6 ms` | Average round-trip time (latency) to an internet server. Lower is better. |
| **Lost data** | `0%` | Share of test packets that never came back (packet loss). |
| **Downloading** | `↓ 26 kbps` | Current receive rate on **this computer's interface**, not your provider's maximum. |
| **Uploading** | `↑ 19 kbps` | Current send rate on this interface. |
| **Wi-Fi network** | `Network (5 GHz)` | The network name (SSID) and frequency band. |

> The download and upload figures show **current traffic**, not capacity. Use `--speed` for a real speed test.

### 1.3 What you can do right now

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
| Tools found | Which diagnostic tools were available. |

### 2.2 Check results

| Tag | Meaning |
|---|---|
| `✓ OK` | Check passed. |
| `• INFO` | Informational. Not a fault. |
| `! WARN` | Something is degraded and worth looking at. |
| `✗ FAIL` | Check failed and affects connectivity. |

| Check | What it verifies |
|---|---|
| **Network adapter** | The active interface, its type (wifi/ethernet) and its state. |
| **Device address** | The IPv4 address with prefix length, and the IPv6 address if any. |
| **Default route** | Which gateway and interface carry your internet traffic. |
| **Router (gateway)** | 20 pings to the router. Replies received and the average time. |
| **DNS lookups** | Resolves several domains through the system resolver. |
| **Internet (HTTPS)** | A real HTTPS request. HTTP status and total time. |
| **Latency / jitter / loss** | Summary of the ping test to a public server (8.8.8.8). |
| **Sign-in page check** | Detects a captive portal. `none (HTTP 204)` means nothing is intercepting traffic. |
| **IPv6** | Whether IPv6 reaches the internet. "Not available" is common and not a fault. |

### 2.3 All network interfaces

| Column | Meaning |
|---|---|
| NAME | Interface name. `lo` is the loopback. |
| STATE | `up`, `down`, or `unknown` (normal for loopback). |
| IPV4 | Address and prefix (point-to-point VPN addresses are read correctly since 2.5). |
| MTU | Largest packet size (bytes) the interface sends without splitting. 1500 is standard. |
| RX / TX | Total data received and sent **since boot**. |
| ERR / DROP | Errors reported and packets dropped by the interface. |

The `▸` marker shows the interface that carries your default route.

### 2.4 Active adapter and counters

| Counter | Meaning |
|---|---|
| `rx_packets` / `tx_packets` | Packets received / sent. |
| `rx_errors` / `tx_errors` | Packets that arrived or left damaged. |
| `rx_dropped` / `tx_dropped` | Packets discarded. |
| `rx_crc_errors` | Frames that failed an integrity check, often a noisy radio link. |
| `rx_missed_errors` | Packets the hardware missed because it was overloaded. |
| `tx_carrier_errors`, `collisions` | Mostly wired links. Usually 0 on Wi-Fi. |
| **Error rate / Drop rate** | Errors or drops as a percentage of all packets. |
| **During this scan** | New errors and drops that appeared while NetScope was running. |

> **Counters are cumulative since boot.** If nothing grew during the scan, NetScope says the errors are historical and does not lower your score.

### 2.5 Wi-Fi link

| Field | Meaning |
|---|---|
| Network (SSID) | Wi-Fi network name. |
| Access point (BSSID) | MAC address of the access point you are connected to. |
| Band / channel | e.g. `5 GHz / ch 36 (5180 MHz)`. |
| Signal | Received strength in dBm. About -50 is excellent, -67 is good, -70 or lower is weak. |
| Link rate (tx / rx) | Negotiated speed with the access point, not your internet speed. |
| Power saving | Whether the card may sleep between packets. |
| Expected throughput | A driver estimate, when available. Not a speed test. |
| Transmit retries / failed | Frames retried or not sent, if the driver reports them. |
| Security | Encryption type (e.g. WPA2). |
| Neighbours on channel | Other networks on your channel, from a cached scan. |

> **Estimated values (`~`):** when a driver does not expose signal and link rate to `iw`, NetScope tries `/proc/net/wireless`, `iwconfig` and NetworkManager. NetworkManager only gives a 0 to 100 quality, so dBm is estimated as quality / 2 - 100.

### 2.6 Routing and neighbours

- **Routing table.** The `default via ...` line is the path to the internet. For a line-by-line explanation, use `--routes`.
- **Gateway / Gateway MAC.** Your router's IP and hardware address.
- **Neighbour cache.** Devices this computer talked to recently. **It is not a network scan.**

### 2.7 DNS

| Item | Meaning |
|---|---|
| Servers in use | Which DNS server(s) your computer asks. Often your router. |
| Protocol flags | `+` or `-` for DefaultRoute, LLMNR, mDNS, DNSOverTLS and DNSSEC. |
| **System resolver lookups** | Real lookups with timing. Repeats may come from a cache. |
| **Direct resolver test** | Asks each server directly to compare them, using `dig`'s own query time. |

### 2.8 Latency, jitter and packet loss

Each target gets 20 pings (router, Cloudflare 1.1.1.1, Google 8.8.8.8). Columns: SENT / RECV, LOSS, MIN / AVG / MAX, JITTER.

| | Good | Acceptable | Poor |
|---|---|---|---|
| Latency to internet | under 30 ms | 30 to 100 ms | over 100 ms |
| Jitter | under 5 ms | 5 to 20 ms | over 20 ms |
| Packet loss | 0% | under 1% | over 2% |

If the router is fast and the others slow, the issue may be outside your home. If the router itself is slow or lossy, look at the local link first.

### 2.9 Speed test and bufferbloat (`--speed`)

Contacts `speed.cloudflare.com` to measure download and upload, and compares idle with loaded latency to give a **bufferbloat grade**. On very fast connections it may transfer up to roughly 130 MB. Use it deliberately on a metered connection.

### 2.10 Web / TLS timing and public address

One HTTPS request split into cumulative stages: DNS lookup, TCP connect, TLS handshake, first byte, total. Also shown: your **public IP** and country, the negotiated TLS version and Cloudflare edge, and IPv6 reachability. Remove your public IP before sharing a report.

### 2.11 Route to 1.1.1.1 (tracepath)

Lists each router hop with timing and the path MTU (`pmtu`). Hop 1 is your router. A drop from 1500 to 1492 is normal on PPPoE. Private-range hops are usually your ISP's internal network. **`no reply` hops are common.** For an annotated version of this, use `--walk`.

### 2.12 TCP / UDP / IP statistics

System-wide totals since boot: TCP segments, **retransmits** (under about 1% is normal; consistently above 2 to 3% suggests a lossy path), connections, UDP counts, IP discards and a socket summary from `ss`.

### 2.13 NetworkManager

Connection profiles, overall state (`connected`) and connectivity (`full` means internet access was confirmed; `limited` or `portal` indicates a problem or a login page).

---

## How the score is calculated

The score starts at **100** and points are deducted for each problem found.

| Score | Rating |
|---|---|
| 90 to 100 | Excellent |
| 75 to 89 | Good |
| 55 to 74 | Needs attention |
| below 55 | Poor |

| Problem | Points |
|---|---|
| No adapter / no IP address / no default route | 30 / 25 / 25 |
| Internet unreachable | 25, and the score is capped at 45 |
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

---

## Reading the results: troubleshooting guide

| Symptom | Likely area | What to try |
|---|---|---|
| Red dot at **Wi-Fi** | Not connected to an access point | Reconnect, check the password, restart the Wi-Fi adapter. |
| Red dot at **Router** | Local link or router | Move closer, restart the router, check the cable if wired. |
| Router OK, red at **Internet** | ISP or router uplink | Restart the router or modem, contact your ISP. `--quick` shows this as DEGRADED. |
| Internet OK, red at **Websites** | DNS or blocked HTTPS | Change DNS servers, check the captive portal line. |
| High router latency or loss | Weak Wi-Fi | Move closer, change channel or band (`--channels`), check interference. |
| Router fast, internet slow | ISP | Run again at another time, test with `--speed`, look at the hop table in `--walk`. |
| High jitter, bad video calls | Wi-Fi interference or congestion | Use 5 GHz or Ethernet, reduce other traffic. |
| Many `rx_crc_errors` / `rx_dropped` | Noisy radio link, or old totals | Look at "During this scan". New errors mean a link-quality issue. |
| Sign-in page check not `none` | Captive portal | Open a browser and log in to the network. |
| Slow DNS | DNS server | Try 1.1.1.1 or 8.8.8.8 and compare. |
| Destination unreachable in `--walk` | Routing or filtering | Read `--routes DEST` to see which route is used, then check hop 1 and 2 of the trace. |
| Several private hops in `--walk` | Possibly double NAT or an ISP-internal network | Compare your router's WAN address with `--nat`. This is a hint, not proof. |

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
| **TTL** | A counter that every router lowers by 1; the packet is discarded at 0. |
| **ARP / neighbour table** | How a computer finds the MAC address for an IP on the same link. |
| **Longest-prefix match** | The routing rule: the most specific matching route wins. |
| **NAT / CGNAT** | A router rewriting private addresses to a public one / the same done by your provider for many customers. |

---

## Network contacts

| Mode | What it sends, and to whom |
|---|---|
| Normal run | Pings to your router, 1.1.1.1 and 8.8.8.8; DNS lookups; one HTTPS request; a Cloudflare trace request. |
| `--speed` | Test data to and from `speed.cloudflare.com` (up to roughly 130 MB on fast links). |
| `--walk DEST` | One ping to your next hop (only if its MAC is not cached) and a `tracepath`/`traceroute` of up to 15 hops toward DEST. |
| `--mtu`, `--topology` | Pings or a `tracepath` toward the host you name (`--topology` defaults to 8.8.8.8). |
| `--dns`, `--tls`, `--handshake` | Ordinary DNS queries or one connection to the host you name. |
| `--nat` | One request to Cloudflare's trace endpoint to learn your public address. |
| `--arp`, `--routes` (no DEST), `--ports`, `--dhcp`, `--channels`, `--subnet`, `--glossary`, `--quiz`, `--course`, `--history`, `--compare` | Nothing is sent. |

No mode scans other devices or probes their ports.

---

## Limitations and notes

- Ping failures alone do not prove a fault: routers and servers may ignore ICMP.
- Counters (bytes, errors, drops, retransmits) are **cumulative since boot**.
- Traffic rates describe this computer's interface, not your provider's maximum speed.
- Hop latency is the round trip of a probe; routers often deprioritise probes, so a single slow hop can be misleading.
- TTL values per hop in `--walk` are calculated, and MAC addresses beyond your own link cannot be observed.
- `--walk` follows IPv4 only.
- The neighbouring-networks count and `--channels` use a cached scan and may be stale.
- Results are a snapshot. Run it a few times, at different moments, before drawing conclusions.
- Targets (1.1.1.1, 8.8.8.8, Cloudflare) need outbound access. A firewall or restricted network can make them look like failures.
- The history file stores your Wi-Fi network name.
- The 2.5 `--walk` and `--routes` changes were tested against simulated command output; please report differences you see on real networks.

---

## FAQ

**What does `--walk` actually do?**
It asks Linux for the route to a destination, shows the subnet calculation and next hop, reads the next-hop MAC from the neighbour table (sending one ping if it is missing), and runs `tracepath` or `traceroute` to list the routers with their latency. It does not capture packet contents or scan the network.

**Why does `--walk` not show the MAC addresses of the routers?**
Your computer only learns the MAC address of the device on its own link. The addresses on later links belong to other networks and are not visible from here. 2.3 used illustrative placeholders; 2.5 says "not visible from here" instead of showing invented values.

**Why are some `--walk` TTL values marked with `*`?**
They are calculated (start TTL minus one per router), not read from a real packet. The latency and addresses in the same table are measured.

**Why does `--walk` show a hop as "no reply"?**
Many routers and destinations ignore probes. It does not mean traffic is blocked. Silent hops at the end of a trace are reported as "no answer", not as a fault.

**Does `--walk` tell me I am behind NAT or double NAT?**
It hints at it. A private source address and a public destination imply a NAT, and several private-range hops can suggest a second one. NetScope cannot see the router's rules, so these are hints. Compare with your router's WAN address to be sure.

**Why does `--routes` say the kernel chose a different route?**
NetScope's model uses only the main routing table. The kernel can also skip `linkdown` routes and apply policy rules or other tables.

**Does `--speed` use a lot of data?**
It transfers test data with `speed.cloudflare.com`. On very fast connections it may use up to roughly 130 MB.

**Why is my download only 26 kbps?**
That is current traffic through your interface while idle, not your connection speed. Run `./netscope.sh --speed`.

**Why does it say 100/100 when there are dropped packets?**
Drops are counted since boot and are a small share of traffic. The score is based on live tests and on errors that appear **during** the scan.

**Which learning tool should I start with?**
Run `./netscope.sh --course` for the map, then `--learn --osi`, `--subnet`, `--routes 8.8.8.8` and `--walk 8.8.8.8`. Use `--glossary` whenever a term is unfamiliar.

**Do the learning tools send anything unusual?**
No. See [Network contacts](#network-contacts). None of them scans other devices or probes ports.

**Why does `--mtu` say the host does not answer ping?**
Some servers and firewalls ignore ICMP. Try another host such as 8.8.8.8.

**Can I use NetScope in another script?**
Yes. Use `--json` for the data, or `--quick` for a one-line verdict, and check the exit code (0, 10 or 20). The JSON does not include your public IP.

**Where is my history stored, and can I delete it?**
In `~/.local/share/netscope/history.jsonl`. Deleting the file is safe; NetScope recreates it on the next run. It contains your Wi-Fi network name.

**Is IPv6 "not available" a problem?**
No. Many networks are IPv4-only and everything still works.

**Does it send my data anywhere?**
It only contacts standard test targets (the router, public DNS servers, Cloudflare) and the hosts you name. Nothing is uploaded, but your public IP is displayed in some reports, so remove it before sharing.

---

*NetScope 2.5 · Page last updated 2026-10-20*
