"""pgvector-backed semantic index for the doc-rag agent.

Storage/retrieval layer behind `docs_tools.search_docs`:

    index_docs()                 — chunk the docs corpus, embed, (re)load pgvector
    search_chunks(query, k)      — embed the query, cosine-nearest chunks
    pgvector_configured()        — is the backend wired (PG password + embed key)?

Embeddings use the SAME Azure AI Foundry endpoint as the LLM (OpenAI-compatible
/embeddings), so no new provider/credential is introduced. Vectors live in a
DEDICATED Postgres (`nanitics-docs-postgres`, pgvector image) — doc embeddings
are their own data domain, exactly as Multica runs its own pgvector (see
platform/17-multica/postgres.yaml).

`psycopg` is imported lazily inside functions, mirroring how watcher.py treats
kubernetes_asyncio and platform_tools.py treats trino: a missing driver must
never break module import (the agent then just falls back to lexical search).

Environment:
    DOCS_DIR                 — docs corpus root (default /srv/docs-bundle)
    DOCS_PG_HOST/PORT/DB/USER/PASSWORD  — the pgvector Postgres
    EMBEDDING_MODEL          — Foundry embedding deployment (default text-embedding-3-small)
    EMBEDDING_DIM            — vector dimension; MUST match the model (default 1536)
    AZURE_AI_FOUNDRY_ENDPOINT / AZURE_AI_FOUNDRY_API_KEY — reused for embeddings
    DOCS_CHUNK_CHARS         — target chunk size (default 1200)
    DOCS_CHUNK_OVERLAP       — overlap between chunks (default 150)
    DOCS_EMBED_BATCH         — embedding batch size for indexing (default 64)
"""

from __future__ import annotations

import json
import logging
import os
import re
from pathlib import Path

import httpx

LOG = logging.getLogger("nanitics-observatory-uwv.docs_index")

DOCS_DIR = Path(os.environ.get("DOCS_DIR", "/srv/docs-bundle"))

PG_HOST = os.environ.get("DOCS_PG_HOST", "nanitics-docs-postgres.uwv-platform.svc.cluster.local")
PG_PORT = int(os.environ.get("DOCS_PG_PORT", "5432"))
PG_DB = os.environ.get("DOCS_PG_DB", "docrag")
PG_USER = os.environ.get("DOCS_PG_USER", "docrag")
PG_PASSWORD = os.environ.get("DOCS_PG_PASSWORD", "")

EMBEDDING_MODEL = os.environ.get("EMBEDDING_MODEL", "text-embedding-3-small")
EMBEDDING_DIM = int(os.environ.get("EMBEDDING_DIM", "1536"))
# Embeddings reuse the Foundry endpoint (OpenAI-compatible /embeddings).
EMBED_ENDPOINT = os.environ.get("AZURE_AI_FOUNDRY_ENDPOINT", "").rstrip("/")
EMBED_API_KEY = os.environ.get("AZURE_AI_FOUNDRY_API_KEY", "")

CHUNK_CHARS = int(os.environ.get("DOCS_CHUNK_CHARS", "1200"))
CHUNK_OVERLAP = int(os.environ.get("DOCS_CHUNK_OVERLAP", "150"))
EMBED_BATCH = int(os.environ.get("DOCS_EMBED_BATCH", "64"))
HTTP_TIMEOUT = float(os.environ.get("PLATFORM_HTTP_TIMEOUT", "30"))


def pgvector_configured() -> bool:
    """True when the vector backend has everything it needs to run."""
    return bool(PG_PASSWORD and EMBED_ENDPOINT and EMBED_API_KEY)


def _conninfo() -> str:
    return (
        f"host={PG_HOST} port={PG_PORT} dbname={PG_DB} "
        f"user={PG_USER} password={PG_PASSWORD}"
    )


def _embeddings_url() -> str:
    base = EMBED_ENDPOINT if EMBED_ENDPOINT.endswith(("/openai/v1", "/v1")) else f"{EMBED_ENDPOINT}/openai/v1"
    return f"{base}/embeddings"


def _embed_headers() -> dict[str, str]:
    return {"Authorization": f"Bearer {EMBED_API_KEY}", "Content-Type": "application/json"}


def _parse_embeddings(payload: dict) -> list[list[float]]:
    data = sorted(payload.get("data", []), key=lambda d: d.get("index", 0))
    return [d["embedding"] for d in data]


def _vec_literal(embedding: list[float]) -> str:
    # pgvector accepts a text literal "[a,b,c]" cast to ::vector — avoids a
    # hard dependency on the pgvector python adapter.
    return "[" + ",".join(f"{x:.7g}" for x in embedding) + "]"


def _chunk_markdown(text: str) -> list[tuple[str, str]]:
    """Split into ~CHUNK_CHARS windows (with overlap), tracking the nearest
    markdown heading so each chunk carries a little context."""
    chunks: list[tuple[str, str]] = []
    heading = ""
    buf: list[str] = []
    size = 0
    for line in text.splitlines():
        if line.startswith("#"):
            heading = line.lstrip("# ").strip() or heading
        buf.append(line)
        size += len(line) + 1
        if size >= CHUNK_CHARS:
            body = "\n".join(buf).strip()
            if body:
                chunks.append((heading, body))
            # carry an overlap tail into the next window
            tail = body[-CHUNK_OVERLAP:] if CHUNK_OVERLAP else ""
            buf = [tail] if tail else []
            size = len(tail)
    body = "\n".join(buf).strip()
    if body:
        chunks.append((heading, body))
    return chunks


