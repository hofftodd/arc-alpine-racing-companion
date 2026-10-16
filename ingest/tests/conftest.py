"""Fixtures: small synthetic PDFs shaped like the real reference documents."""

from __future__ import annotations

import io
import sys
from pathlib import Path

import pytest
from pypdf import PdfReader, PdfWriter
from pypdf.constants import PageLabelStyle
from reportlab.lib.pagesizes import letter
from reportlab.pdfgen import canvas

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

# Numbered rules (Competition Guide / ACR style). Front matter is two roman-numbered pages.
RULES_PAGES = [
    ["ALPINE COMPETITION GUIDE", "Table of Contents"],
    ["Foreword", "These rules govern all sanctioned events."],
    [
        "600 JURY",
        "601 Composition of the Jury",
        "601.1 The jury consists of the Technical Delegate, the Referee and the Chief of Race.",
        "601.2 Assistant Referee For speed events an assistant referee may be appointed",
        "by the Technical Delegate.",
    ],
    [
        "601.2.1 The assistant referee has no vote on the jury.",
        "The race covers 1500 meters of vertical drop.",
        "614 Course Inspection",
        "614.1 Competitors must inspect the course wearing their start bibs.",
        "Inspection by skiing through gates is forbidden and leads to disqualifica-",
        "tion of the competitor.",
    ],
    [
        "614.2 Inspection Time The jury sets the inspection time and announces it at the team",
        "captains' meeting.",
    ],
]

# Officials' Manual chapter style: label line, cover with dot-leader TOC, ALL-CAPS headings.
MANUAL_PAGES = [
    [
        "III/1/2026",
        "ALPINE OFFICIALS' MANUAL",
        "CHAPTER III",
        "RULES, THE JURY, AND",
        "THE TECHNICAL DELEGATE",
        "SEASON 2026",
        "OVERVIEW ................................................ III/ 2/2026",
        "COMPETITION JURY ........................................ III/ 3/2026",
    ],
    [
        "III/2/2026",
        "OVERVIEW",
        "This chapter discusses the jury and the role of the Technical Delegate in detail.",
        "LOCATION:",
        "The jury meets at the start.",
    ],
    [
        "III/3/2026",
        "COMPETITION JURY",
        "The jury controls an event and rules on all matters [601.4, U601.4.2.3].",
        "COMPOSITION OF THE JURY",
        "The jury is composed of the TD, the Referee and the Chief of Race (ICR 601.1).",
    ],
    ["III/4/2026", "DUE PROCESS", "Competitors are entitled to a hearing before a sanction is imposed."],
]

# Study guide / OISRA outline style.
OUTLINE_PAGES = [
    [
        "SECTION I Race Organization",
        "A. THE RACE COMMITTEE, RACE OFFICIALS & JURY:",
        "1. Composition of Race Committee and Jury:",
        "a. Race Committee: Chief of Race, Chief of Course and the Chief Gate Judge.",
        "B. START and FINISH:",
        "1. The start area must be closed off to the public.",
    ],
    [
        "J. Re-Runs:",
        "1. Any racer hindered on course may ask the Start Referee for a provisional re-run.",
        "2. A hindered competitor's inspection follows the national rules [614.1].",
    ],
]

# FIS style decimal sections, including a numbered list that must not become headings.
DECIMAL_PAGES = [
    [
        "1 The Competition",
        "1.1 Requirements",
        "A race counts for points only if:",
        "1. Results must be sent within 24 hours",
        "2. The jury must be complete",
        "1.2 Schedule Changes",
        "Changes must be approved.",
        "1.2.1 Change of categories",
        "If a National Association wishes to change the category it must apply.",
    ],
    [
        "2 The Competitors",
        "2.1 Registration",
        "Competitors are registered by the National Ski Association.",
        "2.1.1 Code Number",
        "Only competitors with a valid code number may start.",
        "3 Evaluation Period",
        "The evaluation period starts in July.",
    ],
]


def render(pages: list[list[str]]) -> bytes:
    buf = io.BytesIO()
    c = canvas.Canvas(buf, pagesize=letter)
    for i, lines in enumerate(pages):
        c.setFont("Helvetica", 11)
        y = 720
        for line in lines:
            c.drawString(50, y, line)
            y -= 18
        c.showPage()
    c.save()
    return buf.getvalue()


def render_with_running_text(pages: list[list[str]]) -> bytes:
    """Adds a running header and footer page number, which the indexer must strip."""
    buf = io.BytesIO()
    c = canvas.Canvas(buf, pagesize=letter)
    for i, lines in enumerate(pages):
        c.setFont("Helvetica", 9)
        c.drawString(72, 750, "U.S. Ski & Snowboard Alpine Competition Guide 2026")
        c.setFont("Helvetica", 11)
        y = 700
        for line in lines:
            c.drawString(72, y, line)
            y -= 18
        c.setFont("Helvetica", 9)
        c.drawString(300, 40, str(i + 1))
        c.showPage()
    c.save()
    return buf.getvalue()


@pytest.fixture
def rules_pdf(tmp_path: Path) -> Path:
    reader = PdfReader(io.BytesIO(render_with_running_text(RULES_PAGES)))
    writer = PdfWriter()
    writer.append(reader)
    writer.set_page_label(0, 1, style=PageLabelStyle.LOWERCASE_ROMAN)
    writer.set_page_label(2, len(RULES_PAGES) - 1, style=PageLabelStyle.DECIMAL, start=1)
    path = tmp_path / "guide.pdf"
    with path.open("wb") as f:
        writer.write(f)
    return path


@pytest.fixture
def pdf_factory(tmp_path: Path):
    def make(name: str, pages: list[list[str]]) -> Path:
        path = tmp_path / name
        path.write_bytes(render(pages))
        return path

    return make
