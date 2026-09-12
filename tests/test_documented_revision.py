"""Keep operator instructions on the same immutable engine as certification."""

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_operator_documents_identify_the_certified_engine():
    dependency = json.loads((ROOT / "bootstrap-manifest.json").read_text())[
        "production_dependency"
    ]
    expected = dependency["commit"]
    assert re.fullmatch(r"[0-9a-f]{40}", expected)
    pattern = re.escape(dependency["repository"]) + r"@([0-9a-f]{40})"
    for name in ("README.md", "AGENTS.md"):
        revisions = re.findall(pattern, (ROOT / name).read_text())
        assert revisions == [expected], f"{name} does not identify the certified engine"


def test_source_and_certification_revisions_keep_distinct_provenance():
    source = json.loads((ROOT / "canonical-quote-source.json").read_text())
    dependency = json.loads((ROOT / "bootstrap-manifest.json").read_text())[
        "production_dependency"
    ]
    assert source["certificationDpmCommit"] == dependency["commit"]
    documented = re.findall(
        r"production DPM revision `([0-9a-f]{40})`", (ROOT / "README.md").read_text()
    )
    assert documented == [source["dpmCommit"]]
