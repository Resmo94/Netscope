#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
#  NetScope 2.1 — a friendly network health console for Linux Mint
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
#  Run  ./netscope.sh --help  to see all options.
#
#  What's new in 2.1
#   - Wi-Fi signal / link rate fall back to NetworkManager and iwconfig, so
#     drivers that hide them from `iw` (e.g. Broadcom "wl") no longer show n/a.
#   - Error counters now include CRC errors and drops, and the report tells you
#     whether they grew during the scan (old totals no longer cost points).
#   - Direct DNS test uses dig's own query time (no process start-up noise).
#   - --json output and meaningful exit codes for use in other scripts.
# ──────────────────────────────────────────────────────────────────────────────

set -u

VERSION="2.1"

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  echo "NetScope needs bash 4.4 or newer." >&2
  exit 1
fi

# ── Locale ────────────────────────────────────────────────────────────────────
# Keep the user's character set (so symbols draw correctly) but force English
# messages and "." decimals so that parsing ping/curl/iw output is reliable on
# any system language.
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) UTF8=1 ;;
  *) UTF8=0 ;;
esac
if [[ -n "${LC_ALL:-}" ]]; then export LC_CTYPE="$LC_ALL"; unset LC_ALL; fi
export LC_MESSAGES=C LC_NUMERIC=C LANGUAGE=C

# Paths (overridable only so the script can be tested against a fake system).
NETSYS="${NETSCOPE_SYS:-/sys/class/net}"
PROCNET="${NETSCOPE_PROC:-/proc/net}"

usage() {
  cat <<'USAGE'
NetScope - a friendly network health console

  ./netscope.sh               Simple health report (then offers advanced details)
  ./netscope.sh --advanced    Simple report + every technical statistic
  ./netscope.sh --speed       Also measure download / upload speed (see note below)
  ./netscope.sh --live        Live monitor with moving graphs (press q to quit)
  ./netscope.sh --json        Print the results as JSON (no colours, no questions)
  ./netscope.sh --no-color    Turn colours off
  ./netscope.sh --ascii       Use plain ASCII instead of special symbols
  ./netscope.sh --no-prompt   Never ask questions (useful in scripts)
  ./netscope.sh --version     Show the version
  ./netscope.sh --help        Show this help

EXIT STATUS
  0  healthy (score 75 or more)      10  needs attention (55 - 74)
  20 poor (below 55)                  1  NetScope could not run
  2  bad command-line option

WHAT IT CHECKS
  Network adapter, Wi-Fi / cable link, IP address, router, internet access,
  website-name lookups (DNS), delay, lost data, stability, sign-in pages,
  IPv6, live traffic, error counters, routing and more.

SAFETY
  Read-only. It changes no settings, installs nothing and needs no sudo.
  It does not scan other devices or probe open ports.

WHO IT TALKS TO
  Your router and 1.1.1.1 / 8.8.8.8 (ping) - cloudflare.com (web test) -
  connectivity-check.ubuntu.com (sign-in page test) - a few popular domains
  (DNS timing). With --speed it also downloads and uploads test data from
  speed.cloudflare.com (up to ~130 MB on very fast connections, far less on
  slow ones).
USAGE
}

# ── Options ───────────────────────────────────────────────────────────────────
ADVANCED=0; PROMPT=1; SPEED=0; LIVE=0; JSON=0; OPT_NOCOLOR=0; OPT_ASCII=0
for arg in "$@"; do
  case "$arg" in
    -a|--advanced)          ADVANCED=1 ;;
    -s|--speed)             SPEED=1 ;;
    -l|--live)              LIVE=1 ;;
    -j|--json)              JSON=1 ;;
    -n|--no-prompt)         PROMPT=0 ;;
    --no-color|--no-colour) OPT_NOCOLOR=1 ;;
    --ascii)                OPT_ASCII=1 ;;
    -V|--version)           echo "NetScope $VERSION"; exit 0 ;;
    -h|--help)              usage; exit 0 ;;
    *) printf 'Unknown option: %s\n\n' "$arg" >&2; usage >&2; exit 2 ;;
  esac
done

