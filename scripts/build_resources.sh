#!/usr/bin/env bash
# Rebuild the bundled search index and copy the documents (as PDFs) into the app.
#   scripts/build_resources.sh                 # ingest/library/documents/ (private submodule),
#                                              # else ingest/documents/ (your own downloads)
#   scripts/build_resources.sh ~/some/folder   # or another folder of PDF/PPTX/PPT files
# Slide decks need LibreOffice (brew install --cask libreoffice); scanned PDFs are
# made searchable when ocrmypdf is installed (brew install ocrmypdf).
set -euo pipefail
cd "$(dirname "$0")/.."

python3 -m pip install --quiet -r ingest/requirements.txt
if [ $# -gt 0 ]; then
  python3 ingest/build_index.py --docs "$1"
else
  python3 ingest/build_index.py
fi

if [ -f ingest/eval/questions.yaml ]; then
  python3 ingest/eval/eval_retrieval.py --db App/Resources/rulebook.sqlite | tail -1
fi
