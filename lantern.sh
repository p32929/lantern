#!/usr/bin/env bash
# Lantern: one page to watch and control anything on this machine.
#
#   ./lantern.sh             set it up (asks a few questions), or manage it
#   ./lantern.sh start|stop|restart|status|port|pin|update|uninstall|version
#
# Each thing on the page is a few shell commands you give it: one that says
# whether it is up, one that prints its logs, one that prints its PID (for
# CPU/RAM), and any actions you want buttons for (restart, deploy, ...).
#
# The web server is busybox httpd, which ships with Ubuntu/Debian. It serves
# lantern.html and runs this same file for the page's requests (as CGI).
set -u
umask 077   # what Lantern keeps (commands, logs, terminal output) is for this user only

VERSION=1.0.2

# ---------------------------------------------------------------- shared ----

if [ -n "${GATEWAY_INTERFACE:-}" ] || [ "${1:-}" = serve ]; then
  # Run by the web server or the service: this file is DIR/app/lantern.sh.
  DIR=$(dirname "$(dirname "$(readlink -f "$0")")")
else
  DIR=${LANTERN_DIR:-$HOME/.lantern}
fi
APP=$DIR/app
WWW=$DIR/www
RUN=$DIR/run
CONF=$DIR/config
UNIT=lantern.service
UNITFILE=$HOME/.config/systemd/user/$UNIT

PORT=80 PIN= MODE= SAVED_PATH=
[ -f "$CONF" ] && . "$CONF"

save_conf() {
  mkdir -p "$DIR"
  printf 'PORT=%q\nPIN=%q\nMODE=%q\nSAVED_PATH=%q\n' "$PORT" "$PIN" "$MODE" "$SAVED_PATH" > "$CONF"
  chmod 600 "$CONF"
}

# ------------------------------------------------------------------ API ----

# A JSON string. Control characters other than newline/tab are dropped.
js() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\t'/\\t}
  s=${s//[$'\001'-$'\010'$'\013'-$'\037']/}
  printf '"%s"' "$s"
}
num() { [[ ${1:-} =~ ^[0-9]+(\.[0-9]+)?$ ]] && printf '%s' "$1" || printf null; }

