#!/usr/bin/env bash
#
# Migrate a journal tree from the old worklog format to Blotter.
#
# For every `*.wkl` file under the given root (recursively) this:
#   * rewrites each block header `--- worklog ... ---` to `--- blots ... ---`
#     (summary section headers `--- summary/tags/locations/logged/totals ---`
#     are left untouched), and
#   * renames the file `.wkl` -> `.blot`.
#
# The clean-cut rename dropped support for the old format, so existing files must
# be converted once. This is safe to run repeatedly: it only ever touches `.wkl`
# files, and it skips any whose `.blot` already exists.
#
# Usage:
#   scripts/migrate-to-blotter.sh <journal-root>            # dry run (default)
#   scripts/migrate-to-blotter.sh --apply <journal-root>    # do it
#   scripts/migrate-to-blotter.sh --apply --backup <root>   # keep each .wkl as .wkl.bak
#
# <journal-root> is your `journal.root` from require("blotter").setup({ journal = ... }).

set -euo pipefail

apply=0
backup=0
root=""

usage() {
  sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

for arg in "$@"; do
  case "$arg" in
    --apply) apply=1 ;;
    --backup) backup=1 ;;
    -h | --help) usage 0 ;;
    -*) echo "unknown option: $arg" >&2; usage 1 ;;
    *) root="$arg" ;;
  esac
done

[ -n "$root" ] || { echo "error: missing <journal-root>" >&2; usage 1; }
[ -d "$root" ] || { echo "error: not a directory: $root" >&2; exit 1; }

# A line is a worklog block header when it is `--- worklog` with the keyword as its
# own word -- followed by whitespace (before any options) or by the closing dashes.
# This mirrors the parser, so `--- worklogs ---` and entry text are never matched.
header_re='^--- worklog([[:space:]]|---)'
# Rewrite only the leading keyword, preserving any `#tag @loc q=N ...` and the close.
rewrite='/^--- worklog([[:space:]]|---)/ s/^(--- )worklog/\1blots/'

files=0
converted=0
skipped=0
headers=0

while IFS= read -r -d '' f; do
  files=$((files + 1))
  target="${f%.wkl}.blot"

  if [ -e "$target" ]; then
    echo "skip (target exists): $f"
    skipped=$((skipped + 1))
    continue
  fi

  n=$(grep -cE "$header_re" "$f" || true)
  headers=$((headers + n))

  if [ "$apply" -eq 1 ]; then
    tmp="$target.tmp.$$"
    sed -E "$rewrite" "$f" > "$tmp"
    mv "$tmp" "$target"
    if [ "$backup" -eq 1 ]; then
      mv "$f" "$f.bak"
    else
      rm "$f"
    fi
    echo "converted ($n header(s)): $f -> $target"
  else
    echo "would convert ($n header(s)): $f -> $target"
  fi
  converted=$((converted + 1))
done < <(find "$root" -type f -name '*.wkl' -print0)

echo
if [ "$apply" -eq 1 ]; then
  echo "done: converted $converted file(s) ($headers header(s)), skipped $skipped, of $files .wkl found."
else
  echo "dry run: $converted file(s) ($headers header(s)) would convert, $skipped would skip, of $files .wkl found."
  echo "re-run with --apply to perform the migration (add --backup to keep .wkl.bak copies)."
fi
