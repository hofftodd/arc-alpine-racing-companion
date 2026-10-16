#!/usr/bin/env python3
"""Measure keyword-retrieval quality (hit@k) against eval/questions.yaml.

A BM25 baseline that mirrors the app's keyword search, document priorities,
race-context weights and role boosts. The app adds semantic search on top, so
on-device recall should be at least this good.

Usage: python3 ingest/eval/eval_retrieval.py --db App/Resources/rulebook.sqlite [-k 5] [-v]
"""

from __future__ import annotations

import argparse
import re
import sqlite3
import sys
from pathlib import Path

import yaml

# Copied from the study guides, so kept in the private library (see build_index.py).
STUDY_GUIDE_QUESTIONS = Path(__file__).resolve().parents[1] / "library/eval/study_guide_questions.yaml"

STOPWORDS = set(
    "a about an and are as at be by can could do does for from how i if in is it its me my of on or our should so "
    "that the their there they this to us was we what when where which who why will with would you your rule rules "
    "too very also just not than then much many more most any all".split()
)
ABBREVIATIONS = {"td": "technical delegate", "dnf": "did not finish", "dns": "did not start", "dsq": "disqualified",
                 "gs": "giant slalom", "sl": "slalom", "dh": "downhill", "hs": "high school"}
# Keep in sync with RaceContext / OfficialRole in Packages/RulebookKit/Sources/RulebookKit/AnswerContext.swift.
CONTEXT_WEIGHTS = {
    "oisra": {"oisra": 2.5, "usss": 1.0, "fis": 0.9, "reference": 1.0},
    "usss": {"oisra": 0.3, "usss": 1.2, "fis": 1.0, "reference": 1.0},
    "fis": {"oisra": 0.3, "usss": 0.9, "fis": 1.3, "reference": 1.0},
    None: {"oisra": 0.6, "usss": 1.0, "fis": 1.0, "reference": 1.0},
}
ROLE_BOOST = 1.4
PRECISION_WEIGHT = 1.0  # all-terms keyword pass; HybridRetriever uses the same weight
# Words that say nothing about the topic; questions left with fewer than two other
# terms ("What timing system should be used?") are too vague to grade on their own.
GENERIC = set("use used using available being get given there any some one need needs needed required allowed".split())
BACK_REFERENCE = re.compile(r"\b(this|that|these|those|they|them|their|she|he|her|his|it|its)\b", re.IGNORECASE)


HEADING_COVER_BOOST = 1.5  # heading contains every topical term of the question
ECHO_MIN = 0.6             # Jaccard similarity for "this passage asks the same question"
ECHO_PROMOTE = 2           # passages moved to the front when they echo the question


def topical_stems(words: list[str]) -> set[str]:
    """First five letters of the non-generic terms: crude stemming ("referees" ~ "referee")."""
    return {w[:5] for w in words if w not in GENERIC}


def jaccard(a: set[str], b: set[str]) -> float:
    return len(a & b) / len(a | b) if a and b else 0.0


SENTENCE_BREAK = re.compile(r"(?<=[.!\]])\s+(?=[A-Z])|\s(?=[a-z]\.\s)|\s(?=\d{1,2}\.\s)")
QUESTION_CLAUSE_BREAK = re.compile(r"(?<=[.!\]])\s+|\s(?=[a-z]\.\s)|\s(?=\d{1,2}\.\s)")


def echo_score(text: str, question_stems: set[str]) -> float:
    """How closely a question asked in `text` matches the user's question. Study guides are full of
    the exact questions officials ask, each followed by the rule that answers it."""
    best = 0.0
    for segment in re.findall(r"[^?]*\?", text):
        clause = QUESTION_CLAUSE_BREAK.split(segment.strip())[-1]
        best = max(best, jaccard(question_stems, topical_stems(terms(clause))))
    return best


def standalone(question: str) -> bool:
    """Checklist follow-ups ("Who has this responsibility?") only make sense under their parent item."""
    topical = [t for t in terms(question) if t not in GENERIC]
    return len(topical) >= 2 and not BACK_REFERENCE.search(question)


