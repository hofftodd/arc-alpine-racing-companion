"""Unit tests for the ranking helpers in ingest/eval/eval_retrieval.py (mirrored in HybridRetriever.swift)."""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "eval"))
import eval_retrieval as ev  # noqa: E402

GUIDE = "4. Protest submittal deadlines depend on the kind of protest [643] 5. Who can submit protests? [645] a. Team captains"


def test_cited_rule_comes_from_the_most_similar_sentence():
    assert ev.cited_rules_near(GUIDE, ev.terms("Who can submit protests?"), 1) == ["645"]


def test_echo_score():
    question = ev.topical_stems(ev.terms("Who can submit protests?"))
    assert ev.echo_score(GUIDE, question) == 1.0
    assert ev.echo_score("Protests must be in writing.", question) == 0


def test_topical_stems_drop_generic_words():
    assert ev.topical_stems(ev.terms("What timing system should be used?")) == {"timin", "syste"}
