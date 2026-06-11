#!/usr/bin/env bash
set -euo pipefail

# Usage: release_notes.sh <version>
# Extracts the changelog section body for <version> from CHANGELOG.md.
# Prints everything between "## [<version>]" and the next "## [" line (exclusive),
# stripping leading/trailing blank lines.

VERSION="${1:?usage: release_notes.sh <version>}"
CHANGELOG="${CHANGELOG:-CHANGELOG.md}"

awk -v ver="$VERSION" '
    /^## \[/ {
        if (in_section) exit
        if ($0 ~ "^## \\[" ver "\\]") in_section = 1
        next
    }
    in_section { lines[++n] = $0 }
    END {
        # strip leading blank lines
        start = 1
        while (start <= n && lines[start] ~ /^[[:space:]]*$/) start++
        # strip trailing blank lines
        end = n
        while (end >= start && lines[end] ~ /^[[:space:]]*$/) end--
        for (i = start; i <= end; i++) print lines[i]
    }
' "$CHANGELOG"