def terms(question: str) -> list[str]:
    out: list[str] = []
    for raw in re.findall(r"[a-z0-9]+", question.lower()):
        # Keep the abbreviation itself too: documents use both "GS" and "Giant Slalom".
        for t in ([raw] + ABBREVIATIONS[raw].split()) if raw in ABBREVIATIONS else [raw]:
            if len(t) > 1 and t not in STOPWORDS and t not in out:
                out.append(t)
    return out


ROLE_TERMS = {  # OfficialRole.searchTerms
    "competition-official": ["official"], "gate-judge": ["gate", "judge"], "chief-of-course": ["chief", "course"],
    "chief-of-race": ["chief", "race"], "referee": ["referee"], "start-finish-referee": ["start", "finish", "referee"],
    "technical-delegate": ["technical", "delegate"], "timing": ["timing", "calculations"],
    "race-admin": ["administrator", "secretary"], "coach": ["coach"],
}


def _keyword(db: sqlite3.Connection, expression: str) -> list[tuple]:
    return db.execute(
        "SELECT c.id, d.slug, d.priority, d.jurisdiction, coalesce(d.roles, ''), c.page_start, c.page_end,"
        " c.heading, coalesce(c.rule_refs, '')"
        " FROM chunks_fts JOIN chunks c ON c.id = chunks_fts.rowid JOIN documents d ON d.id = c.doc_id"
        " WHERE chunks_fts MATCH ? ORDER BY bm25(chunks_fts, 4.0, 3.0, 1.0, 2.0, 1.0) LIMIT 40",
        (expression,),
    ).fetchall()


def search_hits(db: sqlite3.Connection, question: str, k: int, context: str | None, role: str | None) -> list[tuple]:
    """Top-k (slug, page_start, page_end, heading, rule_refs), fused the way HybridRetriever does:
    an any-term keyword list (plus role terms) and an all-terms precision list, combined with RRF."""
    words = terms(question)
    if not words:
        return []
    broad = words + [t for t in ROLE_TERMS.get(role or "", []) if t not in words]
    lists = [(_keyword(db, " OR ".join(f'"{t}"' for t in broad)), 1.0)]
    key_terms = [t for t in words if t not in GENERIC]
    if len(key_terms) > 1:
        lists.append((_keyword(db, " AND ".join(f'"{t}"' for t in key_terms)), PRECISION_WEIGHT))
    weights = CONTEXT_WEIGHTS[context]
    fused: dict[int, float] = {}
    info: dict[int, tuple] = {}
    for ranked, list_weight in lists:
        for rank, (cid, slug, priority, jurisdiction, roles, start, end, heading, refs) in enumerate(ranked):
            fused[cid] = fused.get(cid, 0) + list_weight / (60 + rank + 1)
            weight = priority * weights.get(jurisdiction, 1.0) * (ROLE_BOOST if role and f" {role} " in roles else 1)
            if heading and len(key_terms) > 1 and all(t[:5] in heading.lower() for t in key_terms):
                weight *= HEADING_COVER_BOOST
            info[cid] = (weight, (slug, start, end, heading, refs, cid))
    scores = {cid: fused[cid] * info[cid][0] for cid in fused}
    ranked = sorted(scores, key=lambda cid: (-scores[cid], cid))
    ranked = promote_echoes(db, ranked, words)
    ranked = follow_citations(db, ranked, scores, info, words, context)
    return [info[cid][1] for cid in ranked[:k]]


FOLLOW_TOP = 5          # passages whose cited rules are fetched
FOLLOW_PER_PASSAGE = 2  # cited rules fetched per passage
FOLLOW_FACTOR = 0.95    # a cited rule ranks just below the passage that cites it


RULE_IN_TEXT = re.compile(r"\[([^\]]{3,200})\]|\b(?:ICR|ACR|art\.?|[Rr]ule)\s+(U?\d{3}(?:\.\d{1,3}){0,5})")
NUMBER = re.compile(r"(?<![\d.])U?\d{3}(?:\.\d{1,3}){0,5}(?![\d])")


