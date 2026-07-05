#!/usr/bin/env bash
# Generates a deterministic ASCII payload of the requested byte size once,
# cached under /tmp so repeated calls in the matrix loop don't regenerate it.

payload_file_for_size() {
  local size="$1"
  local f="/tmp/bench-payload-${size}.bin"
  if [[ ! -f "$f" || $(stat -c%s "$f" 2>/dev/null || echo 0) -ne "$size" ]]; then
    head -c "$size" /dev/zero | tr '\0' 'a' > "$f"
  fi
  echo "$f"
}
