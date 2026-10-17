#!/usr/bin/env python3
"""Build the bundled rulebook index from the reference documents.

Finds every PDF, slide deck (PPTX / PPT) and Word or Excel file in the documents folder,
identifies each one with ``catalog.yaml`` (title, collection, jurisdiction, parsing style),
converts the Office files to PDF with LibreOffice, splits the text into heading-aware chunks, and writes a
SQLite database with an FTS5 index. The PDFs are copied into the app under
stable names so citations can open them.

The documents themselves are not part of this repository (they belong to their
publishers). By default they are read from the private library submodule at
``ingest/library/documents``, or from ``ingest/documents`` if you downloaded
your own copies. Table supplements (``supplement:`` in the catalog) are read
from ``<library>/supplements`` and skipped with a warning when absent.

Usage:
    python3 ingest/build_index.py                     # defaults below
    python3 ingest/build_index.py --docs ~/Downloads/officials-docs
"""

from __future__ import annotations

import argparse
import hashlib
import re
import shutil
import sqlite3
import subprocess
import sys
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

import yaml
from pypdf import PdfReader

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
DEFAULT_LIBRARY = HERE / "library"


def default_docs(library: Path) -> Path:
    """`<library>/documents` when the private library is checked out, else ingest/documents."""
    docs = library / "documents"
    return docs if docs.is_dir() else HERE / "documents"
SCHEMA_VERSION = 1

SCHEMA = """
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE documents (
    id           INTEGER PRIMARY KEY,
    slug         TEXT NOT NULL UNIQUE,
    title        TEXT NOT NULL,
    edition      TEXT,
    collection   TEXT,                   -- Library grouping, e.g. "Alpine Officials' Manual"
    jurisdiction TEXT NOT NULL,          -- "oisra" | "usss" | "fis" | "reference"; drives race-context precedence
    roles        TEXT,                   -- officials the document is written for, space-padded: " referee technical-delegate "
    filename     TEXT NOT NULL,          -- PDF name in the app bundle's Documents/ folder
    priority     REAL NOT NULL DEFAULT 1.0,
    sort_order   INTEGER NOT NULL,
    page_count   INTEGER NOT NULL
);
CREATE TABLE pages (
    doc_id     INTEGER NOT NULL REFERENCES documents(id),
    page_index INTEGER NOT NULL,         -- 0-based PDF page index
    page_label TEXT NOT NULL,            -- printed page label: "87", "III/6", "Slide 4"
    PRIMARY KEY (doc_id, page_index)
);
CREATE TABLE chunks (
    id          INTEGER PRIMARY KEY,
    doc_id      INTEGER NOT NULL REFERENCES documents(id),
    rule_number TEXT,                    -- "614.2" (rules) or "4.2.5" (numbered sections); NULL otherwise
    heading     TEXT,                    -- section heading, e.g. "Composition of the Jury"
    breadcrumb  TEXT,                    -- parent headings
    level       INTEGER NOT NULL DEFAULT 0, -- heading depth, for the table of contents
    rule_refs   TEXT,                    -- rules cited in the text, space-padded: " 601.4 U601.3.1 "
    text        TEXT NOT NULL,
    page_start  INTEGER NOT NULL,        -- 0-based PDF page index
    page_end    INTEGER NOT NULL,
    part        INTEGER NOT NULL DEFAULT 0 -- index when a long section is split
);
CREATE INDEX chunks_rule ON chunks(rule_number);
CREATE TABLE toc (                       -- every heading, including ones merged into a larger chunk
    doc_id     INTEGER NOT NULL REFERENCES documents(id),
    position   INTEGER NOT NULL,
    number     TEXT,
    heading    TEXT NOT NULL,
    level      INTEGER NOT NULL,
    page_index INTEGER NOT NULL,
    chunk_id   INTEGER NOT NULL REFERENCES chunks(id),
    PRIMARY KEY (doc_id, position)
);
CREATE VIRTUAL TABLE chunks_fts USING fts5(
    rule_number, heading, breadcrumb, rule_refs, text,
    content='chunks', content_rowid='id',
    tokenize='porter unicode61'
);
"""

TARGET_WORDS = 300
OVERLAP_WORDS = 40
# Converted to PDF with LibreOffice; the app shows every document as a PDF.
OFFICE_EXTENSIONS = {".pptx", ".ppt", ".docx", ".doc", ".xlsx", ".xls"}
DOC_EXTENSIONS = {".pdf"} | OFFICE_EXTENSIONS
# "36 Protest Form" -> "Protest Form": the numbering of a packet like the Master Packet of Forms.
PACKET_NUMBER = re.compile(r"^\d+[a-z]?\s+")


# MARK: - Sources and the catalog


@dataclass
class Source:
    slug: str
    file: Path
    title: str
    edition: str | None = None
    priority: float = 1.0
    collection: str | None = None
    jurisdiction: str = "reference"
    roles: list[str] = field(default_factory=list)
    # "rules": 3-digit numbered rules (ACR / ICR). "outline": ALL-CAPS, I./A. and
    # 1.2.3 headings (manuals, study guides, FIS documents). "slides": one section per slide.
    style: str = "outline"
    # Regex with a `label` group, matched against each page's first lines, to read
    # printed labels such as "III/6" from "III/6/2026". Default: PDF page labels.
    page_label_pattern: str | None = None
    ignore_patterns: list[str] = field(default_factory=list)
    heading_pattern: str | None = None
    skip_pages: list[int] = field(default_factory=list)
    # style "guide": 0-based PDF page where the numbered rules begin (e.g. the ACR chapter);
    # earlier lines that start with a number (addresses, years) are never taken as rules.
    rules_from_page: int = 0
    sort_order: int = 0
    # Markdown transcription of content PDF extraction garbles (tables); see ingest/supplements/.
    supplement: Path | None = None
    # 1-based PDF page every supplement passage cites, when the same table sits on another page
    # of this document (the Competition Guide reprints the course-setting specifications).
    supplement_page: int | None = None
    # Section heading -> ACR rules it restates without citing them (OISRA's "Validity of a Re-Run"
    # is ACR 623.3). Each passage of the section gets a labeled note citing them; see cross_reference().
    see_also: dict[str, list[str]] = field(default_factory=dict)
    # Put the document title in every passage's breadcrumb (searched, not shown). For blank forms,
    # whose text never names them: "PROTESTS Place Country Codex…" is the Protest Form.
    title_in_index: bool = False


