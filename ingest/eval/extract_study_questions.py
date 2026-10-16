#!/usr/bin/env python3
"""Extract the review questions from the officials' study guides into a test set.

Each question is stored with the study guide and page it comes from and any rule
numbers cited after it ("[601.4.1.1]"). eval_retrieval.py --study-guides then checks
that asking the question retrieves that study guide passage (hit@5), searching as the
official the guide is written for.

The questions are copied from the guides, so the test set lives in the private
library (ingest/library/eval/), not in this repository.

Usage: python3 ingest/eval/extract_study_questions.py   # writes <library>/eval/study_guide_questions.yaml
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

import yaml
from pypdf import PdfReader

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import build_index as bi  # noqa: E402
from eval_retrieval import STUDY_GUIDE_QUESTIONS  # noqa: E402

MARKER = re.compile(r"^(?:[a-z]\.|[A-Z]\.|\d{1,2}\.|\d{1,2}\)|[ivx]+\.|•|-)\s+(?P<rest>.+)$")
QUESTION = re.compile(r"^(?P<q>[A-Z\"“'(][^?]{10,240}\?)\s*(?P<refs>\[[^\]]*\])?")
YES_NO_WORDS = re.compile(r"\b(True|False|Yes|No)\b\s*$")


INTERROGATIVE = re.compile(
    r"(?:^|(?<=[.:;!]\s)|(?<=\s))((?:Who|Whom|Whose|What|When|Where|Why|How|Which|Can|Could|Does|Do|Did|Is|Are|Was|"
    r"Were|Should|Must|May|Might|Will|Would|Has|Have|In what|In which|At what|For what|To whom)\b[^?]*\?)$"
)


def interrogative_tail(text: str) -> str | None:
    """The question itself, without leading list or checklist text:
    "Any 500-point holders are seeded ... III. What is SCORING?" -> "What is SCORING?"."""
    best = None
    for m in INTERROGATIVE.finditer(text):
        best = m.group(1)
        break
    if best is None:
        return None
    # Prefer the shortest tail that still starts at a sentence boundary.
    for boundary in re.finditer(r"[.:;!]\s+(?=[A-Z])", text):
        tail = text[boundary.end():]
        if INTERROGATIVE.fullmatch(tail) and len(tail.split()) >= 4:
            best = tail
    return best.strip()


def questions_in(pdf: Path) -> list[dict]:
    pages = bi.strip_running_text(bi.extract_pages(PdfReader(str(pdf))))
    found = []
    for page_index, lines in enumerate(pages):
        i = 0
        while i < len(lines):
            m = MARKER.match(lines[i])
            if not m:
                i += 1
                continue
            # A question may wrap over up to three lines.
            text = m.group("rest")
            j = i
            while "?" not in text and j + 1 < len(lines) and j - i < 2 and not MARKER.match(lines[j + 1]):
                j += 1
                text += " " + lines[j]
            q = QUESTION.match(text)
            if q:
                refs = bi.rule_refs(q.group("refs") or "")
                if not refs and j + 1 < len(lines) and lines[j + 1].startswith("["):
                    refs = bi.rule_refs(lines[j + 1])
                question = interrogative_tail(re.sub(r"\s+", " ", q.group("q")).strip())
                # Skip fragments that only make sense with their parent item ("Why?", "How?").
                if question and len(question.split()) >= 4:
                    found.append({"q": question, "page": page_index, "rules": refs.split() if refs else []})
            i = j + 1
    return found


def main() -> int:
    _, entries = bi.load_catalog(HERE.parent / "catalog.yaml")
    guides = [e for e in entries if e["slug"].startswith("sg-")]
    docs = bi.default_docs(bi.DEFAULT_LIBRARY)
    output = {"generated_by": "ingest/eval/extract_study_questions.py", "guides": []}
    total = 0
    for entry in guides:
        pdf = next((f for f in docs.iterdir() if bi.match_entry(f.name, entries) is entry), None)
        if pdf is None:
            print(f"warning: no file for {entry['slug']}", file=sys.stderr)
            continue
        questions = questions_in(pdf)
        # Same question asked twice in one guide: keep the first.
        seen, unique = set(), []
        for q in questions:
            if q["q"].lower() not in seen:
                seen.add(q["q"].lower())
                unique.append(q)
        roles = entry.get("roles", [])
        output["guides"].append({"slug": entry["slug"], "role": roles[0] if roles else None, "questions": unique})
        total += len(unique)
        print(f"{entry['slug']}: {len(unique)} questions")
    out = STUDY_GUIDE_QUESTIONS
    out.parent.mkdir(parents=True, exist_ok=True)
    # Keep reviewed `also:` lists (extra documents verified to answer a question) across re-runs.
    if out.exists():
        reviewed = {q["q"]: q["also"] for g in yaml.safe_load(out.read_text())["guides"] for q in g["questions"] if q.get("also")}
        for guide in output["guides"]:
            for q in guide["questions"]:
                if q["q"] in reviewed:
                    q["also"] = reviewed[q["q"]]
    out.write_text(yaml.safe_dump(output, sort_keys=False, allow_unicode=True, width=120))
    print(f"Wrote {total} questions to {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
