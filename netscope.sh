#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
#  NetScope 2.4 — a friendly network health console for Linux Mint
#  (also works on other Ubuntu / Debian based desktops)
#
#  • Simple view   : plain-English verdict, a "journey of your data" map,
#                    what you can comfortably do online, and what to try if
#                    something is wrong.
#  • Advanced view : every technical statistic (press A at the end, or use
#                    --advanced).
#  • JSON output   : --json prints the results in machine-readable form.
#  • Read-only     : changes no settings, installs nothing, needs no sudo.
#
#  Run  netscope --help  to see all options.
#
#  What's new in 2.4
#   - Fourteen extra exploration and status modes (see --help):
#       --arp  --routes  --ports  --handshake  --nat  --dhcp  --channels
#       --topology  --quiz  --course  --quick  --history  --compare  --report
#   - Every non-JSON run is appended to ~/.local/share/netscope/history.jsonl
#     so you can compare quality over time with --history / --compare.
#   - --report FILE writes a sanitised Markdown report (MAC addresses and
#     public IP removed) that is safe to share.
#   - The program is invoked as `netscope` (no .sh suffix in commands).
#   - Banner corrected so the figlet art clearly reads NETSCOPE.
# ──────────────────────────────────────────────────────────────────────────────

set -u
VERSION="2.5"

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  echo "NetScope needs bash 4.4 or newer." >&2
  exit 1
fi

case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) UTF8=1 ;;
  *) UTF8=0 ;;
esac
if [[ -n "${LC_ALL:-}" ]]; then export LC_CTYPE="$LC_ALL"; unset LC_ALL; fi
export LC_MESSAGES=C LC_NUMERIC=C LANGUAGE=C

NETSYS="${NETSCOPE_SYS:-/sys/class/net}"
PROCNET="${NETSCOPE_PROC:-/proc/net}"

usage() {
  cat <<'USAGE'
NetScope - a friendly network health console

  netscope                  Simple health report (then offers advanced details)
  netscope --advanced       Simple report + every technical statistic
  netscope --speed          Also measure download / upload speed
  netscope --live           Live monitor with moving graphs (press q to quit)
  netscope --json           Print the results as JSON (no colours, no questions)
  netscope --no-color       Turn colours off
  netscope --ascii          Use plain ASCII instead of special symbols
  netscope --no-prompt      Never ask questions (useful in scripts)
  netscope --version        Show the version
  netscope --help           Show this help

LEARNING TOOLS  (all read-only)
  netscope --walk DEST        Follow one packet to DEST (name or IPv4), hop by hop
                              (sends one ping and a short tracepath toward DEST)
  netscope --learn            Add a plain-language explanation of every step
  netscope --osi              Show your results on the seven OSI layers
  netscope --subnet [CIDR]    Subnet calculator (your own network if no CIDR given)
  netscope --dns DOMAIN       Explore DNS: caching, record types, reverse DNS, trace
  netscope --tls HOST[:PORT]  Inspect a TLS connection and certificate
  netscope --mtu [HOST]       Find the path MTU with Do-Not-Fragment pings
  netscope --glossary [TERM]  Explain networking terms

EXPLORE YOUR OWN NETWORK  (all read-only)
  netscope --arp              Neighbour table, gateway MAC, subnet size
  netscope --routes [DEST]    Routing table + longest-prefix match for DEST
  netscope --ports            Listening ports and active TCP/UDP connections
  netscope --handshake HOST   DNS, TCP and TLS handshake timed separately
  netscope --nat              Private vs public address, CGNAT, double NAT
  netscope --dhcp             Your DHCP lease and the four-step exchange
  netscope --channels         Wi-Fi channel congestion (from a cached scan)
  netscope --topology [DEST]  A labelled ASCII diagram of your path
  netscope --quiz             Short quiz with answers from your own network
  netscope --course           Map each networking topic to a command

STATUS, HISTORY, REPORTS
  netscope --quick            Two-second one-line status
  netscope --history          Show the last 20 saved runs
  netscope --compare [N]      Compare the last N saved runs (default 5)
  netscope --report FILE      Save a sanitised Markdown report to FILE

EXIT STATUS
  0  healthy (score 75 or more)      10  needs attention (55 - 74)
  20 poor (below 55)                  1  NetScope could not run
  2  bad command-line option

SAFETY
  Read-only. It changes no settings, installs nothing and needs no sudo.
  It does not scan other devices or probe open ports. --walk, --mtu and
  --topology send a few probe packets (ping / tracepath) to the host you name.
USAGE
}

ADVANCED=0; PROMPT=1; SPEED=0; LIVE=0; JSON=0; OPT_NOCOLOR=0; OPT_ASCII=0
LEARN=0; OSI=0; MODE=""; MODE_ARG=""; OPT_VAL=""; REPORT_FILE=""
take_arg() {
  if [[ -n "${1:-}" && "${1:0:1}" != - ]]; then OPT_VAL="$1"; return 0; fi
  OPT_VAL=""; return 1
}
need_arg() {
  if ! take_arg "${3:-}"; then printf '%s needs %s\n' "$1" "$2" >&2; exit 2; fi
}
while (( $# )); do
  arg="$1"; shift
  case "$arg" in
    -a|--advanced)          ADVANCED=1 ;;
    -s|--speed)             SPEED=1 ;;
    -l|--live)              LIVE=1 ;;
    -j|--json)              JSON=1 ;;
    -n|--no-prompt)         PROMPT=0 ;;
    --no-color|--no-colour) OPT_NOCOLOR=1 ;;
    --ascii)                OPT_ASCII=1 ;;
    --learn)                LEARN=1 ;;
    --osi)                  OSI=1 ;;
    --walk)                 MODE=walk;      need_arg --walk "a destination, for example: --walk 8.8.8.8" "${1:-}"; shift; MODE_ARG="$OPT_VAL" ;;
    --subnet)               MODE=subnet;    take_arg "${1:-}" && shift; MODE_ARG="$OPT_VAL" ;;
    --mtu)                  MODE=mtu;       take_arg "${1:-}" && shift; MODE_ARG="$OPT_VAL" ;;
    --glossary)             MODE=glossary;  take_arg "${1:-}" && shift; MODE_ARG="$OPT_VAL" ;;
    --dns)                  MODE=dns;       need_arg --dns "a domain, for example: --dns example.com" "${1:-}"; shift; MODE_ARG="$OPT_VAL" ;;
    --tls)                  MODE=tls;       need_arg --tls "a host, for example: --tls example.com" "${1:-}"; shift; MODE_ARG="$OPT_VAL" ;;
    --arp)                  MODE=arp ;;
    --routes)               MODE=routes;    take_arg "${1:-}" && shift; MODE_ARG="$OPT_VAL" ;;
    --ports)                MODE=ports ;;
    --handshake)            MODE=handshake; need_arg --handshake "a host, e.g. --handshake example.com" "${1:-}"; shift; MODE_ARG="$OPT_VAL" ;;
    --nat)                  MODE=nat ;;
    --dhcp)                 MODE=dhcp ;;
    --channels)             MODE=channels ;;
    --topology)             MODE=topology;  take_arg "${1:-}" && shift; MODE_ARG="$OPT_VAL" ;;
    --quiz)                 MODE=quiz ;;
    --course)               MODE=course ;;
    --quick)                MODE=quick ;;
    --history)              MODE=history ;;
    --compare)              MODE=compare;   take_arg "${1:-}" && shift; MODE_ARG="$OPT_VAL" ;;
    --report)               need_arg --report "a file name, e.g. --report ~/report.md" "${1:-}"; shift; REPORT_FILE="$OPT_VAL"; PROMPT=0 ;;
    -V|--version)           echo "NetScope $VERSION"; exit 0 ;;
    -h|--help)              usage; exit 0 ;;
    *) printf 'Unknown option: %s\n\n' "$arg" >&2; usage >&2; exit 2 ;;
  esac
done

IS_TTY=0;      [[ -t 1 ]] && IS_TTY=1
INTERACTIVE=0; [[ -t 0 && -t 1 ]] && INTERACTIVE=1
(( INTERACTIVE )) || PROMPT=0

ANIMATE=0
if (( IS_TTY )) && [[ "${TERM:-dumb}" != dumb ]]; then ANIMATE=1; fi
if (( JSON )); then ANIMATE=0; PROMPT=0; ADVANCED=0; fi

USE_COLOR=1
(( OPT_NOCOLOR )) && USE_COLOR=0
if (( ! IS_TTY )) || [[ "${TERM:-dumb}" == dumb ]]; then USE_COLOR=0; UTF8=0; fi
[[ -n "${NO_COLOR:-}" ]] && USE_COLOR=0
(( OPT_ASCII )) && UTF8=0

NCOL=8
if (( USE_COLOR )); then
  NCOL="$(tput colors 2>/dev/null || echo 8)"
  [[ "$NCOL" =~ ^[0-9]+$ ]] || NCOL=8
fi

W=80
(( IS_TTY )) && W="$(tput cols 2>/dev/null || echo 80)"
[[ "$W" =~ ^[0-9]+$ ]] || W=80
(( W > 100 )) && W=100
(( W < 60 )) && W=60