def normalize_name(name: str) -> str:
    return re.sub(r"[^a-z0-9]", "", name.lower())


def clean_title(stem: str) -> str:
    """'3d9acdbb-CC_STUDY_GUIDE_2026' -> 'CC STUDY GUIDE 2026'."""
    stem = re.sub(r"^[0-9a-f]{8}-", "", stem)
    return re.sub(r"\s+", " ", stem.replace("_", " ")).strip(" .-")


def slugify(text: str) -> str:
    return re.sub(r"-+", "-", re.sub(r"[^a-z0-9]+", "-", text.lower())).strip("-")[:60]


def load_catalog(path: Path) -> tuple[dict, list[dict]]:
    """Catalog entries, each merged with its group's defaults and the top-level defaults."""
    data = yaml.safe_load(path.read_text())
    top = data.get("defaults", {})
    entries = []
    for group in data.get("groups", []):
        for entry in group["documents"]:
            entries.append({**top, **group.get("defaults", {}), **entry})
    return {**top, **data.get("unmatched", {})}, entries


def load_folders(path: Path) -> dict[str, dict]:
    """`folders:` defaults (merged with the top-level ones) for files in a documents subfolder
    that no catalog entry matches, such as the 70 forms of the Master Packet of Forms."""
    data = yaml.safe_load(path.read_text())
    top = data.get("defaults", {})
    return {name: {**top, **settings} for name, settings in (data.get("folders") or {}).items()}


def folder_entry(file: Path, docs: Path, folders: dict[str, dict]) -> dict | None:
    """The folder's defaults, with a title from the file name minus its packet number."""
    parts = file.relative_to(docs).parts
    if len(parts) < 2 or parts[0] not in folders:
        return None
    settings = folders[parts[0]]
    title = PACKET_NUMBER.sub("", clean_title(file.stem))
    return {**settings, "slug": settings.get("slug_prefix", "") + slugify(title), "title": title}


def match_entry(filename: str, entries: list[dict]) -> dict | None:
    """The entry whose longest `match` key occurs in the normalized filename."""
    name = normalize_name(filename)
    best, best_len = None, 0
    for entry in entries:
        for key in entry["match"]:
            key = normalize_name(key)
            if key in name and len(key) > best_len:
                best, best_len = entry, len(key)
    return best


def source_from(entry: dict, file: Path, sort_order: int, library: Path = DEFAULT_LIBRARY) -> Source:
    return Source(
        slug=entry["slug"],
        file=file,
        title=entry["title"],
        edition=str(entry["edition"]) if entry.get("edition") is not None else None,
        priority=float(entry.get("priority", 1.0)),
        collection=entry.get("collection"),
        jurisdiction=entry.get("jurisdiction", "reference"),
        roles=list(entry.get("roles", [])),
        style=entry.get("style", "outline"),
        page_label_pattern=entry.get("page_label_pattern"),
        ignore_patterns=list(entry.get("ignore_patterns", [])),
        heading_pattern=entry.get("heading_pattern"),
        skip_pages=list(entry.get("skip_pages", [])),
        rules_from_page=int(entry.get("rules_from_page", 0)),
        sort_order=sort_order,
        supplement=(library / entry["supplement"]) if entry.get("supplement") else None,
        supplement_page=int(entry["supplement_page"]) if entry.get("supplement_page") else None,
        see_also={heading: [str(r) for r in rules] for heading, rules in (entry.get("see_also") or {}).items()},
        title_in_index=bool(entry.get("title_in_index", False)),
    )


def find_soffice() -> str | None:
    found = shutil.which("soffice") or shutil.which("libreoffice")
    mac = Path("/Applications/LibreOffice.app/Contents/MacOS/soffice")
    return found or (str(mac) if mac.exists() else None)


def convert_to_pdf(file: Path, cache: Path) -> Path | None:
    """Convert a slide deck, Word or Excel file to PDF with LibreOffice; None if LibreOffice is missing."""
    soffice = find_soffice()
    if not soffice:
        return None
    out_dir = cache / "converted"
    out_dir.mkdir(parents=True, exist_ok=True)
    target = out_dir / f"{file.stem}.pdf"
    if target.exists() and target.stat().st_mtime >= file.stat().st_mtime:
        return target
    subprocess.run(
        [soffice, "--headless", "--convert-to", "pdf", "--outdir", str(out_dir), str(file)],
        check=True, capture_output=True, timeout=300,
    )
    return target if target.exists() else None


def ocr_if_needed(pdf: Path, cache: Path) -> tuple[Path, bool]:
    """Returns (pdf, has_text). Scanned PDFs are OCR'd with ocrmypdf when it is installed."""
    reader = PdfReader(str(pdf))
    chars = sum(len((p.extract_text() or "").strip()) for p in reader.pages)
    if chars >= 40 * len(reader.pages):
        return pdf, True
    ocrmypdf = shutil.which("ocrmypdf")
    if not ocrmypdf:
        return pdf, chars > 0
    out = cache / "ocr" / pdf.name
    out.parent.mkdir(parents=True, exist_ok=True)
    if not out.exists():
        subprocess.run([ocrmypdf, "--skip-text", "--quiet", str(pdf), str(out)], check=True, timeout=600)
    return out, True


