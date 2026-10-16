from __future__ import annotations

import sqlite3
from pathlib import Path

import build_index as bi
from conftest import DECIMAL_PAGES, MANUAL_PAGES, OUTLINE_PAGES

MANUAL_LABEL = r"^(?P<label>(?:[IVX]+|BIB)/\s*\d+|[ivx]+)\s*/\s*\d{4}$"
MANUAL_IGNORE = ["^ALPINE OFFICIALS'? MANUAL$", r"^SEASON 20\d\d$", "^CHAPTER [IVX]+$"]


def build_db(tmp_path: Path, *sources: bi.Source) -> sqlite3.Connection:
    out = tmp_path / "rulebook.sqlite"
    bi.build(list(sources), out, tmp_path / "Documents")
    return sqlite3.connect(out)


def rows(db: sqlite3.Connection, sql: str, *args) -> list[tuple]:
    return db.execute(sql, args).fetchall()


def rules_source(path: Path) -> bi.Source:
    return bi.Source(slug="acg", file=path, title="Alpine Competition Guide", style="rules", jurisdiction="usss")


# MARK: Rules style


def test_page_labels_preserved(rules_pdf, tmp_path):
    db = build_db(tmp_path, rules_source(rules_pdf))
    labels = [r[0] for r in rows(db, "SELECT page_label FROM pages ORDER BY page_index")]
    assert labels == ["i", "ii", "1", "2", "3"]


def test_rule_numbers_detected(rules_pdf, tmp_path):
    db = build_db(tmp_path, rules_source(rules_pdf))
    rules = [r[0] for r in rows(db, "SELECT number FROM toc WHERE number IS NOT NULL ORDER BY position")]
    assert rules == ["600", "601", "601.1", "601.2", "601.2.1", "614", "614.1", "614.2"]


def test_measurement_lines_are_not_headings(rules_pdf, tmp_path):
    db = build_db(tmp_path, rules_source(rules_pdf))
    assert rows(db, "SELECT 1 FROM toc WHERE number = '1500'") == []
    assert rows(db, "SELECT 1 FROM chunks WHERE text LIKE '%1500 meters%'")


def test_headings_and_breadcrumbs(rules_pdf, tmp_path):
    db = build_db(tmp_path, rules_source(rules_pdf))
    (heading,) = rows(db, "SELECT heading FROM toc WHERE number = '614.2'")[0]
    assert heading == "Inspection Time"
    sections = bi.sectionize(rules_source(rules_pdf), bi.strip_running_text(bi.extract_pages(bi.PdfReader(str(rules_pdf)))))
    assert next(s for s in sections if s.rule_number == "614.1").breadcrumb == "614 Course Inspection"


def test_dehyphenation_and_running_text(rules_pdf, tmp_path):
    db = build_db(tmp_path, rules_source(rules_pdf))
    assert rows(db, "SELECT 1 FROM chunks WHERE text LIKE '%disqualification%'")
    assert rows(db, "SELECT 1 FROM chunks WHERE text LIKE '%Competition Guide 2026%'") == []


def test_fts_search(rules_pdf, tmp_path):
    db = build_db(tmp_path, rules_source(rules_pdf))
    hits = rows(
        db,
        "SELECT c.text FROM chunks_fts JOIN chunks c ON c.id = chunks_fts.rowid "
        "WHERE chunks_fts MATCH ? ORDER BY bm25(chunks_fts) LIMIT 1",
        "inspecting gates",
    )
    assert hits and "skiing through gates" in hits[0][0]  # porter stemming: inspecting -> inspect


def test_meta_and_pdf_copy(rules_pdf, tmp_path):
    db = build_db(tmp_path, rules_source(rules_pdf))
    meta = dict(rows(db, "SELECT key, value FROM meta"))
    assert meta["schema_version"] == str(bi.SCHEMA_VERSION)
    assert len(meta["index_version"]) == 16
    assert rows(db, "SELECT filename, jurisdiction FROM documents") == [("acg.pdf", "usss")]
    assert (tmp_path / "Documents" / "acg.pdf").exists()


def test_split_heading_separates_title_from_sentence():
    assert bi.split_heading("Inspection Time The jury sets the time")[0] == "Inspection Time"
    assert bi.split_heading("Competitors must inspect the course")[0] == ""
    assert bi.split_heading("Composition of the Jury")[0] == "Composition of the Jury"
    assert bi.split_heading("Start Intervals: The interval is")[0] == "Start Intervals"


