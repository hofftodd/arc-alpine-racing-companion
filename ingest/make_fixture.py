#!/usr/bin/env python3
"""Regenerate the Swift test fixture database from the pytest sample documents.

Two documents: a numbered-rules U.S. Ski & Snowboard guide (tagged for referees)
and an OISRA outline document, so the Swift tests can cover race-context
precedence and role boosts.
"""
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE / "tests")]

import build_index as bi  # noqa: E402
from conftest import OUTLINE_PAGES, RULES_PAGES, render, render_with_running_text  # noqa: E402

out = HERE.parent / "Packages/RulebookKit/Tests/RulebookKitTests/Fixtures/sample.sqlite"
with tempfile.TemporaryDirectory() as tmp:
    guide = Path(tmp) / "guide.pdf"
    guide.write_bytes(render_with_running_text(RULES_PAGES))
    oisra = Path(tmp) / "oisra.pdf"
    oisra.write_bytes(render(OUTLINE_PAGES))
    sources = [
        bi.Source(slug="acg", file=guide, title="Alpine Competition Guide", edition="2026", style="rules",
                  collection="U.S. Ski & Snowboard", jurisdiction="usss", roles=["referee"], sort_order=1),
        bi.Source(slug="oisra", file=oisra, title="OISRA Alpine Race Rules", edition="2026",
                  collection="Oregon High School (OISRA)", jurisdiction="oisra", sort_order=0),
    ]
    print(bi.build(sources, out), "->", out)