# --- indexing (sync — runs in the one-shot indexer Job) -------------------


def _embed_sync(client: httpx.Client, texts: list[str]) -> list[list[float]]:
    resp = client.post(
        _embeddings_url(),
        headers=_embed_headers(),
        json={"model": EMBEDDING_MODEL, "input": texts},
    )
    resp.raise_for_status()
    return _parse_embeddings(resp.json())


def index_docs() -> int:
    """Full reindex: chunk every markdown doc, embed, replace the table.
    Returns the number of chunks indexed. Used by job-docs-indexer.yaml."""
    import psycopg  # lazy

    if not pgvector_configured():
        raise RuntimeError(
            "doc-rag pgvector not configured: need DOCS_PG_PASSWORD + "
            "AZURE_AI_FOUNDRY_ENDPOINT + AZURE_AI_FOUNDRY_API_KEY."
        )
    if not DOCS_DIR.exists():
        raise RuntimeError(f"docs dir not found: {DOCS_DIR}")

    rows: list[tuple[str, int, str, str]] = []
    for path in sorted(DOCS_DIR.rglob("*.md")):
        try:
            text = path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        rel = os.path.relpath(str(path), str(DOCS_DIR))
        for i, (heading, content) in enumerate(_chunk_markdown(text)):
            rows.append((rel, i, heading, content))

    LOG.info("Embedding %d chunks with %s (dim=%d)", len(rows), EMBEDDING_MODEL, EMBEDDING_DIM)
    embeddings: list[list[float]] = []
    with httpx.Client(timeout=HTTP_TIMEOUT) as client:
        for start in range(0, len(rows), EMBED_BATCH):
            batch = [r[3] for r in rows[start : start + EMBED_BATCH]]
            embeddings.extend(_embed_sync(client, batch))

    with psycopg.connect(_conninfo()) as conn:
        with conn.cursor() as cur:
            cur.execute("CREATE EXTENSION IF NOT EXISTS vector")
            cur.execute(
                f"""CREATE TABLE IF NOT EXISTS doc_chunks (
                    id bigserial PRIMARY KEY,
                    path text NOT NULL,
                    chunk_no int NOT NULL,
                    heading text,
                    content text NOT NULL,
                    embedding vector({EMBEDDING_DIM}),
                    UNIQUE (path, chunk_no)
                )"""
            )
            cur.execute(
                "CREATE INDEX IF NOT EXISTS doc_chunks_embedding_idx "
                "ON doc_chunks USING hnsw (embedding vector_cosine_ops)"
            )
            cur.execute("TRUNCATE doc_chunks")
            for (path, chunk_no, heading, content), emb in zip(rows, embeddings):
                cur.execute(
                    "INSERT INTO doc_chunks (path, chunk_no, heading, content, embedding) "
                    "VALUES (%s, %s, %s, %s, %s::vector)",
                    (path, chunk_no, heading, content, _vec_literal(emb)),
                )
        conn.commit()
    LOG.info("Indexed %d chunks into doc_chunks", len(rows))
    return len(rows)


# --- retrieval (async — runs inside the doc-rag agent's search_docs tool) -


async def _embed_async(query: str) -> list[float]:
    async with httpx.AsyncClient(timeout=HTTP_TIMEOUT) as client:
        resp = await client.post(
            _embeddings_url(),
            headers=_embed_headers(),
            json={"model": EMBEDDING_MODEL, "input": [query]},
        )
        resp.raise_for_status()
        return _parse_embeddings(resp.json())[0]


async def search_chunks(query: str, k: int) -> list[dict]:
    """Embed the query and return the k cosine-nearest doc chunks.
    Raises on any DB/embedding error so the caller can fall back to lexical."""
    import psycopg  # lazy

    embedding = await _embed_async(query)
    lit = _vec_literal(embedding)
    async with await psycopg.AsyncConnection.connect(_conninfo()) as conn:
        async with conn.cursor() as cur:
            await cur.execute(
                "SELECT path, chunk_no, heading, content, "
                "1 - (embedding <=> %s::vector) AS score "
                "FROM doc_chunks ORDER BY embedding <=> %s::vector LIMIT %s",
                (lit, lit, k),
            )
            rows = await cur.fetchall()
    return [
        {
            "path": r[0],
            "chunk_no": r[1],
            "heading": r[2],
            "score": round(float(r[4]), 4),
            "snippet": " ".join((r[3] or "").split())[:400],
        }
        for r in rows
    ]


if __name__ == "__main__":
    logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"))
    n = index_docs()
    print(json.dumps({"indexed_chunks": n, "docs_dir": str(DOCS_DIR), "model": EMBEDDING_MODEL}))
