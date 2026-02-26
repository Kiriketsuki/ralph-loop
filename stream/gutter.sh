#!/bin/bash

# stream/gutter.sh - Ralph gutter/stuck-loop detector
#
# Reads the last N entries from .ralph/progress.md and detects:
#   1. Same-task repetition: same task attempted 3+ times in a row
#   2. Ping-pong pattern: alternating A-B-A-B task pattern
#
# Exit codes:
#   0 = no gutter detected
#   1 = gutter detected (agent is in a rut, human review needed)
#
# Usage: bash .ralph/stream/gutter.sh
# Environment:
#   RALPH_GUTTER_LOOKBACK - Number of recent progress entries to examine (default: 6)
#   PROGRESS_FILE         - Path to progress.md (default: .ralph/progress.md)

# NOTE: Parallel-agent limitation — when multiple agents in the same batch work on
# different tasks, their progress entries carry different task IDs and iteration numbers,
# so the 40-char fingerprint differs between entries even if the summaries are identical.
# This means same-task repetition detection cannot fire within a single parallel batch.
# Gutter detection remains effective across sequential batches (e.g. the same task failing
# repeatedly across multiple batch cycles will be caught by the repetition check).
PROGRESS_FILE="${PROGRESS_FILE:-.ralph/progress.md}"
LOOKBACK="${RALPH_GUTTER_LOOKBACK:-6}"

if [ ! -f "$PROGRESS_FILE" ]; then
    # No progress file yet -- no gutter possible
    exit 0
fi

# Extract the last LOOKBACK task references from progress entries.
# Progress format: - **[YYYY-MM-DD HH:MM]** (Iteration N) type: summary
# We look for task IDs mentioned in parentheses after "Iteration N" -- the iteration number
# is a proxy for task sequence. We extract the task name from the summary where possible.
# Simpler approach: extract the iteration numbers and the type+summary for pattern matching.

# Scan full file for progress entries, take last LOOKBACK. Avoids the fragile
# LOOKBACK*3 heuristic that undersamples when entries are multi-line or separated by blanks.
# progress.md is bounded by iteration count (~100 lines max), so O(n) is negligible.
RECENT=$(grep -E '^\- \*\*\[.*\]\*\* \(Iteration [0-9]+\)' "$PROGRESS_FILE" \
    | tail -n "$LOOKBACK" \
    | sed 's/.*Iteration [0-9]*) //')

if [ -z "$RECENT" ]; then
    exit 0
fi

# Build array of task summaries (one per line)
# Using a while-read loop instead of mapfile for bash 3.2 compatibility (macOS default shell).
ENTRIES=()
while IFS= read -r entry_line; do
    ENTRIES+=("$entry_line")
done <<< "$RECENT"
COUNT="${#ENTRIES[@]}"

if [ "$COUNT" -lt 3 ]; then
    # Not enough history to detect patterns
    exit 0
fi

# --- Detection 1: Same-task 3+ times in a row ---
# Extract first token of each entry as a task fingerprint
PREV=""
REPEAT=0
for entry in "${ENTRIES[@]}"; do
    # Use the first 40 chars as fingerprint (enough to catch same task description)
    FINGERPRINT="${entry:0:40}"
    if [ -z "$FINGERPRINT" ]; then
        # Reset repeat counter so an empty entry cannot bridge two identical non-empty
        # entries and inflate the count, causing a false positive (e.g. A,A,"",A).
        REPEAT=0
        continue
    fi
    if [ "$FINGERPRINT" = "$PREV" ]; then
        REPEAT=$(( REPEAT + 1 ))
        if [ "$REPEAT" -ge 2 ]; then
            # Same entry appeared 3+ times (prev set on first match, +1 twice)
            printf 'GUTTER: Same task repeated %d times in a row: "%s"\n' "$(( REPEAT + 1 ))" "$FINGERPRINT" >&2
            exit 1
        fi
    else
        REPEAT=0
    fi
    PREV="$FINGERPRINT"
done

# --- Detection 2: Ping-pong A-B-A-B pattern ---
if [ "$COUNT" -ge 4 ]; then
    # Check last 4 entries for A != B, entries[0]==entries[2] and entries[1]==entries[3]
    # Arithmetic indexing avoids negative indices which require bash 4.3+ (not available on macOS default).
    A="${ENTRIES[$((COUNT-4))]:0:40}"
    B="${ENTRIES[$((COUNT-3))]:0:40}"
    C="${ENTRIES[$((COUNT-2))]:0:40}"
    D="${ENTRIES[$((COUNT-1))]:0:40}"
    if [ "$A" != "$B" ] && [ "$A" = "$C" ] && [ "$B" = "$D" ]; then
        printf 'GUTTER: Ping-pong pattern detected (A-B-A-B): "%s" <-> "%s"\n' "$A" "$B" >&2
        exit 1
    fi
fi

exit 0