def discover(
    docs: Path, catalog: Path, cache: Path, library: Path = DEFAULT_LIBRARY
) -> tuple[list[Source], list[str]]:
    """Find, identify, convert and de-duplicate the documents. Returns sources and warnings."""
    unmatched_defaults, entries = load_catalog(catalog)
    folders = load_folders(catalog)
    order = {entry["slug"]: i for i, entry in enumerate(entries)}
    warnings: list[str] = []
    seen_hashes: dict[str, Path] = {}
    seen_slugs: set[str] = set()
    sources: list[Source] = []

    files = sorted(p for p in docs.rglob("*") if p.suffix.lower() in DOC_EXTENSIONS and not p.name.startswith("."))
    for file in files:
        digest = hashlib.sha256(file.read_bytes()).hexdigest()
        if digest in seen_hashes:
            warnings.append(f"Skipped duplicate: {file.name} (same as {seen_hashes[digest].name})")
            continue
        seen_hashes[digest] = file

        pdf: Path | None = file
        if file.suffix.lower() in OFFICE_EXTENSIONS:
            pdf = convert_to_pdf(file, cache)
            if pdf is None:
                warnings.append(f"Skipped {file.name}: install LibreOffice to convert slide decks and Office files")
                continue
        pdf, has_text = ocr_if_needed(pdf, cache)
        if not has_text:
            warnings.append(f"{file.name} has no text layer (scanned); install ocrmypdf to make it searchable")

        entry = match_entry(file.name, entries) or folder_entry(file, docs, folders)
        if entry is None:
            title = clean_title(file.stem)
            entry = {**unmatched_defaults, "slug": slugify(title), "title": title}
            warnings.append(f"Not in catalog, indexed as \"{title}\": {file.name}")
        if entry["slug"] in seen_slugs:
            warnings.append(f"Skipped {file.name}: another file already matched \"{entry['title']}\"")
            continue
        seen_slugs.add(entry["slug"])
        source = source_from(entry, pdf, order.get(entry["slug"], len(order)), library)
        if source.supplement and not source.supplement.is_file():
            warnings.append(f"{source.slug}: supplement {source.supplement} not found; indexed without it")
            source.supplement = None
        sources.append(source)

    sources.sort(key=lambda s: (s.sort_order, s.title))
    return sources, warnings


# MARK: - Text extraction


def page_labels(reader: PdfReader) -> list[str]:
    """Printed page labels, falling back to 1-based page numbers."""
    try:
        labels = list(reader.page_labels)
    except Exception:  # malformed /PageLabels trees are common
        labels = []
    if len(labels) != len(reader.pages):
        labels = [str(i + 1) for i in range(len(reader.pages))]
    return labels


def labels_from_text(pages: list[list[str]], pattern: str, fallback: list[str]) -> list[str]:
    regex = re.compile(pattern)
    labels = []
    for lines, default in zip(pages, fallback):
        label = default
        for line in lines[:3]:
            if m := regex.match(line):
                label = re.sub(r"\s+", "", m.group("label"))
                break
        labels.append(label)
    return labels


def extract_pages(reader: PdfReader) -> list[list[str]]:
    pages = []
    for page in reader.pages:
        try:
            text = page.extract_text() or ""
        except Exception:
            text = ""
        lines = [normalize_line(l) for l in text.splitlines()]
        pages.append([l for l in lines if l])
    return pages


def normalize_line(line: str) -> str:
    line = (
        line.replace(" ", " ").replace("’", "'").replace("‘", "'")
        .replace("ﬁ", "fi").replace("ﬂ", "fl").replace("", "•")
    )
    return collapse_doubled(re.sub(r"\s+", " ", line).strip())


DOUBLED_RUN = re.compile(r"(\S[^\n]{3,}?)\s?\1(?=\s|$)")


def collapse_doubled(line: str) -> str:
    """Slide titles with a drop shadow extract twice: "CalculatingCalculating U.S. PointsU.S. Points"."""
    # Only runs containing words: repeated times or numbers ("1:00.00 1:00.00") are real data.
    return DOUBLED_RUN.sub(lambda m: m.group(1) if re.search(r"[A-Za-z]{3}", m.group(1)) else m.group(0), line)