def cited_rules_near(text: str, words: list[str], limit: int) -> list[str]:
    """Rules cited in the sentences of `text` most similar to the question: a study-guide
    passage cites dozens of rules, but the one next to the matching question is the answer.
    Similarity is Jaccard over topical stems, so "Protest submittal deadlines depend on the kind of
    protest [643]" loses to "Who can submit protests? [645]"; question sentences win ties."""
    question = topical_stems(words)
    scored = []
    for i, sentence in enumerate(SENTENCE_BREAK.split(text)):
        rules = []
        for m in RULE_IN_TEXT.finditer(sentence):
            rules += NUMBER.findall(m.group(1)) if m.group(1) else [m.group(2)]
        rules = [r for r in rules if 100 <= int(r.lstrip("U").split(".")[0]) <= 1499]
        body = RULE_IN_TEXT.sub(" ", sentence)
        stems = topical_stems(terms(body))
        if rules and question & stems:
            scored.append((-jaccard(question, stems), "?" not in body, i, rules))
    out: list[str] = []
    for *_, rules in sorted(scored):
        for r in rules:
            if r not in out:
                out.append(r)
    return out[:limit]


def promote_echoes(db: sqlite3.Connection, ranked: list[int], words: list[str]) -> list[int]:
    """Mirror of HybridRetriever.promoteEchoes: move the passages that ask (almost) this exact
    question to the front, so the rule they cite is followed into the top results."""
    question = topical_stems(words)
    echoes = []
    for position, cid in enumerate(ranked[:40]):
        (text,) = db.execute("SELECT text FROM chunks WHERE id = ?", (cid,)).fetchone()
        score = echo_score(text, question)
        if score >= ECHO_MIN:
            echoes.append((-score, position, cid))
    promoted = [cid for *_, cid in sorted(echoes)[:ECHO_PROMOTE]]
    return promoted + [cid for cid in ranked if cid not in promoted]


def follow_citations(db: sqlite3.Connection, ranked: list[int], scores: dict, info: dict, words: list[str],
                     context: str | None = None) -> list[int]:
    """Mirror of HybridRetriever.followCitations: study guides and manuals cite rules as
    "[623.1.1]". Insert each cited rule's own passage (ACR, or ICR for FIS races) directly
    after the passage that cites it, so the model sees the rule text next to the explanation."""
    prefer = "fis" if context == "fis" else "usss"
    out: list[int] = []
    for position, cid in enumerate(ranked):
        if cid not in out:
            out.append(cid)
        if position >= FOLLOW_TOP:
            continue
        (text,) = db.execute("SELECT text FROM chunks WHERE id = ?", (cid,)).fetchone()
        for rule in cited_rules_near(text, words, FOLLOW_PER_PASSAGE):
            bare = rule.lstrip("U")
            rows = db.execute(
                "SELECT c.id, d.slug, d.jurisdiction, c.page_start, c.page_end, c.heading, coalesce(c.rule_refs,'')"
                " FROM toc t JOIN chunks c ON c.id = t.chunk_id JOIN documents d ON d.id = c.doc_id"
                " WHERE t.number IN (?, ?, ?)"
                " ORDER BY d.jurisdiction = ? DESC, t.number = ? DESC, c.id LIMIT 1",
                (rule, bare, "U" + bare, prefer, rule),
            ).fetchall()
            for target, slug, jurisdiction, start, end, heading, rrefs in rows:
                if target not in out:
                    out.append(target)
                    info[target] = (1.0, (slug, start, end, heading, rrefs, target))
    return out


def search(db: sqlite3.Connection, question: str, k: int, context: str | None, role: str | None) -> list[str]:
    return [slug for slug, *_ in search_hits(db, question, k, context, role)]


def study_guide_recall(db: sqlite3.Connection, path: Path, k: int, verbose: bool) -> dict:
    """Every standalone study-guide question must retrieve a passage that answers it: from its
    own guide, citing one of the rules the guide lists for it, or containing all its key terms."""
    data = yaml.safe_load(path.read_text())
    result = {"hits": 0, "total": 0, "context_dependent": 0, "misses": []}
    for guide in data["guides"]:
        for item in guide["questions"]:
            if not standalone(item["q"]):
                result["context_dependent"] += 1
                continue
            result["total"] += 1
            found = search_hits(db, item["q"], k, None, guide["role"])
            key_terms = [t for t in terms(item["q"]) if t not in GENERIC]
            covering = set(r[0] for r in db.execute(
                "SELECT rowid FROM chunks_fts WHERE chunks_fts MATCH ?", (" AND ".join(f'"{t}"' for t in key_terms),)
            )) if key_terms else set()
            ids = [r[0] for r in db.execute(
                "SELECT c.id FROM chunks c JOIN documents d ON d.id = c.doc_id WHERE d.slug = ? ", (guide["slug"],))]
            own = set(ids)
            ok = False
            for slug, start, end, heading, refs, cid in found:
                if cid in own or cid in covering or slug in item.get("also", []) \
                        or any(f" {rule} " in refs for rule in item["rules"]):
                    ok = True
                    break
            result["hits"] += ok
            line = f"{'HIT ' if ok else 'MISS'} [{guide['slug']} p{item['page']}] {item['q']!r} -> {[s for s, *_ in found]}"
            if not ok:
                result["misses"].append(line)
            elif verbose:
                print(line)
    return result


