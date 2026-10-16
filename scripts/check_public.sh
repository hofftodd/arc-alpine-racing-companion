#!/usr/bin/env bash
# Fails if this (public) repository tracks anything that must stay in the private library:
# the reference documents, text copied from them, or unexpectedly large files.
# Run it before every commit:  scripts/check_public.sh
set -euo pipefail
cd "$(dirname "$0")/.."

status=0
fail() { echo "check_public: $1" >&2; status=1; }

# Staged and committed files (the submodule itself is a link, not its contents).
files=$(git ls-files --cached)

# Reference documents. Only the synthetic test fixture (built by make_fixture.py) is allowed.
while IFS= read -r f; do
  [ -n "$f" ] && fail "document file tracked: $f"
done < <(printf '%s\n' "$files" | grep -iE '\.(pdf|ppt|pptx|doc|docx|key)$' || true)

# Text copied from the documents.
while IFS= read -r f; do
  [ -n "$f" ] && fail "private library file tracked: $f (it belongs in ingest/library/)"
done < <(printf '%s\n' "$files" | grep -E '(^|/)study_guide_questions\.yaml$|^ingest/supplements/|^ingest/documents/' || true)

# Anything big is suspicious (rendered pages, built indexes, model weights).
while IFS= read -r f; do
  [ -f "$f" ] || continue
  size=$(wc -c <"$f")
  [ "$size" -gt 5000000 ] && fail "file over 5 MB: $f ($size bytes)"
done <<<"$files"

[ $status -eq 0 ] && echo "check_public: OK ($(printf '%s\n' "$files" | wc -l | tr -d ' ') files)"
exit $status