RESET=''; BOLD=''; DIM=''; RED=''; GREEN=''; LGREEN=''; YELLOW=''; ORANGE=''
BLUE=''; CYAN=''; MAGENTA=''; GRAY=''; WHITE=''
BCOL=('' '' '' '' '')
if (( USE_COLOR )); then
  RESET=$'\033[0m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; WHITE=$'\033[97m'
  if (( NCOL >= 256 )); then
    RED=$'\033[38;5;203m';    GREEN=$'\033[38;5;78m';   LGREEN=$'\033[38;5;156m'
    YELLOW=$'\033[38;5;221m'; ORANGE=$'\033[38;5;209m'; BLUE=$'\033[38;5;75m'
    CYAN=$'\033[38;5;87m';    MAGENTA=$'\033[38;5;177m'; GRAY=$'\033[38;5;245m'
    BCOL=($'\033[38;5;51m' $'\033[38;5;45m' $'\033[38;5;39m' $'\033[38;5;75m' $'\033[38;5;141m')
  else
    RED=$'\033[31m';    GREEN=$'\033[32m';  LGREEN=$'\033[32m'
    YELLOW=$'\033[33m'; ORANGE=$'\033[33m'; BLUE=$'\033[34m'
    CYAN=$'\033[36m';   MAGENTA=$'\033[35m'; GRAY=$'\033[2m'
    BCOL=($'\033[36m' $'\033[36m' $'\033[34m' $'\033[34m' $'\033[35m')
  fi
fi
GRAD=("$RED" "$ORANGE" "$YELLOW" "$LGREEN" "$GREEN")

HIDE_CUR=''; SHOW_CUR=''; CLR_LINE=''; ALT_ON=''; ALT_OFF=''
if (( ANIMATE )); then
  HIDE_CUR=$'\033[?25l'; SHOW_CUR=$'\033[?25h'; CLR_LINE=$'\r\033[K'
  ALT_ON=$'\033[?1049h'; ALT_OFF=$'\033[?1049l'
fi

if (( UTF8 )); then
  G_H='─'; G_HB='━'; G_HX='╌'; G_V='┃'; G_OK='✓'; G_FAIL='✗'; G_WARN='!'; G_INFO='•'
  G_DOT='●'; G_RING='○'; G_ON='█'; G_OFF='░'; G_STAR='★'; G_STAR0='☆'
  G_DOWN='↓'; G_UP='↑'; G_LOST='×'; G_ARROW='▸'; G_MID='·'; G_WAVE='((•))'
  G_VERT='│'
  SPARK_GLYPHS='▁ ▂ ▃ ▄ ▅ ▆ ▇ █'
  SPIN=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
else
  G_H='-'; G_HB='='; G_HX='.'; G_V='|'; G_OK='+'; G_FAIL='x'; G_WARN='!'; G_INFO='*'
  G_DOT='O'; G_RING='o'; G_ON='#'; G_OFF='.'; G_STAR='*'; G_STAR0='-'
  G_DOWN='v'; G_UP='^'; G_LOST='x'; G_ARROW='>'; G_MID='-'; G_WAVE='((o))'
  G_VERT='|'
  SPARK_GLYPHS='. : - = + * # @'
  SPIN=('|' '/' '-' '\')
fi

have() { command -v "$1" >/dev/null 2>&1; }
rep()  { local i out=""; for ((i = 0; i < $2; i++)); do out+="$1"; done; printf '%s' "$out"; }
rd()   { local v=""; [[ -r "$1" ]] && read -r v < "$1" 2>/dev/null; printf '%s' "$v"; }
num()  { [[ "${1:-}" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; }
int()  { if num "${1:-}"; then awk -v v="$1" 'BEGIN { printf "%.0f", v }'; else printf '0'; fi; }
to_ms() { awk -v s="${1:-0}" 'BEGIN { printf "%.0f", s * 1000 }'; }

now_ms() {
  if [[ -n "${EPOCHREALTIME:-}" ]]; then
    local t="${EPOCHREALTIME/[.,]/}"; printf '%s' "$(( t / 1000 ))"
  else
    printf '%s' "$(( $(date +%s%N) / 1000000 ))"
  fi
}

fmt_iec() {
  awk -v n="${1:-0}" 'BEGIN { split("B KiB MiB GiB TiB", u, " "); i = 1
    while (n >= 1024 && i < 5) { n /= 1024; i++ }
    if (i == 1) printf "%d %s", n, u[i]; else printf "%.1f %s", n, u[i] }'
}
fmt_rate() {
  awk -v b="${1:-0}" 'BEGIN { v = b * 8
    if (v >= 1e9) printf "%.2f Gbps", v / 1e9
    else if (v >= 1e6) printf "%.1f Mbps", v / 1e6
    else if (v >= 1e3) printf "%.0f kbps", v / 1e3
    else printf "%.0f bps", v }'
}
fmt_ms() {
  if num "${1:-}"; then awk -v v="$1" 'BEGIN { if (v >= 10) printf "%.0f ms", v; else printf "%.1f ms", v }'
  else printf 'n/a'; fi
}

ctr() {
  local s="$1" w="$2" l
  (( ${#s} > w )) && s="${s:0:w}"
  l=$(( (w - ${#s}) / 2 ))
  printf '%*s%s%*s' "$l" '' "$s" "$(( w - ${#s} - l ))" ''
}

state_color() {
  case "$1" in
    OK) printf '%s' "$GREEN" ;;  WARN) printf '%s' "$YELLOW" ;;
    FAIL) printf '%s' "$RED" ;;  INFO) printf '%s' "$BLUE" ;;
    *) printf '%s' "$GRAY" ;;
  esac
}

section() {
  printf '\n  %s%s%s\n' "$BOLD$CYAN" "$1" "$RESET"
  printf '  %s%s%s\n' "$DIM" "$(rep "$G_H" "$(( W - 4 ))")" "$RESET"
}
sub()  { printf '\n  %s%s %s%s\n' "$BOLD$MAGENTA" "$G_ARROW" "$1" "$RESET"; }
kv()   { printf '  %s%-24s%s %s\n' "$GRAY" "$1" "$RESET" "$2"; }
note() { printf '  %s%s%s\n' "$DIM" "$1" "$RESET"; }

TMP=""
JOB_PIDS=(); JOB_NAMES=(); JOB_IDS=(); JOB_SEQ=0
LIVE_PIDS=()
LIVE_ACTIVE=0

cleanup() {
  local p
  printf '%s' "$SHOW_CUR"
  (( LIVE_ACTIVE )) && printf '%s' "$ALT_OFF"
  for p in "${JOB_PIDS[@]:-}" "${LIVE_PIDS[@]:-}"; do
    [[ -n "$p" ]] || continue
    have pkill && pkill -P "$p" 2>/dev/null
    kill "$p" 2>/dev/null
  done
  [[ -n "$TMP" && -d "$TMP" ]] && rm -rf "$TMP"
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT TERM

HISTORY_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/netscope"
HISTORY_FILE="$HISTORY_DIR/history.jsonl"
PUB_IP=""

save_history() {
  mkdir -p "$HISTORY_DIR" 2>/dev/null || return 1
  printf '{"ts":"%s","score":%d,"grade":"%s","lat_ms":"%s","loss":"%s","iface":"%s","internet":"%s","ssid":"%s"}\n' \
    "$(date -Is 2>/dev/null)" "$SCORE" "$GRADE" \
    "${LAT_MS:-}" "${LOSS_PCT:-}" "${LAN_IF:-}" "${INTERNET:-unknown}" "${WIFI_SSID:-}" >> "$HISTORY_FILE" 2>/dev/null
  if [[ -f "$HISTORY_FILE" ]] && (( $(wc -l < "$HISTORY_FILE") > 5000 )); then
    tail -n 1000 "$HISTORY_FILE" > "$HISTORY_FILE.tmp" && mv "$HISTORY_FILE.tmp" "$HISTORY_FILE"
  fi
  return 0
}

spawn() {
  local name="$1"; shift
  local id=$(( ++JOB_SEQ ))
  JOB_NAMES+=("$name"); JOB_IDS+=("$id")
  ( "$@"; : > "$TMP/.done.$id" ) >/dev/null 2>&1 &
  JOB_PIDS+=("$!")
}
begin_phase() { JOB_PIDS=(); JOB_NAMES=(); JOB_IDS=(); }

wait_jobs() {
  local label="$1" total=${#JOB_PIDS[@]} i n names frame=0 filled avail
  (( total == 0 )) && return 0
  if (( ! ANIMATE )); then wait "${JOB_PIDS[@]}" 2>/dev/null; begin_phase; return 0; fi
  printf '%s' "$HIDE_CUR"
  while :; do
    n=0; names=""
    for ((i = 0; i < total; i++)); do
      if [[ -e "$TMP/.done.${JOB_IDS[i]}" ]]; then n=$(( n + 1 )); else names+="${names:+, }${JOB_NAMES[i]}"; fi
    done
    (( n >= total )) && break
    filled=$(( n * 10 / total ))
    avail=$(( W - ${#label} - 24 )); (( avail < 0 )) && avail=0
    printf '%s  %s%s%s %s  %s%s%s%s%s %d/%d  %s%s%s' "$CLR_LINE" "$CYAN" "${SPIN[frame % ${#SPIN[@]}]}" "$RESET" "$label" \
      "$CYAN" "$(rep "$G_ON" "$filled")" "$GRAY" "$(rep "$G_OFF" "$(( 10 - filled ))")" "$RESET" "$n" "$total" "$DIM" "${names:0:avail}" "$RESET"
    frame=$(( frame + 1 )); sleep 0.08
  done
  printf '%s%s' "$CLR_LINE" "$SHOW_CUR"
  wait 2>/dev/null
  begin_phase
}

banner() {
  local art=(
' _   _ _____ _____ ____   ____   ___  ____  _____'
'| \ | | ____|_   _/ ___| / ___| / _ \|  _ \| ____|'
'|  \| |  _|   | | \___ \| |    | | | | |_) |  _|'
'| |\  | |___  | |  ___) | |___ | |_| |  __/| |___'
'|_| \_|_____| |_| |____/ \____| \___/|_|   |_____|')
  local i
  printf '\n'
  for i in "${!art[@]}"; do
    printf '  %s%s%s\n' "${BCOL[i]}$BOLD" "${art[i]}" "$RESET"
    (( ANIMATE )) && sleep 0.04
  done
  printf '  %s%s%s  %sNETWORK HEALTH CONSOLE%s  %sv%s%s\n' "$MAGENTA" "$G_WAVE" "$RESET" "$BOLD" "$RESET" "$GRAY" "$VERSION" "$RESET"
  printf '  %sA friendly check-up of every link between your computer and the internet.%s\n\n' "$DIM" "$RESET"
}

# ══════════════════════════════════════════════════════════════════════════════
#  DETECTION
# ══════════════════════════════════════════════════════════════════════════════
is_vpn_iface()     { [[ "$1" =~ ^(tun|tap|wg|ppp|tailscale|zt|nordlynx|proton|ipsec|vpn|mullvad) ]]; }
is_virtual_iface() { [[ "$1" =~ ^(lo$|docker|veth|br-|virbr|vmnet|vboxnet|vnet|lxc|lxd|podman|cni|flannel|cali|kube|dummy|ifb|bond|team|sit|gre|ip6tnl|nm-) ]] || is_vpn_iface "$1"; }

iface_type() {
  local i="$1"
  if   [[ -d "$NETSYS/$i/wireless" || -d "$NETSYS/$i/phy80211" ]]; then echo wifi
  elif is_vpn_iface "$i";                                          then echo vpn
  elif is_virtual_iface "$i";                                      then echo virtual
  elif [[ -e "$NETSYS/$i/device" ]];                               then echo wired
  else echo other; fi
}

find_physical() {
  local want="${1:-up}" d i st
  for d in "$NETSYS"/*; do
    i="${d##*/}"; [[ -e "$d" ]] || continue
    is_virtual_iface "$i" && continue
    st="$(rd "$d/operstate")"
    if [[ "$want" == any || "$st" == up || "$st" == unknown ]]; then printf '%s' "$i"; return 0; fi
  done
}

route_field() { awk -v k="$2" '{ for (i = 1; i <= NF; i++) if ($i == k) { print $(i + 1); exit } }' <<<"$1"; }

detect_network() {
  local r d i
  local -a DEFROUTES=()
  IFACE=""; GATEWAY=""; DEFAULT_ROUTE=""; ROUTE_FAMILY=""; VPN_IF=""; VPN_ROUTE=""; LAN_IF=""
  mapfile -t DEFROUTES < <(ip -4 route show default 2>/dev/null; ip -6 route show default 2>/dev/null)
  for r in "${DEFROUTES[@]}"; do
    [[ -n "$r" ]] || continue
    d="$(route_field "$r" dev)"
    if is_vpn_iface "$d"; then VPN_IF="${VPN_IF:-$d}"; VPN_ROUTE="${VPN_ROUTE:-$r}"; continue; fi
    DEFAULT_ROUTE="$r"; break
  done
  [[ -z "$DEFAULT_ROUTE" && -n "$VPN_ROUTE" ]] && DEFAULT_ROUTE="$VPN_ROUTE"
  if [[ -n "$DEFAULT_ROUTE" ]]; then
    ROUTE_FAMILY="IPv4"; [[ "$DEFAULT_ROUTE" == *:* ]] && ROUTE_FAMILY="IPv6"
    IFACE="$(route_field "$DEFAULT_ROUTE" dev)"
    GATEWAY="$(route_field "$DEFAULT_ROUTE" via)"
  fi
  [[ -z "$IFACE" ]] && IFACE="$(find_physical up)"
  [[ -z "$IFACE" ]] && IFACE="$(ip -o link show up 2>/dev/null | awk -F': ' '$2 != "lo" { sub(/@.*/, "", $2); print $2; exit }')"
  [[ -z "$IFACE" ]] && IFACE="$(find_physical any)"
  LAN_IF="$IFACE"
  if [[ -n "$IFACE" ]] && is_vpn_iface "$IFACE"; then
    VPN_IF="${VPN_IF:-$IFACE}"; LAN_IF="$(find_physical up)"
  fi
  [[ -z "$LAN_IF" ]] && LAN_IF="$IFACE"
  if [[ -z "$VPN_IF" ]]; then
    for d in "$NETSYS"/*; do
      i="${d##*/}"; [[ -e "$d" ]] || continue
      if is_vpn_iface "$i" && [[ "$(rd "$d/operstate")" != down ]]; then VPN_IF="$i"; break; fi
    done
  fi
  LAN_TYPE=""; [[ -n "$LAN_IF" ]] && LAN_TYPE="$(iface_type "$LAN_IF")"
}

freq_to_chan() {
  local f="$1"
  [[ "$f" =~ ^[0-9]+$ ]] || return 0
  if   (( f == 2484 )); then echo 14
  elif (( f < 2484 ));  then echo $(( (f - 2407) / 5 ))
  elif (( f >= 5955 )); then echo $(( (f - 5950) / 5 ))
  else echo $(( (f - 5000) / 5 )); fi
}
freq_to_band() {
  local f="$1"
  [[ "$f" =~ ^[0-9]+$ ]] || return 0
  if (( f < 3000 )); then echo "2.4 GHz"; elif (( f < 5900 )); then echo "5 GHz"; else echo "6 GHz"; fi
}

read_counters() {
  local d="$NETSYS/$LAN_IF/statistics" c v e dr pk
  local -A X=([rx_errors]=0 [tx_errors]=0 [rx_crc_errors]=0 [rx_dropped]=0 [tx_dropped]=0 [rx_packets]=0 [tx_packets]=0)
  if [[ -n "$LAN_IF" && -d "$d" ]]; then
    for c in "${!X[@]}"; do
      v="$(rd "$d/$c")"; [[ "$v" =~ ^[0-9]+$ ]] && X[$c]="$v"
    done
  fi
  e="${X[rx_errors]}"; (( X[rx_crc_errors] > e )) && e="${X[rx_crc_errors]}"
  e=$(( e + X[tx_errors] ))
  dr=$(( X[rx_dropped] + X[tx_dropped] ))
  pk=$(( X[rx_packets] + X[tx_packets] ))
  printf '%s %s %s' "$e" "$dr" "$pk"
}

wifi_gather() {
  WIFI_CONNECTED=0; WIFI_SSID=""; WIFI_BSSID=""; WIFI_FREQ=""; WIFI_SIGNAL=""; WIFI_TX=""; WIFI_RX=""
  WIFI_CHAN=""; WIFI_BAND=""; WIFI_RETRIES=""; WIFI_FAILED=""; WIFI_TXPKTS=""; WIFI_SIGAVG=""
  WIFI_EXPECTED=""; WIFI_PSAVE=""; WIFI_SEC=""; WIFI_CROWD=""
  WIFI_QUAL=""; WIFI_RATE_ALT=""; WIFI_SIG_EST=0
  [[ "$LAN_TYPE" == wifi ]] || return 0
  local info lvl st cur
  st="$(rd "$NETSYS/$LAN_IF/operstate")"
  if have iw; then
    info="$(iw dev "$LAN_IF" link 2>/dev/null)"
    if grep -q '^Connected to ' <<<"$info"; then
      WIFI_CONNECTED=1
      WIFI_BSSID="$(awk '/^Connected to/ { print $3; exit }' <<<"$info")"
      WIFI_SSID="$(sed -n 's/^[[:space:]]*SSID: //p' <<<"$info" | head -n1)"
      WIFI_FREQ="$(awk '/^[[:space:]]*freq:/ { print int($2); exit }' <<<"$info")"
      WIFI_SIGNAL="$(awk '/^[[:space:]]*signal:/ { print $2; exit }' <<<"$info")"
      WIFI_TX="$(sed -n 's/^[[:space:]]*tx bitrate: //p' <<<"$info" | awk '{ print $1, $2; exit }')"
      WIFI_RX="$(sed -n 's/^[[:space:]]*rx bitrate: //p' <<<"$info" | awk '{ print $1, $2; exit }')"
      info="$(iw dev "$LAN_IF" station dump 2>/dev/null)"
      WIFI_RETRIES="$(awk -F: '/tx retries/ { gsub(/[ \t]/, "", $2); print $2; exit }' <<<"$info")"
      WIFI_FAILED="$(awk -F: '/tx failed/ { gsub(/[ \t]/, "", $2); print $2; exit }' <<<"$info")"
      WIFI_TXPKTS="$(awk -F: '/tx packets/ { gsub(/[ \t]/, "", $2); print $2; exit }' <<<"$info")"
      WIFI_SIGAVG="$(awk '/signal avg:/ { print $3; exit }' <<<"$info")"
      WIFI_EXPECTED="$(awk -F: '/expected throughput/ { gsub(/^[ \t]+/, "", $2); print $2; exit }' <<<"$info")"
      WIFI_PSAVE="$(iw dev "$LAN_IF" get power_save 2>/dev/null | awk '{ print $NF; exit }')"
    fi
  fi
  if (( ! WIFI_CONNECTED )) && [[ "$st" == up ]]; then
    if ! have iw || ! iw dev "$LAN_IF" info >/dev/null 2>&1; then WIFI_CONNECTED=1; fi
  fi
  if (( WIFI_CONNECTED )); then
    if [[ -z "$WIFI_SIGNAL" && -r "$PROCNET/wireless" ]]; then
      lvl="$(awk -v i="$LAN_IF:" '$1 == i { gsub(/\./, "", $4); print $4; exit }' "$PROCNET/wireless")"
      [[ "$lvl" =~ ^-[0-9]+$ ]] && WIFI_SIGNAL="$lvl"
    fi
    if have iwconfig && [[ -z "$WIFI_SIGNAL" || -z "$WIFI_TX" ]]; then
      info="$(iwconfig "$LAN_IF" 2>/dev/null)"
      if [[ -z "$WIFI_SIGNAL" ]]; then
        lvl="$(sed -nE 's/.*Signal level[=:]([-0-9]+).*/\1/p' <<<"$info" | head -n1)"
        [[ "$lvl" =~ ^-[0-9]+$ ]] && WIFI_SIGNAL="$lvl"
      fi
      WIFI_RATE_ALT="$(sed -nE 's/.*Bit Rate[=:]([0-9.]+ [A-Za-z\/]+).*/\1/p' <<<"$info" | head -n1)"
      [[ -z "$WIFI_SSID" ]] && WIFI_SSID="$(sed -nE 's/.*ESSID:"([^"]*)".*/\1/p' <<<"$info" | head -n1)"
    fi
    if [[ -z "$WIFI_SSID" ]]; then
      have iwgetid && WIFI_SSID="$(iwgetid -r 2>/dev/null)"
    fi
    WIFI_SIGNAL="${WIFI_SIGNAL%.*}"
    WIFI_CHAN="$(freq_to_chan "$WIFI_FREQ")"; WIFI_BAND="$(freq_to_band "$WIFI_FREQ")"
    if have nmcli; then
      info="$(nmcli -t -f IN-USE,SIGNAL,RATE,SECURITY,CHAN,FREQ,SSID device wifi list ifname "$LAN_IF" --rescan no 2>/dev/null)"
      if [[ -n "$info" ]]; then
        WIFI_QUAL="$(awk -F: '$1 == "*" { print $2; exit }' <<<"$info")"
        cur="$(awk -F: '$1 == "*" { print $3; exit }' <<<"$info")"
        [[ -z "$WIFI_RATE_ALT" ]] && WIFI_RATE_ALT="$cur"
        WIFI_SEC="$(awk -F: '$1 == "*" { print $4; exit }' <<<"$info")"
        [[ -z "$WIFI_CHAN" ]] && WIFI_CHAN="$(awk -F: '$1 == "*" { print $5; exit }' <<<"$info")"
        if [[ -z "$WIFI_FREQ" ]]; then
          WIFI_FREQ="$(awk -F: '$1 == "*" { split($6, a, " "); print a[1]; exit }' <<<"$info")"
          [[ "$WIFI_FREQ" =~ ^[0-9]+$ ]] || WIFI_FREQ=""
          WIFI_BAND="$(freq_to_band "$WIFI_FREQ")"
        fi
        [[ -n "$WIFI_CHAN" ]] && WIFI_CROWD="$(awk -F: -v c="$WIFI_CHAN" '$1 != "*" && $5 == c { n++ } END { print n + 0 }' <<<"$info")"
      fi
      if [[ -z "$WIFI_SIGNAL" && "$WIFI_QUAL" =~ ^[0-9]+$ ]]; then
        WIFI_SIGNAL=$(( WIFI_QUAL / 2 - 100 )); WIFI_SIG_EST=1
      fi
    fi
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  PROBE JOBS
# ══════════════════════════════════════════════════════════════════════════════
PING_COUNT=20
DNS_DOMAINS=(example.com www.wikipedia.org www.cloudflare.com ubuntu.com)
CURL_FMT='NS_TIMING dns=%{time_namelookup} connect=%{time_connect} tls=%{time_appconnect} ttfb=%{time_starttransfer} total=%{time_total} code=%{http_code} ip=%{remote_ip} ver=%{http_version}\n'
TRACE_URL="https://www.cloudflare.com/cdn-cgi/trace"

job_ping() {
  local opts=(-n -c "$PING_COUNT" -i 0.2 -W 1 -w 9)
  [[ "$2" == *:* ]] && opts+=(-6 -I "${LAN_IF:-$IFACE}")
  ping "${opts[@]}" "$2" > "$TMP/ping_$1.txt" 2>&1
}
job_dns() {
  local d
  for d in "${DNS_DOMAINS[@]}"; do
    (
      t0="$(now_ms)"
      timeout 5 getent ahosts "$d" >/dev/null 2>&1; rc=$?
      printf '%s %s %s\n' "$d" "$rc" "$(( $(now_ms) - t0 ))" > "$TMP/dns_$d.tmp"
    ) &
  done
  wait
  cat "$TMP"/dns_*.tmp > "$TMP/dns.txt" 2>/dev/null
}
curl_probe() {
  local p="$1" ct="$2" mt="$3"; shift 3
  curl -sS --connect-timeout "$ct" --max-time "$mt" -A "NetScope/$VERSION" \
       -o "$TMP/$p.body" -w "$CURL_FMT" "$@" > "$TMP/$p.timing" 2> "$TMP/$p.err"
  printf '%s\n' "$?" > "$TMP/$p.rc"
}
job_http() {
  curl_probe http 4 7 "$TRACE_URL"
  if [[ "$(<"$TMP/http.rc")" != 0 ]]; then
    curl_probe http_ip 3 5 --resolve one.one.one.one:443:1.1.1.1 https://one.one.one.one/cdn-cgi/trace
  fi
}
job_ipv6() { curl_probe v6 3 5 -6 "$TRACE_URL"; }
job_portal() {
  local code
  code="$(curl -sS -o /dev/null --connect-timeout 3 --max-time 5 -w '%{http_code}' http://connectivity-check.ubuntu.com/ 2>/dev/null)"
  printf '%s' "${code:-000}" > "$TMP/portal.code"
}
job_traffic() {
  local i
  : > "$TMP/traffic.txt"
  for i in 0 1 2 3 4; do
    printf '%s %s %s\n' "$(now_ms)" "$(rd "$NETSYS/$IFACE/statistics/rx_bytes")" "$(rd "$NETSYS/$IFACE/statistics/tx_bytes")" >> "$TMP/traffic.txt"
    (( i < 4 )) && sleep 1
  done
}

start_basic_jobs() {
  begin_phase
  have ping && [[ -n "$GATEWAY" ]] && spawn "router"      job_ping gw   "$GATEWAY"
  have ping && spawn "internet"    job_ping pub1 1.1.1.1
  have ping && spawn "reliability" job_ping pub2 8.8.8.8
  have getent && spawn "names"     job_dns
  if have curl; then
    spawn "web"     job_http
    spawn "IPv6"    job_ipv6
    spawn "sign-in" job_portal
  fi
  [[ -n "$IFACE" && -r "$NETSYS/$IFACE/statistics/rx_bytes" ]] && spawn "traffic" job_traffic
}

dns_query() {
  if have host; then timeout 4 host -W 2 -t A "$2" "$1" | grep -i 'has address'
  else return 127; fi
}
job_dns_direct() {
  local srv t0 out rc q
  : > "$TMP/dns_direct.txt"
  for srv in "$@"; do
    t0="$(now_ms)"; q=""
    if have dig; then
      out="$(timeout 4 dig +time=2 +tries=1 +noall +answer +stats "@$srv" example.com A 2>/dev/null)"; rc=$?
      q="$(sed -nE 's/^;; Query time: ([0-9]+) msec.*/\1/p' <<<"$out" | head -n1)"
      grep -qE '[[:space:]]A[[:space:]]+[0-9.]+' <<<"$out" || rc=1
    else
      out="$(dns_query "$srv" example.com 2>/dev/null)"; rc=$?
      [[ -n "$out" ]] || rc=1
    fi
    [[ "$q" =~ ^[0-9]+$ ]] || q=$(( $(now_ms) - t0 ))
    printf '%s %s %s\n' "$srv" "$rc" "$q" >> "$TMP/dns_direct.txt"
  done
}
job_trace() {
  local tool=""
  if have tracepath; then tool=tracepath; elif have traceroute; then tool=traceroute; else return 0; fi
  if have stdbuf; then
    if [[ "$tool" == tracepath ]]; then
      timeout 12 stdbuf -oL tracepath -n -m 12 1.1.1.1 > "$TMP/trace.txt" 2>&1
    else
      timeout 12 stdbuf -oL traceroute -n -q 1 -w 1 -m 12 1.1.1.1 > "$TMP/trace.txt" 2>&1
    fi
  elif [[ "$tool" == tracepath ]]; then
    timeout 12 tracepath -n -m 12 1.1.1.1 > "$TMP/trace.txt" 2>&1
  else
    timeout 12 traceroute -n -q 1 -w 1 -m 12 1.1.1.1 > "$TMP/trace.txt" 2>&1
  fi
  printf '%s' "$tool" > "$TMP/trace.tool"
}

get_dns_servers() {
  local out=""
  if have resolvectl; then
    out="$(resolvectl dns "$LAN_IF" 2>/dev/null)"
    [[ -z "$(grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' <<<"$out")" ]] && out="$(resolvectl dns 2>/dev/null)"
  fi
  if [[ -z "$(grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' <<<"$out")" ]] && have nmcli && [[ -n "$LAN_IF" ]]; then
    out="$(nmcli -g IP4.DNS device show "$LAN_IF" 2>/dev/null)"
  fi
  if [[ -z "$(grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' <<<"$out")" ]]; then
    out="$(grep -E '^[[:space:]]*nameserver[[:space:]]+' /etc/resolv.conf 2>/dev/null)"
  fi
  grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' <<<"$out" | grep -v '^127\.' | awk '!s[$0]++' | head -n 2
}

start_advanced_jobs() {
  local srvs=(1.1.1.1 8.8.8.8) s
  begin_phase
  while read -r s; do [[ -n "$s" ]] && srvs=("$s" "${srvs[@]}"); done < <(get_dns_servers)
  (have dig || have host) && spawn "DNS servers" job_dns_direct "${srvs[@]}"
  have ping && { have tracepath || have traceroute; } && spawn "route to the internet" job_trace
}

job_speed() {
  local start b t tms out pp dl_b=0 dl_ms=0 ul_b=0 ul_ms=0 remain
  ping -n -c 40 -i 0.2 -W 1 -w 10 1.1.1.1 > "$TMP/ping_load.txt" 2>&1 &
  pp=$!
  start="$(now_ms)"
  while (( $(now_ms) - start < 7000 && dl_b < 100000000 )); do
    remain=$(( (8000 - ($(now_ms) - start)) / 1000 )); (( remain < 2 )) && remain=2
    out="$(curl -s -o /dev/null --max-time "$remain" -w '%{size_download} %{time_total}' 'https://speed.cloudflare.com/__down?bytes=25000000' 2>/dev/null)"
    read -r b t <<<"$out"
    [[ "$b" =~ ^[0-9]+$ ]] && (( b > 1000 )) || break
    tms="$(to_ms "$t")"; dl_b=$(( dl_b + b )); dl_ms=$(( dl_ms + tms ))
  done
  wait "$pp" 2>/dev/null
  head -c 6000000 /dev/zero > "$TMP/up.bin" 2>/dev/null
  start="$(now_ms)"
  while (( $(now_ms) - start < 4500 && ul_b < 30000000 )); do
    remain=$(( (5500 - ($(now_ms) - start)) / 1000 )); (( remain < 2 )) && remain=2
    out="$(curl -s -o /dev/null --max-time "$remain" -X POST --data-binary @"$TMP/up.bin" -H 'Content-Type: application/octet-stream' -w '%{size_upload} %{time_total}' 'https://speed.cloudflare.com/__up' 2>/dev/null)"
    read -r b t <<<"$out"
    [[ "$b" =~ ^[0-9]+$ ]] && (( b > 1000 )) || break
    tms="$(to_ms "$t")"; ul_b=$(( ul_b + b )); ul_ms=$(( ul_ms + tms ))
  done
  printf '%s %s %s %s\n' "$dl_b" "$dl_ms" "$ul_b" "$ul_ms" > "$TMP/speed.txt"
  rm -f "$TMP/up.bin"
}
start_speed_job() { begin_phase; spawn "download & upload" job_speed; }

# ══════════════════════════════════════════════════════════════════════════════
#  PARSERS
# ══════════════════════════════════════════════════════════════════════════════
PING_AWK=$(cat <<'AWK'
BEGIN { split(glyphs, G, " "); n = 0; maxseq = 0 }
/bytes from/ {
  v = ""; s = ""
  for (i = 1; i <= NF; i++) {
    if ($i ~ /^time=/)     v = substr($i, 6) + 0
    if ($i ~ /^icmp_seq=/) s = substr($i, 10) + 0
  }
  if (v != "") {
    n++; sum += v
    if (n == 1 || v < mn) mn = v
    if (v > mx) mx = v
    if (n > 1) { d = v - prev; if (d < 0) d = -d; dsum += d }
    prev = v
    if (s == "") s = n
    val[s] = v; if (s > maxseq) maxseq = s
  }
}
/packets transmitted/ {
  sent = $1 + 0; recv = $4 + 0; have = 1
  if (match($0, /[0-9.]+% packet loss/)) loss = substr($0, RSTART, RLENGTH) + 0
}
END {
  if (!have) { sent = maxseq; recv = n; loss = (sent > 0) ? (sent - recv) * 100 / sent : 100 }
  top = (sent > maxseq) ? sent : maxseq
  sp = ""
  for (k = 1; k <= top; k++) {
    if (k in val) {
      v = val[k]
      if (v <= 10) l = 1; else if (v <= 20) l = 2; else if (v <= 40) l = 3; else if (v <= 60) l = 4
      else if (v <= 100) l = 5; else if (v <= 150) l = 6; else if (v <= 250) l = 7; else l = 8
      sp = sp G[l]
    } else sp = sp lost
  }
  if (n == 0) printf "%d %d %.0f - - - - %s\n", sent, recv, loss, sp
  else printf "%d %d %.0f %.1f %.1f %.1f %.1f %s\n", sent, recv, loss, mn, sum / n, mx, (n > 1) ? dsum / (n - 1) : 0, sp
}
AWK
)

TRAFFIC_AWK=$(cat <<'AWK'
BEGIN { split(glyphs, G, " ") }
{ t[NR] = $1; r[NR] = $2; x[NR] = $3 }
END {
  n = NR - 1
  if (n < 1) { print "0 0 - -"; exit }
  for (i = 1; i <= n; i++) {
    dt = (t[i + 1] - t[i]) / 1000; if (dt <= 0) dt = 1
    a = (r[i + 1] - r[i]) / dt; if (a < 0) a = 0
    b = (x[i + 1] - x[i]) / dt; if (b < 0) b = 0
    ra[i] = a; ta[i] = b; rs += a; ts += b
    if (a > pk) pk = a; if (b > pk) pk = b
  }
  if (pk < 65536) pk = 65536
  for (i = 1; i <= n; i++) {
    l = int(ra[i] / pk * 7 + 0.5) + 1; rsp = rsp G[l]
    l = int(ta[i] / pk * 7 + 0.5) + 1; tsp = tsp G[l]
  }
  printf "%.0f %.0f %s %s\n", rs / n, ts / n, rsp, tsp
}
AWK
)

declare -A PG=()
ping_parse() {
  local k="$1" f="$2" out sent recv loss mn avg mx jit spark
  PG[$k.n]=0
  [[ -s "$f" ]] || return 1
  out="$(awk -v glyphs="$SPARK_GLYPHS" -v lost="$G_LOST" "$PING_AWK" "$f")"
  read -r sent recv loss mn avg mx jit spark <<<"$out"
  [[ "$sent" =~ ^[0-9]+$ && "$recv" =~ ^[0-9]+$ ]] || return 1
  (( sent > 0 )) || return 1
  PG[$k.sent]="$sent"; PG[$k.recv]="$recv"; PG[$k.loss]="$loss"; PG[$k.min]="$mn"
  PG[$k.avg]="$avg";   PG[$k.max]="$mx";    PG[$k.jit]="$jit";   PG[$k.spark]="${spark:-}"
  PG[$k.n]="$recv"
}

kv_get() { sed -nE "s/.* $2=([^ ]*).*/\1/p" <<<"$1"; }

http_read() {
  local line
  HR_RC=""; HR_CODE=""; HR_IP=""; HR_VER=""; HR_DNS=""; HR_CONN=""; HR_TLS=""; HR_TTFB=""; HR_TOTAL=""
  [[ -f "$TMP/$1.rc" ]] && HR_RC="$(<"$TMP/$1.rc")"
  line="$(grep -a '^NS_TIMING' "$TMP/$1.timing" 2>/dev/null | tail -n1)"
  [[ -n "$line" ]] || return 1
  HR_CODE="$(kv_get "$line" code)"; HR_IP="$(kv_get "$line" ip)"; HR_VER="$(kv_get "$line" ver)"
  HR_DNS="$(to_ms "$(kv_get "$line" dns)")";   HR_CONN="$(to_ms "$(kv_get "$line" connect)")"
  HR_TLS="$(to_ms "$(kv_get "$line" tls)")";   HR_TTFB="$(to_ms "$(kv_get "$line" ttfb)")"
  HR_TOTAL="$(to_ms "$(kv_get "$line" total)")"
}
http_ok() { [[ "$HR_RC" == 0 && -n "$HR_CODE" && "$HR_CODE" != 000 ]]; }
trace_field() { sed -n "s/^$2=//p" "$TMP/$1.body" 2>/dev/null | head -n1; }

snmp_get() {
  awk -v p="$1:" -v f="$2" '$1 == p { if (!h) { for (i = 2; i <= NF; i++) col[$i] = i; h = 1 } else { if (col[f]) print $(col[f]); exit } }' "$PROCNET/snmp" 2>/dev/null
}

# ══════════════════════════════════════════════════════════════════════════════
#  EVALUATION
# ══════════════════════════════════════════════════════════════════════════════
SCORE=100; PEN=(); TIPS=()
penalize() { SCORE=$(( SCORE - $1 )); PEN+=("$1|$2"); }
add_tip()  { (( ${#TIPS[@]} < 4 )) && TIPS+=("$1"); }

pick_public() {
  local k best="" bl=0 bv=0
  for k in pub1 pub2; do
    (( ${PG[$k.n]:-0} > 0 )) || continue
    if [[ -z "$best" ]] || awk -v l1="${PG[$k.loss]}" -v a1="${PG[$k.avg]}" -v l0="$bl" -v a0="$bv" 'BEGIN { exit !(l1 < l0 || (l1 == l0 && a1 < a0)) }'; then
      best="$k"; bl="${PG[$k.loss]}"; bv="${PG[$k.avg]}"
    fi
  done
  PUB_KEY="$best"
}

AP_SCORE=5; AP_WORST=0; AP_NOTE=""
ap_start() { AP_SCORE=5; AP_WORST=0; AP_NOTE=""; }
ap()       { AP_SCORE=$(( AP_SCORE - $1 )); if (( $1 > AP_WORST )); then AP_WORST="$1"; AP_NOTE="$2"; fi; }
ap_end()   { (( AP_SCORE < 1 )) && AP_SCORE=1; (( AP_SCORE > 5 )) && AP_SCORE=5; ACT_STARS+=("$AP_SCORE"); ACT_NOTE+=("$AP_NOTE"); }

evaluate() {
  local i w ws gl gn errs drops pk
  SCORE=100; PEN=(); TIPS=()
  N_LABEL=("" "YOU" "WI-FI" "ROUTER" "INTERNET" "WEBSITES")
  N_STATE=("" UNK UNK UNK UNK UNK)
  N_WORD=("" "" "" "" "" "")
  case "$LAN_TYPE" in wifi) N_LABEL[2]="WI-FI" ;; wired) N_LABEL[2]="CABLE" ;; *) N_LABEL[2]="LINK" ;; esac

  ping_parse gw   "$TMP/ping_gw.txt"
  ping_parse pub1 "$TMP/ping_pub1.txt"
  ping_parse pub2 "$TMP/ping_pub2.txt"
  pick_public
  PUB_TARGET=""; [[ "$PUB_KEY" == pub1 ]] && PUB_TARGET=1.1.1.1; [[ "$PUB_KEY" == pub2 ]] && PUB_TARGET=8.8.8.8
  PUB_OK=0; [[ -n "$PUB_KEY" ]] && PUB_OK=1

  DNS_TOTAL=0; DNS_OKN=0; DNS_SUM=0; DNS_AVG=0; DNS_MAX=0
  if [[ -s "$TMP/dns.txt" ]]; then
    local dom rc ms
    while read -r dom rc ms; do
      [[ "$ms" =~ ^[0-9]+$ ]] || continue
      DNS_TOTAL=$(( DNS_TOTAL + 1 ))
      if [[ "$rc" == 0 ]]; then DNS_OKN=$(( DNS_OKN + 1 )); DNS_SUM=$(( DNS_SUM + ms )); (( ms > DNS_MAX )) && DNS_MAX="$ms"; fi
    done < "$TMP/dns.txt"
    (( DNS_OKN > 0 )) && DNS_AVG=$(( DNS_SUM / DNS_OKN ))
  fi

  INTERNET="UNKNOWN"; INET_VIA=""; FIRST_RC=""
  H_RC=""; H_CODE=""; H_IP=""; H_VER=""; H_DNS=""; H_CONN=""; H_TLS=""; H_TTFB=""; H_TOTAL=""; H_FROM=""
  if have curl && [[ -f "$TMP/http.rc" ]]; then
    http_read http
    if http_ok; then INTERNET=OK; H_FROM=http
    else
      FIRST_RC="$HR_RC"
      http_read http_ip
      if http_ok; then INTERNET=OK; INET_VIA=ip; H_FROM=http_ip
      elif (( PUB_OK )); then INTERNET=PARTIAL
      else INTERNET=FAIL; fi
    fi
    if [[ "$INTERNET" == OK ]]; then
      H_RC="$HR_RC"; H_CODE="$HR_CODE"; H_IP="$HR_IP"; H_VER="$HR_VER"; H_DNS="$HR_DNS"
      H_CONN="$HR_CONN"; H_TLS="$HR_TLS"; H_TTFB="$HR_TTFB"; H_TOTAL="$HR_TOTAL"
      PUB_IP="$(trace_field "$H_FROM" ip)"
    fi
  elif (( PUB_OK )); then INTERNET=OK; INET_VIA=ping
  fi

  PORTAL=0; PORTAL_CODE=""
  [[ -f "$TMP/portal.code" ]] && PORTAL_CODE="$(<"$TMP/portal.code")"
  if [[ -n "$PORTAL_CODE" && "$PORTAL_CODE" != 204 && "$PORTAL_CODE" != 000 && "$INTERNET" != OK ]]; then PORTAL=1; fi

  IPV6_OK=0; IPV6_ADDR=""
  if [[ -f "$TMP/v6.rc" ]]; then
    http_read v6
    if http_ok; then IPV6_OK=1; IPV6_ADDR="$(trace_field v6 ip)"; fi
  fi

  LAT_MS=""; JIT_MS=""; LOSS_PCT=""; LAT_SRC=""; PUB_SPARK=""
  if (( PUB_OK )); then
    LAT_MS="${PG[$PUB_KEY.avg]}"; JIT_MS="${PG[$PUB_KEY.jit]}"; LOSS_PCT="${PG[$PUB_KEY.loss]}"
    PUB_SPARK="${PG[$PUB_KEY.spark]}"; LAT_SRC=ping
  elif [[ "$H_CONN" =~ ^[0-9]+$ && "$H_DNS" =~ ^[0-9]+$ ]]; then
    LAT_MS=$(( H_CONN - H_DNS )); (( LAT_MS < 1 )) && LAT_MS=1; LAT_SRC=tcp
  fi
  LAT_I="$(int "$LAT_MS")"; JIT_I="$(int "$JIT_MS")"; LOSS_I="$(int "$LOSS_PCT")"

  RX_AVG=0; TX_AVG=0; RX_SPARK=""; TX_SPARK=""; HAS_TRAFFIC=0
  if [[ -s "$TMP/traffic.txt" ]] && (( $(wc -l < "$TMP/traffic.txt") >= 2 )); then
    read -r RX_AVG TX_AVG RX_SPARK TX_SPARK <<<"$(awk -v glyphs="$SPARK_GLYPHS" "$TRAFFIC_AWK" "$TMP/traffic.txt")"
    [[ "$RX_AVG" =~ ^[0-9]+$ ]] && HAS_TRAFFIC=1
  fi

  DL_MBPS=""; UL_MBPS=""; DL_I=-1; UL_I=-1; LOAD_AVG=""; BLOAT_MS=""; BLOAT_GRADE=""; SPEED_RAN=0
  if [[ -s "$TMP/speed.txt" ]]; then
    local dlb dlm ulb ulm
    read -r dlb dlm ulb ulm < "$TMP/speed.txt"
    SPEED_RAN=1
    (( ${dlm:-0} > 0 && ${dlb:-0} > 0 )) && DL_MBPS="$(awk -v b="$dlb" -v m="$dlm" 'BEGIN { printf "%.1f", b * 8 / m / 1000 }')"
    (( ${ulm:-0} > 0 && ${ulb:-0} > 0 )) && UL_MBPS="$(awk -v b="$ulb" -v m="$ulm" 'BEGIN { printf "%.1f", b * 8 / m / 1000 }')"
    [[ -n "$DL_MBPS" ]] && DL_I="$(int "$DL_MBPS")"
    [[ -n "$UL_MBPS" ]] && UL_I="$(int "$UL_MBPS")"
    ping_parse load "$TMP/ping_load.txt"
    if (( ${PG[load.n]:-0} > 3 && PUB_OK )); then
      LOAD_AVG="${PG[load.avg]}"
      BLOAT_MS="$(awk -v a="$LOAD_AVG" -v b="$LAT_MS" 'BEGIN { d = a - b; if (d < 0) d = 0; printf "%.0f", d }')"
      if   (( BLOAT_MS < 30 ));  then BLOAT_GRADE="A (excellent)"
      elif (( BLOAT_MS < 60 ));  then BLOAT_GRADE="B (good)"
      elif (( BLOAT_MS < 200 )); then BLOAT_GRADE="C (noticeable lag under load)"
      else BLOAT_GRADE="D (heavy lag under load)"; fi
    fi
  fi

  ERR_PCT="0"; DROP_PCT="0"; ERR_TOTAL=0; DROP_TOTAL=0; ERR_NEW=0; DROP_NEW=0
  if [[ -n "$LAN_IF" ]]; then
    read -r errs drops pk <<<"$(read_counters)"
    ERR_TOTAL="${errs:-0}"; DROP_TOTAL="${drops:-0}"
    ERR_NEW=$(( ERR_TOTAL - ${CNT0_E:-$ERR_TOTAL} ));   (( ERR_NEW < 0 ))  && ERR_NEW=0
    DROP_NEW=$(( DROP_TOTAL - ${CNT0_D:-$DROP_TOTAL} )); (( DROP_NEW < 0 )) && DROP_NEW=0
    if (( ${pk:-0} > 0 )); then
      ERR_PCT="$(awk -v e="$ERR_TOTAL" -v p="$pk" 'BEGIN { printf "%.2f", e * 100 / p }')"
      DROP_PCT="$(awk -v e="$DROP_TOTAL" -v p="$pk" 'BEGIN { printf "%.2f", e * 100 / p }')"
    fi
  fi

  HAS_IF=0; HAS_IP=0; HAS_ROUTE=0
  [[ -n "$LAN_IF" && -e "$NETSYS/$LAN_IF" ]] && HAS_IF=1
  [[ -n "$DEFAULT_ROUTE" ]] && HAS_ROUTE=1
  OPERSTATE=""; CARRIER=""; ADDR4=""; ADDR6=""
  if (( HAS_IF )); then
    OPERSTATE="$(rd "$NETSYS/$LAN_IF/operstate")"; CARRIER="$(rd "$NETSYS/$LAN_IF/carrier")"
    ADDR4="$(first_cidr "$LAN_IF")"
    ADDR6="$(ip -o -6 addr show dev "$LAN_IF" scope global 2>/dev/null | awk '{ print $4; exit }')"
    [[ -n "$ADDR4$ADDR6" ]] && HAS_IP=1
  fi
  LINK_DOWN=0; WIFI_WEAK=0
  if (( ! HAS_IF )); then
    N_STATE[1]=FAIL; N_WORD[1]="No adapter"; penalize 30 "No network adapter was found"
    N_STATE[2]=FAIL; N_WORD[2]="Nothing"
  else
    if (( HAS_IP )); then N_STATE[1]=OK; N_WORD[1]="Ready"
    else N_STATE[1]=FAIL; N_WORD[1]="No address"; penalize 25 "No IP address on $LAN_IF"; fi

    case "$LAN_TYPE" in
      wifi)
        if (( WIFI_CONNECTED )); then
          if [[ "$WIFI_SIGNAL" =~ ^-?[0-9]+$ ]]; then
            ws="$WIFI_SIGNAL"
            if   (( ws >= -50 )); then w="Excellent"; elif (( ws >= -60 )); then w="Strong"
            elif (( ws >= -70 )); then w="Good";      elif (( ws >= -80 )); then w="Weak"; else w="Very weak"; fi
            N_WORD[2]="$w"; N_STATE[2]=OK
            if   (( ws < -80 )); then N_STATE[2]=WARN; WIFI_WEAK=1; penalize 10 "Wi-Fi signal is very weak (${ws} dBm)"
            elif (( ws < -70 )); then N_STATE[2]=WARN; WIFI_WEAK=1; penalize 5  "Wi-Fi signal is weak (${ws} dBm)"; fi
          else N_STATE[2]=OK; N_WORD[2]="Connected"; fi
        else N_STATE[2]=FAIL; N_WORD[2]="Not joined"; LINK_DOWN=1; penalize 20 "Wi-Fi is not connected to a network"; fi ;;
      wired)
        if [[ "$OPERSTATE" == down || "$CARRIER" == 0 ]]; then N_STATE[2]=FAIL; N_WORD[2]="Unplugged"; LINK_DOWN=1; penalize 20 "Network cable looks unplugged"
        else N_STATE[2]=OK; N_WORD[2]="Plugged in"; fi ;;
      *)
        if [[ "$OPERSTATE" == down ]]; then N_STATE[2]=FAIL; N_WORD[2]="Down"; LINK_DOWN=1; penalize 20 "Network link is down"
        else N_STATE[2]=OK; N_WORD[2]="Connected"; fi ;;
    esac
  fi

  GW_INFERRED=0
  gn="${PG[gw.n]:-0}"
  if (( ! HAS_ROUTE )); then
    N_STATE[3]=FAIL; N_WORD[3]="No route"; penalize 25 "No default route (no way out of the local network)"
  elif [[ -z "$GATEWAY" ]]; then
    N_STATE[3]=OK; N_WORD[3]="Direct"
  elif (( gn > 0 )); then
    gl="${PG[gw.loss]}"
    if   (( gl >= 50 )); then N_STATE[3]=FAIL; N_WORD[3]="Dropping";  penalize 15 "Router drops ${gl}% of pings"
    elif (( gl >= 10 )); then N_STATE[3]=WARN; N_WORD[3]="Unstable";  penalize 8  "Router drops ${gl}% of pings"
    else N_STATE[3]=OK; N_WORD[3]="Replying"; fi
  elif [[ ! -f "$TMP/ping_gw.txt" ]]; then
    N_STATE[3]=UNK; N_WORD[3]="Unknown"
  elif [[ "$INTERNET" == OK ]]; then
    N_STATE[3]=OK; N_WORD[3]="Working"; GW_INFERRED=1
  else
    N_STATE[3]=FAIL; N_WORD[3]="No answer"; penalize 15 "Router did not answer ping"
  fi

  if (( PORTAL )); then
    N_STATE[4]=WARN; N_WORD[4]="Sign-in?"; penalize 20 "Network seems to require a sign-in page"
  else
    case "$INTERNET" in
      OK)      N_STATE[4]=OK;   N_WORD[4]="Online" ;;
      PARTIAL) N_STATE[4]=WARN; N_WORD[4]="Partial"; penalize 10 "Pings work but the web test failed" ;;
      FAIL)    N_STATE[4]=FAIL; N_WORD[4]="Offline"; penalize 25 "Internet is not reachable" ;;
      *)       N_STATE[4]=UNK;  N_WORD[4]="Unknown" ;;
    esac
  fi

  if   (( DNS_TOTAL == 0 ));       then N_STATE[5]=UNK;  N_WORD[5]="Unknown"
  elif (( DNS_OKN == 0 ));         then N_STATE[5]=FAIL; N_WORD[5]="Not working"; penalize 20 "Website names cannot be looked up (DNS)"
  elif (( DNS_OKN < DNS_TOTAL ));  then N_STATE[5]=WARN; N_WORD[5]="Partly";      penalize 8  "Some website-name lookups failed (DNS)"
  elif (( DNS_AVG > 300 ));        then N_STATE[5]=WARN; N_WORD[5]="Slow";        penalize 4  "Website-name lookups are slow (${DNS_AVG} ms)"
  else N_STATE[5]=OK; N_WORD[5]="Working"; fi

  if [[ -n "$LAT_SRC" ]]; then
    if   (( LOSS_I >= 15 )); then penalize 12 "High packet loss (${LOSS_I}%)"
    elif (( LOSS_I >= 5 ));  then penalize 5  "Some packet loss (${LOSS_I}%)"
    elif (( LOSS_I >= 1 ));  then penalize 2  "Minor packet loss (${LOSS_I}%)"; fi
    if   (( LAT_I > 300 )); then penalize 12 "Very high latency (${LAT_I} ms)"
    elif (( LAT_I > 150 )); then penalize 6  "High latency (${LAT_I} ms)"
    elif (( LAT_I > 80 ));  then penalize 2  "Moderate latency (${LAT_I} ms)"; fi
    if [[ "$LAT_SRC" == ping ]]; then
      if   (( JIT_I > 50 )); then penalize 6 "Very unsteady timing (jitter ${JIT_I} ms)"
      elif (( JIT_I > 25 )); then penalize 3 "Unsteady timing (jitter ${JIT_I} ms)"
      elif (( JIT_I > 10 )); then penalize 1 "Slightly unsteady timing (jitter ${JIT_I} ms)"; fi
    fi
  fi
  if (( ERR_NEW > 0 )) && awk -v e="$ERR_PCT" 'BEGIN { exit !(e >= 0.5) }'; then
    penalize 3 "Network adapter keeps reporting errors (${ERR_PCT}% of packets, +${ERR_NEW} during the scan)"
  fi
  awk -v e="$DROP_PCT" 'BEGIN { exit !(e >= 5) }' && (( DROP_NEW > 0 )) && penalize 2 "Network adapter is dropping packets (${DROP_PCT}%)"
  if (( SPEED_RAN )); then
    if   (( DL_I >= 0 && DL_I < 3 ));  then penalize 10 "Download speed is very low (${DL_MBPS} Mbps)"
    elif (( DL_I >= 0 && DL_I < 10 )); then penalize 4  "Download speed is low (${DL_MBPS} Mbps)"; fi
    [[ -n "$BLOAT_MS" ]] && (( BLOAT_MS > 200 )) && penalize 4 "Delay jumps by ${BLOAT_MS} ms when the line is busy"
  fi
  if [[ "$INTERNET" == FAIL ]] && (( SCORE > 45 )); then penalize $(( SCORE - 45 )) "Internet is unreachable, so the score is capped at 45"; fi
  (( SCORE < 0 )) && SCORE=0
  (( SCORE > 100 )) && SCORE=100

  local broken=0
  for i in 1 2 3 4 5; do
    if (( broken )) && [[ "${N_STATE[i]}" != OK ]]; then N_STATE[i]=UNK; N_WORD[i]="Unreachable"; fi
    [[ "${N_STATE[i]}" == FAIL ]] && broken=1
  done

  if   (( SCORE >= 90 )); then GRADE="EXCELLENT";       FACE='\(^o^)/'; VERDICT="Everything looks great!";                  GCOL="$GREEN"
  elif (( SCORE >= 75 )); then GRADE="GOOD";            FACE='(^_^)';   VERDICT="Your connection is working well.";          GCOL="$LGREEN"
  elif (( SCORE >= 55 )); then GRADE="NEEDS ATTENTION"; FACE='(o_o;)';  VERDICT="It works, but something needs attention.";  GCOL="$YELLOW"
  else                         GRADE="POOR";            FACE='(T_T)';   VERDICT="There is a problem with your connection.";  GCOL="$RED"; fi
  (( SCORE < 55 )) && [[ "$INTERNET" == OK ]] && VERDICT="The internet is reachable, but quality is poor."
  diagnose
  rate_activities
  make_tips
}

diagnose() {
  DIAG=""
  if   [[ "${N_STATE[1]}" == FAIL ]]; then
    if (( HAS_IF )); then DIAG="Your computer is connected to the network but was not given an address."
    else DIAG="No network adapter was found on this computer."; fi
  elif [[ "${N_STATE[2]}" == FAIL ]]; then
    case "$LAN_TYPE" in
      wifi)  DIAG="Your computer is not connected to a Wi-Fi network." ;;
      wired) DIAG="The network cable looks unplugged." ;;
      *)     DIAG="The network link is down." ;;
    esac
  elif [[ "${N_STATE[3]}" == FAIL ]]; then DIAG="Your computer cannot reach your router."
  elif (( PORTAL )); then DIAG="This network probably wants you to sign in first (open a web browser)."
  elif [[ "${N_STATE[4]}" == FAIL ]]; then DIAG="Your router is reachable, but it has no working internet connection."
  elif [[ "${N_STATE[5]}" == FAIL ]]; then DIAG="The internet works, but website names cannot be looked up (a DNS problem)."
  elif [[ "${N_STATE[4]}" == WARN ]]; then DIAG="The internet connection is only partly working."
  elif [[ "${N_STATE[5]}" == WARN ]]; then DIAG="Website names are being looked up slowly or unreliably."
  elif [[ "${N_STATE[3]}" == WARN ]]; then DIAG="The link between your computer and your router is unreliable."
  elif (( WIFI_WEAK )); then DIAG="The Wi-Fi signal is weak. Moving closer to the router should help."
  elif (( SCORE < 90 )); then DIAG="Delay or lost data is lowering the quality of your connection."
  else DIAG="No problems found."; fi
}

rate_activities() {
  local i lat="$LAT_I" jit="$JIT_I" loss="$LOSS_I"
  ACT_NAMES=("Browsing websites" "Video calls" "Streaming video" "Online gaming")
  ACT_STARS=(); ACT_NOTE=()
  if [[ "$INTERNET" == FAIL || "${N_STATE[1]}" == FAIL || "${N_STATE[2]}" == FAIL ]]; then
    for i in 0 1 2 3; do ACT_STARS+=(0); ACT_NOTE+=("no internet"); done; return
  fi
  if (( PORTAL )) || [[ "$INTERNET" != OK ]]; then
    for i in 0 1 2 3; do ACT_STARS+=(1); ACT_NOTE+=("connection incomplete"); done; return
  fi

  ap_start
  if   (( lat > 400 )); then ap 3 "very slow replies"; elif (( lat > 200 )); then ap 2 "slow replies"; elif (( lat > 100 )); then ap 1 "slightly slow replies"; fi
  if   (( loss >= 10 )); then ap 3 "lost data"; elif (( loss >= 3 )); then ap 1 "some lost data"; fi
  if   (( DNS_OKN < DNS_TOTAL )); then ap 2 "some names fail to load"; fi
  if   (( DNS_AVG > 400 )); then ap 2 "slow name lookups"; elif (( DNS_AVG > 200 )); then ap 1 "slow name lookups"; fi
  (( WIFI_WEAK )) && ap 1 "weak Wi-Fi"
  if (( SPEED_RAN && DL_I >= 0 )); then if (( DL_I < 2 )); then ap 3 "slow download speed"; elif (( DL_I < 5 )); then ap 1 "modest download speed"; fi; fi
  ap_end

  ap_start
  if   (( lat > 300 )); then ap 3 "high delay"; elif (( lat > 150 )); then ap 2 "high delay"; elif (( lat > 80 )); then ap 1 "some delay"; fi
  if   (( jit > 50 )); then ap 3 "unsteady connection"; elif (( jit > 30 )); then ap 2 "unsteady connection"; elif (( jit > 15 )); then ap 1 "slightly unsteady"; fi
  if   (( loss >= 8 )); then ap 3 "lost data"; elif (( loss >= 3 )); then ap 2 "lost data"; elif (( loss >= 1 )); then ap 1 "a little lost data"; fi
  (( WIFI_WEAK )) && ap 1 "weak Wi-Fi"
  if (( SPEED_RAN && UL_I >= 0 )); then if (( UL_I < 1 )); then ap 2 "slow upload"; elif (( UL_I < 3 )); then ap 1 "modest upload"; fi; fi
  if [[ -n "$BLOAT_MS" ]]; then if (( BLOAT_MS > 200 )); then ap 2 "lags when line is busy"; elif (( BLOAT_MS > 80 )); then ap 1 "lags when line is busy"; fi; fi
  ap_end

  ap_start
  if   (( loss >= 10 )); then ap 3 "lost data"; elif (( loss >= 3 )); then ap 2 "lost data"; elif (( loss >= 2 )); then ap 1 "some lost data"; fi
  (( lat > 400 )) && ap 1 "very slow replies"
  (( WIFI_WEAK )) && ap 1 "weak Wi-Fi"
  if (( SPEED_RAN && DL_I >= 0 )); then
    if   (( DL_I < 3 ));  then ap 4 "slow download speed"
    elif (( DL_I < 8 ));  then ap 3 "modest download speed"
    elif (( DL_I < 15 )); then ap 2 "HD may buffer"
    elif (( DL_I < 25 )); then ap 1 "4K may buffer"; fi
  elif (( AP_WORST == 0 )); then AP_NOTE="speed not measured (use --speed)"; fi
  ap_end

  ap_start
  if   (( lat > 150 )); then ap 3 "high delay"; elif (( lat > 80 )); then ap 2 "high delay"; elif (( lat > 40 )); then ap 1 "some delay"; fi
  if   (( jit > 30 )); then ap 3 "unsteady connection"; elif (( jit > 20 )); then ap 2 "unsteady connection"; elif (( jit > 8 )); then ap 1 "slightly unsteady"; fi
  if   (( loss >= 5 )); then ap 3 "lost data"; elif (( loss >= 2 )); then ap 2 "lost data"; elif (( loss >= 1 )); then ap 1 "a little lost data"; fi
  (( WIFI_WEAK )) && ap 1 "weak Wi-Fi"
  if [[ -n "$BLOAT_MS" ]] && (( BLOAT_MS > 100 )); then ap 1 "lags when line is busy"; fi
  ap_end
}

make_tips() {
  local tls_rc=0
  [[ "$FIRST_RC" =~ ^(35|51|58|59|60|77|83)$ ]] && tls_rc=1
  if (( ! HAS_IF )); then
    add_tip "No network adapter was found. On a virtual machine, check the VM's network settings."
  elif (( LINK_DOWN )); then
    if [[ "$LAN_TYPE" == wifi ]]; then add_tip "Turn Wi-Fi on from the network icon in the bottom-right panel, then choose your network."
    else add_tip "Check that the network cable is firmly plugged in at both ends."; fi
  elif (( ! HAS_IP )); then
    add_tip "You are linked to the network but got no address. Disconnect and reconnect from the network icon, or restart your router."
  fi
  (( PORTAL )) && add_tip "Open your web browser: hotel, cafe and train Wi-Fi usually shows a sign-in page first."
  (( WIFI_WEAK )) && add_tip "Move closer to the router or away from thick walls. The 5 GHz network is faster; 2.4 GHz reaches further."
  if [[ "${N_STATE[3]}" == FAIL || "${N_STATE[3]}" == WARN ]]; then
    add_tip "Restart your router: unplug it for 30 seconds, then plug it back in and wait two minutes."
  elif [[ "$INTERNET" == FAIL ]] && (( ! PORTAL )) && (( ! LINK_DOWN )) && (( HAS_IP )); then
    if (( tls_rc )); then add_tip "Secure connections failed. Check that your computer's date and time are correct, or look for a sign-in page."
    else add_tip "Your router is fine but the internet is not getting through. Restart the router and modem; if it stays down, call your provider."; fi
  fi
  if [[ "${N_STATE[5]}" == FAIL || "${N_STATE[5]}" == WARN ]] && [[ "$INTERNET" == OK ]]; then
    add_tip "Websites are not being found by name. Restart your router; if it persists, your provider's name servers may be having trouble."
  fi
  if [[ -n "$LAT_SRC" ]] && (( LOSS_I >= 3 || LAT_I > 150 || JIT_I > 30 )); then
    add_tip "The connection is unsteady. Pause big downloads or streams on other devices. A network cable is steadier than Wi-Fi."
  fi
  if (( ERR_NEW > 0 )) && [[ "$LAN_TYPE" == wifi ]]; then
    add_tip "The Wi-Fi adapter is reporting new errors. Try another channel or band on your router, or move closer to it."
  fi
  if (( SPEED_RAN && DL_I >= 0 && DL_I < 10 )); then
    add_tip "Speed is low for modern use. Test again next to the router; if it is still slow, contact your internet provider."
  fi
  [[ -n "$BLOAT_MS" ]] && (( BLOAT_MS > 200 )) && add_tip "Your connection slows down a lot when it is busy. Your router may offer a 'Smart Queue' (SQM) setting."
}

# ══════════════════════════════════════════════════════════════════════════════
#  SIMPLE REPORT
# ══════════════════════════════════════════════════════════════════════════════
score_bar() {
  local sc="$1" filled i out=""
  filled=$(( sc / 5 ))
  for ((i = 0; i < 20; i++)); do
    if (( i < filled )); then out+="${GRAD[i / 4]}${G_ON}"; else out+="${GRAY}${G_OFF}"; fi
  done
  printf '%s%s' "$out" "$RESET"
}

stars() {
  local n="$1" col
  if (( n >= 4 )); then col="$GREEN"; elif (( n == 3 )); then col="$YELLOW"; else col="$RED"; fi
  printf '%s%s%s%s%s' "$col" "$(rep "$G_STAR" "$n")" "$GRAY" "$(rep "$G_STAR0" "$(( 5 - n ))")" "$RESET"
}

render_journey() {
  local cw=$(( (W - 4) / 5 )) half i st col
  local l1="" l2="" l3="" left right
  local -a SC=() SG=() MK=()
  half=$(( cw / 2 ))
  for i in 1 2 3 4 5; do
    st="${N_STATE[i]}"; SC[i]="$(state_color "$st")"
    case "$st" in OK|WARN) SG[i]="$G_HB"; MK[i]="$G_DOT" ;; FAIL) SG[i]="$G_HX"; MK[i]="$G_DOT" ;; *) SG[i]="$G_HX"; MK[i]="$G_RING" ;; esac
  done
  for i in 1 2 3 4 5; do
    l1+="$BOLD$WHITE$(ctr "${N_LABEL[i]}" "$cw")$RESET"
    if (( i == 1 )); then left="$(rep ' ' "$half")"; else left="${SC[i]}$(rep "${SG[i]}" "$half")$RESET"; fi
    if (( i == 5 )); then right="$(rep ' ' "$(( cw - half - 1 ))")"; else right="${SC[i+1]}$(rep "${SG[i+1]}" "$(( cw - half - 1 ))")$RESET"; fi
    l2+="${left}${SC[i]}${BOLD}${MK[i]}${RESET}${right}"
    l3+="${SC[i]}$(ctr "${N_WORD[i]}" "$cw")$RESET"
  done
  printf '  %s\n  %s\n  %s\n' "$l1" "$l2" "$l3"
}