def test_long_sections_split_with_overlap():
    words = [(0, f"w{i}") for i in range(700)]
    section = bi.Section("700", "Long", None, 0, lines=words)
    chunks = bi.chunk_section(section)
    assert [c.part for c in chunks] == [0, 1, 2]
    assert chunks[1].text.split()[0] == f"w{bi.TARGET_WORDS - bi.OVERLAP_WORDS}"
    assert chunks[-1].text.split()[-1] == "w699"


# MARK: Outline style (Officials' Manual, study guides, OISRA)


def manual_source(path: Path) -> bi.Source:
    return bi.Source(
        slug="aom-03", file=path, title="Officials' Manual Ch. III", jurisdiction="usss",
        page_label_pattern=MANUAL_LABEL, ignore_patterns=MANUAL_IGNORE, roles=["referee", "technical-delegate"],
    )


def test_manual_page_labels_and_headings(pdf_factory, tmp_path):
    db = build_db(tmp_path, manual_source(pdf_factory("III._Rules.pdf", MANUAL_PAGES)))
    labels = [r[0] for r in rows(db, "SELECT page_label FROM pages ORDER BY page_index")]
    assert labels == ["III/1", "III/2", "III/3", "III/4"]
    headings = [r[0] for r in rows(db, "SELECT heading FROM toc ORDER BY position")]
    assert headings == [
        "Rules, the Jury, and the Technical Delegate",
        "Overview",
        "Competition Jury",
        "Composition of the Jury",
        "Due Process",
    ]
    # Dot-leader TOC lines and cover boilerplate are not indexed as text.
    assert rows(db, "SELECT 1 FROM chunks WHERE text LIKE '%.....%' OR text LIKE '%SEASON 2026%'") == []


def test_manual_rule_refs_and_roles(pdf_factory, tmp_path):
    db = build_db(tmp_path, manual_source(pdf_factory("III._Rules.pdf", MANUAL_PAGES)))
    refs = [r[0] for r in rows(db, "SELECT rule_refs FROM chunks WHERE rule_refs IS NOT NULL")]
    assert any(" 601.4 " in r and " U601.4.2.3 " in r for r in refs)
    assert any(" 601.1 " in r for r in refs)
    assert rows(db, "SELECT roles FROM documents") == [(" referee technical-delegate ",)]


def test_label_lines_are_not_headings():
    assert not bi.caps_heading("LOCATION:")
    assert not bi.caps_heading("IS MANDATORY!")
    assert not bi.caps_heading("(DNF).")
    assert bi.caps_heading("COMPOSITION OF THE JURY")
    assert bi.caps_heading("REFERENCE PUBLICATIONS:")


def test_outline_sections(pdf_factory, tmp_path):
    src = bi.Source(slug="oisra", file=pdf_factory("OISRA.pdf", OUTLINE_PAGES), title="OISRA Rules", jurisdiction="oisra")
    db = build_db(tmp_path, src)
    toc = rows(db, "SELECT heading, level FROM toc ORDER BY position")
    assert toc == [
        ("Race Organization — The Race Committee, Race Officials & Jury", 0),
        ("START and FINISH", 1),
        ("Re-Runs", 1),
    ]
    sections = bi.sectionize(src, [[l for l in p] for p in OUTLINE_PAGES])
    rerun = next(s for s in sections if s.heading == "Re-Runs")
    assert rerun.breadcrumb.startswith("Race Organization")


def test_smart_title_keeps_acronyms():
    assert bi.smart_title("U.S. SKI & SNOWBOARD TIMING RULES IN THE ACR") == "U.S. Ski & Snowboard Timing Rules in the ACR"
    assert bi.smart_title("GATE JUDGE'S CONTROL CARD") == "Gate Judge's Control Card"


# MARK: Decimal sections (FIS documents)


def test_decimal_sections_ignore_numbered_lists(pdf_factory, tmp_path):
    src = bi.Source(slug="fis-points", file=pdf_factory("FIS_Points.pdf", DECIMAL_PAGES), title="FIS Points", jurisdiction="fis")
    db = build_db(tmp_path, src)
    numbers = [r[0] for r in rows(db, "SELECT number FROM toc ORDER BY position")]
    assert numbers == ["1", "1.1", "1.2", "1.2.1", "2", "2.1", "2.1.1", "3"]
    (crumb,) = rows(db, "SELECT breadcrumb FROM toc t JOIN chunks c ON c.id = t.chunk_id WHERE t.number = '1.2.1'")[0]
    assert crumb is None or crumb.startswith("1 The Competition")


