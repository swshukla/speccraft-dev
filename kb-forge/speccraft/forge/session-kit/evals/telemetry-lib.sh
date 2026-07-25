#!/bin/sh
# kb-forge evals — telemetry append helper. POSIX sh: sourced by bash session
# hooks AND sh git hooks. Fire-and-forget: nothing here may fail the caller.
# Contract: kb_telemetry <event> [detail]. Needs $KB (.speccraft/ dir); optional
# $KB_SESSION_ID. detail must not contain double quotes.
kb_telemetry() {
  [ -n "${KB:-}" ] || return 0
  [ -d "$KB" ] || return 0
  _f="$KB/evals/telemetry.jsonl"
  mkdir -p "$KB/evals" 2>/dev/null || return 0
  if [ -f "$_f" ] && [ "$(wc -c < "$_f" 2>/dev/null || echo 0)" -gt 5242880 ]; then
    tail -n 10000 "$_f" > "$_f.tmp" 2>/dev/null && mv "$_f.tmp" "$_f" 2>/dev/null
  fi
  printf '{"ts":"%s","session":"%s","event":"%s","detail":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${KB_SESSION_ID:-nosession}" \
    "$1" "${2:-}" >> "$_f" 2>/dev/null || true
  return 0
}
