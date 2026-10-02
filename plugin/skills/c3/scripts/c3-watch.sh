#!/bin/sh
# c3-watch.sh — the C3 watcher: waits in the background until something in a C3 session
# concerns this agent, prints it, and exits, so Claude Code wakes the agent up.
#
# Only needs sh + curl: Linux, macOS and Git Bash on Windows.
#
#   c3-watch.sh save <url> <code> <name>   # token on stdin; prints the key; then read the inbox
#   c3-watch.sh wait <key>                 # run with run_in_background; exits on the first news
#   c3-watch.sh forget <key>               # after leaving or closing the session
#   c3-watch.sh list                       # saved keys (never the tokens)
#
# State: one file per (session, agent) in $C3_STATE_DIR (default
# ${XDG_STATE_HOME:-$HOME/.local/state}/c3), outside any repository, mode 600: url, code,
# name, token and the cursor `after`, saved after every poll so a restart loses nothing.
# A new `save` starts the cursor at the session's current end, so the watcher only reports
# what happens after it: read the inbox right after saving for what was already waiting.
#
# `wait` long-polls GET <url>/v1/sessions/<code>/watch, which answers a `cursor <seq>` line
# and one line per event that concerns the agent (the server decides). It exits 0 with
# those lines, with an `idle` line after C3_WATCH_MAX_SECONDS without news, or with a
# `stop` line when the session is closed or the token no longer works — always exit 0; the
# lines say what happened. Every exit but a stop ends with the exact command to relaunch
# it. A network error is retried with backoff. Exit 2 is a usage error.

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

# GET /watch once; sets `status` and `body`. Returns curl's exit status.
poll() {
  out=$(printf 'header = "Authorization: Bearer %s"\n' "$2" |
    curl -sS -K - -A "c3-watch/1" --max-time $(($4 + 15)) \
      -w '\n%{http_code}' "$1/watch?after=$3&wait=$4" 2>/dev/null) || return
  status=${out##*"
"}
  body=${out%"
"*}
}

cursor_of() { printf '%s\n' "$1" | sed -n 's/^cursor \([0-9][0-9]*\)$/\1/p'; }

# The session's last seq, paging /watch with wait=0 until the cursor stops moving; 0 if the
# server cannot be reached.
current_end() {
  at=0
  while poll "$1" "$2" "$at" 0 && [ "$status" = 200 ]; do
    next=$(cursor_of "$body")
    [ -n "$next" ] && [ "$next" != "$at" ] || break
    at=$next
  done
  echo "$at"
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
  if [ -f "$file" ] && [ "$(get token "$file")" = "$token" ]; then
    after=$(get after "$file")
  else
    after=$(current_end "$url/v1/sessions/$code" "$token")
  fi
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
    if ! poll "$url/v1/sessions/$code" "$token" "$after" "$POLL_WAIT"; then
      sleep "$backoff"
      backoff=$((backoff * 2))
      [ "$backoff" -gt 60 ] && backoff=60
      continue
    fi

    backoff=$RETRY

    case $status in
      200)
        cursor=$(cursor_of "$body")
        if [ -n "$cursor" ] && [ "$cursor" != "$after" ]; then
          after=$cursor
          write_state "$file" "$(get url "$file")" "$code" "$name" "$token" "$after"
        fi

        news=$(printf '%s\n' "$body" | grep -v -e '^cursor ' -e '^$')
        if [ -n "$news" ]; then
          printf 'c3 %s %s\n%s\n' "$code" "$name" "$news"
          if printf '%s\n' "$news" | grep -q '^stop '; then
            exit 0
          fi
          relaunch "$key"
          exit 0
        fi
        ;;
      401 | 403 | 404 | 410)
        printf 'c3 %s %s\nstop http_%s %s\n' "$code" "$name" "$status" \
          "$(printf '%s' "$body" | tr -d '\n' | cut -c 1-200)"
        exit 0
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
