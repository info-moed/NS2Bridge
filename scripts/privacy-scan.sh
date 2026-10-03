#!/bin/bash
# Fails if personal data would be published: home-folder paths, email addresses or controller serial numbers.
#
#   ./scripts/privacy-scan.sh              # every file tracked by git
#   ./scripts/privacy-scan.sh <dir|file>…  # e.g. an unpacked release zip (binaries are scanned too)
#
# Allowed on purpose: placeholders like /Users/<you>, GitHub's noreply addresses, the SDL license's author address.
set -euo pipefail
cd "$(dirname "$0")/.."

list() { if [ $# -eq 0 ]; then git ls-files; else find "$@" -type f; fi; }   # (bash 3.2: no mapfile)

patterns=(
    '/Users/[A-Za-z0-9._-]+/'                                   # home folders
    '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'            # email addresses
    '\bH[A-Z]{2}[0-9]{11}\b'                                    # Nintendo controller serial numbers
)
allowed='/Users/(runner|Shared|<[^>]*>)/|users\.noreply\.github\.com|noreply@anthropic\.com|slouken@libsdl\.org|ns2bridge@users\.noreply'

found=0
count=0
while IFS= read -r f; do
    [ -f "$f" ] || continue
    count=$((count + 1))
    for p in "${patterns[@]}"; do
        if hits=$(grep -a -o -E "$p" "$f" 2>/dev/null | grep -v -E "$allowed" | sort -u) && [ -n "$hits" ]; then
            printf '%s:\n' "$f"
            while IFS= read -r h; do printf '    %s\n' "$h"; done <<< "$hits"
            found=1
        fi
    done
done < <(list "$@")
if [ "$found" -eq 1 ]; then echo "Privacy scan: personal data found (see above)."; exit 1; fi
echo "Privacy scan: clean ($count files)."
