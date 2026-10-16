"""Retrieval-quality gate over the real documents.

Runs when a built index is available: App/Resources/rulebook.sqlite (from
scripts/build_resources.sh) or the path in $RULEBOOK_DB. Skipped otherwise, since
building the full index converts slide decks and takes a few minutes. The study-guide
tests also need the private library (ingest/library/eval/study_guide_questions.yaml).
"""

from __future__ import annotations

import os
import sqlite3
import sys
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "ingest" / "eval"))
import eval_retrieval as ev  # noqa: E402

DB = Path(os.environ.get("RULEBOOK_DB", ROOT / "App/Resources/rulebook.sqlite"))
pytestmark = pytest.mark.skipif(not DB.exists(), reason=f"no built index at {DB}")
needs_guides = pytest.mark.skipif(
    not ev.STUDY_GUIDE_QUESTIONS.exists(), reason="study-guide questions are in the private library")


@pytest.fixture(scope="module")
def db():
    return sqlite3.connect(DB)


@needs_guides
def test_every_standalone_study_guide_question_is_answered(db):
    result = ev.study_guide_recall(db, ev.STUDY_GUIDE_QUESTIONS, k=5, verbose=False)
    assert result["total"] > 150
    assert result["misses"] == []


def test_official_questions_hit_at_5(db):
    """Every everyday officials' question finds an expected document in the top 5."""
    questions = yaml.safe_load((ROOT / "ingest/eval/questions.yaml").read_text())["questions"]
    misses = [
        q["q"] for q in questions
        if not any(slug in q["expect"] for slug in ev.search(db, q["q"], 5, q.get("context"), q.get("role")))
    ]
    assert misses == []


@needs_guides
@pytest.mark.parametrize("k", [5, 10])
def test_cited_rules_are_retrieved(db, k):
    """Study-guide questions that cite a rule ("[623.1.1]") retrieve that rule's own passage
    from the ACR/ICR: in the top 5 (what Apple Intelligence reads) and the top 10."""
    result = ev.cited_rule_recall(db, ev.STUDY_GUIDE_QUESTIONS, k=k)
    assert result["total"] > 30
    assert result["misses"] == []