def test_decimal_successor():
    assert bi.decimal_successor(None, (1,))
    assert bi.decimal_successor((2, 1), (2, 1, 1))
    assert bi.decimal_successor((2, 1, 1), (2, 2))
    assert bi.decimal_successor((2, 2), (3,))
    assert not bi.decimal_successor((4, 2, 5), (1,))  # a numbered list restarting at 1
    assert not bi.decimal_successor((2, 1), (2, 1))


def test_small_sections_merge_but_stay_in_toc(pdf_factory, tmp_path):
    src = bi.Source(slug="fis-points", file=pdf_factory("FIS_Points.pdf", DECIMAL_PAGES), title="FIS Points")
    db = build_db(tmp_path, src)
    (chunks,) = rows(db, "SELECT count(*) FROM chunks")[0]
    (entries,) = rows(db, "SELECT count(*) FROM toc")[0]
    assert chunks < entries
    # Sections are merged within a top-level number, never across.
    assert rows(db, "SELECT count(DISTINCT rule_number) FROM chunks")[0][0] >= 3


def test_toc_page_detection():
    toc = [f"{i}.{j} Section title number {i}{j} {10 + i}" for i in range(1, 4) for j in range(1, 4)]
    assert bi.is_toc_page(toc)
    assert not bi.is_toc_page(DECIMAL_PAGES[0])


# MARK: Slides


def test_slides_one_section_per_slide(pdf_factory, tmp_path):
    pages = [["Radio Protocol", "Use plain language."], ["Course Holds", "Announce holds clearly."]]
    src = bi.Source(slug="ppt-radio", file=pdf_factory("RADIO.pdf", pages), title="Radio Slides", style="slides")
    db = build_db(tmp_path, src)
    assert [r[0] for r in rows(db, "SELECT page_label FROM pages")] == ["Slide 1", "Slide 2"]
    assert [r[0] for r in rows(db, "SELECT heading FROM toc ORDER BY position")] == ["Radio Protocol", "Course Holds"]


# MARK: Rule references


def test_rule_refs():
    assert bi.rule_refs("Who names the referee? [601.2.3, 601.4.2.2] and ICR 614.2") == " 601.2.3 601.4.2.2 614.2 "
    assert bi.rule_refs("[U601.4.10, 601.4.10.1 ]") == " U601.4.10 601.4.10.1 "
    assert bi.rule_refs("Vertical drop 1500 m, see page 12") is None
    assert bi.rule_refs("[AOM, Chapter III]") is None


# MARK: Discovery and the catalog


def write_catalog(tmp_path: Path) -> Path:
    path = tmp_path / "catalog.yaml"
    path.write_text(
        """
defaults: {edition: "2026", jurisdiction: reference}
unmatched: {collection: Other References, priority: 0.8}
groups:
  - name: Study Guides
    defaults: {collection: Study Guides, jurisdiction: usss}
    documents:
      - {slug: sg-referee, match: [RF_STUDY_GUIDE], title: Referee Study Guide, roles: [referee]}
      - {slug: sg-race-admin, match: [RA_STUDY_GUIDE], title: Race Admin Study Guide}
      - {slug: sg-race-admin-2, match: [RA_STUDY_GUIDE_Section_2], title: Race Admin Study Guide 2}
"""
    )
    return path


def test_discover_matches_dedupes_and_falls_back(pdf_factory, tmp_path):
    docs = tmp_path / "docs"
    docs.mkdir()
    for name, pages in [
        ("8c96b52e-RF_STUDY_GUIDE_2026.pdf", OUTLINE_PAGES),
        ("RA STUDY GUIDE Section 2.pdf", DECIMAL_PAGES),  # longest key wins
        ("Mystery_Memo_2024.pdf", MANUAL_PAGES),  # not in the catalog
    ]:
        (docs / name).write_bytes(pdf_factory(name, pages).read_bytes())
    (docs / "RF Study Guide 2026 copy.pdf").write_bytes((docs / "8c96b52e-RF_STUDY_GUIDE_2026.pdf").read_bytes())
    sources, warnings = bi.discover(docs, write_catalog(tmp_path), tmp_path / "cache")
    by_slug = {s.slug: s for s in sources}
    assert set(by_slug) == {"sg-referee", "sg-race-admin-2", "mystery-memo-2024"}
    assert by_slug["sg-referee"].roles == ["referee"]
    assert by_slug["sg-referee"].jurisdiction == "usss"
    assert by_slug["mystery-memo-2024"].collection == "Other References"
    assert any("duplicate" in w for w in warnings)
    assert any("Not in catalog" in w for w in warnings)


