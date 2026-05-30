"""Doc-RAG retrieval tools — lexical search over the platform docs corpus.

The `docs/` tree is baked into the image at /srv/docs-bundle by
build-and-load.sh (gitignored in the build context, like observatory-ui).
For local-dev runs it falls back to the repo's docs/ directory.

    search_docs(query)  — rank markdown files by query-term hits, return snippets
    read_doc(path)      — return a doc's text (capped), for the agent to cite

Lexical only — no embeddings, no network, no index server. Enough to ground
answers about architecture / ADRs / use-cases / compliance and cite the
source path. read_doc refuses paths outside the docs root (no traversal).

Environment:
    DOCS_DIR             — docs root (default /srv/docs-bundle, else repo docs/)
    DOCS_MAX_RESULTS     — top-N results from search_docs (default 6)
    DOCS_MAX_DOC_CHARS   — read_doc cap (default 8000)
"""

from __future__ import annotations

import json
import logging
import os
import re
from pathlib import Path

from nanitics import tool

from docs_index import pgvector_configured, search_chunks

LOG = logging.getLogger("nanitics-observatory-uwv.docs_tools")

# 'pgvector' (semantic, default) automatically falls back to 'lexical'
# (keyword) when the vector backend isn't configured or a query errors.
DOCS_BACKEND = os.environ.get("DOCS_BACKEND", "pgvector").lower()

_BAKED = Path("/srv/docs-bundle")
# Local-dev fallback: repo docs/ is four levels up from this file
# (repo/platform/19-nanitics-observatory/app/docs_tools.py).
_FALLBACK = Path(__file__).resolve().parents[3] / "docs"
DOCS_DIR = Path(
    os.environ.get("DOCS_DIR", str(_BAKED if _BAKED.exists() else _FALLBACK))
)
MAX_RESULTS = int(os.environ.get("DOCS_MAX_RESULTS", "6"))
MAX_DOC_CHARS = int(os.environ.get("DOCS_MAX_DOC_CHARS", "8000"))


def _tokens(text: str) -> list[str]:
    return [t for t in re.split(r"[^a-z0-9]+", text.lower()) if len(t) > 2]


def _lexical_search(query: str) -> list[dict]:
    """Keyword fallback — rank markdown files by query-term frequency."""
    terms = set(_tokens(query))
    if not terms or not DOCS_DIR.exists():
        return []
    scored: list[dict] = []
    for path in DOCS_DIR.rglob("*.md"):
        try:
            text = path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        low = text.lower()
        score = sum(low.count(t) for t in terms)
        if score <= 0:
            continue
        hits = [low.find(t) for t in terms if low.find(t) >= 0]
        idx = min(hits) if hits else 0
        start = max(0, idx - 120)
        snippet = " ".join(text[start : start + 320].split())
        scored.append(
            {"path": os.path.relpath(str(path), str(DOCS_DIR)), "score": score, "snippet": snippet}
        )
    scored.sort(key=lambda d: d["score"], reverse=True)
    return scored[:MAX_RESULTS]


@tool(
    "search_docs",
    "Search the platform documentation (architecture, ADRs, use-cases, "
    "compliance, runbooks) and return the best-matching passages as JSON "
    "{path, score, snippet}. Semantic (pgvector) when configured, otherwise "
    "keyword search. Use this FIRST to find which docs answer a question, "
    "then call read_doc to get the full text you will cite.",
)
async def search_docs(query: str) -> str:
    if not query.strip():
        return json.dumps({"error": "empty query"})
    if DOCS_BACKEND == "pgvector" and pgvector_configured():
        try:
            results = await search_chunks(query, MAX_RESULTS)
            return json.dumps({"backend": "pgvector", "results": results})
        except Exception as exc:  # noqa: BLE001 — any DB/embed error → lexical
            LOG.warning("pgvector search failed; falling back to lexical: %s", exc)
            return json.dumps(
                {
                    "backend": "lexical",
                    "fallback_reason": str(exc),
                    "docs_dir": str(DOCS_DIR),
                    "results": _lexical_search(query),
                }
            )
    return json.dumps(
        {"backend": "lexical", "docs_dir": str(DOCS_DIR), "results": _lexical_search(query)}
    )


@tool(
    "read_doc",
    "Read a documentation file returned by search_docs and return its text "
    "(capped). Arg: path — the 'path' field from a search_docs result, "
    "relative to the docs root. Refuses paths outside the docs root.",
)
async def read_doc(path: str) -> str:
    root = DOCS_DIR.resolve()
    target = (root / path).resolve()
    try:
        target.relative_to(root)
    except ValueError:
        return json.dumps({"error": "path outside docs root"})
    if not target.is_file():
        return json.dumps({"error": f"not found: {path}"})
    text = target.read_text(encoding="utf-8", errors="ignore")
    return json.dumps(
        {"path": path, "truncated": len(text) > MAX_DOC_CHARS, "text": text[:MAX_DOC_CHARS]}
    )


DOC_RAG_TOOLS = [search_docs, read_doc]