def cited_rule_recall(db: sqlite3.Connection, path: Path, k: int) -> dict:
    """For study-guide questions that cite rules ("[623.1.1]"), is the cited rule's own passage
    (a numbered rule in a rulebook such as the ACR) among the top k? Rules the bundled
    rulebooks don't contain (ICR-only numbers) are counted separately."""
    data = yaml.safe_load(path.read_text())
    known = {r[0] for r in db.execute("SELECT number FROM toc WHERE number IS NOT NULL")}
    result = {"hits": 0, "total": 0, "not_in_rulebooks": 0, "misses": []}
    for guide in data["guides"]:
        for item in guide["questions"]:
            rules = [r for r in item["rules"] if r in known or r.lstrip("U") in known or f"U{r}" in known]
            if not item["rules"] or not standalone(item["q"]):
                continue
            if not rules:
                result["not_in_rulebooks"] += 1
                continue
            result["total"] += 1
            found = search_hits(db, item["q"], k, None, guide["role"])
            ids = [cid for *_, cid in found]
            numbers = {n for cid in ids for (n,) in db.execute("SELECT number FROM toc WHERE chunk_id = ?", (cid,)) if n}
            wanted = {v for r in rules for v in (r, r.lstrip("U"), f"U{r.lstrip('U')}")}
            ok = bool(numbers & wanted) or any(n.startswith(w + ".") or w.startswith(n + ".") for n in numbers for w in wanted)
            result["hits"] += ok
            if not ok:
                result["misses"].append(f"MISS rule {rules} {item['q']!r}")
    return result


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--db", type=Path, required=True)
    p.add_argument("--questions", type=Path, default=Path(__file__).parent / "questions.yaml")
    p.add_argument("-k", type=int, default=5)
    p.add_argument("-v", "--verbose", action="store_true")
    p.add_argument("--study-guides", action="store_true", help="also check every study-guide question")
    p.add_argument("--study-guide-questions", type=Path, default=STUDY_GUIDE_QUESTIONS)
    args = p.parse_args()
    db = sqlite3.connect(args.db)
    if args.study_guides:
        r = study_guide_recall(db, args.study_guide_questions, args.k, args.verbose)
        for line in r["misses"]:
            print(line)
        print(f"study guides hit@{args.k}: {r['hits']}/{r['total']} = {r['hits'] / max(1, r['total']):.0%}"
              f" ({r['context_dependent']} context-dependent follow-ups not graded)")
        c = cited_rule_recall(db, args.study_guide_questions, args.k)
        wide = cited_rule_recall(db, args.study_guide_questions, 2 * args.k)
        for line in c["misses"]:
            print(line)
        print(f"cited rule in top {args.k}: {c['hits']}/{c['total']} = {c['hits'] / max(1, c['total']):.0%};"
              f" top {2 * args.k}: {wide['hits']}/{wide['total']} = {wide['hits'] / max(1, wide['total']):.0%}"
              f" ({c['not_in_rulebooks']} cite only rules not in the bundled rulebooks)\n")
    questions = yaml.safe_load(args.questions.read_text())["questions"]
    hits = 0
    for item in questions:
        found = search(db, item["q"], args.k, item.get("context"), item.get("role"))
        ok = any(slug in item["expect"] for slug in found)
        hits += ok
        if args.verbose or not ok:
            print(f"{'HIT ' if ok else 'MISS'} {item['q']!r} -> {found}")
    print(f"\nhit@{args.k}: {hits}/{len(questions)} = {hits / max(1, len(questions)):.0%}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