def strip_running_text(pages: list[list[str]]) -> list[list[str]]:
    """Drop headers/footers: lines (ignoring digits) repeated on many pages."""
    if len(pages) < 4:
        return pages

    def key(line: str) -> str:
        return re.sub(r"\d+", "#", line.lower())

    counts: Counter[str] = Counter()
    for lines in pages:
        edge = lines[:2] + lines[-2:]
        counts.update({key(l) for l in edge})
    threshold = max(3, len(pages) // 3)
    running = {k for k, c in counts.items() if c >= threshold}
    page_number_only = re.compile(r"^(page\s*)?#(\s*(of|/)\s*#)?$")
    out = []
    for lines in pages:
        kept = []
        for i, l in enumerate(lines):
            at_edge = i < 2 or i >= len(lines) - 2
            k = key(l)
            if at_edge and (k in running or page_number_only.match(k)):
                continue
            kept.append(l)
        out.append(kept)
    return out


TOC_LINE = re.compile(r"\.{5,}|\s[IVX]+/\s*\d+/\d{4}$")
TOC_ENTRY = re.compile(r"^(\d{1,3}(\.\d{1,3})*\.?\s+)?\S.{2,120}?\s\d{1,3}$")


def is_toc_page(lines: list[str]) -> bool:
    """A table-of-contents page: most lines are 'Heading ..... 12' or '2.1 Heading 12'."""
    if len(lines) < 6:
        return False
    hits = sum(1 for l in lines if TOC_LINE.search(l) or TOC_ENTRY.match(l))
    return hits >= 0.6 * len(lines)


# MARK: - Rule-numbered documents (ACR / ICR style)

RULE_HEADING_RE = re.compile(r"^(?P<num>U?\d{3,4}(?:\.\d{1,3}){0,5})\.?\s+(?P<rest>\S.*)$")
# "1500 m of vertical drop" starts with a number but is not a rule.
UNIT_WORDS = {"m", "m.", "meters", "metres", "km", "cm", "mm", "sec", "seconds", "points", "pts", "%", "x", "-", "to", "and"}
RULE_LIST_DENSITY = 0.45  # pages this full of "601 Title" lines are the rulebook's own list of rules
MIN_RULE = 100
MAX_RULE = 1499  # ICR/ACR rules stop around 1260; "1984 ..." or "2026 ..." are years, not rules
CONNECTORS = {"of", "and", "the", "for", "in", "on", "to", "a", "an", "or", "with", "by", "at"}


@dataclass
class Section:
    rule_number: str | None
    heading: str | None
    breadcrumb: str | None
    page_start: int
    lines: list[tuple[int, str]] = field(default_factory=list)  # (page_index, line)
    level: int = 0
    raw_heading: str | None = None  # heading as printed, before title-casing


@dataclass
class Chunk:
    rule_number: str | None
    heading: str | None
    breadcrumb: str | None
    text: str
    page_start: int
    page_end: int
    part: int
    level: int = 0


def rule_key(num: str) -> tuple[int, ...]:
    return tuple(int(p) for p in num.lstrip("U").split("."))


def is_plausible_successor(prev: str | None, num: str) -> bool:
    """Reject numbers that are obviously not headings (e.g. "1500 meters")."""
    if not MIN_RULE <= rule_key(num)[0] <= MAX_RULE:
        return False
    if prev is None:
        return True
    p, n = rule_key(prev), rule_key(num)
    if n <= p and num.lstrip("U") != prev.lstrip("U"):
        return False
    if n == p and num == prev:
        return False
    return n[0] - p[0] <= 400  # the ICR/ACR jump from the 200s (general rules) to the 600s (jury)


def split_heading(rest: str) -> tuple[str, str]:
    """Split "Inspection Time The jury sets..." into ("Inspection Time", "The jury sets...").

    Headings are short title-case phrases. When the line continues into a
    sentence, the last capitalized word is that sentence's first word, so it
    is not part of the heading ("Competitors must inspect..." has no heading).
    """
    words = rest.split()
    run: list[str] = []
    ended_with_punctuation = False
    for w in words:
        bare = w.strip("()–-,:;.")
        if not bare or not (bare[0].isupper() or bare.lower() in CONNECTORS or bare.isdigit()):
            break
        run.append(w)
        if w.endswith((":", ".")) or len(run) >= 12:
            ended_with_punctuation = w.endswith((":", "."))
            break

    if len(run) == len(words) or ended_with_punctuation:
        heading_words = run
    else:
        heading_words = run[:-1]
    while heading_words and heading_words[-1].lower().strip(":.") in CONNECTORS:
        heading_words.pop()
    if not heading_words:
        return "", rest
    heading = " ".join(heading_words).rstrip(":.")
    return heading, " ".join(words[len(heading_words):])


def breadcrumb_for(num: str, headings: dict[str, str]) -> str | None:
    parts = num.split(".")
    crumbs = []
    for i in range(1, len(parts)):
        parent = ".".join(parts[:i])
        if parent in headings:
            crumbs.append(f"{parent} {headings[parent]}".strip())
    return " > ".join(crumbs) or None


def rule_heading(line: str, heading_re: re.Pattern[str]) -> re.Match[str] | None:
    m = heading_re.match(line)
    if m and m.group("rest").split()[0].lower() not in UNIT_WORDS:
        return m
    return None


def is_rule_list_page(lines: list[str], heading_re: re.Pattern[str]) -> bool:
    """The rulebook's own list of rule titles ("604.2 Rights and Duties…" one per line)."""
    if len(lines) < 8:
        return False

    def title_only(line: str) -> bool:
        # "640 Protests" or "604.2 Rights and Duties ... 79", not rule text like "641.1 Against admittance…,"
        m = rule_heading(line, heading_re)
        if not m or len(line.split()) > 12:
            return False
        rest = re.sub(r"[ .]*\d+$", "", m.group("rest")).strip()  # trailing page number
        return bool(rest) and rest[0].isupper() and not rest.endswith((".", ",", ";", ":"))

    hits = sum(1 for l in lines if title_only(l))
    return hits >= RULE_LIST_DENSITY * len(lines)


def rule_sequence(
    pages: list[list[str]], heading_re: re.Pattern[str], skip: set[int], rules_from_page: int
) -> set[tuple[int, int]]:
    """(page, line) positions of real rule headings.

    Any line starting with a number is a candidate. A stray one ("1001.3.2 remain valid."
    wrapped from a sentence) would derail a greedy ascending check, so pick the longest
    chain of candidates in which each plausibly follows the previous one.
    """
    candidates: list[tuple[tuple[int, int], str]] = []
    for p, lines in enumerate(pages):
        if p in skip or p < rules_from_page or is_rule_list_page(lines, heading_re):
            continue
        for i, line in enumerate(lines):
            if m := rule_heading(line, heading_re):
                candidates.append(((p, i), m.group("num")))
    n = len(candidates)
    best = [0] * n
    previous = [-1] * n
    for i, (_, num) in enumerate(candidates):
        best[i] = 1 if is_plausible_successor(None, num) else 0
        for j in range(max(0, i - 400), i):  # chains rarely skip more than a few hundred candidates
            if best[j] and best[j] + 1 > best[i] and is_plausible_successor(candidates[j][1], num):
                best[i], previous[i] = best[j] + 1, j
    if not n or max(best) == 0:
        return set()
    i = max(range(n), key=lambda k: (best[k], -k))
    chosen = set()
    while i >= 0:
        chosen.add(candidates[i][0])
        i = previous[i]
    return chosen


def sectionize_rules(
    pages: list[list[str]], heading_re: re.Pattern[str], skip: set[int], chapters: bool = False,
    rules_from_page: int = 0,
) -> list[Section]:
    """Numbered-rule documents. With `chapters`, ALL-CAPS and CHAPTER headings outside the
    numbered rules also start sections (a guide with narrative chapters around the rules)."""
    sections: list[Section] = []
    current = Section(None, None, None, page_start=0)
    current_has_body = False
    headings_by_rule: dict[str, str] = {}
    rules = rule_sequence(pages, heading_re, skip, rules_from_page)

    for page_index, lines in enumerate(pages):
        if page_index in skip:
            continue
        rule_list = is_rule_list_page(lines, heading_re)
        for line_index, line in enumerate(lines):
            m = rule_heading(line, heading_re) if page_index >= rules_from_page else None
            if rule_list and (m or TOC_ENTRY.match(line) or TOC_LINE.search(line)):
                continue  # entries of the rulebook's own list of rules, not the rules themselves
            if chapters and not m and (caps_heading(line) or UNIT.match(line)):
                unit = UNIT.match(line)
                title = smart_title(short_heading((unit.group("rest") or line) if unit else line))
                if (current.rule_number is None and current.heading and not current_has_body
                        and current.lines and current.lines[-1][0] == page_index):
                    # "CHAPTER 7" + "ALPINE COMPETITION" + "REGULATIONS" -> "Chapter 7 — Alpine Competition Regulations"
                    joiner = " — " if re.fullmatch(r"Chapter \w+", current.heading) else " "
                    current.heading = current.heading + joiner + title
                    current.lines.append((page_index, line))
                    continue
                if current.lines:
                    sections.append(current)
                current = Section(None, title, None, page_start=page_index, level=0)
                current.lines.append((page_index, line))
                current_has_body = False
                continue
            if m and (page_index, line_index) in rules:
                num = m.group("num")
                heading, _ = split_heading(m.group("rest"))
                if current.lines:
                    sections.append(current)
                headings_by_rule[num] = heading
                current = Section(
                    rule_number=num,
                    heading=heading or None,
                    breadcrumb=breadcrumb_for(num, headings_by_rule),
                    page_start=page_index,
                    level=num.count("."),
                )
                current.lines.append((page_index, f"{num} {m.group('rest')}"))
                current_has_body = True
            else:
                if not current.lines:
                    current.page_start = page_index
                current.lines.append((page_index, line))
                current_has_body = True
    if current.lines:
        sections.append(current)
    return sections


# MARK: - Outline documents (manuals, study guides, FIS documents)

ROMAN = re.compile(r"^(?P<num>[IVX]{1,5})\.\s+(?P<rest>\S.*)$")
LETTER = re.compile(r"^(?P<num>[A-Z])\.\s+(?P<rest>\S.*)$")
NUMBERED_CAPS = re.compile(r"^\d{1,2}\.\s+(?P<rest>[^a-z]+)$")
UNIT = re.compile(r"^(?:UNIT|CHAPTER|SECTION|PART|APPENDIX)\s+[IVX\d]+\b[.:;]?\s*(?P<rest>.*)$")
DECIMAL = re.compile(r"^(?P<num>\d{1,2}(?:\.\d{1,2}){0,4})\.?\s+(?P<rest>[A-Z'\"“(][^\n]{1,110})$")
MULTILEVEL_DECIMAL = re.compile(r"^\d{1,2}\.\d{1,2}(?:\.\d{1,2})*\.?\s+[A-Z]")

ACRONYMS = {
    "ACR", "ICR", "FIS", "DNF", "DNS", "DSQ", "DNQ", "TD", "OC", "LOC", "YSL", "NAC", "WC", "AO",
    "AOM", "MAAPP", "MPF", "GS", "SL", "SG", "DH", "AC", "U.S.", "USSS", "II", "III", "IV", "VI",
    "VII", "VIII", "IX", "XI", "XII", "CR", "CC", "RF", "RA", "TC", "CO", "B-NET", "OISRA", "OSIRA",
    "SCRC", "FISU", "UNI", "NSA", "EET", "TDTR", "CDC", "SCAT6", "CRT6", "USA", "PDF", "ID", "NPS", "FIS-U",
}
SMALL_WORDS = {"a", "an", "and", "as", "at", "by", "for", "in", "of", "on", "or", "the", "to", "vs", "versus", "with"}


def smart_title(text: str) -> str:
    """'COMPOSITION OF THE JURY' -> 'Composition of the Jury', keeping acronyms.

    Merged headings ("Race Organization — THE RACE COMMITTEE") are handled per segment.
    """
    if " — " in text:
        return " — ".join(smart_title(part) for part in text.split(" — "))
    if re.search(r"[a-z]", text):
        return text
    words = []
    for i, word in enumerate(text.split()):
        core = word.strip("()\"“”'’,:;!?")
        if core.upper() in ACRONYMS or re.fullmatch(r"[A-Z]\.([A-Z]\.)+", core):
            words.append(word)
        elif i > 0 and core.lower() in SMALL_WORDS:
            words.append(word.lower())
        else:
            words.append(re.sub(r"[A-Z][A-Z']*", lambda m: m.group(0).capitalize(), word))
    return " ".join(words)


def short_heading(text: str, limit: int = 70) -> str:
    """Heading from an outline line that may run on into a sentence."""
    text = re.split(r"\s\[|:|\s\(Refer", text, maxsplit=1)[0].strip()
    if len(text) <= limit:
        return text.rstrip(".;,")
    cut = text[:limit].rsplit(" ", 1)[0]
    return cut.rstrip(".;,") + "…"


def caps_heading(line: str) -> bool:
    """An ALL-CAPS line that reads like a section title, not a shouted label."""
    letters = re.findall(r"[A-Za-z]", line)
    if len(letters) < 4 or re.search(r"[a-z]", line) or len(line) > 100:
        return False
    if line.startswith(("(", "•", "-", "*")) or line.endswith(("!", ".", "?", ",")):
        return False
    words = line.split()
    if not any(len(re.sub(r"[^A-Za-z]", "", w)) >= 3 for w in words):
        return False  # table rows like "DH SL GS SG" or "A E D C"
    if len(words) == 1 and line.endswith(":"):
        return False  # "NOTES:", "LOCATION:" are inline labels
    digits = sum(c.isdigit() for c in line)
    return digits <= len(letters) // 3


def decimal_successor(prev: tuple[int, ...] | None, new: tuple[int, ...]) -> bool:
    """True if `new` plausibly follows `prev` in a 1 / 1.1 / 1.1.1 numbering scheme."""
    if prev is None:
        return new[0] <= 2 and all(x <= 1 for x in new[1:])
    if new[: len(prev)] == prev and len(new) == len(prev) + 1 and new[-1] <= 1:
        return True  # first child: 2.1 -> 2.1.1 (or 3.1.0)
    for k in range(min(len(prev), len(new))):
        if new[:k] != prev[:k]:
            break
        if 0 < new[k] - prev[k] <= 3 and all(x <= 1 for x in new[k + 1:]):
            return True  # next sibling at depth k (small gaps allowed)
    return False


@dataclass
class OutlineState:
    last_letter: str | None = None
    last_decimal: tuple[int, ...] | None = None
    decimal_titles: dict[str, str] = field(default_factory=dict)


def outline_heading(
    line: str, state: OutlineState, decimals: bool, allow_decimal: bool = True
) -> tuple[int, str, str | None] | None:
    """(level, raw heading text, section number) when a line starts a section."""
    if decimals and allow_decimal and (m := DECIMAL.match(line)):
        key = tuple(int(x) for x in m.group("num").split("."))
        if len(m.group("rest").split()) <= 14 and decimal_successor(state.last_decimal, key):
            state.last_decimal = key
            num = m.group("num")
            state.decimal_titles[num] = smart_title(short_heading(m.group("rest")))
            return min(len(key) - 1, 3), short_heading(m.group("rest")), num
    if m := UNIT.match(line):
        rest = m.group("rest").strip() or line
        return 0, short_heading(rest), None
    if (m := ROMAN.match(line)) and not (
        state.last_letter and chr(ord(state.last_letter) + 1) == m.group("num")
    ):
        return 0, short_heading(m.group("rest")), None
    if (m := LETTER.match(line)) and m.group("rest")[0].isupper():
        return 1, short_heading(m.group("rest")), None
    if (m := NUMBERED_CAPS.match(line)) and caps_heading(m.group("rest")):
        return 1, short_heading(m.group("rest")), None
    if caps_heading(line):
        return 0, short_heading(line), None
    return None


def list_item_numbers(pages: list[list[str]], skip: set[int]) -> set[tuple[int, int]]:
    """(page, line) positions of "2. Something" lines that are list items, not sections.

    A top-level number N only starts a section if the next sub-numbered line
    continues it (N.1, N.0) or no sub-numbered line follows at all.
    """
    candidates = []
    for p, lines in enumerate(pages):
        if p in skip or is_toc_page(lines):
            continue
        for i, line in enumerate(lines):
            if m := DECIMAL.match(line):
                candidates.append(((p, i), tuple(int(x) for x in m.group("num").split("."))))
    rejected = set()
    for idx, (pos, key) in enumerate(candidates):
        if len(key) != 1:
            continue
        following = next((k for _, k in candidates[idx + 1:] if len(k) > 1), None)
        if following is not None and following[0] != key[0]:
            rejected.add(pos)
    return rejected


def sectionize_outline(pages: list[list[str]], doc_title: str, skip: set[int]) -> list[Section]:
    """Split outline documents into sections.

    Headings: ALL-CAPS lines, "SECTION I"/"UNIT II", "I." and "A." outline
    items, and (in documents that use them) decimal numbers like "4.2.5".
    Consecutive heading lines with no text between them are merged.
    """
    content = [lines for i, lines in enumerate(pages) if i not in skip and not is_toc_page(lines)]
    decimals = sum(1 for lines in content for l in lines if MULTILEVEL_DECIMAL.match(l)) >= 5

    list_items = list_item_numbers(pages, skip) if decimals else set()
    sections: list[Section] = []
    current = Section(None, None, None, page_start=0)
    current_has_body = False
    parent: str | None = None
    state = OutlineState()

    for page_index, lines in enumerate(pages):
        if page_index in skip or is_toc_page(lines):
            continue
        for line_index, line in enumerate(lines):
            if TOC_LINE.search(line):
                continue
            found = outline_heading(line, state, decimals, allow_decimal=(page_index, line_index) not in list_items)
            if found:
                level, raw, number = found
                if m := LETTER.match(line):
                    state.last_letter = m.group("num")
                elif level == 0 and number is None:
                    state.last_letter = None
                wraps = (current.raw_heading or "").rstrip().endswith((",", " AND", " and", "-", "–", "&", " OF", " THE"))
                if (not current_has_body and current.raw_heading and number is None and current.rule_number is None
                        and current.lines and current.lines[-1][0] == page_index
                        and (level > current.level or (wraps and level == current.level))):
                    # The heading wraps onto the next line, or a sub-heading follows directly.
                    current.raw_heading = f"{current.raw_heading}{' ' if wraps else ' — '}{raw}"
                    current.heading = smart_title(current.raw_heading)
                    if level == 0 or current.level == 0:
                        parent = current.heading
                    current.lines.append((page_index, line))
                    continue
                heading = smart_title(raw)
                if current.lines:
                    sections.append(current)
                if number:
                    crumb = breadcrumb_for(number, state.decimal_titles)
                else:
                    if level == 0:
                        parent = heading
                    crumb = parent if level > 0 and parent else None
                current = Section(
                    rule_number=number, heading=heading, breadcrumb=crumb, page_start=page_index, level=level,
                    raw_heading=raw,
                )
                current.lines.append((page_index, line))
                current_has_body = False
            else:
                if not current.lines:
                    current.page_start = page_index
                current.lines.append((page_index, line))
                current_has_body = True
    if current.lines:
        sections.append(current)
    for s in sections:
        if s.heading is None:
            s.heading = doc_title  # untitled lead-in text, e.g. a cover page
    return sections


def sectionize_slides(pages: list[list[str]], skip: set[int]) -> list[Section]:
    """One section per slide, titled with the slide's first line."""
    sections = []
    for page_index, lines in enumerate(pages):
        if page_index in skip or not lines:
            continue
        title = smart_title(short_heading(lines[0], 80))
        section = Section(None, title, None, page_start=page_index)
        section.lines = [(page_index, l) for l in lines]
        sections.append(section)
    return sections


# MARK: - Chunking


RULE_REF_IN_BRACKETS = re.compile(r"\[([^\]]{3,200})\]")
RULE_REF = re.compile(r"(?<![\d.])U?\d{3}(?:\.\d{1,3}){0,5}(?![\d])")
RULE_REF_INLINE = re.compile(r"\b(?:ICR|ACR|[Rr]ules?|[Aa]rt\.?|[Aa]rticle)\s+(U?\d{3}(?:\.\d{1,3}){0,5})")


def rule_refs(text: str) -> str | None:
    """Rule numbers cited in a passage, e.g. "[601.4.1, U601.4.2.3]" or "ICR 614.2".

    Stored space-padded (" 601.4.1 U601.4.2.3 ") so exact lookups can use LIKE '% n %'.
    """
    found: list[str] = []
    for m in RULE_REF_IN_BRACKETS.finditer(text):
        found += RULE_REF.findall(m.group(1))
    found += RULE_REF_INLINE.findall(text)
    unique = list(dict.fromkeys(r for r in found if 100 <= int(r.lstrip("U").split(".")[0]) <= 999))
    return f" {' '.join(unique)} " if unique else None


def chunk_section(section: Section) -> list[Chunk]:
    """Split a section into ~TARGET_WORDS chunks, tracking page spans."""
    words: list[tuple[int, str]] = []
    for page, line in section.lines:
        words.extend((page, w) for w in line.split())
    if not words:
        return []

    chunks = []
    start = 0
    part = 0
    while start < len(words):
        end = min(len(words), start + TARGET_WORDS)
        # Avoid a tiny trailing chunk: absorb it into this one.
        if len(words) - end < OVERLAP_WORDS * 2:
            end = len(words)
        window = words[start:end]
        chunks.append(
            Chunk(
                rule_number=section.rule_number,
                heading=section.heading,
                breadcrumb=section.breadcrumb,
                text=dehyphenate(" ".join(w for _, w in window)),
                page_start=window[0][0],
                page_end=window[-1][0],
                part=part,
                level=section.level,
            )
        )
        if end == len(words):
            break
        start = end - OVERLAP_WORDS
        part += 1
    return chunks


def dehyphenate(text: str) -> str:
    # "inspec- tion" -> "inspection" (line-break hyphenation)
    return re.sub(r"([a-z])- ([a-z])", r"\1\2", text)


MIN_SECTION_WORDS = 80


def word_count(section: Section) -> int:
    return sum(len(line.split()) for _, line in section.lines)


def can_merge(prev: Section, nxt: Section, slides: bool) -> bool:
    """Short sections are folded into the previous one when they belong together:
    consecutive slides, a sub-section of the previous heading, or a numbered
    sibling under the same top-level number."""
    if slides:
        return True
    if prev.rule_number and nxt.rule_number:
        return prev.rule_number.split(".")[0] == nxt.rule_number.split(".")[0]
    return nxt.level > prev.level or (nxt.level == prev.level and nxt.breadcrumb == prev.breadcrumb and nxt.level > 0)


def merge_small_sections(sections: list[Section], slides: bool = False) -> list[tuple[Section, list[Section]]]:
    """Group sections so tiny ones don't become chunks too small to be useful.

    Returns (merged section, original sections it contains) pairs; the originals
    feed the table of contents.
    """
    groups: list[tuple[Section, list[Section]]] = []
    for section in sections:
        if groups:
            merged, members = groups[-1]
            size = word_count(merged)
            if size < MIN_SECTION_WORDS and size + word_count(section) <= TARGET_WORDS \
                    and can_merge(members[-1], section, slides):
                merged.lines.extend(section.lines)
                members.append(section)
                continue
        copy = Section(section.rule_number, section.heading, section.breadcrumb, section.page_start,
                       list(section.lines), section.level)
        groups.append((copy, [section]))
    return groups


def cross_reference(heading: str, rules: list[str]) -> str:
    """Note for a passage that restates ACR rules without citing them. Retrieval follows the cited
    rules, as it does a study guide's "[623.3.3]", so the model reads the ACR wording alongside:
    OISRA's "remains valid if it proves slower" lacks the ACR's "even", and was read as "only if"."""
    return f"(ARC cross-reference: {heading}, see " + " and ".join(f"ACR {r}" for r in rules) + ".)"


def supplement_sections(path: Path, page: int | None = None) -> list[Section]:
    """'## Heading' blocks of a supplement file; '<!-- page: N -->' (1-based) sets the cited page,
    unless `page` (1-based) is given: then every passage cites that page."""
    text = re.sub(r"<!--(?!\s*page:).*?-->", "", path.read_text(), flags=re.DOTALL)
    sections: list[Section] = []
    fixed = page is not None
    page = page - 1 if fixed else 0
    for line in text.splitlines():
        line = line.strip()
        if m := re.match(r"<!--\s*page:\s*(\d+)\s*-->", line):
            if not fixed:
                page = int(m.group(1)) - 1
        elif line.startswith("## "):
            sections.append(Section(None, line[3:].strip(), "Transcribed table", page, [(page, line[3:].strip())], 1))
        elif line and sections:
            sections[-1].lines.append((page, line))
    return sections


def sectionize(src: Source, pages: list[list[str]]) -> list[Section]:
    skip = set(src.skip_pages)
    if src.style in ("rules", "guide"):
        heading_re = re.compile(src.heading_pattern) if src.heading_pattern else RULE_HEADING_RE
        return sectionize_rules(pages, heading_re, skip, chapters=src.style == "guide",
                                rules_from_page=src.rules_from_page)
    if src.style == "slides":
        return sectionize_slides(pages, skip)
    return sectionize_outline(pages, src.title, skip)


# MARK: - Build


def build(sources: list[Source], out: Path, pdf_out: Path | None = None) -> dict[str, int]:
    if out.exists():
        out.unlink()
    out.parent.mkdir(parents=True, exist_ok=True)
    if pdf_out:
        pdf_out.mkdir(parents=True, exist_ok=True)
        for old in pdf_out.glob("*.pdf"):
            old.unlink()
    db = sqlite3.connect(out)
    db.executescript(SCHEMA)
    digest = hashlib.sha256()
    stats = {"documents": 0, "sections": 0, "chunks": 0}

    for doc_id, src in enumerate(sources, start=1):
        if not src.file.exists():
            raise FileNotFoundError(f"{src.slug}: {src.file} not found")
        data = src.file.read_bytes()
        digest.update(data)
        filename = f"{src.slug}.pdf"
        if pdf_out:
            (pdf_out / filename).write_bytes(data)

        reader = PdfReader(str(src.file))
        raw_pages = extract_pages(reader)
        labels = page_labels(reader)
        if src.style == "slides":
            labels = [f"Slide {i + 1}" for i in range(len(reader.pages))]
        elif src.page_label_pattern:
            labels = labels_from_text(raw_pages, src.page_label_pattern, labels)
        ignore = [re.compile(p) for p in src.ignore_patterns]
        pages = raw_pages if src.style == "slides" else strip_running_text(raw_pages)
        pages = [[l for l in lines if not any(r.match(l) for r in ignore)] for lines in pages]
        sections = sectionize(src, pages)

        db.execute(
            "INSERT INTO documents (id, slug, title, edition, collection, jurisdiction, roles, filename,"
            " priority, sort_order, page_count) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
            (doc_id, src.slug, src.title, src.edition, src.collection, src.jurisdiction,
             f" {' '.join(src.roles)} " if src.roles else None, filename, src.priority, src.sort_order,
             len(reader.pages)),
        )
        db.executemany(
            "INSERT INTO pages (doc_id, page_index, page_label) VALUES (?,?,?)",
            [(doc_id, i, label) for i, label in enumerate(labels)],
        )
        groups = merge_small_sections(sections, slides=src.style == "slides")
        if src.supplement:
            groups += [(s, [s]) for s in supplement_sections(src.supplement, src.supplement_page)]
            digest.update(src.supplement.read_bytes())
        position = 0
        unmatched = set(src.see_also)
        for merged, members in groups:
            first_chunk_id = None
            for c in chunk_section(merged):
                text = c.text
                breadcrumb = c.breadcrumb
                if src.title_in_index:
                    breadcrumb = f"{src.title} › {breadcrumb}" if breadcrumb else src.title
                if c.heading in src.see_also:
                    unmatched.discard(c.heading)
                    text += " " + cross_reference(c.heading, src.see_also[c.heading])
                cursor = db.execute(
                    "INSERT INTO chunks (doc_id, rule_number, heading, breadcrumb, level, rule_refs, text,"
                    " page_start, page_end, part) VALUES (?,?,?,?,?,?,?,?,?,?)",
                    (doc_id, c.rule_number, c.heading, breadcrumb, c.level, rule_refs(text), text,
                     c.page_start, c.page_end, c.part),
                )
                first_chunk_id = first_chunk_id or cursor.lastrowid
                stats["chunks"] += 1
            if first_chunk_id is None:
                continue
            for member in members:
                if member.heading or member.rule_number:
                    db.execute(
                        "INSERT INTO toc (doc_id, position, number, heading, level, page_index, chunk_id)"
                        " VALUES (?,?,?,?,?,?,?)",
                        (doc_id, position, member.rule_number, member.heading or "", member.level,
                         member.page_start, first_chunk_id),
                    )
                    position += 1
        stats["sections"] += len(sections)
        stats["documents"] += 1
        if src.see_also:
            digest.update(repr(sorted(src.see_also.items())).encode())  # notes change passage text
        for heading in sorted(unmatched):
            print(f"warning: {src.slug}: see_also heading \"{heading}\" matches no section", file=sys.stderr)

    db.execute("INSERT INTO chunks_fts(chunks_fts) VALUES ('rebuild')")
    db.executemany(
        "INSERT INTO meta (key, value) VALUES (?, ?)",
        [("schema_version", str(SCHEMA_VERSION)), ("index_version", digest.hexdigest()[:16])],
    )
    db.commit()
    db.execute("VACUUM")
    db.close()
    return stats


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--library", type=Path, default=DEFAULT_LIBRARY,
                        help="private document library (documents/, supplements/, eval/)")
    parser.add_argument("--docs", type=Path, help="folder of PDF, PPTX/PPT and Word/Excel files (default: <library>/documents)")
    parser.add_argument("--catalog", type=Path, default=HERE / "catalog.yaml")
    parser.add_argument("--out", type=Path, default=ROOT / "App/Resources/rulebook.sqlite")
    parser.add_argument("--pdf-out", type=Path, default=ROOT / "App/Resources/Documents")
    parser.add_argument("--cache", type=Path, default=HERE / ".build")
    args = parser.parse_args(argv)
    args.docs = args.docs or default_docs(args.library)

    if not args.docs.is_dir():
        print(f"No documents folder at {args.docs}", file=sys.stderr)
        return 1
    sources, warnings = discover(args.docs, args.catalog, args.cache, args.library)
    for w in warnings:
        print(f"warning: {w}", file=sys.stderr)
    stats = build(sources, args.out, args.pdf_out)
    print(f"Wrote {args.out}: {stats['documents']} documents, {stats['sections']} sections, {stats['chunks']} chunks")
    return 0


if __name__ == "__main__":
    sys.exit(main())
