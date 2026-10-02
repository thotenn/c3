#!/bin/sh
# c3-attach.sh — sends files from disk as C3 attachments, and downloads them, without the
# content passing through the agent. Uses the state c3-watch.sh saved (url, code, token).
#
# Only needs sh, curl, base64, sed and awk: Linux, macOS and Git Bash on Windows.
#
#   c3-attach.sh post <key> <thread> [--kind note|request|response] [--to AG2] [--reply-to T1.2] [--body TEXT] FILE...
#   c3-attach.sh open <key> --title TITLE [--to AG2] [--body TEXT] FILE...
#   c3-attach.sh get <key> <attachment-id> [OUT]
#
# `post` posts to a thread (kind `note` by default), `open` opens a thread with a first
# request; both print the JSON the server answers. `--body -` reads the body from stdin.
# `get` saves an attachment to OUT (default: its id in the current directory) and prints
# the path. Every file goes as base64; the server keeps its name (last path segment) and
# serves it back as a download. Exit 1 on an HTTP error (the error body goes to stderr),
# 2 on a usage error.

set -u

STATE_DIR=${C3_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/c3}
SELF=$0

usage() {
  sed -n '7,9p' "$SELF" | sed 's/^# *//' >&2
  exit 2
}

state_file() {
  case $1 in
    "" | */* | *..*) echo "c3-attach: bad key '$1'" >&2; exit 2 ;;
  esac
  f="$STATE_DIR/$1"
  [ -f "$f" ] || { echo "c3-attach: no state for $1 (save it with c3-watch.sh first)" >&2; exit 2; }
  printf '%s\n' "$f"
}

get() { sed -n "s/^$1=//p" "$2" | head -n 1; }

# A JSON string from stdin: escapes \ and ", turns tabs, CRs and newlines into escapes and
# drops the other control characters.
json_string() {
  LC_ALL=C awk '
    BEGIN { printf "\"" }
    {
      gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\t/, "\\t"); gsub(/\r/, "\\r")
      gsub(/[\001-\010\013\014\016-\037\177]/, "")
      if (NR > 1) printf "\\n"
      printf "%s", $0
    }
    END { printf "\"" }'
}

str() { printf '%s' "$1" | json_string; }

# POSTs the JSON in $2 to $1 with the token in $3 (on stdin, never on the command line).
send() {
  out=$(printf 'header = "Authorization: Bearer %s"\n' "$3" |
    curl -sS -K - -A "c3-attach/1" -H 'content-type: application/json' \
      --data-binary "@$2" -w '\n%{http_code}' "$1") || { echo "c3-attach: request failed" >&2; exit 1; }
  status=${out##*"
"}
  body=${out%"
"*}
  if [ "$status" -ge 400 ] 2>/dev/null; then
    printf 'HTTP %s %s\n' "$status" "$body" >&2
    exit 1
  fi
  printf '%s\n' "$body"
}

# Writes the request body to $tmp: the fields gathered so far, then each file as base64.
build() {
  {
    printf '{'
    printf '%s' "$fields"
    printf '"attachments":['
    sep=
    for path in "$@"; do
      printf '%s{"filename":%s,"base64":"' "$sep" "$(str "${path##*/}")"
      base64 <"$path" | tr -d '\n\r'
      printf '"}'
      sep=,
    done
    printf ']}'
  } >"$tmp"
}

cmd_send() {
  mode=$1
  shift
  [ $# -ge 1 ] || usage
  file=$(state_file "$1") || exit 2
  shift

  thread=
  if [ "$mode" = post ]; then
    [ $# -ge 1 ] || usage
    thread=$1
    shift
  fi

  kind=note to= reply_to= title= body="See attached."
  while [ $# -gt 0 ]; do
    case $1 in
      --kind) kind=${2:?}; shift 2 ;;
      --to) to=${2:?}; shift 2 ;;
      --reply-to) reply_to=${2:?}; shift 2 ;;
      --title) title=${2:?}; shift 2 ;;
      --body)
        if [ "${2:?}" = - ]; then body=$(cat); else body=$2; fi
        shift 2
        ;;
      --) shift; break ;;
      -*) usage ;;
      *) break ;;
    esac
  done

  [ $# -ge 1 ] || { echo "c3-attach: no files" >&2; exit 2; }
  for path in "$@"; do
    [ -f "$path" ] && [ -r "$path" ] || { echo "c3-attach: cannot read $path" >&2; exit 2; }
  done

  url=${C3_URL:-$(get url "$file")}
  url=${url%/}
  code=$(get code "$file") token=$(get token "$file")

  fields="\"body\":$(str "$body"),"
  [ -n "$to" ] && fields="$fields\"to\":$(str "$to"),"

  if [ "$mode" = open ]; then
    [ -n "$title" ] || { echo "c3-attach: open needs --title" >&2; exit 2; }
    fields="$fields\"title\":$(str "$title"),"
    target="$url/v1/sessions/$code/threads"
  else
    fields="$fields\"kind\":$(str "$kind"),"
    [ -n "$reply_to" ] && fields="$fields\"reply_to\":$(str "$reply_to"),"
    target="$url/v1/threads/$thread/messages"
  fi

  tmp=$(mktemp "${TMPDIR:-/tmp}/c3-attach.XXXXXX") || exit 1
  trap 'rm -f "$tmp"' EXIT
  build "$@"
  send "$target" "$tmp" "$token"
}

cmd_get() {
  [ $# -ge 2 ] && [ $# -le 3 ] || usage
  file=$(state_file "$1") || exit 2
  id=$2
  case $id in *[!0-9]* | "") echo "c3-attach: bad attachment id '$id'" >&2; exit 2 ;; esac
  out=${3:-$id}

  url=${C3_URL:-$(get url "$file")}
  url=${url%/}
  token=$(get token "$file")

  status=$(printf 'header = "Authorization: Bearer %s"\n' "$token" |
    curl -sS -K - -A "c3-attach/1" -o "$out" -w '%{http_code}' "$url/v1/attachments/$id") ||
    { echo "c3-attach: request failed" >&2; exit 1; }

  if [ "$status" -ge 400 ] 2>/dev/null; then
    printf 'HTTP %s %s\n' "$status" "$(cat "$out")" >&2
    rm -f "$out"
    exit 1
  fi
  printf '%s\n' "$out"
}

command -v curl >/dev/null 2>&1 || { echo "c3-attach: curl is required" >&2; exit 2; }

[ $# -ge 1 ] || usage
sub=$1
shift
case $sub in
  post | open) cmd_send "$sub" "$@" ;;
  get) cmd_get "$@" ;;
  *) usage ;;
esac