# ── Terminal capabilities ─────────────────────────────────────────────────────
IS_TTY=0;      [[ -t 1 ]] && IS_TTY=1
INTERACTIVE=0; [[ -t 0 && -t 1 ]] && INTERACTIVE=1
(( INTERACTIVE )) || PROMPT=0

ANIMATE=0
if (( IS_TTY )) && [[ "${TERM:-dumb}" != dumb ]]; then ANIMATE=1; fi
if (( JSON )); then ANIMATE=0; PROMPT=0; ADVANCED=0; fi

USE_COLOR=1
(( OPT_NOCOLOR )) && USE_COLOR=0
if (( ! IS_TTY )) || [[ "${TERM:-dumb}" == dumb ]]; then
  USE_COLOR=0
  UTF8=0
fi
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
GRAD=("$RED" "$ORANGE" "$YELLOW" "$LGREEN" "$GREEN")   # score-bar gradient

HIDE_CUR=''; SHOW_CUR=''; CLR_LINE=''; ALT_ON=''; ALT_OFF=''
if (( ANIMATE )); then
  HIDE_CUR=$'\033[?25l'; SHOW_CUR=$'\033[?25h'; CLR_LINE=$'\r\033[K'
  ALT_ON=$'\033[?1049h'; ALT_OFF=$'\033[?1049l'
fi

# ── Symbols (Unicode when the terminal supports it, ASCII otherwise) ─────────
if (( UTF8 )); then
  G_H='─'; G_HB='━'; G_HX='╌'; G_V='┃'; G_OK='✓'; G_FAIL='✗'; G_WARN='!'; G_INFO='•'
  G_DOT='●'; G_RING='○'; G_ON='█'; G_OFF='░'; G_STAR='★'; G_STAR0='☆'
  G_DOWN='↓'; G_UP='↑'; G_LOST='×'; G_ARROW='▸'; G_MID='·'; G_WAVE='((•))'
  SPARK_GLYPHS='▁ ▂ ▃ ▄ ▅ ▆ ▇ █'
  SPIN=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