render_basic() {
  local i sw
  section "THE JOURNEY OF YOUR DATA"
  note "Every web page travels along this path. The first red spot shows where it breaks."
  printf '\n'
  render_journey

  section "RIGHT NOW"
  if [[ -n "$LAT_SRC" ]]; then
    if [[ "$LAT_SRC" == ping ]]; then
      printf '  %-17s %s%-9s%s %s%s%s %s(one bar per test; taller = slower)%s\n' "Reply speed" "$BOLD" "$(fmt_ms "$LAT_MS")" "$RESET" "$CYAN" "$PUB_SPARK" "$RESET" "$DIM" "$RESET"
      printf '  %-17s %s%-9s%s %s\n' "Lost data" "$BOLD" "${LOSS_I}%" "$RESET" "$( (( LOSS_I == 0 )) && echo "${GREEN}none${RESET}" || echo "${YELLOW}some replies never arrived${RESET}")"
    else
      printf '  %-17s %s%-9s%s %s(estimated; this network ignores ping)%s\n' "Reply speed" "$BOLD" "$(fmt_ms "$LAT_MS")" "$RESET" "$DIM" "$RESET"
    fi
  fi
  if (( HAS_TRAFFIC )); then
    printf '  %-17s %s%s %-11s%s %s%s%s\n' "Downloading" "$GREEN" "$G_DOWN" "$(fmt_rate "$RX_AVG")" "$RESET" "$GREEN" "$RX_SPARK" "$RESET"
    printf '  %-17s %s%s %-11s%s %s%s%s\n' "Uploading" "$BLUE" "$G_UP" "$(fmt_rate "$TX_AVG")" "$RESET" "$BLUE" "$TX_SPARK" "$RESET"
  fi
  if (( SPEED_RAN )); then
    printf '  %-17s %s%s %-11s%s %s%s %-11s%s %s(speed test)%s\n' "Measured speed" "$GREEN" "$G_DOWN" "${DL_MBPS:-n/a} Mbps" "$RESET" "$BLUE" "$G_UP" "${UL_MBPS:-n/a} Mbps" "$RESET" "$DIM" "$RESET"
  fi
  if [[ "$LAN_TYPE" == wifi && -n "$WIFI_SSID" ]]; then
    printf '  %-17s %s%s%s%s\n' "Wi-Fi network" "$BOLD" "$WIFI_SSID" "$RESET" "${WIFI_BAND:+  $GRAY($WIFI_BAND)$RESET}"
  elif [[ "$LAN_TYPE" == wired ]]; then
    printf '  %-17s %sCable%s %s(%s)%s\n' "Connected by" "$BOLD" "$RESET" "$GRAY" "$LAN_IF" "$RESET"
  fi
  [[ -n "$VPN_IF" ]] && printf '  %-17s %sVPN is active%s %s(%s)%s\n' "Privacy" "$BOLD" "$RESET" "$GRAY" "$VPN_IF" "$RESET"

  section "WHAT YOU CAN DO RIGHT NOW"
  local words=("Not working" "Struggling" "Poor" "OK" "Good" "Great")
  for i in 0 1 2 3; do
    printf '  %-19s %s  %-12s %s%s%s\n' "${ACT_NAMES[i]}" "$(stars "${ACT_STARS[i]}")" "${words[ACT_STARS[i]]}" "$DIM" "${ACT_NOTE[i]}" "$RESET"
  done

  section "OVERALL NETWORK HEALTH"
  printf '  %s%s%s\n' "$GCOL" "$G_V" "$RESET"
  printf '  %s%s%s  %s%s%-9s%s %s%s%s\n' "$GCOL" "$G_V" "$RESET" "$GCOL$BOLD" "" "$FACE" "$RESET" "$BOLD" "$VERDICT" "$RESET"
  printf '  %s%s%s\n' "$GCOL" "$G_V" "$RESET"
  printf '  %s%s%s  %s  %s%3d%s/100  %s%s%s\n' "$GCOL" "$G_V" "$RESET" "$(score_bar "$SCORE")" "$BOLD" "$SCORE" "$RESET" "$GCOL$BOLD" "$GRADE" "$RESET"
  printf '  %s%s%s  %s%s%s\n' "$GCOL" "$G_V" "$RESET" "$DIM" "$DIAG" "$RESET"
  printf '  %s%s%s\n' "$GCOL" "$G_V" "$RESET"
  note "A quick local check-up, not an official speed rating."

  if (( ${#TIPS[@]} > 0 )); then
    section "WHAT TO TRY"
    i=1
    for sw in "${TIPS[@]}"; do
      local first=1 ln
      while IFS= read -r ln; do
        ln="${ln%"${ln##*[![:space:]]}"}"
        if (( first )); then printf '  %s%d.%s %s\n' "$BOLD$CYAN" "$i" "$RESET" "$ln"; first=0
        else printf '     %s\n' "$ln"; fi
      done < <(fold -s -w "$(( W - 8 ))" <<<"$sw")
      i=$(( i + 1 ))
    done
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  JSON REPORT
# ══════════════════════════════════════════════════════════════════════════════
json_str() {
  local s="${1:-}"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\n'/ }"; s="${s//$'\t'/ }"; s="${s//$'\r'/ }"
  printf '"%s"' "$s"
}
json_num()  { if num "${1:-}"; then printf '%s' "$1"; else printf 'null'; fi; }
json_bool() { if (( ${1:-0} )); then printf 'true'; else printf 'false'; fi; }
json_or_null() { if [[ -n "${1:-}" ]]; then json_str "$1"; else printf 'null'; fi; }

render_json() {
  local i sep="" e
  local keys=(you link router internet websites)
  printf '{\n'
  printf '  "version": %s,\n' "$(json_str "$VERSION")"
  printf '  "timestamp": %s,\n' "$(json_str "$(date -Is 2>/dev/null)")"
  printf '  "score": %d,\n' "$SCORE"
  printf '  "grade": %s,\n' "$(json_str "$GRADE")"
  printf '  "diagnosis": %s,\n' "$(json_str "$DIAG")"
  printf '  "interface": {"name": %s, "type": %s, "ipv4": %s, "ipv6": %s, "gateway": %s, "vpn": %s},\n' \
    "$(json_or_null "$LAN_IF")" "$(json_or_null "$LAN_TYPE")" "$(json_or_null "$ADDR4")" "$(json_or_null "$ADDR6")" \
    "$(json_or_null "$GATEWAY")" "$(json_or_null "$VPN_IF")"
  printf '  "wifi": {"ssid": %s, "bssid": %s, "band": %s, "channel": %s, "signal_dbm": %s, "signal_estimated": %s, "link_rate": %s, "quality_pct": %s},\n' \
    "$(json_or_null "$WIFI_SSID")" "$(json_or_null "$WIFI_BSSID")" "$(json_or_null "$WIFI_BAND")" "$(json_num "$WIFI_CHAN")" \
    "$(json_num "$WIFI_SIGNAL")" "$(json_bool "$WIFI_SIG_EST")" "$(json_or_null "${WIFI_TX:-$WIFI_RATE_ALT}")" "$(json_num "$WIFI_QUAL")"
  printf '  "journey": {'
  for i in 1 2 3 4 5; do
    printf '%s"%s": %s' "$sep" "${keys[i-1]}" "$(json_str "${N_STATE[i]}")"; sep=", "
  done
  printf '},\n'
  printf '  "latency": {"avg_ms": %s, "jitter_ms": %s, "loss_pct": %s, "source": %s},\n' \
    "$(json_num "$LAT_MS")" "$(json_num "$JIT_MS")" "$(json_num "$LOSS_PCT")" "$(json_or_null "$LAT_SRC")"
  printf '  "dns": {"ok": %d, "total": %d, "avg_ms": %d},\n' "$DNS_OKN" "$DNS_TOTAL" "$DNS_AVG"
  printf '  "https": {"ok": %s, "status": %s, "total_ms": %s},\n' \
    "$(json_bool "$([[ "$INTERNET" == OK ]] && echo 1 || echo 0)")" "$(json_num "$H_CODE")" "$(json_num "$H_TOTAL")"
  printf '  "ipv6": %s,\n' "$(json_bool "$IPV6_OK")"
  printf '  "captive_portal": %s,\n' "$(json_bool "$PORTAL")"
  printf '  "adapter_errors": {"error_rate_pct": %s, "drop_rate_pct": %s, "errors_total": %d, "drops_total": %d, "new_errors_during_scan": %d},\n' \
    "$ERR_PCT" "$DROP_PCT" "$ERR_TOTAL" "$DROP_TOTAL" "$ERR_NEW"
  printf '  "speed": {"measured": %s, "download_mbps": %s, "upload_mbps": %s, "bufferbloat_ms": %s},\n' \
    "$(json_bool "$SPEED_RAN")" "$(json_num "$DL_MBPS")" "$(json_num "$UL_MBPS")" "$(json_num "$BLOAT_MS")"
  printf '  "activities": ['
  sep=""
  for i in 0 1 2 3; do
    printf '%s{"name": %s, "stars": %d, "note": %s}' "$sep" "$(json_str "${ACT_NAMES[i]}")" "${ACT_STARS[i]}" "$(json_str "${ACT_NOTE[i]}")"; sep=", "
  done
  printf '],\n'
  printf '  "penalties": ['
  sep=""
  for e in "${PEN[@]:-}"; do
    [[ -n "$e" ]] || continue
    printf '%s{"points": %d, "reason": %s}' "$sep" "${e%%|*}" "$(json_str "${e#*|}")"; sep=", "
  done
  printf ']\n}\n'
}

# ══════════════════════════════════════════════════════════════════════════════
#  ADVANCED REPORT
# ══════════════════════════════════════════════════════════════════════════════
mark_state() {
  local c m
  c="$(state_color "$1")"
  case "$1" in OK) m="$G_OK" ;; WARN) m="$G_WARN" ;; FAIL) m="$G_FAIL" ;; *) m="$G_INFO" ;; esac
  printf '%s[%s %s]%s' "$c" "$m" "$1" "$RESET"
}
show_check() {
  local state="$1" label="$2" detail="$3"
  printf '  %s %-26s %s\n' "$(mark_state "$state")" "$label" "$detail"
}
ping_row() {
  local k="$2" l="$1"
  if (( ${PG[$k.n]:-0} > 0 )) || [[ -n "${PG[$k.sent]:-}" ]]; then
    local loss="${PG[$k.loss]}" lc="$GREEN"
    (( loss >= 10 )) && lc="$RED"; (( loss > 0 && loss < 10 )) && lc="$YELLOW"
    printf '  %-22s %4s %4s %s%5s%%%s %8s %8s %8s %8s\n' "$l" "${PG[$k.sent]}" "${PG[$k.recv]}" "$lc" "$loss" "$RESET" \
      "$(num "${PG[$k.min]}" && echo "${PG[$k.min]} ms" || echo -)" "$(num "${PG[$k.avg]}" && echo "${PG[$k.avg]} ms" || echo -)" \
      "$(num "${PG[$k.max]}" && echo "${PG[$k.max]} ms" || echo -)" "$(num "${PG[$k.jit]}" && echo "${PG[$k.jit]} ms" || echo -)"
    printf '  %s%-22s%s %s%s%s\n' "$GRAY" "" "$RESET" "$CYAN" "${PG[$k.spark]}" "$RESET"
  else
    printf '  %-22s %s%s%s\n' "$l" "$GRAY" "no reply / not tested (ICMP may be blocked)" "$RESET"
  fi
}

adv_system() {
  local distro kernel t
  distro="$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-}")"
  kernel="$(uname -r 2>/dev/null)"
  sub "System"
  kv "Host" "${HOSTNAME:-$(uname -n 2>/dev/null)}"
  kv "OS / kernel" "${distro:-unknown} / ${kernel:-unknown}"
  kv "Report time" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
  kv "Tools found" "$(for t in ip ping curl iw iwconfig nmcli ethtool resolvectl dig tracepath traceroute ss; do have "$t" && printf '%s ' "$t"; done)"
}
adv_checklist() {
  sub "Check results"
  local st word
  if (( HAS_IF )); then show_check OK "Network adapter" "$LAN_IF ($LAN_TYPE), state: ${OPERSTATE:-?}"; else show_check FAIL "Network adapter" "none found"; fi
  if (( HAS_IP )); then show_check OK "Device address" "${ADDR4:--}${ADDR6:+  |  $ADDR6}"; else show_check FAIL "Device address" "no global IPv4/IPv6 address"; fi
  if (( HAS_ROUTE )); then show_check OK "Default route" "$ROUTE_FAMILY via ${GATEWAY:-direct} dev $IFACE"; else show_check FAIL "Default route" "none"; fi
  st="${N_STATE[3]}"; word="${N_WORD[3]}"
  if (( ${PG[gw.n]:-0} > 0 )); then show_check "$st" "Router (gateway)" "$word - ${PG[gw.recv]}/${PG[gw.sent]} replies, avg ${PG[gw.avg]} ms"
  else show_check "$st" "Router (gateway)" "$word$( (( GW_INFERRED )) && echo ' - ping blocked, but traffic passes')"; fi
  if (( DNS_TOTAL > 0 )); then show_check "${N_STATE[5]}" "DNS lookups" "$DNS_OKN/$DNS_TOTAL succeeded, avg ${DNS_AVG} ms, slowest ${DNS_MAX} ms"; else show_check INFO "DNS lookups" "not tested"; fi
  case "$INTERNET" in
    OK) show_check OK "Internet (HTTPS)" "HTTP $H_CODE in ${H_TOTAL} ms${INET_VIA:+ (reached via $INET_VIA)}" ;;
    PARTIAL) show_check WARN "Internet (HTTPS)" "web test failed (curl exit ${FIRST_RC:-?}) but pings work" ;;
    FAIL) show_check FAIL "Internet (HTTPS)" "unreachable (curl exit ${FIRST_RC:-?})" ;;
    *) show_check INFO "Internet (HTTPS)" "not tested" ;;
  esac
  if [[ -n "$LAT_SRC" ]]; then
    show_check INFO "Latency / jitter / loss" "${LAT_MS} ms avg, ${JIT_MS:-n/a} ms jitter, ${LOSS_PCT:-n/a}% loss (via $LAT_SRC${PUB_TARGET:+ to $PUB_TARGET})"
  fi
  if (( HAS_IF )); then
    if   (( ERR_NEW > 0 ));   then show_check WARN "Adapter errors" "+${ERR_NEW} new errors during this scan (${ERR_TOTAL} since boot)"
    elif (( ERR_TOTAL > 0 )); then show_check INFO "Adapter errors" "${ERR_TOTAL} since boot (${ERR_PCT}% of packets), none new during this scan"
    else show_check OK "Adapter errors" "none"; fi
  fi
  case "$PORTAL_CODE" in
    204) show_check OK "Sign-in page check" "none (HTTP 204)" ;;
    ""|000) show_check INFO "Sign-in page check" "inconclusive" ;;
    *) if (( PORTAL )); then show_check WARN "Sign-in page check" "HTTP $PORTAL_CODE - likely a captive portal"; else show_check INFO "Sign-in page check" "HTTP $PORTAL_CODE (ignored: web test succeeded)"; fi ;;
  esac
  if (( IPV6_OK )); then show_check OK "IPv6" "works end-to-end (${IPV6_ADDR:-address hidden})"; else show_check INFO "IPv6" "not available on this network (common, not a fault)"; fi
}
adv_interfaces() {
  sub "All network interfaces"
  printf '  %s%-11s %-7s %-18s %-5s %9s %9s %5s %5s%s\n' "$GRAY" "NAME" "STATE" "IPV4" "MTU" "RX" "TX" "ERR" "DROP" "$RESET"
  local d i st ip4 mtu rx tx e dr mk
  for d in "$NETSYS"/*; do
    i="${d##*/}"; [[ -e "$d" ]] || continue
    st="$(rd "$d/operstate")"; mtu="$(rd "$d/mtu")"
    ip4="$(first_cidr "$i" any)"
    rx="$(rd "$d/statistics/rx_bytes")"; tx="$(rd "$d/statistics/tx_bytes")"
    e=$(( $(rd "$d/statistics/rx_errors" | grep -E '^[0-9]+$' || echo 0) + $(rd "$d/statistics/tx_errors" | grep -E '^[0-9]+$' || echo 0) ))
    dr=$(( $(rd "$d/statistics/rx_dropped" | grep -E '^[0-9]+$' || echo 0) + $(rd "$d/statistics/tx_dropped" | grep -E '^[0-9]+$' || echo 0) ))
    mk=" "; [[ "$i" == "$IFACE" ]] && mk="$G_ARROW"
    printf '  %s%-11s %-7s %-18s %-5s %9s %9s %5s %5s\n' "$mk" "${i:0:10}" "${st:-?}" "${ip4:--}" "${mtu:--}" "$(fmt_iec "${rx:-0}")" "$(fmt_iec "${tx:-0}")" "$e" "$dr"
  done
  note "$G_ARROW marks the interface that carries your default route. Counters are totals since boot."
}
adv_link() {
  [[ -n "$LAN_IF" ]] || return 0
  local c k=0 v col sp dup drv flags
  sub "Active adapter: $LAN_IF"
  drv="$(basename "$(readlink -f "$NETSYS/$LAN_IF/device/driver" 2>/dev/null)" 2>/dev/null)"
  [[ "$drv" == "." || "$drv" == "/" ]] && drv=""
  kv "Type / driver" "$LAN_TYPE${drv:+ / $drv}"
  kv "MAC address" "$(rd "$NETSYS/$LAN_IF/address")"
  kv "MTU" "$(rd "$NETSYS/$LAN_IF/mtu")"
  flags="$(ip -o link show dev "$LAN_IF" 2>/dev/null | grep -oE '<[^>]*>' | head -n1)"
  kv "Flags / state" "${flags:-?} / ${OPERSTATE:-?}"
  if [[ "$LAN_TYPE" == wired ]]; then
    sp="$(rd "$NETSYS/$LAN_IF/speed")"; dup="$(rd "$NETSYS/$LAN_IF/duplex")"
    if have ethtool; then
      local et; et="$(ethtool "$LAN_IF" 2>/dev/null)"
      [[ -n "$et" ]] && { sp="$(awk '/Speed:/ { print $2 }' <<<"$et")"; dup="$(awk '/Duplex:/ { print $2 }' <<<"$et")"; kv "Auto-negotiation" "$(awk '/Auto-negotiation:/ { print $2 }' <<<"$et")"; }
    fi
    if [[ "$sp" =~ ^[0-9]+$ ]] && (( sp > 0 )); then sp="${sp} Mb/s"; else sp=""; fi
    [[ "$dup" == "-1" ]] && dup=""
    kv "Link speed / duplex" "${sp:-unknown} / ${dup:-unknown}"
    kv "Cable (carrier)" "$([[ "$CARRIER" == 1 ]] && echo 'link detected' || echo 'no link')"
  fi
  [[ -n "$VPN_IF" ]] && kv "VPN interface" "$VPN_IF ($(rd "$NETSYS/$VPN_IF/operstate"))"
  printf '\n'
  ip -brief address show dev "$LAN_IF" 2>/dev/null | sed 's/^/  /'

  sub "Counters for $LAN_IF (since boot)"
  kv "Data received" "$(fmt_iec "$(rd "$NETSYS/$LAN_IF/statistics/rx_bytes")")"
  kv "Data sent" "$(fmt_iec "$(rd "$NETSYS/$LAN_IF/statistics/tx_bytes")")"
  for c in rx_packets tx_packets rx_errors tx_errors rx_dropped tx_dropped rx_crc_errors rx_missed_errors tx_carrier_errors collisions; do
    v="$(rd "$NETSYS/$LAN_IF/statistics/$c")"; v="${v:-0}"; col=""
    case "$c" in *errors|*dropped|collisions) [[ "$v" != 0 ]] && col="$YELLOW" ;; esac
    printf '  %s%-20s%s %s%-12s%s' "$GRAY" "$c" "$RESET" "$col" "$v" "$RESET"
    (( ++k % 2 == 0 )) && printf '\n'
  done
  (( k % 2 )) && printf '\n'
  kv "Error rate" "${ERR_PCT}% of packets  (${ERR_TOTAL} errors, CRC included)"
  kv "Drop rate" "${DROP_PCT}% of packets  (${DROP_TOTAL} dropped)"
  kv "During this scan" "+${ERR_NEW} errors, +${DROP_NEW} drops"
  if (( ERR_TOTAL > 0 && ERR_NEW == 0 )); then
    note "The errors above are historical: none appeared while NetScope was running."
  elif (( ERR_NEW > 0 )); then
    note "New errors are appearing right now. On Wi-Fi this usually means interference or a weak signal."
  fi
}
adv_wifi() {
  [[ "$LAN_TYPE" == wifi ]] || return 0
  sub "Wi-Fi link"
  if (( ! WIFI_CONNECTED )); then note "Not associated with a network."; return 0; fi
  local q="" estimated=0
  if [[ "$WIFI_SIGNAL" =~ ^-?[0-9]+$ ]]; then
    q=$(( 2 * (WIFI_SIGNAL + 100) )); (( q > 100 )) && q=100; (( q < 0 )) && q=0
  fi
  kv "Network (SSID)" "${WIFI_SSID:-hidden / unknown}"
  kv "Access point (BSSID)" "${WIFI_BSSID:-unknown}"
  kv "Band / channel" "${WIFI_BAND:-?} / ch ${WIFI_CHAN:-?}${WIFI_FREQ:+ ($WIFI_FREQ MHz)}"
  if (( WIFI_SIG_EST )); then
    kv "Signal" "~${WIFI_SIGNAL} dBm  (estimated from the ${WIFI_QUAL}% quality NetworkManager reports)"; estimated=1
  elif [[ -n "$WIFI_SIGNAL" ]]; then
    kv "Signal" "${WIFI_SIGNAL} dBm${q:+  (~ $q% quality)}${WIFI_SIGAVG:+  avg $WIFI_SIGAVG dBm}"
  else
    kv "Signal" "n/a  (the driver does not report it)"
  fi
  if [[ -n "$WIFI_TX$WIFI_RX" ]]; then
    kv "Link rate (tx / rx)" "${WIFI_TX:-n/a}  /  ${WIFI_RX:-n/a}"
  elif [[ -n "$WIFI_RATE_ALT" ]]; then
    kv "Link rate" "$WIFI_RATE_ALT  (from NetworkManager / iwconfig)"; estimated=1
  else
    kv "Link rate (tx / rx)" "n/a  (the driver does not report it)"
  fi
  [[ -n "$WIFI_EXPECTED" ]] && kv "Expected throughput" "$WIFI_EXPECTED"
  if [[ "$WIFI_TXPKTS" =~ ^[0-9]+$ && "$WIFI_RETRIES" =~ ^[0-9]+$ ]] && (( WIFI_TXPKTS > 0 )); then
    kv "Transmit retries" "$WIFI_RETRIES of $WIFI_TXPKTS packets ($(awk -v r="$WIFI_RETRIES" -v t="$WIFI_TXPKTS" 'BEGIN { printf "%.1f", r * 100 / t }')%)${WIFI_FAILED:+, $WIFI_FAILED failed}"
  fi
  [[ -n "$WIFI_PSAVE" ]] && kv "Power saving" "$WIFI_PSAVE"
  [[ -n "$WIFI_SEC" ]] && kv "Security" "$WIFI_SEC"
  [[ -n "$WIFI_CROWD" ]] && kv "Neighbours on channel" "$WIFI_CROWD other network(s) seen on this channel (cached scan)"
  (( estimated )) && note "Some drivers (for example Broadcom 'wl') expose limited data to Linux tools, so values marked ~ are estimates."
}
adv_routing() {
  sub "Routing & neighbours"
  ip route show 2>/dev/null | sed 's/^/  /'
  ip -6 route show 2>/dev/null | head -n 8 | sed 's/^/  /'
  if [[ -n "$GATEWAY" ]]; then
    printf '\n'
    kv "Gateway" "$GATEWAY"
    kv "Gateway MAC" "$(ip neigh show "$GATEWAY" dev "$IFACE" 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i == "lladdr") { print $(i + 1); exit } }')"
  fi
  local nb; nb="$(ip neigh show 2>/dev/null | awk '{ c[$NF]++ } END { for (s in c) printf "%s=%d  ", s, c[s] }')"
  [[ -n "$nb" ]] && kv "Neighbour cache" "$nb"
  note "The neighbour cache only lists devices this computer talked to recently; it is not a network scan."
}
adv_dns() {
  sub "DNS"
  local servers; servers="$(get_dns_servers | tr '\n' ' ')"
  kv "Servers in use" "${servers:-unknown (local stub resolver)}"
  if have resolvectl; then
    resolvectl status "$LAN_IF" 2>/dev/null | awk -F': ' '/Current DNS Server|DNS Domain|Protocols|DNS Servers/ { gsub(/^[ \t]+/, "", $0); print "  " $0 }' | head -n 6
  fi
  if [[ -s "$TMP/dns.txt" ]]; then
    printf '\n  %s%-24s %-8s %s%s\n' "$GRAY" "System resolver lookups" "result" "time" "$RESET"
    local dom rc ms
    while read -r dom rc ms; do
      printf '  %-24s %-8s %s ms\n' "$dom" "$([[ "$rc" == 0 ]] && echo "${GREEN}ok${RESET}" || echo "${RED}failed${RESET}")" "$ms"
    done < "$TMP/dns.txt"
    note "Repeat lookups may be answered from a local cache, which makes them look faster."
  fi
  if [[ -s "$TMP/dns_direct.txt" ]]; then
    printf '\n  %s%-24s %-8s %s%s\n' "$GRAY" "Direct resolver test" "result" "time" "$RESET"
    local srv
    while read -r srv rc ms; do
      printf '  %-24s %-8s %s ms\n' "$srv" "$([[ "$rc" == 0 ]] && echo "${GREEN}ok${RESET}" || echo "${RED}failed${RESET}")" "$ms"
    done < "$TMP/dns_direct.txt"
    have dig && note "Times are dig's own query time (a cold first query can be a little slower)."
  elif ! have dig && ! have host; then
    note "Install 'bind9-dnsutils' (dig) to compare your DNS against public resolvers."
  fi
}
adv_latency() {
  sub "Latency, jitter and packet loss  (${PING_COUNT} pings each)"
  printf '  %s%-22s %4s %4s %6s %8s %8s %8s %8s%s\n' "$GRAY" "TARGET" "SENT" "RECV" "LOSS" "MIN" "AVG" "MAX" "JITTER" "$RESET"
  ping_row "Router ${GATEWAY:-}" gw
  ping_row "Cloudflare 1.1.1.1" pub1
  ping_row "Google 8.8.8.8" pub2
  note "Each bar is one ping (taller = slower, $G_LOST = no reply). Jitter = average change between consecutive pings."
  if (( ${PG[load.n]:-0} > 0 )); then
    ping_row "1.1.1.1 under load" load
  fi
}
adv_web() {
  sub "Web / TLS timing and public address"
  if [[ "$INTERNET" == OK && -n "$H_CODE" ]]; then
    kv "Request" "$TRACE_URL${INET_VIA:+  (via IP fallback)}"
    kv "Result" "HTTP $H_CODE, ${H_VER:+HTTP/$H_VER, }server $H_IP"
    kv "DNS lookup" "${H_DNS} ms"
    kv "TCP connect (cumulative)" "${H_CONN} ms"
    kv "TLS handshake (cumul.)" "${H_TLS} ms"
    kv "First byte (cumulative)" "${H_TTFB} ms"
    kv "Total" "${H_TOTAL} ms"
    local pip loc colo tls
    pip="$(trace_field "$H_FROM" ip)"; loc="$(trace_field "$H_FROM" loc)"; colo="$(trace_field "$H_FROM" colo)"; tls="$(trace_field "$H_FROM" tls)"
    [[ -n "$pip" ]]  && kv "Your public IP" "$pip${loc:+  (country: $loc)}"
    [[ -n "$tls$colo" ]] && kv "Negotiated TLS / edge" "${tls:-?}${colo:+  via Cloudflare $colo}"
  else
    kv "Web test" "failed (curl exit ${FIRST_RC:-?})"
    [[ -s "$TMP/http.err" ]] && printf '  %s%s%s\n' "$DIM" "$(head -n1 "$TMP/http.err")" "$RESET"
  fi
  kv "IPv6" "$(( IPV6_OK )) = $( (( IPV6_OK )) && echo "reachable (${IPV6_ADDR:-?})" || echo 'not reachable')"
  [[ -n "${http_proxy:-}${https_proxy:-}${HTTP_PROXY:-}${HTTPS_PROXY:-}" ]] && kv "Proxy variables" "${https_proxy:-${HTTPS_PROXY:-${http_proxy:-${HTTP_PROXY:-}}}}"
}
adv_path() {
  [[ -s "$TMP/trace.txt" ]] || return 0
  sub "Route to 1.1.1.1  ($(cat "$TMP/trace.tool" 2>/dev/null))"
  awk '!seen[$1]++' "$TMP/trace.txt" | head -n 16 | sed 's/^/  /'
  note "'no reply' hops are common: many routers hide themselves. Only the last hops matter for reachability."
}
adv_transport() {
  [[ -r "$PROCNET/snmp" ]] || return 0
  sub "TCP / UDP / IP statistics (system-wide, since boot)"
  local out rt
  out="$(snmp_get Tcp OutSegs)"; rt="$(snmp_get Tcp RetransSegs)"
  kv "TCP segments sent / in" "${out:-?}  /  $(snmp_get Tcp InSegs)"
  kv "TCP retransmits" "${rt:-?}$([[ "$out" =~ ^[0-9]+$ && "$rt" =~ ^[0-9]+$ ]] && (( out > 0 )) && awk -v r="$rt" -v o="$out" 'BEGIN { printf "  (%.2f%% of sent)", r * 100 / o }')"
  kv "TCP connections" "now $(snmp_get Tcp CurrEstab) established, $(snmp_get Tcp AttemptFails) failed attempts, $(snmp_get Tcp EstabResets) resets"
  kv "UDP in / out / errors" "$(snmp_get Udp InDatagrams) / $(snmp_get Udp OutDatagrams) / $(snmp_get Udp InErrors)"
  kv "IP in / discards" "$(snmp_get Ip InReceives) / $(snmp_get Ip InDiscards) in, $(snmp_get Ip OutDiscards) out"
  if have ss; then printf '\n'; ss -s 2>/dev/null | head -n 6 | sed 's/^/  /'; fi
  note "Retransmits under ~1% are normal; consistently above 2-3% suggests a lossy path."
}
adv_manager() {
  have nmcli || return 0
  sub "NetworkManager"
  nmcli -t -f NAME,TYPE,DEVICE connection show --active 2>/dev/null | awk -F: '{ printf "  %-28s %-12s %s\n", $1, $2, $3 }'
  kv "Overall state" "$(nmcli -g STATE general status 2>/dev/null)"
  kv "Connectivity" "$(nmcli networking connectivity 2>/dev/null)"
}
adv_speed() {
  (( SPEED_RAN )) || return 0
  sub "Speed test (speed.cloudflare.com)"
  kv "Download" "${DL_MBPS:-failed} Mbps"
  kv "Upload" "${UL_MBPS:-failed} Mbps"
  if [[ -n "$BLOAT_MS" ]]; then
    kv "Latency idle to loaded" "${LAT_MS} ms to ${LOAD_AVG} ms (+${BLOAT_MS} ms)"
    kv "Bufferbloat grade" "$BLOAT_GRADE"
  fi
  note "Single-server test, short duration: a good indication, not a lab measurement."
}
adv_score() {
  sub "How the score was calculated"
  local e
  if (( ${#PEN[@]} == 0 )); then printf '  %s100 points, nothing deducted.%s\n' "$GREEN" "$RESET"
  else
    for e in "${PEN[@]}"; do printf '  %s-%-3s%s %s\n' "$YELLOW" "${e%%|*}" "$RESET" "${e#*|}"; done
    printf '  %s= %s / 100%s\n' "$BOLD" "$SCORE" "$RESET"
  fi
}
render_advanced() {
  section "ADVANCED DIAGNOSTICS"
  adv_system
  adv_checklist
  adv_interfaces
  adv_link
  adv_wifi
  adv_routing
  adv_dns
  adv_latency
  adv_web
  adv_path
  adv_transport
  adv_manager
  adv_speed
  adv_score
  sub "Notes"
  note "$G_INFO Ping failures alone do not prove a fault: routers and servers may ignore ICMP."
  note "$G_INFO Counters (bytes, errors, drops, retransmits) are cumulative since boot, not per-second."
  note "$G_INFO Traffic rates describe this computer's interface, not your provider's maximum speed."
  note "$G_INFO NetScope never scans other devices, tests open ports or changes any configuration."
}

# ══════════════════════════════════════════════════════════════════════════════
#  LIVE MONITOR
# ══════════════════════════════════════════════════════════════════════════════
spark_lat() {
  (( $# )) || return 0
  printf '%s\n' "$@" | awk -v glyphs="$SPARK_GLYPHS" -v lost="$G_LOST" '
    BEGIN { split(glyphs, G, " ") }
    { if ($1 == "x") s = s lost
      else { v = $1 + 0
        if (v <= 10) l = 1; else if (v <= 20) l = 2; else if (v <= 40) l = 3; else if (v <= 60) l = 4
        else if (v <= 100) l = 5; else if (v <= 150) l = 6; else if (v <= 250) l = 7; else l = 8
        s = s G[l] } }
    END { print s }'
}
spark_rate() {
  local scale="$1"; shift
  (( $# )) || return 0
  printf '%s\n' "$@" | awk -v glyphs="$SPARK_GLYPHS" -v sc="$scale" '
    BEGIN { split(glyphs, G, " ") }
    { l = int($1 / sc * 7 + 0.5) + 1; if (l > 8) l = 8; if (l < 1) l = 1; s = s G[l] }
    END { print s }'
}
lat_stats() {
  printf '%s\n' "$@" | awk '
    { n++; last = $1; if ($1 == "x") { lost++; next }
      v = $1 + 0; c++; sum += v; if (c == 1 || v < mn) mn = v; if (v > mx) mx = v }
    END { if (c == 0) { print "lost - - - 100"; exit }
          printf "%s %.1f %.1f %.1f %.0f\n", (last == "x") ? "lost" : last, sum / c, mn, mx, lost * 100 / n }'
}
live_lat_block() {
  local label="$1" target="$2" cur avg mn mx loss col s; shift 2
  (( $# )) || return 0
  read -r cur avg mn mx loss <<<"$(lat_stats "$@")"
  col="$GREEN"
  if [[ "$cur" == lost ]] || { num "$cur" && awk -v v="$cur" 'BEGIN { exit !(v > 150) }'; }; then col="$RED"
  elif num "$cur" && awk -v v="$cur" 'BEGIN { exit !(v > 60) }'; then col="$YELLOW"; fi
  printf '  %s%-10s%s %s%-12s%s now %s%-8s%s avg %-7s min %-7s max %-7s lost %s%%\033[K\n' \
    "$BOLD" "$label" "$RESET" "$GRAY" "$target" "$RESET" "$col$BOLD" "$(num "$cur" && fmt_ms "$cur" || echo "$cur")" "$RESET" \
    "$(fmt_ms "$avg")" "$(fmt_ms "$mn")" "$(fmt_ms "$mx")" "$loss"
  s="$(spark_lat "$@")"; s="${s//$G_LOST/${RED}${G_LOST}${col}}"
  printf '  %s%s%s\033[K\n' "$col" "$s" "$RESET"
}
live_rate_block() {
  local label="$1" arrow="$2" col="$3" pk cur; shift 3
  (( $# )) || return 0
  cur="${!#}"
  pk="$(printf '%s\n' "$@" | awk '{ if ($1 > m) m = $1 } END { printf "%d", m }')"
  (( pk < 125000 )) && pk=125000
  printf '  %s%-10s%s %s%s %-13s%s peak %s\033[K\n' "$BOLD" "$label" "$RESET" "$col$BOLD" "$arrow" "$(fmt_rate "$cur")" "$RESET" "$(fmt_rate "$pk")"
  printf '  %s%s%s\033[K\n' "$col" "$(spark_rate "$pk" "$@")" "$RESET"
}
live_mode() {
  if (( ! INTERACTIVE )); then echo "Live mode needs an interactive terminal." >&2; exit 2; fi
  have ip   || { echo "NetScope needs the 'ip' command (package: iproute2)." >&2; exit 1; }
  have ping || { echo "Live mode needs the 'ping' command." >&2; exit 1; }
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/netscope.XXXXXX")" || exit 1
  detect_network; wifi_gather
  [[ -n "$IFACE" ]] || { echo "No active network interface was found." >&2; exit 1; }

  local N=$(( W - 6 )) t0 t1 dt rx0 rx1 tx0 tx1 key v title sig
  (( N > 80 )) && N=80
  local -a NETH=() GWH=() RXH=() TXH=()
  title="$IFACE"
  [[ "$LAN_TYPE" == wifi && -n "$WIFI_SSID" ]] && title="$IFACE · Wi-Fi “$WIFI_SSID”"
  (( UTF8 )) || title="$IFACE"

  LIVE_ACTIVE=1
  printf '%s%s\033[2J' "$ALT_ON" "$HIDE_CUR"
  rx0="$(rd "$NETSYS/$IFACE/statistics/rx_bytes")"; tx0="$(rd "$NETSYS/$IFACE/statistics/tx_bytes")"; t0="$(now_ms)"
  while :; do
    LIVE_PIDS=()
    ( v="$(ping -n -c1 -W1 1.1.1.1 2>/dev/null | sed -n 's/.*time=\([0-9.]*\).*/\1/p')"; printf '%s' "${v:-x}" > "$TMP/lv_net" ) &
    LIVE_PIDS+=("$!")
    if [[ -n "$GATEWAY" ]]; then
      ( v="$(ping -n -c1 -W1 "$GATEWAY" 2>/dev/null | sed -n 's/.*time=\([0-9.]*\).*/\1/p')"; printf '%s' "${v:-x}" > "$TMP/lv_gw" ) &
      LIVE_PIDS+=("$!")
    fi
    key=""; read -rsn1 -t 1 key || true
    if [[ "$key" == q || "$key" == Q ]]; then
      wait "${LIVE_PIDS[@]}" 2>/dev/null || true
      LIVE_PIDS=()
      break
    fi
    wait "${LIVE_PIDS[@]}" 2>/dev/null || true
    LIVE_PIDS=()
    t1="$(now_ms)"; dt=$(( t1 - t0 )); (( dt < 1 )) && dt=1
    rx1="$(rd "$NETSYS/$IFACE/statistics/rx_bytes")"; tx1="$(rd "$NETSYS/$IFACE/statistics/tx_bytes")"
    v=$(( (${rx1:-0} - ${rx0:-0}) * 1000 / dt )); (( v < 0 )) && v=0; RXH+=("$v")
    v=$(( (${tx1:-0} - ${tx0:-0}) * 1000 / dt )); (( v < 0 )) && v=0; TXH+=("$v")
    rx0="$rx1"; tx0="$tx1"; t0="$t1"
    NETH+=("$(<"$TMP/lv_net")")
    [[ -n "$GATEWAY" ]] && GWH+=("$(<"$TMP/lv_gw")")
    (( ${#NETH[@]} > N )) && NETH=("${NETH[@]: -N}")
    (( ${#GWH[@]}  > N )) && GWH=("${GWH[@]: -N}")
    (( ${#RXH[@]}  > N )) && RXH=("${RXH[@]: -N}")
    (( ${#TXH[@]}  > N )) && TXH=("${TXH[@]: -N}")

    sig=""
    if [[ "$LAN_TYPE" == wifi ]] && have iw; then
      sig="$(iw dev "$LAN_IF" link 2>/dev/null | awk '/signal:/ { print $2; exit }')"
      [[ -n "$sig" ]] && sig="  $G_MID  signal ${sig} dBm"
    fi
    printf '\033[H'
    printf '  %sNETSCOPE LIVE%s  %s%s%s%s%s\033[K\n' "$BOLD$CYAN" "$RESET" "$GRAY" "$title" "$sig" "$RESET" ""
    printf '  %s%s%s  %sq = quit%s\033[K\n' "$DIM" "$(rep "$G_H" "$(( W - 14 ))")" "$RESET" "$GRAY" "$RESET"
    printf '\033[K\n'
    live_lat_block "INTERNET" "1.1.1.1" "${NETH[@]}"
    printf '\033[K\n'
    [[ -n "$GATEWAY" ]] && { live_lat_block "ROUTER" "$GATEWAY" "${GWH[@]}"; printf '\033[K\n'; }
    live_rate_block "DOWNLOAD" "$G_DOWN" "$GREEN" "${RXH[@]}"
    printf '\033[K\n'
    live_rate_block "UPLOAD" "$G_UP" "$BLUE" "${TXH[@]}"
    printf '\033[J'
  done
  LIVE_ACTIVE=0
  printf '%s%s' "$ALT_OFF" "$SHOW_CUR"
  exit 0
}

# ══════════════════════════════════════════════════════════════════════════════
#  LEARNING HELPERS
# ══════════════════════════════════════════════════════════════════════════════
wrap() {
  local ln c="${2:-}"
  while IFS= read -r ln; do
    ln="${ln%"${ln##*[![:space:]]}"}"
    printf '  %s%s%s\n' "$c" "$ln" "$RESET"
  done < <(fold -s -w "$(( W - 4 ))" <<<"$1")
}
try_cmd() { printf '  %s%s Try it:%s %s%s%s\n' "$GRAY" "$G_ARROW" "$RESET" "$CYAN" "$1" "$RESET"; }
lblock() {
  printf '\n  %s%s%s  %s[%s]%s\n' "$BOLD$WHITE" "$1" "$RESET" "$MAGENTA" "$2" "$RESET"
  wrap "$3"
}

render_learn() {
  local gwavg="${PG[gw.avg]:-}" sig lat_txt
  section "LEARN: WHAT EACH STEP MEANS"
  wrap "Networks are built in layers, and each layer depends on the one below it. That is why NetScope checks your journey in order: if an early step is broken, every step after it fails too."

  lblock "1. YOU: adapter and IP address" "layers 1-3" \
    "Your computer needs a network adapter and an IP address, its identity on the network. ${LAN_IF:-Your adapter} has ${ADDR4:-no IPv4 address}. Home routers hand these out automatically using DHCP. The number after the slash (the prefix) says how many bits belong to the network part."
  try_cmd "ip -br address"
  try_cmd "netscope --subnet"

  if [[ "$LAN_TYPE" == wifi ]]; then
    sig="not reported by the driver"
    [[ -n "$WIFI_SIGNAL" ]] && sig="${WIFI_SIGNAL} dBm"
    lblock "2. WI-FI: the radio link" "layers 1-2" \
      "Wi-Fi is a radio link between your computer and the access point. On this link, data travels in frames addressed by MAC (hardware) address, not by IP address. You are on ${WIFI_BAND:-an unknown band}, channel ${WIFI_CHAN:-?}, with a signal of ${sig}. dBm is a logarithmic scale: -70 dBm carries 100 times less power than -50 dBm."
    try_cmd "iw dev ${LAN_IF:-wlan0} link"
    try_cmd "nmcli device wifi list"
  else
    lblock "2. CABLE: the physical link" "layers 1-2" \
      "A wired link carries electrical or optical signals on a cable, grouped into Ethernet frames addressed by MAC (hardware) address. If the carrier is up, the cable and the port at both ends are working."
    try_cmd "ip -s link show ${LAN_IF:-eth0}"
    try_cmd "ethtool ${LAN_IF:-eth0}"
  fi

  lblock "3. ROUTER: the way out" "layer 3, with ARP on layer 2" \
    "Anything outside your local network is sent to the default gateway, which is your router. Your computer first finds the router's MAC address with ARP, then hands it the packet. Your gateway is ${GATEWAY:-unknown}${gwavg:+ and it answered in ${gwavg} ms}."
  try_cmd "ip route"
  try_cmd "ip neigh"
  try_cmd "netscope --walk 8.8.8.8"
  [[ -n "$GATEWAY" ]] && try_cmd "ping -c 4 $GATEWAY"

  lat_txt=""; [[ -n "$LAT_MS" ]] && lat_txt="Your reply time was ${LAT_MS} ms to ${PUB_TARGET:-the internet}."
  lblock "4. INTERNET: beyond your home" "layer 3" \
    "Ping sends ICMP echo packets. Pinging a public IP address instead of a name tests routing and your provider without involving DNS. Every router that forwards a packet lowers its TTL by one, and when the TTL reaches zero that router sends back an error. This is how tracepath maps the route. ${lat_txt}"
  try_cmd "ping -c 4 1.1.1.1"
  try_cmd "tracepath -n 1.1.1.1"
  try_cmd "netscope --mtu"

  lblock "5. WEBSITES: names, then HTTPS" "layers 4-7" \
    "People use names, computers use IP addresses, and DNS translates between them (usually over UDP port 53). Then your browser opens a TCP connection with a three-way handshake (SYN, SYN-ACK, ACK), sets up TLS encryption, and finally sends the HTTP request. Your name lookups averaged ${DNS_AVG} ms and one full HTTPS request took ${H_TOTAL:-?} ms."
  try_cmd "dig example.com"
  try_cmd "curl -v -o /dev/null https://example.com"
  try_cmd "netscope --dns example.com"
  try_cmd "netscope --tls example.com"

  lblock "Troubleshooting from the bottom up" "method" \
    "Test one step at a time. Can you ping your router? Can you ping 1.1.1.1? Can you ping example.com? The first 'no' shows where the fault is."

  lblock "Your three quality numbers" "performance" \
    "Latency is the round-trip time (${LAT_MS:-?} ms for you). Jitter is how much that time varies (${JIT_MS:-?} ms). Packet loss is the share of packets that never arrive (${LOSS_PCT:-?}%)."
  printf '\n'
  note "More to explore: --walk DEST  --osi  --subnet  --dns DOMAIN  --tls HOST  --mtu  --glossary TERM"
}

norm()  { if [[ "$1" == UNK ]]; then printf INFO; else printf '%s' "$1"; fi; }
worst() {
  local s w=OK u=0 n=0
  for s in "$@"; do
    n=$(( n + 1 ))
    case "$s" in FAIL) printf FAIL; return ;; WARN) w=WARN ;; UNK) u=$(( u + 1 )) ;; esac
  done
  (( u == n )) && w=INFO
  printf '%s' "$w"
}
osi_row() {
  local st pad
  st="$(norm "$4")"; pad=$(( 8 - (4 + ${#st}) )); (( pad < 0 )) && pad=0
  printf '  %s%s%s  %-13s %s%*s  %s\n' "$BOLD" "$1" "$RESET" "$2" "$(mark_state "$st")" "$pad" "" "$3"
}

render_osi() {
  local tls="" tcp_ms="" out rt pct inet_state i first=0 mac
  local -a LS=() LD=()
  local names=("" "Physical" "Data link" "Network" "Transport" "Session" "Presentation" "Application")
  [[ -n "$H_FROM" ]] && tls="$(trace_field "$H_FROM" tls)"
  case "$INTERNET" in OK) inet_state=OK ;; PARTIAL) inet_state=WARN ;; FAIL) inet_state=FAIL ;; *) inet_state=UNK ;; esac

  case "$LAN_TYPE" in
    wifi)
      if [[ "$WIFI_SIGNAL" =~ ^-[0-9]+$ ]]; then
        if (( WIFI_SIGNAL < -70 )); then LS[1]=WARN; else LS[1]=OK; fi
        LD[1]="Radio signal ${WIFI_SIGNAL} dBm$( (( WIFI_SIG_EST )) && echo ' (estimated)')"
      else LS[1]=INFO; LD[1]="Radio signal not reported by the driver"; fi ;;
    wired)
      if [[ "$CARRIER" == 1 ]]; then LS[1]=OK; LD[1]="Cable carrier detected"; else LS[1]=FAIL; LD[1]="No carrier on the cable"; fi ;;
    *) LS[1]=INFO; LD[1]="Physical link not measured" ;;
  esac

  mac="$(rd "$NETSYS/${LAN_IF:-none}/address")"
  LS[2]="${N_STATE[2]}"
  [[ "${LS[2]}" == OK ]] && (( ERR_NEW > 0 )) && LS[2]=WARN
  LD[2]="Link to the router, MAC ${mac:--}, +${ERR_NEW} new errors during the scan"

  LS[3]="$(worst "${N_STATE[1]}" "${N_STATE[3]}" "${N_STATE[4]}")"
  [[ -n "$LAT_MS" ]] && LD[3]="IP ${ADDR4:--}, gateway ${GATEWAY:--}, internet ping ${LAT_MS} ms" || LD[3]="IP ${ADDR4:--}, gateway ${GATEWAY:--}, internet ping n/a"

  if [[ "$H_CONN" =~ ^[0-9]+$ && "$H_DNS" =~ ^[0-9]+$ ]]; then tcp_ms=$(( H_CONN - H_DNS )); fi
  out="$(snmp_get Tcp OutSegs)"; rt="$(snmp_get Tcp RetransSegs)"; LS[4]=INFO; pct=""
  if [[ "$out" =~ ^[0-9]+$ && "$rt" =~ ^[0-9]+$ ]] && (( out > 0 )); then
    pct="$(awk -v r="$rt" -v o="$out" 'BEGIN { printf "%.2f", r * 100 / o }')"
    if awk -v p="$pct" 'BEGIN { exit !(p >= 3) }'; then LS[4]=WARN; else LS[4]=OK; fi
  fi
  LD[4]="TCP connect ${tcp_ms:-n/a} ms, retransmits ${pct:-n/a}% of segments"

  LS[5]=INFO; LD[5]="Sessions (logins, TLS resumption) are not measured"
  if [[ -n "$tls" ]]; then LS[6]=OK; LD[6]="TLS encryption negotiated: $tls"; else LS[6]=INFO; LD[6]="TLS version not measured"; fi
  LS[7]="$(worst "${N_STATE[5]}" "$inet_state")"
  LD[7]="DNS ${DNS_OKN}/${DNS_TOTAL} lookups ok, HTTPS ${H_CODE:-no response}"

  section "THE OSI MODEL APPLIED TO YOUR NETWORK"
  wrap "The OSI model splits networking into seven layers. A problem on a lower layer breaks everything above it, so always troubleshoot from layer 1 upward."
  printf '\n'
  for i in 7 6 5 4 3 2 1; do osi_row "$i" "${names[i]}" "${LD[i]}" "${LS[i]}"; done
  printf '\n'
  for i in 1 2 3 4 5 6 7; do
    if [[ "${LS[i]}" == WARN || "${LS[i]}" == FAIL ]]; then first=$i; break; fi
  done
  if (( first )); then wrap "First problem, working from the bottom: layer $first (${names[first]}). Fix it before looking at the layers above." "$YELLOW"
  else wrap "No problems found at any measured layer." "$GREEN"; fi
  note "Typical protocols: 7 HTTP, DNS, DHCP  |  6 TLS  |  4 TCP, UDP  |  3 IP, ICMP  |  2 Ethernet, Wi-Fi, ARP  |  1 radio, cable."
}

bin_ip() {
  local n=$1 i k o b out=()
  for i in 3 2 1 0; do
    o=$(( (n >> (8 * i)) & 255 )); b=""
    for k in 7 6 5 4 3 2 1 0; do b+=$(( (o >> k) & 1 )); done
    out+=("$b")
  done
  local IFS=.; printf '%s' "${out[*]}"
}
int2ip() { printf '%d.%d.%d.%d' $(( ($1 >> 24) & 255 )) $(( ($1 >> 16) & 255 )) $(( ($1 >> 8) & 255 )) $(( $1 & 255 )); }
ip2int() {
  local a b c d
  [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  a=$((10#${BASH_REMATCH[1]})); b=$((10#${BASH_REMATCH[2]})); c=$((10#${BASH_REMATCH[3]})); d=$((10#${BASH_REMATCH[4]}))
  (( a > 255 || b > 255 || c > 255 || d > 255 )) && return 1
  printf '%s' "$(( (a << 24) | (b << 16) | (c << 8) | d ))"
}
ip_kind() {
  local a=$(( $1 >> 24 )) b=$(( ($1 >> 16) & 255 ))
  if   (( a == 10 )); then echo "private (RFC 1918, 10.0.0.0/8)"
  elif (( a == 172 && b >= 16 && b <= 31 )); then echo "private (RFC 1918, 172.16.0.0/12)"
  elif (( a == 192 && b == 168 )); then echo "private (RFC 1918, 192.168.0.0/16)"
  elif (( a == 100 && b >= 64 && b <= 127 )); then echo "shared address space (carrier-grade NAT, 100.64.0.0/10)"
  elif (( a == 169 && b == 254 )); then echo "link-local (169.254.0.0/16, self-assigned)"
  elif (( a == 127 )); then echo "loopback (127.0.0.0/8)"
  elif (( a == 192 && b == 0 && (($1 >> 8) & 255) == 2 )); then echo "documentation only (TEST-NET-1, 192.0.2.0/24, never routed)"
  elif (( a == 198 && b == 51 && (($1 >> 8) & 255) == 100 )); then echo "documentation only (TEST-NET-2, 198.51.100.0/24, never routed)"
  elif (( a == 203 && b == 0 && (($1 >> 8) & 255) == 113 )); then echo "documentation only (TEST-NET-3, 203.0.113.0/24, never routed)"
  elif (( a >= 224 && a <= 239 )); then echo "multicast"
  else echo "public (routable on the internet)"; fi
}

lab_subnet() {
  local cidr="$MODE_ARG" own=0 pfx ip mask net wild bc first last hosts gwi="" t tn
  LAN_IF=""; IFACE=""; GATEWAY=""
  if [[ -z "$cidr" ]]; then
    have ip || { echo "NetScope needs the 'ip' command (package: iproute2)." >&2; exit 1; }
    detect_network
    cidr="$(first_cidr "$LAN_IF")"
    [[ -n "$cidr" ]] || { echo "No IPv4 address found. Try: netscope --subnet 192.168.1.10/24" >&2; exit 1; }
    own=1
  fi
  if [[ ! "$cidr" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$ ]]; then
    echo "Please give an address with a prefix, for example: netscope --subnet 192.168.1.10/24" >&2; exit 2
  fi
  local o1=$((10#${BASH_REMATCH[1]})) o2=$((10#${BASH_REMATCH[2]})) o3=$((10#${BASH_REMATCH[3]})) o4=$((10#${BASH_REMATCH[4]}))
  pfx=$((10#${BASH_REMATCH[5]}))
  if (( o1 > 255 || o2 > 255 || o3 > 255 || o4 > 255 )); then echo "Each number in an IPv4 address must be 0 to 255." >&2; exit 2; fi
  if (( pfx > 32 )); then echo "The prefix must be between 0 and 32." >&2; exit 2; fi

  ip=$(( (o1 << 24) | (o2 << 16) | (o3 << 8) | o4 ))
  if (( pfx == 0 )); then mask=0; else mask=$(( (0xFFFFFFFF << (32 - pfx)) & 0xFFFFFFFF )); fi
  net=$(( ip & mask )); wild=$(( ~mask & 0xFFFFFFFF )); bc=$(( net | wild ))
  if   (( pfx == 32 )); then hosts=1; first=$ip; last=$ip
  elif (( pfx == 31 )); then hosts=2; first=$net; last=$bc
  else hosts=$(( wild - 1 )); first=$(( net + 1 )); last=$(( bc - 1 )); fi

  section "SUBNET CALCULATOR: $cidr"
  (( own )) && note "Using the address of your own adapter (${LAN_IF})."
  sub "The answer"
  kv "Address" "$(int2ip "$ip")"
  kv "Prefix / netmask" "/$pfx  =  $(int2ip "$mask")"
  kv "Network address" "$(int2ip "$net")   (first address, names the whole network)"
  kv "Broadcast address" "$(int2ip "$bc")   (last address, reaches every host)"
  kv "Usable host range" "$(int2ip "$first")  to  $(int2ip "$last")"
  kv "Number of hosts" "$hosts"
  kv "Address type" "$(ip_kind "$ip")"

  sub "How it works: AND the address with the mask"
  printf '  %s%-10s%s %s\n' "$GRAY" "address" "$RESET" "$(bin_ip "$ip")"
  printf '  %s%-10s%s %s\n' "$GRAY" "netmask" "$RESET" "$(bin_ip "$mask")"
  printf '  %s%-10s%s %s%s%s\n' "$GRAY" "network" "$RESET" "$BOLD" "$(bin_ip "$net")" "$RESET"
  wrap "The prefix /$pfx means the first $pfx bits identify the network and the remaining $(( 32 - pfx )) bits identify the host. Where the mask has a 1 the bit is kept, where it has a 0 the bit is cleared. The result is the network address." "$DIM"
  wrap "Hosts = 2^$(( 32 - pfx )) minus 2, because the network address and the broadcast address cannot be given to a computer (the exceptions are /31 point-to-point links and /32 single hosts)." "$DIM"

  sub "Is it on your local network or does it go to the gateway?"
  [[ -n "$GATEWAY" ]] && gwi="$GATEWAY"
  for t in $gwi 1.1.1.1 "$(int2ip $(( net + 1 )))"; do
    [[ "$t" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || continue
    tn=$(( (BASH_REMATCH[1] << 24) | (BASH_REMATCH[2] << 16) | (BASH_REMATCH[3] << 8) | BASH_REMATCH[4] ))
    if (( (tn & mask) == net )); then printf '  %-16s %son this network%s: sent directly to the device (found with ARP)\n' "$t" "$GREEN" "$RESET"
    else printf '  %-16s %sother network%s: handed to the default gateway (router)\n' "$t" "$YELLOW" "$RESET"; fi
  done

  sub "Cheat sheet"
  printf '  %s%-8s %-16s %s%s\n' "$GRAY" "PREFIX" "NETMASK" "USABLE HOSTS" "$RESET"
  for t in 8 16 20 24 25 26 27 28 29 30; do
    printf '  /%-7s %-16s %s\n' "$t" "$(int2ip $(( (0xFFFFFFFF << (32 - t)) & 0xFFFFFFFF )))" "$(( (1 << (32 - t)) - 2 ))"
  done
  printf '\n'
  note "Try other networks:  netscope --subnet 10.0.0.1/8   netscope --subnet 172.16.5.9/20"
}

GLOSSARY=$(cat <<'EOF'
ARP|layer 2-3|Address Resolution Protocol. Finds the MAC address that belongs to an IPv4 address on your local network. See your cache with: ip neigh
BSSID|layer 2|The MAC address of one particular Wi-Fi access point. Mesh systems have several BSSIDs under one network name.
Bufferbloat|performance|Extra delay that appears when a router's queues fill up because the line is busy. Shows up as lag during big downloads.
CGNAT|layer 3|Carrier-grade NAT. Your provider shares one public IPv4 address between many customers. Addresses in 100.64.0.0/10 are a sign of it.
CIDR|layer 3|Classless Inter-Domain Routing. Writes a network as an address plus a prefix length, such as 192.168.1.0/24.
Captive portal|layer 7|A sign-in page that hotel, cafe or train Wi-Fi forces you through before getting internet access.
DHCP|layer 7|Dynamic Host Configuration Protocol. Your router lends your computer an address, gateway and DNS server for a limited time called a lease.
DNS|layer 7|Domain Name System. The internet's phone book: it turns names such as example.com into IP addresses. Usually uses UDP port 53.
Firewall|layers 3-4|Software or hardware that allows or blocks traffic using rules based on addresses, ports and connection state.
Frame|layer 2|The unit of data on a local link (Ethernet or Wi-Fi). It carries source and destination MAC addresses around an IP packet.
Gateway|layer 3|The router your computer sends traffic to when the destination is not on the local network. Also called the default gateway.
Handshake|layer 4-6|The opening exchange before data flows. TCP uses SYN, SYN-ACK, ACK. TLS then agrees on encryption keys.
Hop|layer 3|One router along the path between you and a destination. Tracepath lists them one by one.
HTTP|layer 7|HyperText Transfer Protocol. How browsers ask web servers for pages. HTTPS is HTTP carried inside TLS encryption.
ICMP|layer 3|Internet Control Message Protocol. Carries error and test messages. Ping and tracepath are built on it.
IPv4|layer 3|The classic 32-bit internet address, written as four numbers such as 192.168.1.10. About 4.3 billion exist, which is why NAT is used.
IPv6|layer 3|The newer 128-bit address, written in hexadecimal such as fd3a:7f9f::1. Large enough to give every device its own address.
Jitter|performance|How much the delay changes from one packet to the next. High jitter makes calls and games choppy even when average delay is low.
Latency|performance|The time a packet needs to go to a destination and back, measured in milliseconds. Also called round-trip time or ping time.
MAC address|layer 2|A 48-bit hardware address such as b8:e8:56:07:51:dc. It identifies a network card on the local link only and is not routed.
MTU|layer 2-3|Maximum Transmission Unit. The largest packet a link can carry without splitting it. Ethernet is usually 1500 bytes. Try: netscope --mtu
NAT|layer 3|Network Address Translation. Your router swaps your private address for its public one so many devices can share one internet address.
OSI model|all layers|A seven-layer way to think about networks: physical, data link, network, transport, session, presentation, application. Try: netscope --osi
Packet|layer 3|The unit of data that travels across the internet. It carries source and destination IP addresses.
Packet loss|performance|The share of packets that never arrive. Even 1 to 2 percent can hurt calls, games and TCP speed.
Ping|layer 3|A test that sends an ICMP echo request and times the reply. It shows whether a host is reachable and how long the round trip takes.
Port|layer 4|A number from 0 to 65535 that tells the computer which program a TCP or UDP packet is for. HTTPS uses 443, DNS uses 53.
Prefix|layer 3|The number after the slash in 192.168.1.0/24. It says how many leading bits are the network part of the address.
Router|layer 3|A device that forwards packets between networks. Your home router connects your local network to your provider.
SSID|layer 2|Service Set Identifier. The name of a Wi-Fi network, such as the one you pick from the network menu.
Subnet|layer 3|A smaller network carved out of a larger address range. Devices in the same subnet talk directly without a router. Try: netscope --subnet
TCP|layer 4|Transmission Control Protocol. Reliable, ordered delivery: lost segments are sent again. Used by web pages, email and file transfers.
TLS|layer 6|Transport Layer Security. Encrypts and authenticates a connection so others cannot read or change it. The S in HTTPS. Try: netscope --tls example.com
TTL|layer 3|Time To Live. A counter that each router lowers by one, so packets cannot loop forever. In DNS, the TTL is how long an answer may be cached.
UDP|layer 4|User Datagram Protocol. Fast and simple with no delivery guarantee. Used by DNS, video calls and many games.
VPN|layers 3-7|Virtual Private Network. Wraps your traffic in an encrypted tunnel to another network. The tunnel adds headers, so it lowers the usable MTU.
EOF
)

lab_glossary() {
  local q="${MODE_ARG,,}" term layer def n=0
  section "NETWORKING GLOSSARY"
  while IFS='|' read -r term layer def; do
    [[ -n "$term" ]] || continue
    if [[ -z "$q" || "${term,,}" == *"$q"* ]]; then
      printf '\n  %s%s%s  %s[%s]%s\n' "$BOLD$CYAN" "$term" "$RESET" "$GRAY" "$layer" "$RESET"
      wrap "$def"; n=$(( n + 1 ))
    fi
  done <<<"$GLOSSARY"
  (( n )) || note "No entry matches '$MODE_ARG'. Run --glossary on its own to list everything."
  printf '\n'
}

dns_type_help() {
  case "$1" in
    A)     echo "the IPv4 address of the name" ;;
    AAAA)  echo "the IPv6 address of the name" ;;
    CNAME) echo "an alias that points to another name" ;;
    MX)    echo "mail servers (a lower number means higher priority)" ;;
    NS)    echo "the name servers that are authoritative for the domain" ;;
    TXT)   echo "free text, often email security (SPF) and ownership proofs" ;;
    SOA)   echo "start of authority: the zone's main server, contact and timers" ;;
  esac
}

lab_dns() {
  local d="$MODE_ARG" srv out t ty n ip1
  LAN_IF=""; IFACE=""
  d="${d#http://}"; d="${d#https://}"; d="${d%%/*}"
  [[ "$d" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "That does not look like a domain name. Example: netscope --dns example.com" >&2; exit 2; }
  have dig || { echo "The DNS explorer needs 'dig'. Install it with: sudo apt install bind9-dnsutils" >&2; exit 1; }
  have ip && detect_network
  srv="$(get_dns_servers | head -n1)"
  section "DNS EXPLORER: $d"
  wrap "Your computer does not look names up itself. It asks a resolver (usually your router), which answers from its memory or asks other servers on your behalf."
  kv "Your resolver" "${srv:-unknown}"

  sub "Step 1: ask the same question twice (caching)"
  local answered=0
  for n in 1 2; do
    out="$(timeout 6 dig +noall +answer +stats +time=3 +tries=1 "$d" A 2>/dev/null)"
    t="$(sed -nE 's/^;; Query time: ([0-9]+) msec.*/\1/p' <<<"$out" | head -n1)"
    if awk '$4 == "A" || $4 == "CNAME" { f = 1 } END { exit !f }' <<<"$out"; then
      kv "Query $n" "${t:-?} ms"; answered=$(( answered + 1 ))
    else
      kv "Query $n" "no answer (timed out, blocked or the name does not exist)"
    fi
  done
  if (( answered == 2 )); then note "The second answer is usually faster because the resolver remembered (cached) the first one."
  else note "No cache comparison is possible without two answers. Check your connection with netscope first."; fi

  sub "Step 2: record types"
  for ty in A AAAA CNAME MX NS TXT SOA; do
    out="$(timeout 6 dig +noall +answer +time=3 +tries=1 "$d" "$ty" 2>/dev/null)"
    printf '\n  %s%s%s  %s%s%s\n' "$BOLD" "$ty" "$RESET" "$DIM" "$(dns_type_help "$ty")" "$RESET"
    if [[ -n "$out" ]]; then head -n 6 <<<"$out" | sed 's/^/    /'; else printf '    %s(none)%s\n' "$GRAY" "$RESET"; fi
  done
  printf '\n'
  note "The number after each name is the TTL: how many seconds a resolver may keep that answer before asking again."

  ip1="$(timeout 6 dig +short +time=3 +tries=1 "$d" A 2>/dev/null | grep -E '^[0-9.]+$' | head -n1)"
  if [[ -n "$ip1" ]]; then
    sub "Step 3: reverse lookup of $ip1"
    out="$(timeout 6 dig +short +time=3 +tries=1 -x "$ip1" 2>/dev/null | head -n1)"
    kv "PTR record" "${out:-none}"
    note "Reverse DNS maps an address back to a name. Many servers have none, or a generic provider name."
  fi

  sub "Step 4: the path DNS follows from the top (dig +trace)"
  note "Starts at the root servers and walks down, ignoring your resolver's cache."
  out="$(timeout 25 dig +trace +nodnssec +noall +answer +time=3 +tries=1 "$d" 2>/dev/null)"
  if ! awk '$4 == "A" || $4 == "AAAA" || $4 == "CNAME" { f = 1 } END { exit !f }' <<<"$out"; then
    note "The trace did not reach an answer. Some networks block DNS queries sent directly to root servers, or you are offline."
  else
    awk '$4 == "NS" { if (!($1 in c)) o[++n] = $1; c[$1]++ }
         END { for (i = 1; i <= n; i++) printf "  %d. zone %-24s %d name servers\n", i, (o[i] == "." ? ". (root)" : o[i]), c[o[i]] }' <<<"$out"
    printf '  %sanswer:%s\n' "$GRAY" "$RESET"
    awk '$4 == "A" || $4 == "AAAA" || $4 == "CNAME" { print "    " $0 }' <<<"$out" | head -n 6
    note "Each level only knows who runs the next one down: the root knows the TLD, the TLD knows the domain, and the domain's own server knows the answer."
  fi
  printf '\n'
}

lab_tls() {
  local t="$MODE_ARG" host port out proto cipher verify leaf subj iss na exp days nchain san a b tm
  t="${t#https://}"; t="${t%%/*}"
  host="${t%%:*}"; port=443; [[ "$t" == *:* ]] && port="${t##*:}"
  [[ "$host" =~ ^[A-Za-z0-9._-]+$ && "$port" =~ ^[0-9]{1,5}$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 )) || { echo "Please give a host such as example.com or example.com:443" >&2; exit 2; }
  have openssl || { echo "The TLS inspector needs 'openssl'. Install it with: sudo apt install openssl" >&2; exit 1; }
  section "TLS INSPECTOR: $host:$port"
  wrap "TLS is what makes HTTPS private. After the TCP handshake, the client and server agree on a protocol version and cipher, the server proves its identity with a certificate signed by an authority your computer trusts, and both sides derive secret keys."
  out="$(timeout 12 openssl s_client -connect "$host:$port" -servername "$host" -showcerts </dev/null 2>&1)"
  if ! grep -q 'BEGIN CERTIFICATE' <<<"$out"; then
    note "No TLS handshake could be completed with $host:$port."
    head -n 3 <<<"$out" | sed 's/^/  /'
    exit 1
  fi
  proto="$(sed -nE 's/^New, ([^,]+), Cipher is (.*)$/\1/p' <<<"$out" | head -n1)"
  cipher="$(sed -nE 's/^New, ([^,]+), Cipher is (.*)$/\2/p' <<<"$out" | head -n1)"
  verify="$(sed -nE 's/^ *Verify return code: (.*)$/\1/p' <<<"$out" | tail -n1)"
  nchain="$(grep -c 'BEGIN CERTIFICATE' <<<"$out")"
  leaf="$(awk '/BEGIN CERTIFICATE/ { f = 1 } f { print } /END CERTIFICATE/ { if (f) exit }' <<<"$out")"
  subj="$(openssl x509 -noout -subject <<<"$leaf" 2>/dev/null | sed 's/^subject= *//')"
  iss="$(openssl x509 -noout -issuer <<<"$leaf" 2>/dev/null | sed 's/^issuer= *//')"
  na="$(openssl x509 -noout -enddate <<<"$leaf" 2>/dev/null | cut -d= -f2)"
  san="$(openssl x509 -noout -ext subjectAltName <<<"$leaf" 2>/dev/null | tail -n +2 | tr -d ' \n')"
  exp="$(date -d "$na" +%s 2>/dev/null)"; days=""
  [[ "$exp" =~ ^[0-9]+$ ]] && days=$(( (exp - $(date +%s)) / 86400 ))

  sub "The connection"
  kv "Protocol" "${proto:-unknown}"
  kv "Cipher suite" "${cipher:-unknown}"
  if have curl; then
    if tm="$(curl -sS -o /dev/null --max-time 8 -w '%{time_connect} %{time_appconnect}' "https://$host:$port/" 2>/dev/null)"; then
      read -r a b <<<"$tm"
      [[ -n "$b" ]] && kv "TCP connect / TLS done" "$(to_ms "$a") ms / $(to_ms "$b") ms  (cumulative)"
    else
      kv "TCP connect / TLS done" "not timed (curl could not verify the certificate)"
    fi
  fi
  sub "The certificate"
  kv "Subject" "${subj:-unknown}"
  kv "Issued by" "${iss:-unknown}"
  kv "Expires" "${na:-unknown}${days:+  ($days days left)}"
  [[ -n "$san" ]] && kv "Valid for names" "${san:0:90}"
  kv "Chain length" "$nchain certificate(s) sent"
  if [[ "$verify" == "0 (ok)"* ]]; then show_check OK "Trusted by this computer" "$verify"
  else show_check WARN "Trusted by this computer" "${verify:-unknown}"; fi
  if [[ -n "$days" ]]; then
    if   (( days < 0 ));  then show_check FAIL "Expiry" "the certificate has expired"
    elif (( days < 14 )); then show_check WARN "Expiry" "expires in $days days"
    else show_check OK "Expiry" "$days days left"; fi
  fi
  printf '\n'
  wrap "A chain means the server's own certificate is signed by an intermediate authority, which is signed by a root authority that is already stored on your computer." "$DIM"
  printf '\n'
}

mtu_try() {
  if ping -n -c 1 -W 1 -M do -s "$2" "$1" >/dev/null 2>&1; then
    printf '  payload %4d + 28 header = %4d bytes   %sfits%s\n' "$2" "$(( $2 + 28 ))" "$GREEN" "$RESET"; return 0
  fi
  printf '  payload %4d + 28 header = %4d bytes   %stoo big%s\n' "$2" "$(( $2 + 28 ))" "$YELLOW" "$RESET"; return 1
}

lab_mtu() {
  local h="${MODE_ARG:-1.1.1.1}" lo hi mid best pmtu ifmtu=""
  LAN_IF=""; IFACE=""
  [[ "$h" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "That does not look like a host name or address." >&2; exit 2; }
  have ping || { echo "The MTU test needs the 'ping' command." >&2; exit 1; }
  have ip && detect_network
  [[ -n "$LAN_IF" ]] && ifmtu="$(rd "$NETSYS/$LAN_IF/mtu")"
  section "PATH MTU DISCOVERY: $h"
  wrap "The MTU is the largest packet a link can carry without splitting it. The smallest MTU anywhere along the path decides what really fits. NetScope sends pings with the Do-Not-Fragment flag at different sizes and uses a binary search to find the largest one that gets through. A ping adds 28 bytes of headers (20 IP + 8 ICMP) to its payload."
  printf '\n'
  if ! ping -n -c 1 -W 2 "$h" >/dev/null 2>&1; then
    note "$h does not answer ping, so the test cannot run. Try another host, for example: netscope --mtu 8.8.8.8"
    exit 1
  fi
  if mtu_try "$h" 1472; then best=1472
  else
    lo=56; hi=1471
    while (( lo < hi )); do
      mid=$(( (lo + hi + 1) / 2 ))
      if mtu_try "$h" "$mid"; then lo=$mid; else hi=$(( mid - 1 )); fi
    done
    best=$lo
  fi
  pmtu=$(( best + 28 ))
  sub "Result"
  kv "Path MTU to $h" "$pmtu bytes"
  [[ -n "$ifmtu" ]] && kv "Your adapter's MTU" "$ifmtu bytes"
  case "$pmtu" in
    1500) wrap "A full 1500 bytes fits. This is the normal Ethernet size and nothing on the path is shrinking it." ;;
    1492) wrap "1492 is the classic sign of PPPoE, which many DSL and some fibre providers use. It adds an 8-byte header." ;;
    *)    if (( pmtu < 1492 )); then wrap "Something on the path has a smaller MTU than Ethernet. VPN tunnels, mobile networks and some tunnels add headers, which is why you can see values such as 1420, 1400 or 1280."
          else wrap "Slightly below 1500. A small tunnel or provider setting is using some of the space for its own headers."; fi ;;
  esac
  if [[ "$ifmtu" =~ ^[0-9]+$ ]] && (( pmtu < ifmtu )); then
    wrap "Your adapter allows $ifmtu bytes, but the path only allows $pmtu. Normally routers tell your computer about this (path MTU discovery). If some sites hang while others work, a firewall blocking those messages is a classic cause." "$DIM"
  fi
  printf '\n'
}

# ══════════════════════════════════════════════════════════════════════════════
#  WALK
# ══════════════════════════════════════════════════════════════════════════════
WALK_N=0; PW_SM=""; PW_DM=""; PW_SI=""; PW_DI=""; PW_TT=""
WALK_HOST=""; WALK_PORT=""
walk_step() { WALK_N=$(( WALK_N + 1 )); sub "Step $WALK_N: $1"; }
wf_fld() {
  if [[ -n "${2:-}" && "$1" != "$2" ]]; then printf '%s%s%s' "$YELLOW$BOLD" "$1" "$RESET"
  else printf '%s' "$1"; fi
}
walk_frame() {
  local title="$1" mack="${2:-1}" sm="${3:--}" dm="${4:--}" si="${5:--}" di="${6:--}" tt="${7:--}"
  printf '\n    %s%s%s\n' "$BOLD" "$title" "$RESET"
  if (( mack )); then
    printf '      %sMAC%s  %s  %s→%s  %s\n' "$GRAY" "$RESET" \
      "$(wf_fld "$sm" "$PW_SM")" "$RESET" "$RESET" "$(wf_fld "$dm" "$PW_DM")"
  else
    printf '      %sMAC%s  %s(not present on this link — tunnel interface)%s\n' \
      "$GRAY" "$RESET" "$DIM" "$RESET"
  fi
  printf '      %sIP%s   %s  %s→%s  %s  %sTTL %s%s\n' "$GRAY" "$RESET" \
    "$(wf_fld "$si" "$PW_SI")" "$RESET" "$RESET" "$(wf_fld "$di" "$PW_DI")" \
    "$GRAY" "$(wf_fld "$tt" "$PW_TT")" "$RESET"
  PW_SM="$sm"; PW_DM="$dm"; PW_SI="$si"; PW_DI="$di"; PW_TT="$tt"
}

# first_cidr DEV [SRC]: "address/length" of DEV's IPv4 address. Understands
# point-to-point lines ("inet 10.8.0.2 peer 10.8.0.1/32"), where field 4 is not the address.
# SRC "any" means: first address of any scope.
first_cidr() {
  local -a scope=(scope global)
  local want="${2:-}"
  [[ -n "$want" ]] && scope=()
  want="${want/#any/}"
  ip -o -4 addr show dev "$1" "${scope[@]}" 2>/dev/null | awk -v s="$want" '
    { for (i = 1; i < NF; i++) if ($i == "inet") {
        a = $(i + 1); if (a !~ /\//) a = a "/32"
        split(a, p, "/"); if (s == "" || p[1] == s) { print a; exit } } }'
}

# walk_target ARG: validate the user's destination, set WALK_HOST / WALK_PORT, or exit 2.
walk_target() {
  local d="$1" cc
  WALK_PORT=""
  d="${d#http://}"; d="${d#https://}"; d="${d%%[/?#]*}"; d="${d##*@}"
  cc="${d//[^:]/}"
  if (( ${#cc} > 1 )); then
    printf -- '--walk follows IPv4 packets only; that looks like an IPv6 address.\n' >&2
    printf -- 'Try a hostname or an IPv4 address, e.g. netscope --walk 8.8.8.8\n' >&2
    exit 2
  fi
  if (( ${#cc} == 1 )); then
    WALK_PORT="${d##*:}"; d="${d%%:*}"
    if [[ ! "$WALK_PORT" =~ ^[0-9]{1,5}$ ]] || (( 10#$WALK_PORT > 65535 )); then
      printf -- 'Not a valid port number: %s\n' "$WALK_PORT" >&2; exit 2
    fi
  fi
  if [[ ! "$d" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    printf 'Not a valid host name or IPv4 address: %s\n' "${d:-(empty)}" >&2
    printf 'Example: netscope --walk 8.8.8.8\n' >&2
    exit 2
  fi
  if [[ "$d" =~ ^[0-9.]+$ ]] && { [[ "$d" =~ (^|\.)0[0-9] ]] || ! ip2int "$d" >/dev/null 2>&1; }; then
    printf '"%s" is not a valid IPv4 address (four numbers from 0 to 255, no leading zeros).\n' "$d" >&2
    exit 2
  fi
  WALK_HOST="$d"
}

# walk_trace_job TOOL DEST: run in the background; output in $TMP/trace.out, exit status in $TMP/trace.rc
walk_trace_job() {
  local rc
  # shellcheck disable=SC2086  # SDBUF is deliberately split into words (stdbuf -oL)
  if [[ "$1" == tracepath ]]; then
    timeout 25 ${SDBUF:-} tracepath -n -m 15 "$2" >"$TMP/trace.out" 2>/dev/null
  else
    timeout 25 ${SDBUF:-} traceroute -n -q 1 -w 1 -m 15 "$2" >"$TMP/trace.out" 2>/dev/null
  fi
  rc=$?
  printf '%s' "$rc" >"$TMP/trace.rc"
}

# walk_parse: tracepath / traceroute text on stdin -> "hop addr rtt asymm flag reached" per hop
walk_parse() {
  awk '
    $1 ~ /\?:$/ { next }
    { h = $1; sub(/:$/, "", h); if (h !~ /^[0-9]+$/ || (h in seen)) next
      a = $2; rtt = "-"; asy = "-"; flag = "-"; rch = 0
      if (a ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
        for (i = 3; i <= NF; i++) {
          if ($i ~ /^[0-9.]+ms$/) { rtt = $i; sub(/ms$/, "", rtt) }
          else if ($i ~ /^[0-9.]+$/ && $(i + 1) == "ms") rtt = $i
          else if ($i == "asymm" && $(i + 1) ~ /^[0-9]+$/) asy = $(i + 1)
          else if ($i ~ /^![A-Za-z0-9]*$/) flag = $i
          else if ($i == "reached") rch = 1
        }
        seen[h] = 1; print h, a, rtt, asy, flag, rch
      } else if (a == "no" || a == "*") { seen[h] = 1; print h, "?", "-", "-", "-", 0 } }'
}

walk_role() {
  local n k
  n="$(ip2int "$1" 2>/dev/null)" || { printf 'other'; return 0; }
  k="$(ip_kind "$n")"
  case "$k" in
    private*)    printf 'private' ;;
    shared*)     printf 'CGNAT range' ;;
    public*)     printf 'public' ;;
    link-local*) printf 'link-local' ;;
    *)           printf 'other' ;;
  esac
}

walk_slow() { awk -v r="$1" -v p="${2:--}" 'BEGIN { exit !(r >= 150 || (p != "-" && r - p >= 80)) }'; }

wnote() { wrap "$1" "$DIM"; }
walk_summary() {
  local ttl0="$1" lh="${2:-0}" isdest="${3:-0}" nathint="${4:-0}" ttl_line=""
  if (( lh > 0 )); then
    local arr=$(( ttl0 - lh + 1 ))
    if (( arr < 1 )); then ttl_line="TTL would have run out before hop $lh"
    elif (( isdest )); then ttl_line="arrives at hop $lh with TTL $arr *"
    else ttl_line="TTL $arr * at hop $lh (last one seen)"; fi
  fi
  section "WHAT STAYS AND WHAT CHANGES"
  kv "IP addresses" "unchanged (unless a NAT device rewrites the source)"
  kv "MAC addresses" "a new pair on every link"
  kv "TTL" "starts at $ttl0, minus 1 at every router *"
  [[ -n "$ttl_line" ]] && kv "" "$ttl_line"
  if (( nathint )); then
    printf '\n'
    wnote "Your address is private and the destination is public, so a router on the way very likely rewrites the source address (NAT). That is inferred from the address ranges; it cannot be observed from your computer."
  fi
  printf '\n'
  wrap "In short: the IP header is the address written on the parcel, the MAC header is the courier's hand-over slip for one single stretch. Every router throws the old slip away and writes a new one." "$DIM"
  wnote "* calculated from the hop number, not read from a real packet."
  wnote "Try it yourself:  ip route get <ip>    ip neigh    tracepath -n <ip>"
  printf '\n'
}

lab_walk() {
  local d dest dn rt rt_err rc dev nh src cidr pfx mask net smac ttl0 ttl_src tool line
  local nhmac nstate arp_how srckind destkind sn k h a r flag rch role st lat bar n pad
  local l2=1 by_and=0 nat_hint=0 total=0 reached=0 last_hop=0 trail=0 wide=0 is_gw=0
  local SDBUF="" trc="" pmtu="" back="" maxr=0 prev_r="-" priv_list="" first_a="" arr tail_txt
  local -a HOPS=()
  have stdbuf && SDBUF="stdbuf -oL"

  LAN_IF=""; IFACE=""; PW_SM=""; PW_DM=""; PW_SI=""; PW_DI=""; PW_TT=""; WALK_N=0
  (( W >= 76 )) && wide=1

  walk_target "$MODE_ARG"
  d="$WALK_HOST"
  have ip || { printf "NetScope needs the 'ip' command (package: iproute2).\n" >&2; exit 1; }

  if dn="$(ip2int "$d" 2>/dev/null)" && [[ -n "$dn" ]]; then
    dest="$d"
  else
    have getent || { printf -- "--walk needs 'getent' to look up names; give an IPv4 address instead.\n" >&2; exit 1; }
    dest="$(timeout 6 getent ahostsv4 "$d" 2>/dev/null | awk 'NR == 1 { print $1; exit }')"
    if [[ -z "$dest" ]] || ! dn="$(ip2int "$dest" 2>/dev/null)"; then
      printf 'Could not find an IPv4 address for %s.\n' "$d" >&2
      printf 'Check the name, or try an IPv4 address such as 8.8.8.8.\n' >&2
      exit 1
    fi
  fi

  rt_err="$(ip -4 route get "$dest" 2>&1)"; rc=$?
  if (( rc != 0 )) || [[ -z "$rt_err" || "$rt_err" == *RTNETLINK* || "$rt_err" == *rror* ]]; then
    printf 'Your computer has no route to %s (%s).\n' "$dest" "${rt_err:-no answer}" >&2
    printf 'Check your connection with netscope first.\n' >&2
    exit 1
  fi
  rt="$(head -n1 <<<"$rt_err")"

  section "PACKET WALK-THROUGH"
  if [[ "$d" != "$dest" ]]; then
    kv "Destination" "$d  →  $dest   $(ip_kind "$dn")"
  else
    kv "Destination" "$dest   $(ip_kind "$dn")"
  fi
  wrap "Following one IPv4 packet from this computer to $dest, using your real addresses. Nothing on your computer is changed. At most one ping and a short route trace are sent toward the destination." "$DIM"
  [[ -n "$WALK_PORT" ]] && wnote "Port $WALK_PORT is ignored: ports belong to TCP/UDP, above the IP packet that is followed here."

  case "$rt" in
    local*)
      sub "Local destination"
      wrap "$dest belongs to this computer, so the packet never leaves it. It is handed to the loopback interface; no router, MAC address or TTL change is involved."
      printf '\n'; return 0 ;;
    broadcast*|multicast*)
      sub "Not a single destination"
      wrap "$dest is a ${rt%% *} address: it is delivered to many devices on the link at once, so there is no single next hop to follow."
      printf '\n'; return 0 ;;
  esac

  dev="$(route_field "$rt" dev)"; nh="$(route_field "$rt" via)"; src="$(route_field "$rt" src)"
  cidr="$(first_cidr "$dev" "$src")"
  [[ -z "$cidr" ]] && cidr="$(first_cidr "$dev")"
  if [[ -z "$cidr" || -z "$dev" ]]; then
    printf 'No IPv4 address found on %s; cannot continue.\n' "${dev:-the outgoing interface}" >&2; exit 1
  fi
  src="${cidr%/*}"; pfx="${cidr#*/}"
  if ! sn="$(ip2int "$src")" || [[ ! "$pfx" =~ ^[0-9]+$ ]] || (( pfx > 32 )); then
    printf 'Could not parse your IPv4 address %s.\n' "$cidr" >&2; exit 1
  fi
  if (( pfx == 0 )); then mask=0; else mask=$(( (0xFFFFFFFF << (32 - pfx)) & 0xFFFFFFFF )); fi
  net=$(( sn & mask ))
  (( (dn & mask) == net )) && by_and=1
  smac="$(rd "$NETSYS/$dev/address")"
  if [[ -z "$smac" || "$smac" == 00:00:00:00:00:00 ]] || ip -o link show dev "$dev" 2>/dev/null | grep -q NOARP; then l2=0; fi
  ttl0="$(rd /proc/sys/net/ipv4/ip_default_ttl)"; ttl_src="this computer's default"
  if [[ ! "$ttl0" =~ ^[0-9]+$ ]]; then ttl0=64; ttl_src="assumed (could not be read)"; fi
  srckind="$(ip_kind "$sn")"; destkind="$(ip_kind "$dn")"
  if [[ "$srckind" == private* || "$srckind" == shared* ]] && [[ "$destkind" == public* ]]; then nat_hint=1; fi

  walk_step "Your computer"
  kv "Interface" "$dev"
  kv "IPv4" "$src/$pfx   (mask $(int2ip "$mask"))"
  if (( l2 )); then kv "MAC" "$smac"; else kv "MAC" "none: $dev is a tunnel, no Ethernet frames on it"; fi

  walk_step "Local or remote?  (AND with the netmask)"
  kv "My network" "$(int2ip "$net")/$pfx"
  kv "Destination's network" "$(int2ip $(( dn & mask )))/$pfx   (same mask applied to $dest)"
  if (( ADVANCED )); then
    printf '\n'
    printf '  %s%-14s%s %s   %s\n' "$GRAY" "my IP" "$RESET" "$(bin_ip "$sn")" "$src"
    printf '  %s%-14s%s %s   /%s\n' "$GRAY" "netmask" "$RESET" "$(bin_ip "$mask")" "$pfx"
    printf '  %s%-14s%s %s%s%s   %s\n' "$GRAY" "my network" "$RESET" "$BOLD" "$(bin_ip "$net")" "$RESET" "$(int2ip "$net")"
    printf '  %s%-14s%s %s   %s\n' "$GRAY" "destination" "$RESET" "$(bin_ip "$dn")" "$dest"
    printf '  %s%-14s%s %s%s%s   %s\n' "$GRAY" "dest. network" "$RESET" "$BOLD" "$(bin_ip $(( dn & mask )))" "$RESET" "$(int2ip $(( dn & mask )))"
  fi
  printf '\n'
  if (( by_and )) && [[ -z "$nh" || "$nh" == "$dest" ]]; then
    printf '  %sSame network → LOCAL%s: delivered directly, no router.\n' "$GREEN$BOLD" "$RESET"
  elif (( by_and )); then
    printf '  %sSame network%s, but the routing table sends it via %s.\n' "$GREEN" "$RESET" "$nh"
  elif [[ -z "$nh" ]]; then
    printf '  %sDifferent network → REMOTE%s by the netmask test, but the routing table sends it straight out of %s (no gateway address, typical of a VPN or tunnel).\n' "$YELLOW$BOLD" "$RESET" "$dev"
  else
    printf '  %sDifferent network → REMOTE%s: the packet must go through a router.\n' "$YELLOW$BOLD" "$RESET"
  fi
  (( ADVANCED )) || wnote "Add --advanced to see the binary working of the AND step, or run netscope --subnet."

  walk_step "The first frame leaves your computer"
  printf '  %s%s%s\n' "$CYAN" "$rt" "$RESET"
  if [[ -n "$nh" ]]; then
    ip -4 route show default 2>/dev/null | grep -qw "via $nh" && is_gw=1
    kv "Next hop" "$nh   $( (( is_gw )) && echo '(your default gateway)' || echo '(from the routing table)' )"
    wrap "The IP packet is addressed to $dest, but the frame carrying it is handed to $nh. The router's address never becomes the packet's destination." "$DIM"
  else
    kv "Next hop" "$dest   (directly reachable on $dev)"
    nh="$dest"
  fi

  nhmac=""; nstate=""; arp_how=""
  if (( ! l2 )); then
    wnote "$dev is a tunnel: packets go straight in, so there is no ARP and no MAC to look up."
  else
    line="$(ip neigh show "$nh" dev "$dev" 2>/dev/null | head -n1)"
    nhmac="$(awk '{ for (i = 1; i < NF; i++) if ($i == "lladdr") { print $(i + 1); exit } }' <<<"$line")"
    nstate="$(awk '{ print $NF }' <<<"$line")"
    if [[ -n "$nhmac" ]]; then
      arp_how="from the neighbour cache"
    elif have ping; then
      wnote "Next hop not in the neighbour cache yet: sending one ping, which makes the kernel ask with ARP."
      timeout 4 ping -n -c 1 -W 1 "$nh" >/dev/null 2>&1
      line="$(ip neigh show "$nh" dev "$dev" 2>/dev/null | head -n1)"
      nhmac="$(awk '{ for (i = 1; i < NF; i++) if ($i == "lladdr") { print $(i + 1); exit } }' <<<"$line")"
      nstate="$(awk '{ print $NF }' <<<"$line")"
      [[ -n "$nhmac" ]] && arp_how="learned after one ping"
    fi
    if [[ -n "$nhmac" ]]; then
      kv "Next hop MAC" "$nhmac   ($arp_how, state ${nstate:-?})"
      [[ "$nstate" == STALE ]] && wnote "STALE: cached but not re-checked recently. It is probably still right; the kernel re-verifies it on use."
    else
      kv "Next hop MAC" "not known"
      if have ping; then
        wnote "No ARP answer was seen (neighbour state: ${nstate:-none}). The device may be off, or filtering ARP or ping; that is not proven."
      else
        wnote "Not in the neighbour cache, and 'ping' is not installed to trigger ARP. Try: ip neigh   after contacting $nh."
      fi
    fi
    (( ADVANCED )) && [[ -n "$line" ]] && kv "ip neigh says" "$line"
  fi

  walk_frame "Frame leaving your computer" "$l2" "$smac" "${nhmac:-unknown}" "$src" "$dest" "$ttl0"
  wnote "The MAC header is for one link only; the IP header is for the whole trip. TTL starts at $ttl0 ($ttl_src; a program may choose another)."

  if (( by_and )) && [[ "$nh" == "$dest" ]]; then
    walk_step "Delivered: nothing in between"
    walk_summary "$ttl0" 0 0 0
    return 0
  fi

  walk_step "Routers along the way"
  if have tracepath; then tool=tracepath; elif have traceroute; then tool=traceroute; else tool=""; fi
  if [[ -z "$tool" ]]; then
    wnote "Neither tracepath nor traceroute is installed."
    wnote "Install one to see the routers:  sudo apt install iputils-tracepath"
  elif ! have timeout; then
    wnote "The 'timeout' command (coreutils) is missing, so the trace is skipped to avoid hanging."
    tool=""
  elif [[ -z "$TMP" ]] && ! TMP="$(mktemp -d "${TMPDIR:-/tmp}/netscope.XXXXXX")"; then
    wnote "Cannot create a temporary folder, so the trace is skipped."
    TMP=""; tool=""
  else
    begin_phase
    spawn "$tool" walk_trace_job "$tool" "$dest"
    wait_jobs "Tracing the route with $tool (up to 25 s)"
    trc="$(rd "$TMP/trace.rc")"
    mapfile -t HOPS < <(walk_parse <"$TMP/trace.out")
    pmtu="$(sed -n 's/.*Resume: pmtu \([0-9]*\).*/\1/p' "$TMP/trace.out" 2>/dev/null | head -n1)"
    back="$(sed -n 's/.*Resume:.* back \([0-9]*\).*/\1/p' "$TMP/trace.out" 2>/dev/null | head -n1)"
  fi
  total=${#HOPS[@]}
  while (( total > 0 )); do
    read -r _ a _ <<<"${HOPS[total - 1]}"
    [[ "$a" == "?" ]] || break
    unset 'HOPS[total-1]'; total=$(( total - 1 )); trail=$(( trail + 1 ))
  done

  if (( total == 0 )); then
    if [[ -n "$tool" ]]; then
      if [[ "$trc" == 124 ]]; then wnote "$tool timed out after 25 seconds without a usable answer."
      elif (( trail > 0 )); then wnote "$tool got no reply from any router. Many networks block these probes; that does not mean your traffic is blocked."
      else wnote "$tool returned no hops (exit status ${trc:-?})."; fi
    fi
    wnote "Conceptually the packet still gets a new frame and loses 1 TTL at every router."
    walk_summary "$ttl0" 0 0 "$nat_hint"
    return 0
  fi

  maxr="$(printf '%s\n' "${HOPS[@]}" | awk '$3 ~ /^[0-9.]+$/ && $3 + 0 > m { m = $3 + 0 } END { print m + 0 }')"
  printf '\n  %s%-4s %-16s %-9s' "$GRAY" "HOP" "ADDRESS" "LATENCY"
  (( wide )) && printf ' %-8s' "      "
  printf ' %-8s %s%s\n' "REPLY" "NOTE" "$RESET"
  printf '  %s%s%s\n' "$DIM" "$(rep "$G_H" "$(( W - 4 ))")" "$RESET"
  for (( k = 0; k < total; k++ )); do
    read -r h a r _ flag rch <<<"${HOPS[k]}"
    bar=""; lat="-"; pad="  "; role=""
    if [[ "$a" == "?" ]]; then
      st=INFO; role="no reply (common, not an error)"; a="*"
    else
      st=OK
      [[ "$r" =~ ^[0-9.]+$ ]] && lat="$(fmt_ms "$r")"
      if [[ "$a" == "$dest" || "$rch" == 1 ]]; then reached=1; role="destination"
      elif (( h == 1 )) && [[ "$a" == "$nh" ]]; then role="$( (( is_gw )) && echo gateway || echo 'next hop' )"
      else role="$(walk_role "$a")"; fi
      last_hop="$h"
      [[ -z "$first_a" ]] && first_a="$a"
      if (( h > 1 )) && [[ "$a" != "$dest" ]]; then
        case "$(walk_role "$a")" in private|'CGNAT range') priv_list+="${priv_list:+, }$h" ;; esac
      fi
      if [[ "$r" =~ ^[0-9.]+$ ]]; then
        if walk_slow "$r" "$prev_r"; then st=WARN; role+="${role:+, }slow reply"; fi
        prev_r="$r"
        n="$(awk -v r="$r" -v m="$maxr" 'BEGIN { n = (m > 0) ? int(r / m * 8 + 0.5) : 0; if (n < 1) n = 1; if (n > 8) n = 8; print n }')"
        bar="$(rep "$G_ON" "$n")$GRAY$(rep "$G_OFF" "$(( 8 - n ))")$RESET"
      fi
      [[ "$flag" != "-" ]] && { st=FAIL; role="router reports $flag"; }
    fi
    [[ "$st" == OK ]] || pad=""
    printf '  %-4s %-16s %-9s' "$h" "$a" "$lat"
    if (( wide )); then
      if [[ -n "$bar" ]]; then printf ' %s%s%s' "$CYAN" "$bar" "$RESET"; else printf ' %8s' ""; fi
    fi
    printf ' %s%s %s%s%s\n' "$(mark_state "$st")" "$pad" "$DIM" "$role" "$RESET"
  done

  if (( ! reached )); then
    printf '\n'
    if (( trail > 0 )); then
      wnote "The $trail hop(s) after hop $last_hop gave no answer. Routers and destinations often ignore these probes, so this does not prove $dest is unreachable."
    elif [[ "$trc" == 124 ]]; then
      wnote "$tool timed out after hop $last_hop, so this list may be incomplete."
    else
      wnote "$tool stopped at hop $last_hop (15-hop limit or an error); $dest was not seen answering."
    fi
  fi
  [[ -n "$first_a" && "$first_a" != "$nh" ]] && (( ${HOPS[0]%% *} == 1 )) \
    && wnote "Hop 1 ($first_a) differs from the next hop in your routing table ($nh). The trace may have seen a different device; the reason is not determined here."
  [[ -n "$priv_list" ]] && wnote "Another private-range router at hop(s) $priv_list: often double NAT or an ISP-internal network. This is a hint from the addresses only."
  wnote "LATENCY is the measured round trip of each probe. Routers often answer probes slowly, so one slow hop followed by fast ones is usually harmless."
  wnote "REPLY describes the probe's answer, not the health of your traffic. WARN = slow (150 ms or more, or +80 ms over the previous hop)."

  walk_step "What changes at each hop"
  printf '  %s%-8s %-16s %-6s %s%s\n' "$GRAY" "FROM" "TO" "TTL*" "MAC PAIR ON THAT LINK" "$RESET"
  local prev_name="you" hn
  for (( k = 0; k < total; k++ )); do
    read -r h a _ <<<"${HOPS[k]}"
    arr=$(( ttl0 - h + 1 ))
    hn="hop $h"; [[ "$a" == "?" ]] && hn="hop $h (silent)"
    if (( k == 0 && h == 1 )); then tail_txt="shown in step 3"; else tail_txt="new pair, not visible from here"; fi
    (( arr < 1 )) && tail_txt="TTL would be used up before here"
    printf '  %-8s %-16s %-6s %s%s%s\n' "$prev_name" "$hn" "$arr" "$DIM" "$tail_txt" "$RESET"
    prev_name="hop $h"
  done
  wnote "Each router lowers TTL by 1 and builds a new frame; its source MAC is its own, its destination MAC is the next device's."
  if (( ADVANCED )); then
    sub "Technical details"
    kv "Trace tool" "$tool (exit status ${trc:-?}; 124 = timed out)"
    [[ -n "$pmtu" ]] && kv "Path MTU (tracepath)" "$pmtu bytes"
    [[ -n "$back" ]] && kv "Return hops (estimate)" "$back   (tracepath guesses this from reply TTLs; treat as a hint)"
    kv "Start TTL" "$ttl0 ($ttl_src)"
  fi
  walk_summary "$ttl0" "$last_hop" "$reached" "$nat_hint"
}

# ══════════════════════════════════════════════════════════════════════════════
#  EXPLORATION MODES
# ══════════════════════════════════════════════════════════════════════════════
lab_arp() {
  have ip || { echo "NetScope needs the 'ip' command (package: iproute2)." >&2; exit 1; }
  LAN_IF=""; IFACE=""; GATEWAY=""
  detect_network
  section "ARP / NEIGHBOUR TABLE"
  wrap "On a local network, computers find each other by MAC address. When one needs to reach an IP, it broadcasts 'who has this address?' (ARP) and the owner replies with its MAC. The answers are cached below, with a state that says how fresh and reliable each entry is."
  printf '\n'
  local nb line ip_ iface_ mac_ state_ c
  nb="$(ip neigh show 2>/dev/null)"
  if [[ -z "$nb" ]]; then
    note "The neighbour table is empty. Talk to another device first (for example: ping your router), then try again."
    printf '\n'; return 0
  fi
  printf '  %s%-18s %-20s %-12s %s%s\n' "$GRAY" "IP" "MAC" "STATE" "INTERFACE" "$RESET"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    ip_="$(awk '{print $1}' <<<"$line")"
    iface_="$(awk '{print $3}' <<<"$line")"
    mac_="$(awk '{ for(i=1;i<=NF;i++) if($i=="lladdr"){print $(i+1); exit} }' <<<"$line")"
    state_="$(awk '{print $NF}' <<<"$line")"
    c="$RESET"
    case "$state_" in
      REACHABLE)  c="$GREEN"  ;;
      STALE|DELAY|PROBE) c="$YELLOW" ;;
      FAILED|INCOMPLETE) c="$RED" ;;
      PERMANENT)  c="$CYAN" ;;
    esac
    printf '  %-18s %-20s %s%-12s%s %s\n' "$ip_" "${mac_:--}" "$c" "$state_" "$RESET" "${iface_:--}"
  done <<<"$nb"
  printf '\n'
  sub "What the states mean"
  kv "REACHABLE"  "confirmed recently; safe to use"
  kv "STALE"      "cached but not verified; will be re-checked when next used"
  kv "DELAY"      "waiting briefly before re-checking"
  kv "PROBE"      "actively asking to re-verify"
  kv "INCOMPLETE" "asked, no reply yet"
  kv "FAILED"     "asked, no reply; will not be used"
  kv "PERMANENT"  "manually configured, never expires"
  printf '\n'
  if [[ -n "$GATEWAY" ]]; then
    local gw_mac
    gw_mac="$(ip neigh show "$GATEWAY" 2>/dev/null | awk '{ for(i=1;i<=NF;i++) if($i=="lladdr"){print $(i+1); exit} }')"
    sub "Gateway"
    kv "Address" "$GATEWAY"
    kv "MAC"     "${gw_mac:-not in the cache yet}"
  fi
  local my_addr my_pfx hosts
  my_addr="$(first_cidr "${LAN_IF:-$IFACE}")"
  if [[ -n "$my_addr" ]]; then
    my_pfx="${my_addr#*/}"
    if (( my_pfx == 32 )); then hosts=1
    elif (( my_pfx == 31 )); then hosts=2
    else hosts=$(( (1 << (32 - my_pfx)) - 2 )); fi
    sub "Your subnet"
    kv "Address"           "$my_addr"
    kv "Broadcast domain"  "up to $hosts usable addresses (theoretical, from /$my_pfx)"
    note "ARP only reaches devices in the same subnet. For other subnets, frames go to the router's MAC instead."
  fi
  printf '\n'
  note "Try it yourself:  ip neigh    (or the older: arp -n)"
  printf '\n'
}

R_RAW=(); R_NET=(); R_PFX=(); R_KIND=(); R_VIA=(); R_DEV=(); R_PROTO=(); R_SCOPE=(); R_SRC=(); R_MET=(); R_FLAGS=()

pfx_mask() { local p=$1; if (( p <= 0 )); then printf 0; else printf '%s' "$(( (0xFFFFFFFF << (32 - p)) & 0xFFFFFFFF ))"; fi; }

bin_pfx() {   # address prefix-length -> dotted binary; the first <prefix> bits are green, then "|"
  local n=$1 p=$2 i out=""
  for (( i = 0; i < 32; i++ )); do
    (( i > 0 && i % 8 == 0 )) && out+="."
    (( i == 0 && p > 0 )) && out+="$GREEN"
    (( i == p )) && out+="$RESET|"
    out+=$(( (n >> (31 - i)) & 1 ))
  done
  (( p >= 32 )) && out+="$RESET|"
  printf '%s%s' "$out" "$RESET"
}

resolve_ipv4() {   # name-or-address -> IPv4 address (fails if it cannot be found)
  local d="$1" a
  if ip2int "$d" >/dev/null 2>&1; then printf '%s' "$d"; return 0; fi
  have getent || return 1
  a="$(timeout 6 getent ahostsv4 "$d" 2>/dev/null | awk '{ print $1; exit }')"
  ip2int "${a:-x}" >/dev/null 2>&1 || return 1
  printf '%s' "$a"
}

routes_load() {
  local line w tok kind ip pfx m base len
  local -a LN=()
  R_RAW=(); R_NET=(); R_PFX=(); R_KIND=(); R_VIA=(); R_DEV=(); R_PROTO=(); R_SCOPE=(); R_SRC=(); R_MET=(); R_FLAGS=()
  while IFS= read -r line; do   # multipath "nexthop" lines continue the previous route
    [[ -n "$line" ]] || continue
    if [[ "$line" == [[:space:]]* ]] && (( ${#LN[@]} > 0 )); then
      line="${line#"${line%%[![:space:]]*}"}"; LN[${#LN[@]}-1]+=" $line"
    else LN+=("$line"); fi
  done < <(ip -4 route show 2>/dev/null)
  for line in "${LN[@]}"; do
    read -ra w <<<"$line"
    tok="${w[0]:-}"; kind=unicast
    case "$tok" in
      blackhole|unreachable|prohibit|throw) kind="$tok"; tok="${w[1]:-}" ;;
      unicast) tok="${w[1]:-}" ;;
    esac
    pfx=-1; ip=0
    if [[ "$tok" == default ]]; then pfx=0
    else
      base="${tok%%/*}"; len=32; [[ "$tok" == */* ]] && len="${tok#*/}"
      if ip="$(ip2int "$base" 2>/dev/null)" && [[ "$len" =~ ^[0-9]+$ ]] && (( len <= 32 )); then pfx="$len"; else ip=0; fi
    fi
    m="$(pfx_mask "$pfx")"
    R_RAW+=("$line"); R_NET+=("$(( ip & m ))"); R_PFX+=("$pfx"); R_KIND+=("$kind")
    R_VIA+=("$(route_field "$line" via)"); R_DEV+=("$(route_field "$line" dev)")
    R_PROTO+=("$(route_field "$line" proto)"); R_SCOPE+=("$(route_field "$line" scope)")
    R_SRC+=("$(route_field "$line" src)"); R_MET+=("$(route_field "$line" metric)")
    m=""
    [[ " $line " == *" onlink "* ]] && m+=" onlink"
    [[ " $line " == *" linkdown "* || " $line " == *" dead "* ]] && m+=" linkdown"
    [[ "$line" == *nexthop* ]] && m+=" multipath"
    R_FLAGS+=("$m")
  done
}

route_explain() {   # index -> one explanatory paragraph
  local i=$1 p="${R_PFX[$1]}" net="${R_NET[$1]}" size last t=""
  local k="${R_KIND[$1]}" via="${R_VIA[$1]}" dev="${R_DEV[$1]}" pr="${R_PROTO[$1]}" src="${R_SRC[$1]}" met="${R_MET[$1]}" fl="${R_FLAGS[$1]}"
  if (( p < 0 )); then printf 'NetScope does not decode this form of line. See: man ip-route'; return; fi
  size=$(( 1 << (32 - p) )); last=$(( net + size - 1 ))
  if   (( p == 0 ));  then t="DEFAULT ROUTE: used for every destination that no more specific route covers (0.0.0.0/0, the whole internet)."
  elif (( p == 32 )); then t="HOST ROUTE: exactly one address, $(int2ip "$net")."
  else t="NETWORK $(int2ip "$net")/$p: the $size addresses from $(int2ip "$net") to $(int2ip "$last") ($(ip_kind "$net"))."; fi
  case "$k" in
    blackhole)   t+=" Matching packets are silently thrown away (blackhole)." ;;
    unreachable) t+=" Matching packets are refused with 'host unreachable'." ;;
    prohibit)    t+=" Matching packets are refused with 'administratively prohibited'." ;;
    throw)       t+=" 'throw' means: stop searching this table (another routing table may answer)." ;;
    *) if [[ -n "$via" ]]; then t+=" Packets are handed to the gateway $via (a router) through ${dev:-the interface}."
       else t+=" No router needed: these addresses are directly reachable on ${dev:-the interface} (the device is found with ARP)."; fi ;;
  esac
  case "$pr" in
    kernel) t+=" Added automatically by the kernel when ${dev:-the interface} received its address." ;;
    dhcp)   t+=" Learned from DHCP: your router told your computer." ;;
    static) t+=" Configured by hand, or by NetworkManager or a VPN client." ;;
    boot)   t+=" Added at boot." ;;
    ra)     t+=" Learned from a router advertisement." ;;
    "")     ;;
    *)      t+=" Added by '$pr'." ;;
  esac
  [[ -n "$src" ]] && t+=" Packets sent this way carry source address $src."
  [[ -n "$met" ]] && t+=" Metric $met: the tie-breaker between routes of the same prefix length (lower wins)."
  [[ "$fl" == *onlink* ]]    && t+=" 'onlink': the gateway is treated as directly reachable."
  [[ "$fl" == *linkdown* ]]  && t+=" The interface is currently down (linkdown), so this route is probably not used."
  [[ "$fl" == *multipath* ]] && t+=" Several next hops share the traffic (multipath)."
  printf '%s' "$t"
}

wrap5() {   # wrap "text" [colour]  (indented under a numbered route)
  local ln c="${2:-}"
  while IFS= read -r ln; do
    ln="${ln%"${ln##*[![:space:]]}"}"
    printf '     %s%s%s\n' "$c" "$ln" "$RESET"
  done < <(fold -s -w "$(( W - 8 ))" <<<"$1")
}

lab_routes() {
  local d="$MODE_ARG" dest="" dn=0 i n cnt=0 m x b wp wm wi sp sm si kr kdev kvia tag c
  local -a CAND=() SORTED=()
  local -A ISM=()
  LAN_IF=""; IFACE=""
  have ip || { echo "NetScope needs the 'ip' command (package: iproute2)." >&2; exit 1; }
  if [[ -n "$d" ]]; then
    d="${d#http://}"; d="${d#https://}"; d="${d%%/*}"; d="${d%%:*}"
    [[ "$d" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "That does not look like a host name or IPv4 address. Example: netscope --routes 8.8.8.8" >&2; exit 2; }
    dest="$(resolve_ipv4 "$d")" || { echo "Could not find an IPv4 address for '$d'. Check the name, or give an IP address." >&2; exit 1; }
    dn="$(ip2int "$dest")"
  fi
  routes_load
  n=${#R_RAW[@]}
  if (( n == 0 )); then echo "No IPv4 routes found: this computer has no routing table entries." >&2; exit 1; fi

  # ── which routes contain the destination? sort: longest prefix, then lowest metric ──
  if [[ -n "$dest" ]]; then
    for (( i = 0; i < n; i++ )); do
      (( R_PFX[i] >= 0 )) || continue
      m="$(pfx_mask "${R_PFX[i]}")"
      if (( (dn & m) == R_NET[i] )); then ISM[$i]=1; CAND+=("${R_PFX[i]} ${R_MET[i]:-0} $i"); fi
    done
    cnt=${#CAND[@]}
    if (( cnt > 0 )); then mapfile -t SORTED < <(printf '%s\n' "${CAND[@]}" | sort -k1,1nr -k2,2n -k3,3n); fi
    (( cnt > 0 )) && read -r wp wm wi <<<"${SORTED[0]}"
  fi

  # ── the table, one explained line per route ────────────────────────────────
  section "YOUR ROUTING TABLE (IPv4)"
  wrap "Each line is one rule: 'to reach THESE addresses, go THIS way'. For every packet, the kernel finds the rules whose range contains the destination and uses the most specific one (the longest prefix)."
  wrap "The order of the lines does not matter." "$DIM"
  printf '\n'
  for (( i = 0; i < n; i++ )); do
    tag=""
    if [[ -n "$dest" && -n "${ISM[$i]:-}" ]]; then
      if (( cnt > 0 && i == wi )); then tag="  ${GREEN}${BOLD}<== WINNER${RESET}"; else tag="  ${YELLOW}<== matches${RESET}"; fi
    fi
    printf '  %s%2d.%s %s%s%s%s\n' "$BOLD" "$(( i + 1 ))" "$RESET" "$CYAN" "${R_RAW[i]}" "$RESET" "$tag"
    wrap5 "$(route_explain "$i")" "$DIM"
  done
  x="$(ip -6 route show 2>/dev/null | grep -c .)"
  printf '\n'
  note "IPv6 has its own table ($x routes here): ip -6 route"
  [[ -z "$dest" ]] && note "See which line wins for a destination:  netscope --routes 8.8.8.8"

  # ── longest-prefix match ───────────────────────────────────────────────────
  if [[ -n "$dest" ]]; then
    section "WHICH ROUTE WINS FOR $dest ?"
    [[ "$d" != "$dest" ]] && kv "Name resolved to" "$dest  ($d)"
    kv "Destination" "$dest   $(ip_kind "$dn")"
    printf '\n'
    wrap "A route matches when the destination's first <prefix> bits equal the route's network bits. Below, the green bits (left of the | bar) are the ones that must match; the bits after the bar are ignored."
    printf '\n  %s%-12s%s %s\n' "$GRAY" "destination" "$RESET" "$(bin_ip "$dn")   ($dest)"

    if (( cnt == 0 )); then
      printf '\n'
      wrap "No route in the table contains $dest, and there is no default route. The kernel has nowhere to send the packet and answers 'Network is unreachable'." "$YELLOW"
    else
      sub "Every route that matches (best first)"
      for (( c = 0; c < cnt; c++ )); do
        read -r sp sm si <<<"${SORTED[c]}"
        if (( c == 0 )); then tag="${GREEN}${BOLD}WINNER${RESET}"; else tag="${YELLOW}loses${RESET}"; fi
        printf '  %s#%d%s  /%-2s  %s   [%s]\n' "$BOLD" "$(( c + 1 ))" "$RESET" "$sp" "${R_RAW[si]}" "$tag"
        printf '       %s\n' "$(bin_pfx "$dn" "$sp")"
        if (( c > 0 )); then
          if   (( sp < wp )); then printf '       %sloses: prefix /%s is shorter than /%s, so it is less specific%s\n' "$DIM" "$sp" "$wp" "$RESET"
          elif (( sm > wm )); then printf '       %sloses: same prefix length, but metric %s is higher than %s%s\n' "$DIM" "$sm" "$wm" "$RESET"
          else printf '       %sloses: same prefix and metric; the kernel keeps the first one%s\n' "$DIM" "$RESET"; fi
        fi
      done

      sub "Routes that do NOT match"
      b=0
      for (( i = 0; i < n; i++ )); do
        [[ -z "${ISM[$i]:-}" ]] || continue
        (( R_PFX[i] >= 0 )) || continue
        (( b++ >= 12 )) && continue
        m="$(pfx_mask "${R_PFX[i]}")"; x=$(( (dn ^ R_NET[i]) & m )); c=0
        while (( c < 32 && ! (x & (1 << (31 - c))) )); do c=$(( c + 1 )); done
        printf '  %s%s/%s%s: differs at bit %d, inside its %d network bits\n' "$GRAY" "$(int2ip "${R_NET[i]}")" "${R_PFX[i]}" "$RESET" "$(( c + 1 ))" "${R_PFX[i]}"
      done
      (( b == 0 )) && note "(every route matches)"
      (( b > 12 )) && note "... and $(( b - 12 )) more."

      sub "Why route #1 wins"
      if (( cnt == 1 )); then
        wrap "It is the only route whose range contains $dest, so there is no competition."
      else
        read -r sp sm si <<<"${SORTED[1]}"
        if (( wp > sp )); then
          wrap "Its prefix /$wp is longer than the next best match, /$sp. A longer prefix describes a smaller, more precise group of addresses, so it is the most specific knowledge your computer has about $dest. The kernel always prefers the longest prefix and looks at the metric only when prefix lengths are equal."
        elif (( wm < sm )); then
          wrap "Several routes have the same prefix length, /$wp, so the tie is broken by the metric: $wm beats $sm (lower is preferred)."
        else
          wrap "Several routes match equally well (same prefix length and same metric), so the kernel keeps the first one it finds."
        fi
      fi
      (( wp == 0 )) && wrap "Only the default route covers it: $dest is outside every network your computer knows directly, so the packet goes to the gateway and the router decides the rest." "$DIM"
      case "${R_KIND[wi]}" in
        blackhole|unreachable|prohibit) wrap "This winner is a special route: the packet will not be sent anywhere (${R_KIND[wi]})." "$YELLOW" ;;
      esac

      sub "What the kernel itself says  (ip route get $dest)"
      kr="$(ip -4 route get "$dest" 2>&1 | head -n1)"
      printf '  %s%s%s\n' "$CYAN" "${kr:-no answer}" "$RESET"
      kdev="$(route_field "$kr" dev)"; kvia="$(route_field "$kr" via)"
      if [[ "$kr" == local* ]]; then
        wrap "This is one of your own addresses. The separate 'local' table (ip route show table local) answers first, so the main table above is never consulted." "$DIM"
      elif [[ "$kdev" == "${R_DEV[wi]}" && "$kvia" == "${R_VIA[wi]}" ]]; then
        wrap "The kernel agrees: it uses route #$(( wi + 1 ))." "$GREEN"
      else
        wrap "The kernel chose a different exit than this simple model. Usual reasons: a route marked linkdown is skipped, policy routing rules (ip rule), or another routing table." "$YELLOW"
      fi
      note "Next: follow the packet hop by hop with  netscope --walk $dest"
    fi
  fi
  printf '\n'
}

lab_ports() {
  section "PORTS AND CONNECTIONS"
  wrap "A port is a number (0 to 65535) that identifies which program on a computer a packet belongs to. Listening ports wait for incoming connections; established connections are the ones in use right now."
  printf '\n'
  if ! have ss; then
    note "This needs 'ss' (package iproute2, usually already installed)."
    printf '\n'; return 0
  fi
  sub "Listening (waiting for incoming connections)"
  ss -tlnp 2>/dev/null | head -n 25 | sed 's/^/  /'
  printf '\n'
  sub "Established TCP connections (sessions open right now)"
  ss -tnp state established 2>/dev/null | head -n 25 | sed 's/^/  /'
  printf '\n'
  sub "UDP sockets"
  ss -ulnp 2>/dev/null | head -n 15 | sed 's/^/  /'
  printf '\n'
  sub "Common service names"
  kv "22"   "SSH (remote login)"
  kv "53"   "DNS (name lookup)"
  kv "80"   "HTTP (web, unencrypted)"
  kv "123"  "NTP (time sync)"
  kv "443"  "HTTPS (web, encrypted)"
  kv "631"  "CUPS (printing)"
  kv "5353" "mDNS (local name discovery)"
  printf '\n'
  note "Only ports on THIS computer are shown. NetScope does not scan other devices."
  printf '\n'
}

lab_handshake() {
  local h="${MODE_ARG:-}" host port out rc dns tcp tls ttfb total
  local dns_ms tcp_ms tls_ms ttfb_ms total_ms d_tcp d_tls d_ttfb
  [[ -z "$h" ]] && { echo "--handshake needs a host, e.g. --handshake example.com" >&2; exit 2; }
  h="${h#https://}"; h="${h%%/*}"
  host="${h%%:*}"; port=443; [[ "$h" == *:* ]] && port="${h##*:}"
  [[ "$host" =~ ^[A-Za-z0-9._-]+$ && "$port" =~ ^[0-9]{1,5}$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 )) || { echo "Please give a host such as example.com or example.com:443" >&2; exit 2; }
  have curl || { echo "--handshake needs 'curl'." >&2; exit 1; }
  section "TCP + TLS HANDSHAKE: $host:$port"
  wrap "Before any page content arrives, your computer and the server perform a two-stage conversation. First a TCP three-way handshake establishes a reliable stream. Then a TLS handshake negotiates encryption and proves the server's identity with a certificate."
  printf '\n'
  out="$(curl -sS -o /dev/null --max-time 15 -w '%{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total}' "https://$host:$port/" 2>/dev/null)"; rc=$?
  if (( rc != 0 )) || [[ -z "$out" ]]; then
    note "The connection to $host:$port did not complete (curl exit status $rc: 6 = name not found, 7 = refused, 28 = timed out, 35/60 = TLS problem)."
    printf '\n'; return 1
  fi
  read -r dns tcp tls ttfb total <<<"$out"
  dns_ms="$(to_ms "$dns")"; tcp_ms="$(to_ms "$tcp")"; tls_ms="$(to_ms "$tls")"; ttfb_ms="$(to_ms "$ttfb")"; total_ms="$(to_ms "$total")"
  sub "Timeline (cumulative, in ms)"
  printf '  %s  0%s DNS lookup start\n' "$GRAY" "$RESET"
  printf '  %s%3s%s DNS answer received          %s(dns)%s\n' "$CYAN" "$dns_ms" "$RESET" "$GRAY" "$RESET"
  printf '  %s%3s%s TCP connect done (SYN/ACK)    %s(tcp)%s\n' "$GREEN" "$tcp_ms" "$RESET" "$GRAY" "$RESET"
  printf '  %s%3s%s TLS handshake done           %s(tls)%s\n' "$GREEN" "$tls_ms" "$RESET" "$GRAY" "$RESET"
  printf '  %s%3s%s First byte of HTTP reply      %s(http)%s\n' "$MAGENTA" "$ttfb_ms" "$RESET" "$GRAY" "$RESET"
  printf '  %s%3s%s Connection closed            %s(end)%s\n' "$GRAY" "$total_ms" "$RESET" "$GRAY" "$RESET"
  printf '\n'
  d_tcp=$(( tcp_ms - dns_ms ));     (( d_tcp  < 0 )) && d_tcp=0
  d_tls=$(( tls_ms - tcp_ms ));     (( d_tls  < 0 )) && d_tls=0
  d_ttfb=$(( ttfb_ms - tls_ms ));   (( d_ttfb < 0 )) && d_ttfb=0
  sub "Durations"
  kv "DNS lookup"    "${dns_ms} ms"
  kv "TCP handshake" "${d_tcp} ms  (three-way, roughly one round-trip)"
  kv "TLS handshake" "${d_tls} ms  (certificate + key exchange)"
  kv "Server think"  "${d_ttfb} ms  (server prepares the reply)"
  printf '\n'
  wrap "DNS is often cached, so it can be near zero. The TCP handshake is one round-trip time. TLS adds another round trip and certificate verification." "$DIM"
  printf '\n'
}

lab_nat() {
  section "NAT: HOW YOUR PRIVATE ADDRESS REACHES THE INTERNET"
  wrap "Your computer has a private IPv4 address. Your router also has a private one (on the home side) and a public one (on the provider side). When you send a packet out, the router rewrites the SOURCE address to its public one and remembers which connection it belongs to. Replies are reversed so they find their way back to you."
  printf '\n'
  have ip || { echo "NetScope needs the 'ip' command (package: iproute2)." >&2; exit 1; }
  LAN_IF=""; IFACE=""; GATEWAY=""
  detect_network
  local my_addr my_int pub pub_int
  my_addr="$(first_cidr "${LAN_IF:-$IFACE}")"
  sub "Your side"
  kv "Your address" "${my_addr:-not found}"
  if [[ -n "$my_addr" ]]; then
    my_int="$(ip2int "${my_addr%/*}" 2>/dev/null)"
    [[ -n "$my_int" ]] && kv "Address type" "$(ip_kind "$my_int")"
  fi
  kv "Your gateway" "${GATEWAY:-not found}"
  printf '\n'
  if ! have curl; then
    note "The public-address lookup needs 'curl'."
    printf '\n'; return 0
  fi
  pub="$(curl -4 -sS --max-time 6 "https://www.cloudflare.com/cdn-cgi/trace" 2>/dev/null | sed -n 's/^ip=//p' | head -n1)"
  if [[ -z "$pub" ]]; then
    note "Could not read the public address from Cloudflare's trace endpoint."
    printf '\n'; return 0
  fi
  pub_int="$(ip2int "$pub" 2>/dev/null)"
  sub "The outside view"
  kv "Your public address" "$pub"
  [[ -n "$pub_int" ]] && kv "Public address type" "$(ip_kind "$pub_int")"
  printf '\n'
  sub "Interpretation"
  if [[ -z "$my_addr" ]]; then
    note "No local IPv4 address was found, so the two cannot be compared."
  elif [[ "${my_addr%/*}" == "$pub" ]]; then
    printf '  %sYour address is the public one.%s No NAT between your computer and the internet on this path.\n' "$GREEN" "$RESET"
  else
    printf '  %sYour address differs from the public one.%s Something on the way (usually your router) translates between them (NAT).\n' "$GREEN" "$RESET"
    printf '\n'
    wrap "How many NAT layers there are cannot be told from this computer: it only sees its own address and the final public one. Compare with your router's WAN address (in its admin page): if that is private or in 100.64.0.0/10, there is a second NAT (double NAT or carrier-grade NAT); if it equals $pub, there is only one." "$DIM"
  fi
  printf '\n'
  wrap "Try it yourself:  curl https://www.cloudflare.com/cdn-cgi/trace    ip route    ip neigh" "$DIM"
  printf '\n'
}

lab_dhcp() {
  section "DHCP: HOW YOUR COMPUTER GOT ITS ADDRESS"
  wrap "DHCP is a four-step conversation. Discover: your computer broadcasts 'is there a DHCP server?'. Offer: the server offers an address. Request: your computer asks for that specific one. Acknowledge: the server confirms the address, the lease duration, the gateway and DNS servers."
  printf '\n'
  have ip || { echo "NetScope needs the 'ip' command (package: iproute2)." >&2; exit 1; }
  LAN_IF=""; IFACE=""; GATEWAY=""
  detect_network
  local my_addr dns_list lease_file=""
  my_addr="$(first_cidr "${LAN_IF:-$IFACE}")"
  dns_list="$(get_dns_servers 2>/dev/null | tr '\n' ' ')"
  sub "Your current address"
  kv "Address"     "${my_addr:--}"
  kv "Gateway"     "${GATEWAY:--}"
  kv "DNS servers" "${dns_list:-unknown}"
  printf '\n'
  for lease_file in \
    /var/lib/NetworkManager/*.lease \
    /var/lib/NetworkManager/dhclient-*.lease \
    /var/lib/dhcp/dhclient*.leases; do
    [[ -r "$lease_file" ]] && break
  done
  if [[ -r "${lease_file:-/nonexistent}" ]]; then
    sub "From the lease file: $lease_file"
    awk '/^(interface|fixed-address|option subnet-mask|option routers|option domain-name-servers|option dhcp-lease-time|option dhcp-server-identifier|renew |rebind |expire )/ { print "  " $0 }' "$lease_file" 2>/dev/null | head -n 20
    printf '\n'
    note "renew / rebind / expire are the times at which the client will renew, give up the lease or expire it."
  else
    note "No readable lease file found. You may be using a static address or a non-standard DHCP client."
    note "Try:  journalctl -u NetworkManager --since today | grep -i dhcp"
  fi
  printf '\n'
  sub "The four steps"
  kv "1. DISCOVER" "broadcast: 'any DHCP server out there?'"
  kv "2. OFFER"    "server: 'I can give you this address for this long'"
  kv "3. REQUEST"  "client: 'I would like that address, please'"
  kv "4. ACK"      "server: 'confirmed, use it'"
  printf '\n'
  note "The whole exchange usually takes under a second. If your address changes on every reboot, DHCP never received a matching lease."
  printf '\n'
}

lab_channels() {
  have ip || { echo "NetScope needs the 'ip' command (package: iproute2)." >&2; exit 1; }
  LAN_IF=""; IFACE=""; GATEWAY=""
  detect_network
  section "WI-FI CHANNEL CONGESTION"
  if [[ "$LAN_TYPE" != wifi ]]; then
    note "This adapter is not Wi-Fi ($LAN_TYPE). Nothing to analyse."
    printf '\n'; return 0
  fi
  if ! have nmcli; then
    note "This needs 'nmcli' (NetworkManager)."
    printf '\n'; return 0
  fi
  wrap "Networks on the same channel (or overlapping channels on 2.4 GHz) compete for airtime. The list below is what your computer saw in its last scan; no new scan is triggered."
  printf '\n'
  local info
  info="$(nmcli -t -f IN-USE,SIGNAL,CHAN,FREQ,SSID device wifi list ifname "$LAN_IF" --rescan no 2>/dev/null)"
  if [[ -z "$info" ]]; then
    note "No Wi-Fi scan data available."
    printf '\n'; return 0
  fi
  local inuse sig chan freq ssid band
  local -A per_chan=()
  printf '  %s%-4s %-4s %-6s %-8s %s%s\n' "$GRAY" "BAND" "CH" "SIG" "IN USE" "SSID" "$RESET"
  while IFS=: read -r inuse sig chan freq ssid; do
    [[ -n "$chan" && "$chan" =~ ^[0-9]+$ ]] || continue
    band="?"; freq="${freq%% *}"
    if [[ "$freq" =~ ^[0-9]+$ ]]; then
      if   (( freq < 3000 )); then band="2.4"
      elif (( freq < 5925 )); then band="5"
      else band="6"; fi
    elif (( chan >= 1 && chan <= 14 )); then band="2.4"
    fi
    per_chan["$band/$chan"]=$(( ${per_chan["$band/$chan"]:-0} + 1 ))
    printf '  %-4s %-4s %-6s %-8s %s\n' "$band" "$chan" "${sig:--}" "${inuse:-(other)}" "${ssid:-(hidden)}"
  done <<<"$info"
  printf '\n'
  sub "Networks per channel"
  local k
  for k in "${!per_chan[@]}"; do
    printf '%d\t%s\n' "${per_chan[$k]}" "$k"
  done | sort -k1,1nr -k2,2 | head -n 12 | while IFS=$'\t' read -r n k; do
    printf '  %-8s %d network(s)\n' "$k" "$n"
  done
  printf '\n'
  wrap "If your own channel is crowded, switching your router to a quieter channel (1, 6 or 11 on 2.4 GHz) usually helps. On 5 GHz the channels are mostly independent and there is far more room." "$DIM"
  printf '\n'
}

lab_topology() {
  have ip || { echo "NetScope needs the 'ip' command (package: iproute2)." >&2; exit 1; }
  local dest="${MODE_ARG:-8.8.8.8}"
  LAN_IF=""; IFACE=""; GATEWAY=""
  detect_network
  section "TOPOLOGY: YOUR PATH TO $dest"
  wrap "A labelled diagram. Solid lines are what your computer knows directly. The routers were found with tracepath."
  printf '\n'
  local my_addr my_mac gw_mac
  my_addr="$(first_cidr "${LAN_IF:-$IFACE}")"
  my_mac="$(rd "$NETSYS/${LAN_IF:-none}/address")"
  gw_mac=""
  [[ -n "$GATEWAY" ]] && gw_mac="$(ip neigh show "$GATEWAY" 2>/dev/null | awk '{ for(i=1;i<=NF;i++) if($i=="lladdr"){print $(i+1); exit} }')"

  local router_count=0
  local -a HOPS=()
  if have tracepath; then
    mapfile -t HOPS < <(timeout 25 tracepath -n -m 15 "$dest" 2>/dev/null | walk_parse | awk '{ print $1, $2 }')
    router_count=${#HOPS[@]}
  fi

  printf '  %s[YOU]%s\n' "$BOLD$GREEN" "$RESET"
  printf '    %-20s %s\n' "interface:" "${LAN_IF:-?}"
  printf '    %-20s %s\n' "IPv4:" "${my_addr:--}"
  printf '    %-20s %s\n' "MAC:" "${my_mac:--}"
  printf '    %s\n' "$G_VERT"
  if [[ -n "$GATEWAY" ]]; then
    printf '    %s%s Local network %s%s\n' "$GRAY" "$G_H" "$(rep "$G_H" 20)" "$RESET"
    printf '    %s\n' "$G_VERT"
    printf '  %s[ROUTER / GATEWAY]%s\n' "$BOLD$CYAN" "$RESET"
    printf '    %-20s %s\n' "address:" "$GATEWAY"
    printf '    %-20s %s\n' "MAC:" "${gw_mac:--}"
    printf '    %s\n' "$G_VERT"
  fi
  if (( router_count > 0 )); then
    local i h hn
    for (( i=0; i<router_count; i++ )); do
      read -r hn h <<<"${HOPS[$i]}"
      [[ "$h" == "$GATEWAY" || "$h" == "$dest" ]] && continue
      [[ "$h" == "?" ]] && h="(no reply)"
      printf '  %s[HOP %d]%s  %s\n' "$BOLD$YELLOW" "$hn" "$RESET" "$h"
      printf '    %s\n' "$G_VERT"
    done
  fi
  printf '  %s[DESTINATION]%s\n' "$BOLD$MAGENTA" "$RESET"
  printf '    %-20s %s\n' "address:" "$dest"
  printf '\n'
  note "Routers that hide themselves would not appear above. That is normal."
  printf '\n'
}

lab_quiz() {
  local q_score=0 q_total=0 answer correct
  LAN_IF=""; IFACE=""; GATEWAY=""
  detect_network
  local my_addr my_pfx my_int mask net hosts
  my_addr="$(first_cidr "${LAN_IF:-$IFACE}")"
  [[ -z "$my_addr" ]] && { echo "No IPv4 address found." >&2; exit 1; }
  my_pfx="${my_addr#*/}"
  my_int="$(ip2int "${my_addr%/*}")"
  if (( my_pfx == 0 )); then mask=0; else mask=$(( (0xFFFFFFFF << (32 - my_pfx)) & 0xFFFFFFFF )); fi
  net=$(( my_int & mask ))

  section "NETSCOPE QUIZ"
  wrap "Five quick questions about your own network. Answers are computed from what NetScope sees; you just have to say them."
  if (( ! INTERACTIVE )); then
    note "Run interactively (in a terminal) to answer the questions. Right now showing the answers."
    kv "Q1 Your IPv4 address" "${my_addr%/*}"
    kv "Q2 Your network address" "$(int2ip "$net")/$my_pfx"
    kv "Q3 Your gateway" "${GATEWAY:-none}"
    if (( my_pfx == 32 )); then hosts=1; elif (( my_pfx == 31 )); then hosts=2
    else hosts=$(( (1 << (32 - my_pfx)) - 2 )); fi
    kv "Q4 Usable hosts in subnet" "$hosts"
    kv "Q5 Your subnet mask" "$(int2ip "$mask")"
    printf '\n'; return 0
  fi

  printf '\n  %sQ1.%s What is your IPv4 address (without prefix)?\n  > ' "$BOLD" "$RESET"
  read -r answer; q_total=$((q_total+1)); correct="${my_addr%/*}"
  if [[ "$answer" == "$correct" ]]; then printf '  %s✓ correct%s\n' "$GREEN" "$RESET"; q_score=$((q_score+1))
  else printf '  %s✗ answer: %s%s\n' "$RED" "$correct" "$RESET"; fi

  printf '\n  %sQ2.%s What is your network address (with prefix)?\n  > ' "$BOLD" "$RESET"
  read -r answer; q_total=$((q_total+1)); correct="$(int2ip "$net")/$my_pfx"
  if [[ "$answer" == "$correct" ]]; then printf '  %s✓ correct%s\n' "$GREEN" "$RESET"; q_score=$((q_score+1))
  else printf '  %s✗ answer: %s%s\n' "$RED" "$correct" "$RESET"; fi

  printf '\n  %sQ3.%s What is your default gateway?\n  > ' "$BOLD" "$RESET"
  read -r answer; q_total=$((q_total+1)); correct="${GATEWAY:-none}"
  if [[ "$answer" == "$correct" ]]; then printf '  %s✓ correct%s\n' "$GREEN" "$RESET"; q_score=$((q_score+1))
  else printf '  %s✗ answer: %s%s\n' "$RED" "$correct" "$RESET"; fi

  printf '\n  %sQ4.%s How many usable host addresses does your subnet have?\n  > ' "$BOLD" "$RESET"
  read -r answer; q_total=$((q_total+1))
  if (( my_pfx == 32 )); then hosts=1; elif (( my_pfx == 31 )); then hosts=2
  else hosts=$(( (1 << (32 - my_pfx)) - 2 )); fi
  correct="$hosts"
  if [[ "$answer" == "$correct" ]]; then printf '  %s✓ correct%s\n' "$GREEN" "$RESET"; q_score=$((q_score+1))
  else printf '  %s✗ answer: %s%s\n' "$RED" "$correct" "$RESET"; fi

  printf '\n  %sQ5.%s What is your subnet mask?\n  > ' "$BOLD" "$RESET"
  read -r answer; q_total=$((q_total+1)); correct="$(int2ip "$mask")"
  if [[ "$answer" == "$correct" ]]; then printf '  %s✓ correct%s\n' "$GREEN" "$RESET"; q_score=$((q_score+1))
  else printf '  %s✗ answer: %s%s\n' "$RED" "$correct" "$RESET"; fi

  printf '\n  %sScore: %d / %d%s\n\n' "$BOLD" "$q_score" "$q_total" "$RESET"
}

lab_course() {
  section "COURSE MAP"
  wrap "Each row is a networking topic and the NetScope command that demonstrates it on YOUR network."
  printf '\n'
  printf '  %s%-24s %-34s%s\n' "$BOLD" "TOPIC" "COMMAND" "$RESET"
  printf '  %s\n' "$(rep "$G_H" 60)"
  local rows=(
    "OSI model|netscope --osi"
    "Subnetting|netscope --subnet"
    "ARP|netscope --arp"
    "Routing|netscope --routes 8.8.8.8"
    "Packet journey|netscope --walk 8.8.8.8"
    "Ports and services|netscope --ports"
    "TCP + TLS handshake|netscope --handshake example.com"
    "NAT and CGNAT|netscope --nat"
    "DHCP|netscope --dhcp"
    "DNS|netscope --dns example.com"
    "TLS certificates|netscope --tls example.com"
    "MTU / PMTU|netscope --mtu 8.8.8.8"
    "Wi-Fi channels|netscope --channels"
    "Topology|netscope --topology 8.8.8.8"
    "Quiz yourself|netscope --quiz"
    "Glossary|netscope --glossary DNS"
  )
  local r topic cmd
  for r in "${rows[@]}"; do
    topic="${r%|*}"; cmd="${r#*|}"
    printf '  %-24s %s%s%s\n' "$topic" "$CYAN" "$cmd" "$RESET"
  done
  printf '\n'
  note "Start with --osi for the big picture, then --walk for the packet's journey. The rest fill in the details."
  printf '\n'
}

lab_quick() {
  have ip || exit 1
  LAN_IF=""; IFACE=""; GATEWAY=""
  detect_network
  local lat="" loss="" gw_ok=0 pub_ok=0
  if [[ -n "$GATEWAY" ]] && have ping; then
    local gw_out
    gw_out="$(ping -n -c 2 -i 0.2 -W 1 "$GATEWAY" 2>/dev/null)"
    [[ "$gw_out" == *" 0% packet loss"* ]] && gw_ok=1
  fi
  if have ping; then
    local pub_out
    pub_out="$(ping -n -c 3 -i 0.2 -W 1 1.1.1.1 2>/dev/null)"
    lat="$(sed -n 's/.*time=\([0-9.]*\).*/\1/p' <<<"$pub_out" | awk '{ sum+=$1; n++ } END { if (n) printf "%.1f", sum/n }')"
    loss="$(sed -n 's/.* \([0-9]*\)% packet loss.*/\1/p' <<<"$pub_out" | head -n1)"
    [[ -n "$loss" && "$loss" != "100" ]] && pub_ok=1
  fi
  if (( pub_ok )); then
    printf '%sOK%s  %s  loss=%s%%  iface=%s\n' "$GREEN" "$RESET" "$(fmt_ms "${lat:-?}")" "${loss:-?}" "${LAN_IF:-?}"
    exit 0
  elif (( gw_ok )); then
    printf '%sDEGRADED%s  router replies but internet does not\n' "$YELLOW" "$RESET"
    exit 10
  else
    printf '%sFAIL%s  no reply from router or internet\n' "$RED" "$RESET"
    exit 20
  fi
}

lab_history() {
  section "HISTORY (last 20 runs)"
  if [[ ! -r "$HISTORY_FILE" ]]; then
    note "No history yet. Run NetScope normally to start recording."
    printf '\n'; return 0
  fi
  printf '  %s%-22s %3s  %-15s %-10s %-6s %s%s\n' "$GRAY" "WHEN" "SC" "GRADE" "LATENCY" "LOSS" "IFACE" "$RESET"
  local line ts score grade lat loss iface
  while IFS= read -r line; do
    ts="$(sed -n 's/.*"ts":"\([^"]*\)".*/\1/p' <<<"$line")"
    score="$(sed -n 's/.*"score":\([0-9]*\).*/\1/p' <<<"$line")"
    grade="$(sed -n 's/.*"grade":"\([^"]*\)".*/\1/p' <<<"$line")"
    lat="$(sed -n 's/.*"lat_ms":"\([^"]*\)".*/\1/p' <<<"$line")"
    loss="$(sed -n 's/.*"loss":"\([^"]*\)".*/\1/p' <<<"$line")"
    iface="$(sed -n 's/.*"iface":"\([^"]*\)".*/\1/p' <<<"$line")"
    printf '  %-22s %3s  %-15s %-10s %-6s %s\n' "${ts:0:19}" "${score:-?}" "${grade:-?}" "${lat:-?}ms" "${loss:-?}%" "$iface"
  done < <(tail -n 20 "$HISTORY_FILE")
  printf '\n'
  note "History is stored in $HISTORY_FILE. Up to 5000 runs are kept; older entries are trimmed automatically."
  printf '\n'
}

lab_compare() {
  local n="${MODE_ARG:-5}"
  section "COMPARE (last $n runs)"
  if [[ ! -r "$HISTORY_FILE" ]]; then
    note "No history yet. Run NetScope normally to start recording."
    printf '\n'; return 0
  fi
  if ! [[ "$n" =~ ^[0-9]+$ ]] || (( n < 1 )); then n=5; fi
  local -a SCORES=() LATS=() LOSSES=() TS=()
  local line
  while IFS= read -r line; do
    SCORES+=("$(sed -n 's/.*"score":\([0-9]*\).*/\1/p' <<<"$line")")
    LATS+=("$(sed -n 's/.*"lat_ms":"\([^"]*\)".*/\1/p' <<<"$line")")
    LOSSES+=("$(sed -n 's/.*"loss":"\([^"]*\)".*/\1/p' <<<"$line")")
    TS+=("$(sed -n 's/.*"ts":"\([^"]*\)".*/\1/p' <<<"$line")")
  done < <(tail -n "$n" "$HISTORY_FILE")
  printf '  %s%3s  %-22s  %-10s  %-10s  %-10s%s\n' "$GRAY" "#" "WHEN" "SCORE" "LATENCY" "LOSS" "$RESET"
  local i
  for i in "${!SCORES[@]}"; do
    printf '  %3d  %-22s  %-10s  %-10s  %-10s\n' "$((i+1))" "${TS[$i]:0:19}" "${SCORES[$i]}" "${LATS[$i]:-?} ms" "${LOSSES[$i]:-?}%"
  done
  if (( ${#SCORES[@]} >= 2 )); then
    local first="${SCORES[0]}" last="${SCORES[${#SCORES[@]}-1]}"
    local diff=$(( last - first ))
    printf '\n'
    if (( diff > 0 )); then printf '  %s↑ improved by %d points since run 1%s\n' "$GREEN" "$diff" "$RESET"
    elif (( diff < 0 )); then printf '  %s↓ dropped by %d points since run 1%s\n' "$RED" "$((-diff))" "$RESET"
    else printf '  %s→ unchanged%s\n' "$GRAY" "$RESET"; fi
  fi
  printf '\n'
}

render_report_to() {
  local file="$1"
  local dir; dir="$(dirname "$file")"
  [[ -d "$dir" ]] || { printf 'Directory does not exist: %s\n' "$dir" >&2; return 1; }
  local i words=("Not working" "Struggling" "Poor" "OK" "Good" "Great")
  {
    printf '# NetScope report — %s\n\n' "$(date -Is 2>/dev/null)"
    printf 'Generated by NetScope %s on %s.\n\n' "$VERSION" "$(date '+%Y-%m-%d %H:%M %Z')"
    printf 'This report is sanitised: MAC addresses, BSSIDs and the public IP are not included.\n\n'
    printf '## Summary\n\n'
    printf '| Item | Value |\n|---|---|\n'
    printf '| Score | %d / 100 |\n' "$SCORE"
    printf '| Grade | %s |\n' "$GRADE"
    printf '| Verdict | %s |\n' "$VERDICT"
    printf '| Diagnosis | %s |\n' "$DIAG"
    printf '| Internet | %s |\n' "$INTERNET"
    printf '| Latency | %s ms |\n' "${LAT_MS:--}"
    printf '| Jitter | %s ms |\n' "${JIT_MS:--}"
    printf '| Packet loss | %s%% |\n' "${LOSS_PCT:--}"
    printf '| DNS lookups | %d / %d ok |\n' "$DNS_OKN" "$DNS_TOTAL"
    printf '| DNS average | %d ms |\n' "$DNS_AVG"
    printf '| IPv6 | %s |\n' "$( (( IPV6_OK )) && echo reachable || echo 'not reachable')"
    printf '| Captive portal | %s |\n' "$( (( PORTAL )) && echo 'likely' || echo 'no')"
    printf '\n## Journey\n\n'
    printf '| Layer | State | Notes |\n|---|---|---|\n'
    printf '| You | %s | |\n' "${N_STATE[1]}"
    printf '| Link (%s) | %s | %s |\n' "$LAN_TYPE" "${N_STATE[2]}" "${N_WORD[2]}"
    printf '| Router | %s | %s |\n' "${N_STATE[3]}" "${N_WORD[3]}"
    printf '| Internet | %s | %s |\n' "${N_STATE[4]}" "${N_WORD[4]}"
    printf '| Websites | %s | %s |\n' "${N_STATE[5]}" "${N_WORD[5]}"
    printf '\n## Interface\n\n'
    printf -- '- Name: %s\n' "${LAN_IF:--}"
    printf -- '- Type: %s\n' "${LAN_TYPE:--}"
    printf -- '- IPv4: %s\n' "${ADDR4:--}"
    if [[ "$LAN_TYPE" == wifi ]]; then
      printf -- '- SSID: %s\n' "${WIFI_SSID:-(hidden)}"
      printf -- '- Band: %s\n' "${WIFI_BAND:--}"
      printf -- '- Channel: %s\n' "${WIFI_CHAN:--}"
      printf -- '- Signal: %s dBm\n' "${WIFI_SIGNAL:--}"
    fi
    printf '\n## Activities\n\n'
    for i in 0 1 2 3; do
      printf -- '- %s: %s\n' "${ACT_NAMES[i]}" "${words[ACT_STARS[i]]}"
    done
    printf '\n## If something is wrong\n\n'
    if (( ${#TIPS[@]} > 0 )); then
      for i in "${!TIPS[@]}"; do printf '%d. %s\n' "$((i+1))" "${TIPS[$i]}"; done
    else
      printf 'No issues detected.\n'
    fi
    printf '\n## Notes\n\n'
    printf 'This report was produced by a quick local check-up, not an official speed rating. '
    printf 'MAC addresses, BSSIDs and the public IP are left out. The Wi-Fi name, your private IPv4 address and the diagnosis text are included, so read it before sharing.\n'
  } > "$file" 2>/dev/null || { printf 'Cannot write to %s\n' "$file" >&2; return 1; }
  printf '\n  %sSaved sanitised report to %s%s\n\n' "$GREEN" "$file" "$RESET"
}

run_lab() {
  case "$MODE" in
    walk)      lab_walk ;;
    subnet)    lab_subnet ;;
    glossary)  lab_glossary ;;
    dns)       lab_dns ;;
    tls)       lab_tls ;;
    mtu)       lab_mtu ;;
    arp)       lab_arp ;;
    routes)    lab_routes ;;
    ports)     lab_ports ;;
    handshake) lab_handshake ;;
    nat)       lab_nat ;;
    dhcp)      lab_dhcp ;;
    channels)  lab_channels ;;
    topology)  lab_topology ;;
    quiz)      lab_quiz ;;
    course)    lab_course ;;
    quick)     lab_quick ;;
    history)   lab_history ;;
    compare)   lab_compare ;;
  esac
  exit 0
}

finish() {
  if   (( SCORE >= 75 )); then exit 0
  elif (( SCORE >= 55 )); then exit 10
  else exit 20; fi
}

main() {
  local t_start t_end do_adv key=""

  (( LIVE )) && live_mode
  [[ -n "$MODE" ]] && run_lab

  if ! have ip; then
    (( JSON )) || banner
    printf '  The "ip" command is missing (normally provided by the iproute2 package).\n' >&2
    printf '  Install it with:  sudo apt install iproute2   and run NetScope again.\n\n' >&2
    exit 1
  fi
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/netscope.XXXXXX")" || { echo "Cannot create a temporary folder." >&2; exit 1; }
  t_start="$(now_ms)"

  (( JSON )) || banner
  detect_network
  wifi_gather
  read -r CNT0_E CNT0_D _ <<<"$(read_counters)"
  start_basic_jobs
  wait_jobs "Scanning your network"
  if (( SPEED )); then
    if have curl && have ping; then start_speed_job; wait_jobs "Measuring speed (about 15 seconds)"
    else printf '  Speed test skipped: it needs both curl and ping.\n' >&2; fi
  fi
  evaluate
  save_history
  t_end="$(now_ms)"

  if (( JSON )); then
    render_json
    finish
  fi

  if [[ -n "$REPORT_FILE" ]]; then
    render_report_to "$REPORT_FILE"
    finish
  fi

  printf '  %s%s%s Scan complete in %s seconds.\n' "$GREEN" "$G_OK" "$RESET" "$(awk -v a="$t_start" -v b="$t_end" 'BEGIN { printf "%.1f", (b - a) / 1000 }')"

  render_basic
  (( LEARN )) && render_learn
  (( OSI )) && render_osi

  do_adv="$ADVANCED"
  if (( ! do_adv && PROMPT )); then
    printf '\n  %sPress %sA%s%s for advanced technical details, or %sEnter%s%s to finish:%s ' "$DIM" "$BOLD$CYAN" "$RESET" "$DIM" "$BOLD" "$RESET" "$DIM" "$RESET"
    read -rsn1 key || key=""
    printf '\n'
    [[ "$key" == [Aa] ]] && do_adv=1
  fi
  if (( do_adv )); then
    start_advanced_jobs
    if (( ${#JOB_PIDS[@]} > 0 )); then printf '\n'; wait_jobs "Running deeper checks (up to ~12 s)"; fi
    render_advanced
  fi

  printf '\n  %sNetScope %s%s' "$DIM" "$VERSION" "$RESET"
  if (( ! do_adv && ! PROMPT )); then printf '%s  %s  use --advanced for the technical view%s' "$DIM" "$G_MID" "$RESET"; fi
  (( SPEED )) || printf '%s  %s  --speed measures download/upload%s' "$DIM" "$G_MID" "$RESET"
  (( LEARN )) || printf '%s  %s  --learn explains each step%s' "$DIM" "$G_MID" "$RESET"
  printf '%s  %s  --walk DEST follows a packet%s' "$DIM" "$G_MID" "$RESET"
  printf '%s  %s  --live for a live monitor%s\n\n' "$DIM" "$G_MID" "$RESET"
  finish
}

main
