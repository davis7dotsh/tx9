# MCP initialize/validate/delete-session handshake, sourced by both ./box
# (host) and guest/hb (guest) so their health checks can't drift apart.
#
# Callers that track temp files for signal-safe cleanup (currently only
# ./box) must define _track_temp before sourcing this file; other callers
# don't need it since every path below already rm -f's its temp files.
declare -f _track_temp >/dev/null 2>&1 || _track_temp() { :; }

_mcp_delete_session() {
  local url="$1" token="$2" session="$3"
  curl -sS --connect-timeout 2 --max-time 5 -o /dev/null -X DELETE \
    -H "Authorization: Bearer $token" \
    -H 'Accept: application/json,text/event-stream' \
    -H "Mcp-Session-Id: $session" "$url" >/dev/null 2>&1 || true
}

_mcp_response_valid() {
  local body="$1" content_type="$2" filter
  filter='type == "object" and .jsonrpc == "2.0" and .id == 1 and
    has("result") and (has("error") | not) and
    (.result | type == "object") and
    .result.protocolVersion == "2025-03-26" and
    (.result.serverInfo | type == "object") and
    (.result.serverInfo.name | type == "string" and length > 0) and
    (.result.serverInfo.version | type == "string") and
    (.result.capabilities | type == "object")'
  case "$content_type" in
    application/json*) jq -e "$filter" "$body" >/dev/null 2>&1 ;;
    text/event-stream*) sed -n 's/^data:[[:space:]]*//p' "$body" | jq -e "$filter" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

_mcp_initialize() {
  local url="$1" token="$2" headers body code session content_type initialized_code initialized_ok=0
  headers="$(mktemp)" || return 1
  body="$(mktemp)" || { rm -f -- "$headers"; return 1; }
  _track_temp "$headers"
  _track_temp "$body"
  if ! code="$(curl -sS --connect-timeout 2 --max-time 5 -D "$headers" -o "$body" -w '%{http_code}' \
    -X POST \
    -H "Authorization: Bearer $token" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json,text/event-stream' \
    --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"hermes-box-doctor","version":"1"}}}' \
    "$url")"; then
    rm -f -- "$headers" "$body"
    return 1
  fi
  session="$(awk 'tolower($1) == "mcp-session-id:" { sub(/^[^:]*:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit }' "$headers")"
  content_type="$(awk 'tolower($1) == "content-type:" { sub(/^[^:]*:[[:space:]]*/, ""); sub(/\r$/, ""); print tolower($0); exit }' "$headers")"
  if [[ "$code" != 200 || -z "$session" ]] || ! _mcp_response_valid "$body" "$content_type"; then
    rm -f -- "$headers" "$body"
    [[ -n "$session" ]] && _mcp_delete_session "$url" "$token" "$session"
    return 1
  fi
  if initialized_code="$(curl -sS --connect-timeout 2 --max-time 5 -o /dev/null -w '%{http_code}' \
    -X POST \
    -H "Authorization: Bearer $token" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json,text/event-stream' \
    -H "Mcp-Session-Id: $session" \
    --data '{"jsonrpc":"2.0","method":"notifications/initialized"}' "$url")" &&
    [[ "$initialized_code" == 202 ]]; then
    initialized_ok=1
  fi
  rm -f -- "$headers" "$body"
  _mcp_delete_session "$url" "$token" "$session"
  [[ "$initialized_ok" == 1 ]]
}
