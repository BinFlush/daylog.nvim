#!/usr/bin/env bash
#
# Migrate a daybook tree to Daylog from an older format.
#
# Converts every legacy file under <root> straight to the current Daylog format:
#   * a worklog file (`*.wkl`, `--- worklog ... ---`)  -> `*.day`, `--- log ... ---`
#   * a blotter file (`*.blot`, `--- blots ... ---`)   -> `*.day`, `--- log ... ---`
# (summary section headers `--- summary/tags/locations/logged/totals ---` are left
# untouched.) Each clean-cut rename dropped support for the old format, so existing
# files must be converted once. Safe to run repeatedly: it only touches the source
# extension and skips any file whose `.day` target already exists.
#
# Pick the source format with --from, or let it auto-detect (it prompts if both
# `*.wkl` and `*.blot` are present under <root>).
#
# Usage:
#   scripts/migrate-to-daylog.sh <root>                        # dry run (default)
#   scripts/migrate-to-daylog.sh --from=blot --apply <root>    # do it
#   scripts/migrate-to-daylog.sh --apply --backup <root>       # keep each source as .bak
#
# <root> is your `daybook.root` from require("daylog").setup({ daybook = ... }).

set -euo pipefail

apply=0
backup=0
from=""
root=""

usage() {
  sed -n '3,21p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) apply=1 ;;
    --backup) backup=1 ;;
    --from) shift; from="${1:-}" ;;
    --from=*) from="${1#--from=}" ;;
    -h | --help) usage 0 ;;
    -*) echo "unknown option: $1" >&2; usage 1 ;;
    *) root="$1" ;;
  esac
  shift
done

[ -n "$root" ] || { echo "error: missing <root>" >&2; usage 1; }
[ -d "$root" ] || { echo "error: not a directory: $root" >&2; exit 1; }

# Pick the source format. With no --from, auto-detect; if both legacy formats are
# present, ask which one to migrate.
if [ -z "$from" ]; then
  has_wkl=0
  has_blot=0
  [ -n "$(find "$root" -type f -name '*.wkl' -print -quit)" ] && has_wkl=1 || true
  [ -n "$(find "$root" -type f -name '*.blot' -print -quit)" ] && has_blot=1 || true

  if [ "$has_wkl" -eq 1 ] && [ "$has_blot" -eq 1 ]; then
    printf 'Both .wkl and .blot found. Migrate from .wkl (worklog) or .blot (blotter)? [wkl/blot] ' >&2
    read -r from
  elif [ "$has_wkl" -eq 1 ]; then
    from="wkl"
    echo "detected .wkl files" >&2
  elif [ "$has_blot" -eq 1 ]; then
    from="blot"
    echo "detected .blot files" >&2
  else
    echo "no .wkl or .blot files found under $root; nothing to do." >&2
    exit 0
  fi
fi

case "$from" in
  wkl) src_ext="wkl"; src_kw="worklog" ;;
  blot) src_ext="blot"; src_kw="blots" ;;
  *) echo "error: --from must be 'wkl' or 'blot' (got '$from')" >&2; exit 1 ;;
esac

# A line is an old block header when the source keyword is its own word -- followed
# by whitespace (before any options) or by the closing dashes. This mirrors the old
# parser, so a near-miss like `--- worklogs ---` and entry text are never matched.
header_re="^--- ${src_kw}([[:space:]]|---)"
# Rewrite only the leading keyword, preserving any `#tag @loc q=N ...` and the close.
rewrite="/^--- ${src_kw}([[:space:]]|---)/ s/^(--- )${src_kw}/\\1log/"

files=0
converted=0
skipped=0
headers=0

while IFS= read -r -d '' f; do
  files=$((files + 1))
  target="${f%.${src_ext}}.day"

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
done < <(find "$root" -type f -name "*.${src_ext}" -print0)

echo
if [ "$apply" -eq 1 ]; then
  echo "done: converted $converted .${src_ext} file(s) ($headers header(s)), skipped $skipped, of $files found."
else
  echo "dry run: $converted .${src_ext} file(s) ($headers header(s)) would convert, $skipped would skip, of $files found."
  echo "re-run with --apply to perform the migration (add --backup to keep .bak copies)."
fi
