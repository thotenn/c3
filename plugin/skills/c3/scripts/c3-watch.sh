#!/bin/sh
# c3-watch.sh — the C3 watcher: waits in the background until something in a C3 session
# concerns this agent, prints it, and exits, so Claude Code wakes the agent up.
#
# Only needs sh + curl: Linux, macOS and Git Bash on Windows.
#
#   c3-watch.sh save <url> <code> <name>   # the token on stdin; prints the key <code>-<name>
#   c3-watch.sh wait <key>                 # run with run_in_background; exits on the first news
#   c3-watch.sh forget <key>               # after leaving or closing the session
#   c3-watch.sh list                       # saved keys (never the tokens)
#
# State: one file per (session, agent) in $C3_STATE_DIR (default
# ${XDG_STATE_HOME:-$HOME/.local/state}/c3), outside any repository, mode 600: url, code,
# name, token and the cursor `after`, saved after every poll so a restart loses nothing.
#
# `wait` long-polls GET <url>/v1/sessions/<code>/watch, which answers a `cursor <seq>` line
# and one line per event that concerns the agent (the server decides). It exits 0 with
# those lines, 0 with an `idle` line after C3_WATCH_MAX_SECONDS without news, and 3 with a
# `stop` line when the session is closed or the token no longer works. Every exit but a
# stop ends with the exact command to relaunch it. A network error is retried with backoff.

set -u

STATE_DIR=${C3_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/c3}
MAX_SECONDS=${C3_WATCH_MAX_SECONDS:-6000}
POLL_WAIT=${C3_WATCH_POLL:-30}
RETRY=${C3_WATCH_RETRY:-2}
SELF=$0

usage() {
  sed -n '7,10p' "$SELF" | sed 's/^# *//' >&2
  exit 2
}

state_file() {
  case $1 in
    "" | */* | *..*) echo "c3-watch: bad key '$1'" >&2; exit 2 ;;
  esac
  printf '%s/%s\n' "$STATE_DIR" "$1"
}

get() { sed -n "s/^$1=//p" "$2" | head -n 1; }

# Rewrites the state file in one move, readable only by the user.
write_state() {
  file=$1 url=$2 code=$3 name=$4 token=$5 after=$6
  mkdir -p "$STATE_DIR" || exit 1
  tmp="$file.tmp.$$"
  (umask 077 && printf 'url=%s\ncode=%s\nname=%s\ntoken=%s\nafter=%s\n' \
    "$url" "$code" "$name" "$token" "$after" >"$tmp") && mv -f "$tmp" "$file"
}

relaunch() {
  printf 'relaunch: sh "%s" wait %s\n' "$SELF" "$1"
}

cmd_save() {
  [ $# -eq 3 ] || usage
  url=${1%/} code=$2 name=$3
  IFS= read -r token || [ -n "${token:-}" ] || { echo "c3-watch: the token goes on stdin" >&2; exit 2; }
  key="$code-$name"
  file=$(state_file "$key")
  after=0
  [ -f "$file" ] && [ "$(get token "$file")" = "$token" ] && after=$(get after "$file")
  write_state "$file" "$url" "$code" "$name" "$token" "${after:-0}"
  echo "$key"
}

cmd_wait() {
  [ $# -eq 1 ] || usage
  key=$1
  file=$(state_file "$key")
  [ -f "$file" ] || { echo "c3-watch: no state for $key (run save first)" >&2; exit 2; }
  url=${C3_URL:-$(get url "$file")}
  url=${url%/}
  code=$(get code "$file") name=$(get name "$file") token=$(get token "$file")
  after=$(get after "$file")
  after=${after:-0}

  started=$(date +%s)
  backoff=$RETRY

  while [ $(($(date +%s) - started)) -lt "$MAX_SECONDS" ]; do
    # The token goes to curl on stdin, never on its command line.
    out=$(printf 'header = "Authorization: Bearer %s"\n' "$token" |
      curl -sS -K - -A "c3-watch/1" --max-time $((POLL_WAIT + 15)) \
        -w '\n%{http_code}' "$url/v1/sessions/$code/watch?after=$after&wait=$POLL_WAIT" 2>/dev/null)

    if [ $? -ne 0 ]; then
      sleep "$backoff"
      backoff=$((backoff * 2))
      [ "$backoff" -gt 60 ] && backoff=60
      continue
    fi

    backoff=$RETRY
    status=${out##*"
"}
    body=${out%"
"*}

    case $status in
      200)
        cursor=$(printf '%s\n' "$body" | sed -n 's/^cursor \([0-9][0-9]*\)$/\1/p')
        if [ -n "$cursor" ] && [ "$cursor" != "$after" ]; then
          after=$cursor
          write_state "$file" "$(get url "$file")" "$code" "$name" "$token" "$after"
        fi

        news=$(printf '%s\n' "$body" | grep -v -e '^cursor ' -e '^$')
        if [ -n "$news" ]; then
          printf 'c3 %s %s\n%s\n' "$code" "$name" "$news"
          if printf '%s\n' "$news" | grep -q '^stop '; then
            exit 3
          fi
          relaunch "$key"
          exit 0
        fi
        ;;
      401 | 403 | 404 | 410)
        printf 'c3 %s %s\nstop http_%s %s\n' "$code" "$name" "$status" \
          "$(printf '%s' "$body" | tr -d '\n' | cut -c 1-200)"
        exit 3
        ;;
      429)
        sleep 30
        ;;
      *)
        sleep "$backoff"
        backoff=$((backoff * 2))
        [ "$backoff" -gt 60 ] && backoff=60
        ;;
    esac
  done

  printf 'c3 %s %s\nidle no news for %s s\n' "$code" "$name" "$MAX_SECONDS"
  relaunch "$key"
}

cmd_forget() {
  [ $# -eq 1 ] || usage
  rm -f "$(state_file "$1")"
}

cmd_list() {
  [ -d "$STATE_DIR" ] || exit 0
  for f in "$STATE_DIR"/*; do
    [ -f "$f" ] || continue
    case $f in *.tmp.*) continue ;; esac
    printf '%s url=%s after=%s\n' "${f##*/}" "$(get url "$f")" "$(get after "$f")"
  done
}

command -v curl >/dev/null 2>&1 || { echo "c3-watch: curl is required" >&2; exit 2; }

[ $# -ge 1 ] || usage
sub=$1
shift
case $sub in
  save) cmd_save "$@" ;;
  wait) cmd_wait "$@" ;;
  forget) cmd_forget "$@" ;;
  list) cmd_list "$@" ;;
  *) usage ;;
esac