def test_supplements_resolve_against_the_library(pdf_factory, tmp_path):
    """Supplements live in the private library; without it the document is indexed without them."""
    docs = tmp_path / "docs"
    docs.mkdir()
    (docs / "RF_STUDY_GUIDE_2026.pdf").write_bytes(pdf_factory("rf.pdf", OUTLINE_PAGES).read_bytes())
    catalog = write_catalog(tmp_path)
    catalog.write_text(catalog.read_text().replace("roles: [referee]}", "roles: [referee], supplement: supplements/rf.md}"))

    library = tmp_path / "library"
    (library / "supplements").mkdir(parents=True)
    (library / "supplements/rf.md").write_text("## Table\n\nRows.\n")
    sources, warnings = bi.discover(docs, catalog, tmp_path / "cache", library)
    assert sources[0].supplement == library / "supplements/rf.md"
    assert not any("supplement" in w for w in warnings)

    sources, warnings = bi.discover(docs, catalog, tmp_path / "cache", tmp_path / "missing")
    assert sources[0].supplement is None
    assert any("supplement" in w for w in warnings)


def test_repository_catalog_is_valid():
    _, entries = bi.load_catalog(bi.HERE / "catalog.yaml")
    slugs = [e["slug"] for e in entries]
    assert len(slugs) == len(set(slugs))
    roles = {r for e in entries for r in e.get("roles", [])}
    assert roles <= {
        "competition-official", "gate-judge", "chief-of-course", "chief-of-race", "referee",
        "start-finish-referee", "technical-delegate", "timing", "race-admin", "coach",
    }
    assert {e["jurisdiction"] for e in entries} <= {"oisra", "usss", "fis", "reference"}
    assert bi.match_entry("66e0fdc6-OSIRA_ALPINE_RACE_RULES_Updated_2026_5.pdf", entries)["slug"] == "oisra-alpine-race-rules"
    assert bi.match_entry("III. Rules, Jury & Technical Delegate 2026.pdf", entries)["slug"] == "aom-03-rules-jury-td"
    assert bi.match_entry("CHIEF_OF_COURSE_2026.pptx", entries)["slug"] == "ppt-chief-of-course"
    assert bi.match_entry("CC_STUDY_GUIDE_2026.pdf", entries)["slug"] == "sg-chief-of-course"


def test_collapse_doubled_slide_titles():
    assert bi.normalize_line("CalculatingCalculating U.S.  PointsU.S.  Points") == "Calculating U.S. Points"
    assert bi.normalize_line("Who gets a radio at an event?Who gets a radio at an event?") == "Who gets a radio at an event?"
    assert bi.normalize_line("Radio Protocol & Techniques Radio Protocol & Techniques ") == "Radio Protocol & Techniques"
    assert bi.normalize_line("CALCULATION OF RACE POINTSCALCULATION OF RACE POINTS") == "CALCULATION OF RACE POINTS"
    # Ordinary text is untouched.
    for text in ["the the course", "Gate 10 10 seconds", "Time 1:00.00 1:00.00", "Slalom and Giant Slalom"]:
        assert bi.normalize_line(text) == text


def test_supplement_sections_are_indexed(pdf_factory, tmp_path):
    sup = tmp_path / "specs.md"
    sup.write_text("<!-- note for editors -->\n<!-- page: 1 -->\n## Giant Slalom by age\nU14 GS: vertical drop max. 350 m.\n\n## Slalom by age\nU14 SL: max. 160 m.\n")
    src = bi.Source(slug="specs", file=pdf_factory("specs.pdf", [["Table", "garbled 350 m 160 m"]]), title="Specs", supplement=sup)
    db = build_db(tmp_path, src)
    rows_ = rows(db, "SELECT heading, page_start, text FROM chunks WHERE breadcrumb = 'Transcribed table' ORDER BY id")
    assert [(h, p) for h, p, _ in rows_] == [("Giant Slalom by age", 0), ("Slalom by age", 0)]
    assert "U14 GS: vertical drop max. 350 m." in rows_[0][2]
    assert "note for editors" not in " ".join(t for *_, t in rows_)