urldecode() { local s=${1//+/ }; s=${s//\\/\\\\}; printf '%b' "${s//%/\\x}"; }
parse() {
  local p parts
  IFS='&' read -ra parts <<< "$1"
  for p in "${parts[@]}"; do
    [[ $p == *=* && ${p%%=*} =~ ^[a-z0-9_]+$ ]] || continue
    F[${p%%=*}]=$(urldecode "${p#*=}")
  done
}

rd() { [ -f "$DIR/items/$1/$2" ] && cat "$DIR/items/$1/$2"; }
wd() { local w; w=$(rd "$1" dir); w=${w/#\~/$HOME}; [ -d "$w" ] && echo "$w" || echo "$HOME"; }
# Run an item's command in its folder, quietly, with a time limit.
sh_in() { (cd "$1" && timeout "$2" bash -c "$3") 2>/dev/null < /dev/null; }

# A correct PIN gets a token the browser keeps. It is tied to this boot and this
# PIN, so it stops working only when the machine reboots or the PIN changes.
token() { printf '%s:%s' "$PIN" "$(< /proc/sys/kernel/random/boot_id)" | sha256sum | cut -d' ' -f1; }
# Wrong PINs are counted per IP address. The 5th one blocks that address from
# everything for 7 days. 20 wrong PINs in total, from any addresses, stop PIN
# logins altogether, so many addresses can't share the guessing; browsers that
# already have a token keep working. Only starting Lantern again clears both.
MAX_TRIES=5 BLOCK_DAYS=7 MAX_TOTAL=20 LEFT= LOCKED=
fail_file() {
  local ip=${REMOTE_ADDR:-unknown}
  ip=${ip#[}; ip=${ip%]}; ip=${ip#::ffff:}   # busybox gives IPv4 as [::ffff:a.b.c.d]
  echo "$RUN/fails/${ip//[^a-zA-Z0-9.:]/_}"
}
blocked() { local n u; read -r n u 2> /dev/null < "$(fail_file)" && [ "${u:-0}" -gt "$(date +%s)" ]; }

pin_ok() {
  [ -z "$PIN" ] && return 0
  [ "${F[tok]:-}" = "$(token)" ] && return 0
  [ -n "${F[pin]:-}" ] || return 1
  # One PIN check at a time, so firing many requests at once can't get past the limit.
  local f n=0 u=0 tot=0 lk ok=1
  f=$(fail_file); mkdir -p "$RUN/fails"
  exec {lk}> "$RUN/fails/.lock"; flock "$lk"
  read -r n u 2> /dev/null < "$f"
  read -r tot 2> /dev/null < "$RUN/fails/.total"
  if [ "${u:-0}" -gt "$(date +%s)" ]; then ok=1
  elif ((${tot:-0} >= MAX_TOTAL)); then LOCKED=1
  elif [ "$(printf %s "${F[pin]}" | sha256sum | cut -d' ' -f1)" = "$PIN" ]; then rm -f "$f"; ok=0
  else
    n=$((${n:-0} + 1))
    ((n >= MAX_TRIES)) && u=$(($(date +%s) + BLOCK_DAYS * 86400))
    echo "$n ${u:-0}" > "$f"; LEFT=$((MAX_TRIES - n))
    echo $((${tot:-0} + 1)) > "$RUN/fails/.total"
  fi
  exec {lk}>&-
  return $ok
}
# The answer to a request without a good token or PIN. X-Error says why, so the
# page can tell for any request (JSON, text or the terminal stream).
denied() {
  local e=pin
  [ -n "${F[pin]:-}" ] && sleep 1   # slows guessing
  if blocked; then e=blocked; elif [ -n "$LOCKED" ]; then e=locked; fi
  printf 'Content-Type: application/json\r\nCache-Control: no-store\r\nX-Error: %s\r\n\r\n' "$e"
  if [ $e = pin ] && [ -n "$LEFT" ]; then printf '{"error":"pin","left":%s}\n' "$LEFT"
  else printf '{"error":"%s"}\n' "$e"; fi
}

now_us() { local t; t=$(date +%s%N); echo $((t / 1000)); }

# CPU (% of the whole machine) and memory of the process tree a PID lives in:
# its cgroup when it has one (a service or container), else just the process.
usage() {
  local id=$1 pid=$2 state=$RUN/${3:-cpu}.$1 cg f u t pu pt
  sample() {
    cg=$(sed -n 's/^0:://p' "/proc/$pid/cgroup" 2>/dev/null); f=/sys/fs/cgroup$cg
    # A service's or container's own cgroup covers all its processes. A login
    # session's (pm2, nohup, screen...) holds unrelated things, so count the process.
    if [ "$cg" != / ] && [[ $cg != */session-*.scope ]] && [ -r "$f/memory.current" ]; then
      mem=$(< "$f/memory.current"); u=$(awk '$1=="usage_usec"{print $2}' "$f/cpu.stat")
    else
      mem=$(awk '/^VmRSS/{print $2*1024}' "/proc/$pid/status" 2>/dev/null)
      u=$(awk -v hz="$(getconf CLK_TCK)" '{print int(($14+$15)*1000000/hz)}' "/proc/$pid/stat" 2>/dev/null)
    fi
    t=$(now_us)
  }
  sample
  if ! read -r pu pt < "$state" 2>/dev/null || [ "$t" -le "$pt" ] || [ "$u" -lt "$pu" ]; then
    pu=$u pt=$t; sleep 0.5; sample
  fi
  cpu=$(awk -v a=$((u - pu)) -v b=$((t - pt)) -v n="$(nproc)" 'BEGIN{printf "%.4f", (b>0 ? a/b*100/n : 0)}')
  echo "$u $t" > "$state"
}

# A button is actions/N (label, then the command) plus actions/N.opt (icon=…, table=0|1).
is_act() { [[ ${1##*/} =~ ^[0-9]+$ && -f $1 ]]; }
act_opt() {
  local icon= table=0 k v
  if [ -f "$1.opt" ]; then
    while IFS='=' read -r k v; do case $k in icon) icon=$v ;; table) table=$v ;; esac; done < "$1.opt"
  fi
  printf '"icon":%s,"table":%s' "$(js "$icon")" "$([ "$table" = 1 ] && echo true || echo false)"
}

# The PID an item's PID command prints, if that process exists.
item_pid() {
  local c p
  c=$(rd "$1" pid); [ -n "$c" ] || return 1
  p=$(sh_in "$2" 10 "$c" | grep -o '[0-9]\+' | head -1)
  [ -n "$p" ] && [ "$p" -gt 0 ] && [ -r "/proc/$p/stat" ] && echo "$p"
}

# Last hour of history as two arrays, for the small graphs.
hist_json() {
  local f=$DIR/history/$1
  [ -s "$f" ] || { printf '"hc":[],"hm":[]'; return; }
  tail -n 60 "$f" | awk '{c = c s $2; m = m s $3; s = ","} END {printf "\"hc\":[%s],\"hm\":[%s]", c, m}'
}

# The machine's last 24 hours for the boxes at the top, averaged into 10-minute steps.
server_hist() {
  local f=$DIR/history/_server
  [ -s "$f" ] || { printf '"hc":[],"hm":[],"hl":[],"hs":[],"hb":[],"hd":[]'; return; }
  tail -n 1440 "$f" | awk '
    NR == 1 { t0 = $1 }
    { j = int(($1 - t0) / 600); if (j > last) last = j
      for (i = 2; i <= 7; i++) if (i <= NF && $i != "-") { sum[i, j] += $i; cnt[i, j]++ } }
    END { split("hc hm hl hs hb hd", key, " ")
      for (i = 2; i <= 7; i++) {
        a = ""; sep = ""
        for (j = 0; j <= last; j++) if (cnt[i, j]) { a = a sep sprintf("%.6g", sum[i, j] / cnt[i, j]); sep = "," }
        printf "%s\"%s\":[%s]", (i > 2 ? "," : ""), key[i - 1], a
      } }'
}

item_json() {
  local id=$1 w up=null link cpu=null mem=null c pid acts= f first=1
  w=$(wd "$id")
  c=$(rd "$id" check)
  if [ -n "$c" ]; then sh_in "$w" 10 "$c" > /dev/null && up=true || up=false; fi
  link=$(rd "$id" link)
  [[ $link == '$ '* ]] && link=$(sh_in "$w" 10 "${link:2}" | head -1)
  pid=$(item_pid "$id" "$w") && usage "$id" "$pid"
  for f in "$DIR/items/$id/actions/"*; do
    is_act "$f" || continue
    ((first)) || acts+=,; first=0
    acts+="{\"n\":${f##*/},\"label\":$(js "$(head -1 "$f")"),$(act_opt "$f")}"
  done
  printf '{"id":%s,"name":%s,"group":%s,"link":%s,"note":%s,"logs":%s,"up":%s,"cpu":%s,"mem":%s,%s,"actions":[%s]}' \
    "$(js "$id")" "$(js "$(rd "$id" name)")" "$(js "$(rd "$id" group)")" "$(js "$link")" \
    "$(js "$(rd "$id" note)")" "$([ -s "$DIR/items/$id/logs" ] && echo true || echo false)" \
    "$up" "$(num "$cpu")" "$(num "$mem")" "$(hist_json "$id")" "$acts"
}

stats_json() {
  local a b c d e f g h total idle pt pi cpu=null z tz ip ifc= sig= ssid= bat=null chg= mt ma du dt
  read -r _ a b c d e f g h _ < /proc/stat
  total=$((a + b + c + d + e + f + g + h)) idle=$((d + e))
  if read -r pt pi < "$RUN/cpu.server" 2>/dev/null && [ "$total" -gt "$pt" ]; then
    cpu=$(awk -v t=$((total - pt)) -v i=$((idle - pi)) 'BEGIN{printf "%.4f", (t-i)/t*100}')
  fi
  echo "$total $idle" > "$RUN/cpu.server"
  read -r mt ma < <(awk '/^MemTotal/{t=$2}/^MemAvailable/{a=$2}END{print t*1024, a*1024}' /proc/meminfo)
  read -r du dt < <(df -Pk / | awk 'NR==2{print $3*1024, $2*1024}')
  z=$(date +%z); tz=$((${z:0:1}1 * (10#${z:1:2} * 3600 + 10#${z:3:2} * 60)))
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')
  read -r ifc sig < <(awk 'NR>2{sub(":","",$1); print $1, int($3*100/70)}' /proc/net/wireless 2>/dev/null)
  [ -n "${ifc:-}" ] && command -v iw > /dev/null && ssid=$(iw dev "$ifc" link 2>/dev/null | sed -n 's/^\s*SSID: //p')
  for b in /sys/class/power_supply/BAT*; do
    [ -r "$b/capacity" ] && bat=$(< "$b/capacity") && chg=$(< "$b/status") && break
  done
  printf '{"host":%s,"now":%s,"tz":%s,"up":%s,"cpu":%s,"load":%s,"mem_used":%s,"mem_total":%s,"disk_used":%s,"disk_total":%s,"battery":%s,"charge":%s,"wifi":%s,"signal":%s,"ip":%s}' \
    "$(js "$(hostname)")" "$(date +%s)" "$tz" "$(cut -d. -f1 /proc/uptime)" "$cpu" \
    "$(js "$(cut -d' ' -f1-3 /proc/loadavg)")" "$((mt - ma))" "$mt" "$du" "$dt" "$(num "$bat")" \
    "$(js "$chg")" "$(js "$ssid")" "$( [ -n "$ssid" ] && num "$sig" || echo null)" "$(js "$ip")"
}

api_list() {
  local tmp d id f first=1
  # A request cut off midway leaves its folder behind; sweep old ones.
  find "$RUN" -maxdepth 1 -name 'list.*' -mmin +2 -exec rm -rf {} + 2> /dev/null
  tmp=$(mktemp -d "$RUN/list.XXXXXX")
  for d in "$DIR"/items/*/; do
    [ -d "$d" ] || continue
    id=$(basename "$d"); item_json "$id" > "$tmp/$id" &
  done
  wait
  printf '{"version":"%s","pin":%s,"stats":' "$VERSION" "$([ -n "$PIN" ] && echo true || echo false)"; stats_json; printf ',"hist":{%s},"items":[' "$(server_hist)"
  for f in "$tmp"/*; do
    [ -f "$f" ] || continue
    ((first)) || printf ,; first=0; cat "$f"
  done
  printf ']}'
  rm -rf "$tmp"
}

valid_id() { [[ ${F[id]:-} =~ ^[a-z0-9-]+$ ]] && [ -d "$DIR/items/${F[id]}" ]; }

api_logs() {
  valid_id || { echo "That item is gone."; return; }
  local c; c=$(rd "${F[id]}" logs)
  [ -n "$c" ] || { echo "No logs command is set. Add one under Edit."; return; }
  (cd "$(wd "${F[id]}")" && timeout 20 bash -c "$c") 2>&1 < /dev/null | tail -c 300000
}


api_auth() {
  printf '{"ok":true,"token":%s}\n' "$(js "$(token)")"
}

api_item() {
  valid_id || { echo '{"error":"gone"}'; return; }
  local id=${F[id]} k f acts= first=1
  printf '{"id":%s' "$(js "$id")"
  for k in name group link note dir check logs pid; do printf ',"%s":%s' "$k" "$(js "$(rd "$id" "$k")")"; done
  for f in "$DIR/items/$id/actions/"*; do
    is_act "$f" || continue
    ((first)) || acts+=,; first=0
    acts+="{\"label\":$(js "$(head -1 "$f")"),\"cmd\":$(js "$(tail -n +2 "$f")"),$(act_opt "$f")}"
  done
  printf ',"actions":[%s]}' "$acts"
}

api_save() {
  local id=${F[id]:-} d k i n=1 label cmd base
  [ -n "${F[name]:-}" ] || { echo '{"error":"A name is needed."}'; return; }
  if ! valid_id; then
    base=$(printf %s "${F[name]}" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9]\+/-/g; s/^-//; s/-$//')
    base=${base:-item} id=$base i=2
    while [ -e "$DIR/items/$id" ]; do id=$base-$i; i=$((i + 1)); done
  fi
  d=$DIR/items/$id
  mkdir -p "$d"
  for k in name group link note dir check logs pid; do printf '%s' "${F[$k]:-}" > "$d/$k"; done
  rm -rf "$d/actions"; mkdir "$d/actions"
  for i in $(seq 0 49); do
    label=${F[alabel$i]:-} cmd=${F[acmd$i]:-}
    [ -n "$label$cmd" ] || continue
    printf '%s\n%s' "${label:-Run}" "$cmd" > "$d/actions/$n"
    printf 'icon=%s\ntable=%s\n' "$(printf %s "${F[aicon$i]:-}" | tr -cd 'a-z0-9-')" "$([ "${F[atable$i]:-}" = 1 ] && echo 1 || echo 0)" > "$d/actions/$n.opt"
    n=$((n + 1))
  done
  printf '{"id":%s}' "$(js "$id")"
}

api_delete() { valid_id && rm -rf "$DIR/items/${F[id]}" "$DIR/history/${F[id]}"; echo '{"ok":true}'; }

# Recorded CPU and memory, one "time cpu memory" line a minute, for the charts.
api_history() {
  local id=${F[id]:-} n=${F[h]:-1}
  [[ $id =~ ^[a-z0-9-]+$ || $id = _server ]] && [[ $n =~ ^[0-9]+$ ]] && [ -f "$DIR/history/$id" ] && tail -n $((n * 60)) "$DIR/history/$id"
}

# Starts the command in the background and returns at once; the page reads
# its output with a=job until it has finished.
# A button pressed in the table runs in the background; the page polls a=job.
api_run() {
  local f w j
  valid_id && [[ ${F[action]:-} =~ ^[0-9]+$ ]] && f=$DIR/items/${F[id]}/actions/${F[action]} && [ -f "$f" ] ||
    { echo '{"error":"no such button"}'; return; }
  w=$(wd "${F[id]}")
  mkdir -p "$DIR/jobs"; find "$DIR/jobs" -type f -mmin +1440 -delete
  j=$(date +%s)-$RANDOM
  setsid bash -c 'cd "$1"; bash -c "$2" > "$3.out" 2>&1 < /dev/null; echo $? > "$3.code"' _ "$w" "$(tail -n +2 "$f")" "$DIR/jobs/$j" \
    < /dev/null > /dev/null 2>&1 &
  printf '{"job":"%s"}' "$j"
}
api_job() {
  local j=${F[j]:-} code=null
  [[ $j =~ ^[0-9]+-[0-9]+$ && -f $DIR/jobs/$j.out ]] || { echo '{"error":"gone"}'; return; }
  [ -f "$DIR/jobs/$j.code" ] && code=$(< "$DIR/jobs/$j.code")
  printf '{"code":%s,"tail":%s}' "$(num "$code")" "$(js "$(tail -n 4 "$DIR/jobs/$j.out" | cut -c1-200)")"
}

# ---- terminal: a login shell on a pseudo-terminal (script), fed through a FIFO ----
# Started in the background, so Ctrl-C would be ignored: env --default-signal undoes that.
# One shell per item (session "s" = item id, "_home" for the plain one). It keeps
# running when the page closes, so reopening picks up where it was.
valid_s() { [[ ${F[s]:-} =~ ^[a-z0-9_-]{1,40}$ ]]; }
t_dir() { echo "$DIR/term/${F[s]}"; }
t_alive() { [ -f "$1/pid" ] && kill -0 "$(< "$1/pid")" 2>/dev/null; }
t_size() { [[ ${F[cols]:-} =~ ^[0-9]{1,3}$ && ${F[rows]:-} =~ ^[0-9]{1,3}$ ]]; }

api_term_open() {
  valid_s || { echo '{"error":"bad session"}'; return; }
  local d w=$HOME c=100 r=30
  d=$(t_dir)
  t_alive "$d" && { echo '{"ok":true}'; return; }
  valid_id && w=$(wd "${F[id]}")
  t_size && c=${F[cols]} r=${F[rows]}
  rm -rf "$d"; mkdir -p "$d"; mkfifo "$d/in"
  (cd "$w" && exec env -i HOME="$HOME" PATH="$PATH" USER="$(id -un)" SHELL=/bin/bash LANG=C.UTF-8 \
    TERM=xterm-256color XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" setsid bash -c \
    'exec 3<>"$1/in"; echo $$ > "$1/pid"; exec script -qfec "stty cols $2 rows $3; tty > \"$1/tty\"; exec env --default-signal bash -l" /dev/null <&3 > "$1/out" 2>&1' \
    _ "$d" "$c" "$r") < /dev/null > /dev/null 2>&1 &
  sleep 0.3
  echo '{"ok":true,"new":true}'
}

# The shell's output from byte offset o, streamed as it appears: the response
# stays open and tail -f pushes new bytes the moment the shell prints them. It
# ends when the shell does, or after a minute: the page then reconnects, and a
# stream whose page has closed doesn't linger longer than that.
api_term_stream() {
  local d n o=${F[o]:-0} reset=0
  valid_s && d=$(t_dir) && [ -f "$d/out" ] || { printf 'Content-Type: text/plain\r\nX-Start: 0\r\n\r\n'; return; }
  [[ $o =~ ^[0-9]+$ ]] || o=0
  n=$(stat -c %s "$d/out")
  ((o > n)) && o=0 reset=1
  ((n - o > 200000)) && o=$((n - 200000))
  printf 'Content-Type: application/octet-stream\r\nCache-Control: no-store\r\nX-Start: %s\r\nX-Reset: %s\r\n\r\n' "$o" "$reset"
  if t_alive "$d"; then exec timeout 60 tail -s 0.05 -c +$((o + 1)) -f --pid="$(< "$d/pid")" "$d/out"; fi
  tail -c +$((o + 1)) "$d/out"
}

api_term_alive() { valid_s && t_alive "$(t_dir)" && echo '{"alive":true}' || echo '{"alive":false}'; }

# Keys typed in the page, or a button's command (typed in and run).
api_term_write() {
  local d f data=${F[d]:-} fd
  valid_s && d=$(t_dir) && t_alive "$d" || { echo '{"error":"closed"}'; return; }
  if [[ ${F[action]:-} =~ ^[0-9]+$ ]]; then
    valid_id && f=$DIR/items/${F[id]}/actions/${F[action]} && [ -f "$f" ] || { echo '{"error":"no such button"}'; return; }
    data=$(tail -n +2 "$f"); data=${data//$'
'/$'
'}$'
'
  fi
  exec {fd}<> "$d/in"   # read-write open never blocks on a FIFO
  printf '%s' "$data" >&"$fd"
  exec {fd}>&-
  echo '{"ok":true}'
}

api_term_resize() {
  local d
  valid_s && d=$(t_dir) && t_size && [ -f "$d/tty" ] && stty -F "$(< "$d/tty")" cols "${F[cols]}" rows "${F[rows]}" 2>/dev/null
  echo '{"ok":true}'
}

api_term_close() {
  local d
  local i
  if valid_s && d=$(t_dir) && t_alive "$d"; then
    kill -HUP "$(< "$d/pid")"
    for ((i = 0; i < 30; i++)); do t_alive "$d" || break; sleep 0.1; done
    t_alive "$d" && kill -KILL "$(< "$d/pid")"
  fi
  echo '{"ok":true}'
}

cgi() {
  [ -n "$SAVED_PATH" ] && export PATH=$SAVED_PATH
  export HOME=${HOME:-$(getent passwd "$(id -u)" | cut -d: -f6)}
  export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
  mkdir -p "$RUN"
  declare -gA F=()
  local n=${CONTENT_LENGTH:-0}
  [[ $n =~ ^[0-9]+$ ]] || n=0
  if ((n > 1000000)); then   # the biggest real request (saving an item) is a few KB
    printf 'Status: 413\r\nContent-Type: application/json\r\n\r\n{"error":"too big"}\n'; return
  fi
  # Only the body is read: the token never sits in a URL.
  [ "${REQUEST_METHOD:-}" = POST ] && ((n > 0)) && parse "$(head -c "$n")"
  local a=${QUERY_STRING#a=}
  a=${a%%&*}
  # Everything needs the PIN (or the token it gave), looking included.
  if [ -n "$PIN" ] && { blocked || ! pin_ok; }; then denied; return; fi
  case $a in
    term_stream) api_term_stream ;;
    logs | history) printf 'Content-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\n\r\n'; "api_$a" ;;
    list | item | job | auth | save | delete | run | term_open | term_write | term_resize | term_close | term_alive)
      printf 'Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n'; "api_$a" ;;
    *) printf 'Content-Type: application/json\r\n\r\n{"error":"unknown request"}\n' ;;
  esac
}

# ---------------------------------------------------------- recorder ----
# Once a minute: CPU and memory of every item with a PID command, and of the
# machine, appended to history/<id>. Keeps the last 24 hours.

keep() { (($(wc -l < "$1") > 1500)) && tail -n 1440 "$1" > "$1.tmp" && mv "$1.tmp" "$1"; true; }

record() {
  local d id pid cpu mem t a b c e f g h i total idle pt pi mt ma sg bt
  mkdir -p "$DIR/history"; t=$(date +%s)
  for d in "$DIR"/items/*/; do
    [ -d "$d" ] || continue
    id=$(basename "$d") cpu= mem=
    pid=$(item_pid "$id" "$(wd "$id")") || continue
    usage "$id" "$pid" rec
    [ -n "$mem" ] && echo "$t $(printf '%.2f' "$cpu") $mem" >> "$DIR/history/$id" && keep "$DIR/history/$id"
  done
  read -r _ a b c e f g h i _ < /proc/stat
  total=$((a + b + c + e + f + g + h + i)) idle=$((e + f))
  if read -r pt pi < "$RUN/rec.server" 2>/dev/null && ((total > pt)); then
    read -r mt ma < <(awk '/^MemTotal/{t=$2}/^MemAvailable/{a=$2}END{print t*1024, a*1024}' /proc/meminfo)
    # time cpu memory load wifi-signal battery disk ("-" when there is none)
    sg=$(awk 'NR>2{print int($3*100/70); exit}' /proc/net/wireless 2> /dev/null)
    bt=-; for b in /sys/class/power_supply/BAT*; do [ -r "$b/capacity" ] && bt=$(< "$b/capacity") && break; done
    echo "$t $(awk -v t=$((total - pt)) -v i=$((idle - pi)) 'BEGIN{printf "%.2f", (t-i)/t*100}') $((mt - ma))" \
      "$(cut -d' ' -f1 /proc/loadavg) ${sg:--} $bt $(df -Pk / | awk 'NR==2{print $3*1024}')" >> "$DIR/history/_server"
    keep "$DIR/history/_server"
  fi
  echo "$total $idle" > "$RUN/rec.server"
}

# What the service runs: the recorder in the background, and the web server.
serve() {
  [ -n "$SAVED_PATH" ] && export PATH=$SAVED_PATH
  mkdir -p "$RUN"
  chmod -R go-rwx "$DIR"   # older versions left it readable by other users
  rm -rf "$RUN/fails"   # starting again forgets wrong PINs and blocked addresses
  (while :; do record; sleep 60; done) &
  exec busybox httpd -f -p "$PORT" -h "$WWW"
}

if [ -n "${GATEWAY_INTERFACE:-}" ]; then cgi; exit 0; fi

# ---------------------------------------------------------------- setup ----

say() { printf '%s\n' "$*"; }
ask() { local a; read -rp "$1 [$2]: " a; printf '%s' "${a:-$2}"; }
yes() { local a; read -rp "$1 [Y/n]: " a; [[ ! $a =~ ^[Nn] ]]; }
no() { local a; read -rp "$1 [y/N]: " a; [[ ! $a =~ ^[Yy] ]]; }
has_systemd() { command -v systemctl > /dev/null && systemctl --user show-environment > /dev/null 2>&1; }
lan_ip() { ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p'; }
url() { echo "http://$(lan_ip || hostname):$PORT"; }

running() {
  if [ "$MODE" = systemd ]; then systemctl --user is-active -q $UNIT
  else [ -f "$RUN/pid" ] && kill -0 "$(< "$RUN/pid")" 2> /dev/null; fi
}

# Copies this script and the page next to it into DIR, so the running panel
# does not depend on where they were downloaded.
install_files() {
  local here; here=$(dirname "$(readlink -f "$0")")
  [ -f "$here/lantern.html" ] || { say "lantern.html must be next to this script."; exit 1; }
  mkdir -p "$APP" "$WWW/cgi-bin" "$RUN" "$DIR/items"
  if [ "$here" != "$APP" ]; then cp "$here/lantern.sh" "$here/lantern.html" "$APP/"; fi
  chmod 755 "$APP/lantern.sh"
  ln -sfn "$APP/lantern.html" "$WWW/index.html"
  ln -sfn "$APP/lantern.sh" "$WWW/cgi-bin/api"
}

port_ok() {
  local low; low=$(cat /proc/sys/net/ipv4/ip_unprivileged_port_start 2>/dev/null || echo 1024)
  [ "$(id -u)" = 0 ] || [ "$PORT" -ge "$low" ] && return 0
  say "Port $PORT is below $low, which normal users may not use on this machine."
  if yes "Allow ports from $PORT for normal users? (asks for your sudo password)"; then
    echo "net.ipv4.ip_unprivileged_port_start=$PORT" | sudo tee /etc/sysctl.d/99-lantern.conf > /dev/null &&
      sudo sysctl -q -p /etc/sysctl.d/99-lantern.conf && return 0
  fi
  say "Pick a port of $low or higher then."; return 1
}

write_unit() {
  mkdir -p "${UNITFILE%/*}"
  printf '[Unit]\nDescription=lantern on port %s\nAfter=network-online.target\n[Service]\nExecStart=%s serve\nRestart=always\nRestartSec=3\n[Install]\nWantedBy=default.target\n' \
    "$PORT" "$APP/lantern.sh" > "$UNITFILE"
  systemctl --user daemon-reload
}

start() {
  if [ "$MODE" = systemd ]; then write_unit; systemctl --user enable -q $UNIT; systemctl --user restart $UNIT
  else
    running && kill -- -"$(< "$RUN/pid")"
    setsid nohup "$APP/lantern.sh" serve > "$RUN/httpd.log" 2>&1 < /dev/null &
    echo $! > "$RUN/pid"
  fi
  sleep 1
  if running; then say "Running: $(url)"; else say "It did not start. Is port $PORT already taken?"; return 1; fi
}

stop() {
  if [ "$MODE" = systemd ]; then systemctl --user disable -q --now $UNIT 2>/dev/null
  else [ -f "$RUN/pid" ] && kill -- -"$(< "$RUN/pid")" 2>/dev/null; rm -f "$RUN/pid"; fi
  say "Stopped."
}

status() {
  if running; then say "Lantern is running: $(url)  (v$VERSION, $([ "$MODE" = systemd ] && echo "always on, starts on boot" || echo "in the background, not on boot"))"
  else say "Lantern is stopped (port $PORT)."; fi
  local f n u now; now=$(date +%s)
  for f in "$RUN/fails/"*; do
    [ -f "$f" ] && read -r n u < "$f" && [ "${u:-0}" -gt "$now" ] &&
      say "Blocked after $n wrong PINs: ${f##*/} (until $(date -d "@$u" '+%a %d %b %H:%M'); restart to unblock)"
  done
  read -r n 2> /dev/null < "$RUN/fails/.total" && ((n >= MAX_TOTAL)) &&
    say "PIN logins are off after $n wrong PINs in total; browsers already in still work. Restart to turn them back on."
  true
}

set_pin() {
  local p
  read -rsp "PIN to open Lantern (empty = no PIN: anyone who can reach the port gets in): " p; echo
  PIN=$([ -n "$p" ] && printf %s "$p" | sha256sum | cut -d' ' -f1)
}

setup() {
  busybox httpd --help > /dev/null 2>&1 || { say "This needs busybox: sudo apt install busybox"; exit 1; }
  say "Setting up Lantern."
  while :; do
    PORT=$(ask "Port" "$PORT")
    [[ $PORT =~ ^[0-9]+$ ]] && [ "$PORT" -lt 65536 ] && port_ok && break
  done
  set_pin
  if has_systemd && yes "Keep it running always (starts on boot, comes back if it crashes)?"; then
    MODE=systemd
    loginctl show-user "$USER" -p Linger 2>/dev/null | grep -q yes || loginctl enable-linger "$USER" 2>/dev/null ||
      sudo loginctl enable-linger "$USER" || say "Could not turn on start-at-boot (loginctl enable-linger)."
  else
    MODE=bg
  fi
  SAVED_PATH=$PATH
  save_conf
  install_files
  if [ "$MODE" = systemd ] || yes "Start it now?"; then start; else say "Start it later with: $0 start"; fi
}

manage() {
  status
  say "  1) restart   2) stop   3) start   4) change port   5) change PIN"
  say "  6) update files from here   7) uninstall   q) quit"
  case $(ask "Choose" q) in
    1 | 3) start ;;
    2) stop ;;
    4) local old=$PORT
      PORT=$(ask "New port" "$PORT")
      if [[ $PORT =~ ^[0-9]+$ ]] && port_ok; then save_conf; running && start; else PORT=$old; fi ;;
    5) set_pin; save_conf; say "PIN changed." ;;
    6) install_files; say "Files updated."; running && start ;;
    7) uninstall ;;
  esac
}

uninstall() {
  no "Remove Lantern?" && return
  stop
  rm -f "$UNITFILE"; has_systemd && systemctl --user daemon-reload
  if no "Also delete everything you added to it?"; then
    rm -rf "$APP" "$WWW" "$RUN" "$DIR/jobs" "$DIR/term" "$DIR/history"; say "Removed. Your items are kept in $DIR/items."
  else
    rm -rf "$DIR"; say "Removed everything."
  fi
}

case ${1:-} in
  start | restart) start ;;
  stop) stop ;;
  status) status ;;
  serve) serve ;;
  version | -v | --version) echo "Lantern $VERSION" ;;
  port) PORT=$(ask "New port" "$PORT"); port_ok && save_conf && { running && start || true; } ;;
  pin) set_pin; save_conf; say "PIN changed." ;;
  update) install_files; say "Files updated."; if running; then start; fi ;;
  uninstall) uninstall ;;
  "") if [ -f "$CONF" ] && [ -d "$APP" ]; then manage; else setup; fi ;;
  *) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
