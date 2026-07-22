#!/bin/bash
# Deterministic tripwire checker. Usage: check-tripwires.sh <patterns> <artifact>...
# Prints TRIP: <pattern> per hit and HITS: <n>. Exit 0 always.
set -u
P="$1"; shift
HITS=0
while IFS= read -r pat; do
  [ -z "$pat" ] && continue
  if grep -qE "$pat" "$@" 2>/dev/null; then echo "TRIP: $pat"; HITS=$((HITS+1)); fi
done < "$P"
echo "HITS: $HITS"
exit 0