else
  G_H='-'; G_HB='='; G_HX='.'; G_V='|'; G_OK='+'; G_FAIL='x'; G_WARN='!'; G_INFO='*'
  G_DOT='O'; G_RING='o'; G_ON='#'; G_OFF='.'; G_STAR='*'; G_STAR0='-'
  G_DOWN='v'; G_UP='^'; G_LOST='x'; G_ARROW='>'; G_MID='-'; G_WAVE='((o))'
  SPARK_GLYPHS='. : - = + * # @'
  SPIN=('|' '/' '-' '\')
fi

# ── Small helpers ─────────────────────────────────────────────────────────────
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
fmt_rate() {   # bytes per second -> bits per second, human friendly
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

ctr() {   # centre plain text in a field of width $2
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

# ── Temp dir, background jobs, clean-up ───────────────────────────────────────
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

spawn() {   # spawn "friendly name" function args...
  local name="$1"; shift
  local id=$(( ++JOB_SEQ ))
  JOB_NAMES+=("$name"); JOB_IDS+=("$id")
  ( "$@"; : > "$TMP/.done.$id" ) >/dev/null 2>&1 &
  JOB_PIDS+=("$!")
}
begin_phase() { JOB_PIDS=(); JOB_NAMES=(); JOB_IDS=(); }

wait_jobs() {   # animated progress while background jobs finish
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
' _   _ _____ _____ ____   ____   ____  ____  _____'
'| \ | | ____|_   _/ ___| / ___| / ___||  _ \| ____|'
'|  \| |  _|   | | \___ \| |     \___ \| |_) |  _|'
'| |\  | |___  | |  ___) | |___   ___) |  __/| |___'
'|_| \_|_____| |_| |____/ \____| |____/|_|   |_____|')
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
#  DETECTION — which interface, router, Wi-Fi details (instant, local only)
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

find_physical() {   # find_physical [up|any] -> first real adapter
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
  if [[ -z "$VPN_IF" ]]; then   # a VPN may be up without owning the default route
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

# Reads error / drop / packet totals for the active adapter: prints "errors drops packets".
# errors = the larger of rx_errors and rx_crc_errors (some drivers count CRC separately,
#          others include it) + tx_errors.
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
  # `iw` can be missing, or the driver (e.g. Broadcom "wl") may not speak nl80211.
  # Trust the kernel's link state in that case and look for the details elsewhere.
  if (( ! WIFI_CONNECTED )) && [[ "$st" == up ]]; then
    if ! have iw || ! iw dev "$LAN_IF" info >/dev/null 2>&1; then WIFI_CONNECTED=1; fi
  fi
  if (( WIFI_CONNECTED )); then
    # 1) /proc/net/wireless
    if [[ -z "$WIFI_SIGNAL" && -r "$PROCNET/wireless" ]]; then
      lvl="$(awk -v i="$LAN_IF:" '$1 == i { gsub(/\./, "", $4); print $4; exit }' "$PROCNET/wireless")"
      [[ "$lvl" =~ ^-[0-9]+$ ]] && WIFI_SIGNAL="$lvl"
    fi
    # 2) iwconfig (wireless-tools; works with legacy "wext" drivers)
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
    # 3) NetworkManager's cached scan list: never forces a rescan.
    #    Variable-length SSID goes last so ':' inside it cannot shift the other fields.
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
      # NetworkManager only gives a 0-100 quality figure; estimate dBm from it so the
      # signal can still be judged (quality = 2 x (dBm + 100)).
      if [[ -z "$WIFI_SIGNAL" && "$WIFI_QUAL" =~ ^[0-9]+$ ]]; then
        WIFI_SIGNAL=$(( WIFI_QUAL / 2 - 100 )); WIFI_SIG_EST=1
      fi
    fi
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  PROBE JOBS — each runs in the background and writes its raw output to $TMP
# ══════════════════════════════════════════════════════════════════════════════
PING_COUNT=20
DNS_DOMAINS=(example.com www.wikipedia.org www.cloudflare.com ubuntu.com)
CURL_FMT='NS_TIMING dns=%{time_namelookup} connect=%{time_connect} tls=%{time_appconnect} ttfb=%{time_starttransfer} total=%{time_total} code=%{http_code} ip=%{remote_ip} ver=%{http_version}\n'
TRACE_URL="https://www.cloudflare.com/cdn-cgi/trace"

job_ping() {   # key target
  local opts=(-n -c "$PING_COUNT" -i 0.2 -W 1 -w 9)
  [[ "$2" == *:* ]] && opts+=(-6 -I "${LAN_IF:-$IFACE}")
  ping "${opts[@]}" "$2" > "$TMP/ping_$1.txt" 2>&1
}

job_dns() {   # looks up several names in parallel using the system resolver
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

curl_probe() {   # prefix connect-timeout max-time [curl args...] url
  local p="$1" ct="$2" mt="$3"; shift 3
  curl -sS --connect-timeout "$ct" --max-time "$mt" -A "NetScope/$VERSION" \
       -o "$TMP/$p.body" -w "$CURL_FMT" "$@" > "$TMP/$p.timing" 2> "$TMP/$p.err"
  printf '%s\n' "$?" > "$TMP/$p.rc"
}

job_http() {   # normal HTTPS test; if it fails, retry by IP to separate "DNS broken" from "offline"
  curl_probe http 4 7 "$TRACE_URL"
  if [[ "$(<"$TMP/http.rc")" != 0 ]]; then
    curl_probe http_ip 3 5 --resolve one.one.one.one:443:1.1.1.1 https://one.one.one.one/cdn-cgi/trace
  fi
}
job_ipv6() { curl_probe v6 3 5 -6 "$TRACE_URL"; }
job_portal() {   # Ubuntu/Mint's own "am I behind a sign-in page?" test (expects HTTP 204)
  local code
  code="$(curl -sS -o /dev/null --connect-timeout 3 --max-time 5 -w '%{http_code}' http://connectivity-check.ubuntu.com/ 2>/dev/null)"
  printf '%s' "${code:-000}" > "$TMP/portal.code"
}

job_traffic() {   # 4 one-second samples of the interface byte counters
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

# ── Deeper checks (advanced view only) ───────────────────────────────────────
dns_query() {   # server name  (fallback when dig is not installed)
  if have host; then timeout 4 host -W 2 -t A "$2" "$1" | grep -i 'has address'
  else return 127; fi
}
job_dns_direct() {
  local srv t0 out rc q
  : > "$TMP/dns_direct.txt"
  for srv in "$@"; do
    t0="$(now_ms)"; q=""
    if have dig; then
      # dig reports its own query time, which excludes process start-up.
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

get_dns_servers() {   # IPv4 DNS servers actually in use (best effort, no root)
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

# ── Speed test (opt-in with --speed) ─────────────────────────────────────────
job_speed() {
  local start b t tms out pp dl_b=0 dl_ms=0 ul_b=0 ul_ms=0 remain
  # latency under load: ping 1.1.1.1 while downloading
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
#  PARSERS — turn raw job output into numbers
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
ping_parse() {   # key file -> PG[key.sent|recv|loss|min|avg|max|jit|spark|n]
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

http_read() {   # prefix -> HR_*
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

snmp_get() {   # Proto Field -> value from /proc/net/snmp
  awk -v p="$1:" -v f="$2" '$1 == p { if (!h) { for (i = 2; i <= NF; i++) col[$i] = i; h = 1 } else { if (col[f]) print $(col[f]); exit } }' "$PROCNET/snmp" 2>/dev/null
}



# ══════════════════════════════════════════════════════════════════════════════
#  EVALUATION — turn measurements into a score, a journey map and plain advice
# ══════════════════════════════════════════════════════════════════════════════
SCORE=100; PEN=(); TIPS=()
penalize() { SCORE=$(( SCORE - $1 )); PEN+=("$1|$2"); }
add_tip()  { (( ${#TIPS[@]} < 4 )) && TIPS+=("$1"); }

pick_public() {   # choose the public ping target with the best result
  local k best="" bl=0 bv=0
  for k in pub1 pub2; do
    (( ${PG[$k.n]:-0} > 0 )) || continue
    if [[ -z "$best" ]] || awk -v l1="${PG[$k.loss]}" -v a1="${PG[$k.avg]}" -v l0="$bl" -v a0="$bv" 'BEGIN { exit !(l1 < l0 || (l1 == l0 && a1 < a0)) }'; then
      best="$k"; bl="${PG[$k.loss]}"; bv="${PG[$k.avg]}"
    fi
  done
  PUB_KEY="$best"
}

# Activity rating helpers ----------------------------------------------------
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

  # ── measurements ───────────────────────────────────────────────────────────
  ping_parse gw   "$TMP/ping_gw.txt"
  ping_parse pub1 "$TMP/ping_pub1.txt"
  ping_parse pub2 "$TMP/ping_pub2.txt"
  pick_public
  PUB_TARGET=""; [[ "$PUB_KEY" == pub1 ]] && PUB_TARGET=1.1.1.1; [[ "$PUB_KEY" == pub2 ]] && PUB_TARGET=8.8.8.8
  PUB_OK=0; [[ -n "$PUB_KEY" ]] && PUB_OK=1

  # DNS (system resolver)
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

  # Internet reachability (HTTPS)
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
    fi
  elif (( PUB_OK )); then INTERNET=OK; INET_VIA=ping
  fi

  # Sign-in page (captive portal): only relevant if the web test did not succeed
  PORTAL=0; PORTAL_CODE=""
  [[ -f "$TMP/portal.code" ]] && PORTAL_CODE="$(<"$TMP/portal.code")"
  if [[ -n "$PORTAL_CODE" && "$PORTAL_CODE" != 204 && "$PORTAL_CODE" != 000 && "$INTERNET" != OK ]]; then PORTAL=1; fi

  # IPv6
  IPV6_OK=0; IPV6_ADDR=""
  if [[ -f "$TMP/v6.rc" ]]; then
    http_read v6
    if http_ok; then IPV6_OK=1; IPV6_ADDR="$(trace_field v6 ip)"; fi
  fi

  # Latency / jitter / loss to the internet (ping; falls back to TCP connect time)
  LAT_MS=""; JIT_MS=""; LOSS_PCT=""; LAT_SRC=""; PUB_SPARK=""
  if (( PUB_OK )); then
    LAT_MS="${PG[$PUB_KEY.avg]}"; JIT_MS="${PG[$PUB_KEY.jit]}"; LOSS_PCT="${PG[$PUB_KEY.loss]}"
    PUB_SPARK="${PG[$PUB_KEY.spark]}"; LAT_SRC=ping
  elif [[ "$H_CONN" =~ ^[0-9]+$ && "$H_DNS" =~ ^[0-9]+$ ]]; then
    LAT_MS=$(( H_CONN - H_DNS )); (( LAT_MS < 1 )) && LAT_MS=1; LAT_SRC=tcp
  fi
  LAT_I="$(int "$LAT_MS")"; JIT_I="$(int "$JIT_MS")"; LOSS_I="$(int "$LOSS_PCT")"

  # Traffic sample
  RX_AVG=0; TX_AVG=0; RX_SPARK=""; TX_SPARK=""; HAS_TRAFFIC=0
  if [[ -s "$TMP/traffic.txt" ]] && (( $(wc -l < "$TMP/traffic.txt") >= 2 )); then
    read -r RX_AVG TX_AVG RX_SPARK TX_SPARK <<<"$(awk -v glyphs="$SPARK_GLYPHS" "$TRAFFIC_AWK" "$TMP/traffic.txt")"
    [[ "$RX_AVG" =~ ^[0-9]+$ ]] && HAS_TRAFFIC=1
  fi

  # Speed test results (only with --speed)
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

  # Interface errors and drops. Totals are since boot, so we also compare against the
  # values taken just before the scan to see whether anything NEW happened.
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

  # ── node 1: this computer ──────────────────────────────────────────────────
  HAS_IF=0; HAS_IP=0; HAS_ROUTE=0
  [[ -n "$LAN_IF" && -e "$NETSYS/$LAN_IF" ]] && HAS_IF=1
  [[ -n "$DEFAULT_ROUTE" ]] && HAS_ROUTE=1
  OPERSTATE=""; CARRIER=""; ADDR4=""; ADDR6=""
  if (( HAS_IF )); then
    OPERSTATE="$(rd "$NETSYS/$LAN_IF/operstate")"; CARRIER="$(rd "$NETSYS/$LAN_IF/carrier")"
    ADDR4="$(ip -o -4 addr show dev "$LAN_IF" scope global 2>/dev/null | awk '{ print $4; exit }')"
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

    # ── node 2: Wi-Fi / cable ────────────────────────────────────────────────
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

  # ── node 3: router ─────────────────────────────────────────────────────────
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
    N_STATE[3]=OK; N_WORD[3]="Working"; GW_INFERRED=1   # ICMP is blocked, but traffic clearly passes
  else
    N_STATE[3]=FAIL; N_WORD[3]="No answer"; penalize 15 "Router did not answer ping"
  fi

  # ── node 4: internet ───────────────────────────────────────────────────────
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

  # ── node 5: website names (DNS) ────────────────────────────────────────────
  if   (( DNS_TOTAL == 0 ));       then N_STATE[5]=UNK;  N_WORD[5]="Unknown"
  elif (( DNS_OKN == 0 ));         then N_STATE[5]=FAIL; N_WORD[5]="Not working"; penalize 20 "Website names cannot be looked up (DNS)"
  elif (( DNS_OKN < DNS_TOTAL ));  then N_STATE[5]=WARN; N_WORD[5]="Partly";      penalize 8  "Some website-name lookups failed (DNS)"
  elif (( DNS_AVG > 300 ));        then N_STATE[5]=WARN; N_WORD[5]="Slow";        penalize 4  "Website-name lookups are slow (${DNS_AVG} ms)"
  else N_STATE[5]=OK; N_WORD[5]="Working"; fi

  # ── connection quality penalties ───────────────────────────────────────────
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
  # Old counters from hours ago must not lower today's score: only count errors that are
  # still happening (new during this scan) or very frequent drops.
  if (( ERR_NEW > 0 )) && awk -v e="$ERR_PCT" 'BEGIN { exit !(e >= 0.5) }'; then
    penalize 3 "Network adapter keeps reporting errors (${ERR_PCT}% of packets, +${ERR_NEW} during the scan)"
  fi
  awk -v e="$DROP_PCT" 'BEGIN { exit !(e >= 5) }' && (( DROP_NEW > 0 )) && penalize 2 "Network adapter is dropping packets (${DROP_PCT}%)"
  if (( SPEED_RAN )); then
    if   (( DL_I >= 0 && DL_I < 3 ));  then penalize 10 "Download speed is very low (${DL_MBPS} Mbps)"
    elif (( DL_I >= 0 && DL_I < 10 )); then penalize 4  "Download speed is low (${DL_MBPS} Mbps)"; fi
    [[ -n "$BLOAT_MS" ]] && (( BLOAT_MS > 200 )) && penalize 4 "Delay jumps by ${BLOAT_MS} ms when the line is busy"
  fi
  (( SCORE < 0 )) && SCORE=0
  (( SCORE > 100 )) && SCORE=100

  # ── cascade: after the first hard failure, later nodes are "not reachable" ──
  local broken=0
  for i in 1 2 3 4 5; do
    if (( broken )) && [[ "${N_STATE[i]}" != OK ]]; then N_STATE[i]=UNK; N_WORD[i]="Unreachable"; fi
    [[ "${N_STATE[i]}" == FAIL ]] && broken=1
  done

  # ── grade, face, diagnosis ─────────────────────────────────────────────────
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

  ap_start   # browsing
  if   (( lat > 400 )); then ap 3 "very slow replies"; elif (( lat > 200 )); then ap 2 "slow replies"; elif (( lat > 100 )); then ap 1 "slightly slow replies"; fi
  if   (( loss >= 10 )); then ap 3 "lost data"; elif (( loss >= 3 )); then ap 1 "some lost data"; fi
  if   (( DNS_OKN < DNS_TOTAL )); then ap 2 "some names fail to load"; fi
  if   (( DNS_AVG > 400 )); then ap 2 "slow name lookups"; elif (( DNS_AVG > 200 )); then ap 1 "slow name lookups"; fi
  (( WIFI_WEAK )) && ap 1 "weak Wi-Fi"
  if (( SPEED_RAN && DL_I >= 0 )); then if (( DL_I < 2 )); then ap 3 "slow download speed"; elif (( DL_I < 5 )); then ap 1 "modest download speed"; fi; fi
  ap_end

  ap_start   # video calls
  if   (( lat > 300 )); then ap 3 "high delay"; elif (( lat > 150 )); then ap 2 "high delay"; elif (( lat > 80 )); then ap 1 "some delay"; fi
  if   (( jit > 50 )); then ap 3 "unsteady connection"; elif (( jit > 30 )); then ap 2 "unsteady connection"; elif (( jit > 15 )); then ap 1 "slightly unsteady"; fi
  if   (( loss >= 8 )); then ap 3 "lost data"; elif (( loss >= 3 )); then ap 2 "lost data"; elif (( loss >= 1 )); then ap 1 "a little lost data"; fi
  (( WIFI_WEAK )) && ap 1 "weak Wi-Fi"
  if (( SPEED_RAN && UL_I >= 0 )); then if (( UL_I < 1 )); then ap 2 "slow upload"; elif (( UL_I < 3 )); then ap 1 "modest upload"; fi; fi
  if [[ -n "$BLOAT_MS" ]]; then if (( BLOAT_MS > 200 )); then ap 2 "lags when line is busy"; elif (( BLOAT_MS > 80 )); then ap 1 "lags when line is busy"; fi; fi
  ap_end

  ap_start   # streaming
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

  ap_start   # gaming
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
  (( PORTAL )) && add_tip "Open your web browser: hotel, café and train Wi-Fi usually shows a sign-in page first."
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

stars() {   # n -> ★★★☆☆
  local n="$1" col
  if (( n >= 4 )); then col="$GREEN"; elif (( n == 3 )); then col="$YELLOW"; else col="$RED"; fi
  printf '%s%s%s%s%s' "$col" "$(rep "$G_STAR" "$n")" "$GRAY" "$(rep "$G_STAR0" "$(( 5 - n ))")" "$RESET"
}

render_journey() {
  local cw=$(( (W - 4) / 5 )) half i st col seg mark
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
#  JSON REPORT (--json)
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
#  ADVANCED REPORT — every technical statistic
# ══════════════════════════════════════════════════════════════════════════════
mark_state() {   # state -> coloured "[✓ OK]"
  local c m
  c="$(state_color "$1")"
  case "$1" in OK) m="$G_OK" ;; WARN) m="$G_WARN" ;; FAIL) m="$G_FAIL" ;; *) m="$G_INFO" ;; esac
  printf '%s[%s %s]%s' "$c" "$m" "$1" "$RESET"
}

show_check() {
  local state="$1" label="$2" detail="$3"
  printf '  %s %-26s %s\n' "$(mark_state "$state")" "$label" "$detail"
}

ping_row() {   # label key
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
  if (( ${PG[gw.n]:-0} > 0 )); then show_check "$st" "Router (gateway)" "$word — ${PG[gw.recv]}/${PG[gw.sent]} replies, avg ${PG[gw.avg]} ms"
  else show_check "$st" "Router (gateway)" "$word$( (( GW_INFERRED )) && echo ' — ping blocked, but traffic passes')"; fi
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
    *) if (( PORTAL )); then show_check WARN "Sign-in page check" "HTTP $PORTAL_CODE — likely a captive portal"; else show_check INFO "Sign-in page check" "HTTP $PORTAL_CODE (ignored: web test succeeded)"; fi ;;
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
    ip4="$(ip -o -4 addr show dev "$i" 2>/dev/null | awk '{ print $4; exit }')"
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
    kv "Latency idle → loaded" "${LAT_MS} ms → ${LOAD_AVG} ms (+${BLOAT_MS} ms)"
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
  note "• Ping failures alone do not prove a fault: routers and servers may ignore ICMP."
  note "• Counters (bytes, errors, drops, retransmits) are cumulative since boot, not per-second."
  note "• Traffic rates describe this computer's interface, not your provider's maximum speed."
  note "• NetScope never scans other devices, tests open ports or changes any configuration."
}



# ══════════════════════════════════════════════════════════════════════════════
#  LIVE MONITOR  (--live)
# ══════════════════════════════════════════════════════════════════════════════
spark_lat() {   # values... ("x" = lost)
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
spark_rate() {   # scale values...
  local scale="$1"; shift
  (( $# )) || return 0
  printf '%s\n' "$@" | awk -v glyphs="$SPARK_GLYPHS" -v sc="$scale" '
    BEGIN { split(glyphs, G, " ") }
    { l = int($1 / sc * 7 + 0.5) + 1; if (l > 8) l = 8; if (l < 1) l = 1; s = s G[l] }
    END { print s }'
}
lat_stats() {   # values... -> cur avg min max loss%
  printf '%s\n' "$@" | awk '
    { n++; last = $1; if ($1 == "x") { lost++; next }
      v = $1 + 0; c++; sum += v; if (c == 1 || v < mn) mn = v; if (v > mx) mx = v }
    END { if (c == 0) { print "lost - - - 100"; exit }
          printf "%s %.1f %.1f %.1f %.0f\n", (last == "x") ? "lost" : last, sum / c, mn, mx, lost * 100 / n }'
}

live_lat_block() {   # label target values...
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

live_rate_block() {   # label arrow colour values...
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
    key=""; read -rsn1 -t 1 key || true       # doubles as the one-second tick
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
      [[ -n "$sig" ]] && sig="  ·  signal ${sig} dBm"
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
#  MAIN
# ══════════════════════════════════════════════════════════════════════════════
finish() {   # exit status reflects the health score so other scripts can react
  if   (( SCORE >= 75 )); then exit 0
  elif (( SCORE >= 55 )); then exit 10
  else exit 20; fi
}

main() {
  local t_start t_end do_adv key=""

  (( LIVE )) && live_mode

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
  read -r CNT0_E CNT0_D _ <<<"$(read_counters)"   # baseline: did errors grow during the scan?
  start_basic_jobs
  wait_jobs "Scanning your network"
  if (( SPEED )); then
    if have curl && have ping; then start_speed_job; wait_jobs "Measuring speed (about 15 seconds)"
    else printf '  Speed test skipped: it needs both curl and ping.\n' >&2; fi
  fi
  evaluate
  t_end="$(now_ms)"

  if (( JSON )); then
    render_json
    finish
  fi

  printf '  %s%s%s Scan complete in %s seconds.\n' "$GREEN" "$G_OK" "$RESET" "$(awk -v a="$t_start" -v b="$t_end" 'BEGIN { printf "%.1f", (b - a) / 1000 }')"

  render_basic

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
  printf '%s  %s  --live for a live monitor%s\n\n' "$DIM" "$G_MID" "$RESET"
  finish
}

main
