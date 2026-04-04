#!/usr/bin/env python3
"""
Obsidian Vault Embedding Generator for Vomo RAG Search.

Reads all .md files from an Obsidian vault, chunks by section headers,
generates embeddings via sentence-transformers (local, free) or OpenAI,
and stores in ChromaDB + compact iOS export format.

Output (in {vault}/.embeddings/ by default):
  - chroma_db/     ChromaDB persistent store (for Python-side queries)
  - index.json     Chunk text + metadata (~2-3 MB)
  - vectors.bin    Raw float32 embeddings (~9 MB for 384-dim)
  - manifest.json  Incremental indexing state

Usage:
    # Default: local sentence-transformers, stores in {vault}/.embeddings/
    python scripts/embed_vault.py --vault "/path/to/vault"

    # Custom embeddings path
    python scripts/embed_vault.py --vault "/path/to/vault" \
        --embeddings-path "/fast/local/path"

    # OpenAI provider
    python scripts/embed_vault.py --vault "/path/to/vault" \
        --provider openai --api-key "$OPENAI_API_KEY"
"""

import argparse
import hashlib
import json
import os
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

# Provider configs: model name, dimensions
PROVIDERS = {
    "local": {
        "model": "all-MiniLM-L6-v2",
        "dimensions": 384,
        "description": "Local sentence-transformers (free, no API key)",
    },
    "openai": {
        "model": "text-embedding-3-small",
        "dimensions": 1536,
        "description": "OpenAI API ($0.02/1M tokens)",
    },
}


def parse_args():
    p = argparse.ArgumentParser(description="Generate embeddings for an Obsidian vault")
    p.add_argument("--vault", required=True, help="Path to the Obsidian vault root")
    p.add_argument(
        "--embeddings-path",
        help="Custom path for embedding storage (default: sibling Embeddings/ dir)",
    )
    p.add_argument(
        "--provider",
        choices=list(PROVIDERS.keys()),
        default="local",
        help="Embedding provider (default: local)",
    )
    p.add_argument("--api-key", help="API key for cloud providers (or set OPENAI_API_KEY)")
    p.add_argument("--force", action="store_true", help="Force full re-index, ignoring cache")
    p.add_argument("--batch-size", type=int, default=64, help="Embedding batch size (default: 64)")
    p.add_argument("--chunk-size", type=int, default=400, help="Max words per chunk (default: 400)")
    p.add_argument("--chunk-overlap", type=int, default=60, help="Word overlap between chunks (default: 60)")
    p.add_argument("--dry-run", action="store_true", help="Discover and chunk only, skip embedding")
    return p.parse_args()


# ---------------------------------------------------------------------------
# Vault discovery
# ---------------------------------------------------------------------------

SKIP_DIRS = {".obsidian", ".copilot-index", ".trash", ".git", ".embeddings", "node_modules"}


def discover_md_files(vault_path: Path) -> list[Path]:
    """Find all .md files in vault, skipping hidden/system dirs."""
    files = []
    for p in vault_path.rglob("*.md"):
        if any(part in SKIP_DIRS for part in p.parts):
            continue
        if p.name.startswith(".") and p.name.endswith(".icloud"):
            continue
        files.append(p)
    return sorted(files)


# ---------------------------------------------------------------------------
# Frontmatter extraction
# ---------------------------------------------------------------------------

_FRONTMATTER_RE = re.compile(r"^---\s*\n(.*?)\n---\s*\n", re.DOTALL)


def strip_frontmatter(text: str) -> tuple[dict, str]:
    """Return (frontmatter_dict, body) — basic YAML-like parsing."""
    m = _FRONTMATTER_RE.match(text)
    if not m:
        return {}, text
    raw = m.group(1)
    body = text[m.end() :]
    meta = {}
    for line in raw.split("\n"):
        if ":" in line:
            key, _, val = line.partition(":")
            meta[key.strip()] = val.strip()
    return meta, body


# ---------------------------------------------------------------------------
# Chunking
# ---------------------------------------------------------------------------

_HEADING_RE = re.compile(r"^(#{1,6})\s+(.+)$", re.MULTILINE)


def chunk_by_sections(
    body: str,
    title: str,
    max_words: int = 400,
    overlap_words: int = 60,
) -> list[dict]:
    """Split markdown body into chunks, preferring section boundaries."""
    sections = []
    last_end = 0
    last_heading = title

    for m in _HEADING_RE.finditer(body):
        if m.start() > last_end:
            sections.append((last_heading, body[last_end : m.start()], last_end))
        last_heading = m.group(2).strip()
        last_end = m.end()
    if last_end < len(body):
        sections.append((last_heading, body[last_end:], last_end))

    if not sections:
        sections = [(title, body, 0)]

    chunks = []
    chunk_index = 0

    for section_heading, section_text, char_offset in sections:
        text = section_text.strip()
        if not text:
            continue

        words = text.split()
        if len(words) <= max_words:
            chunks.append(
                {
                    "text": text,
                    "section": section_heading,
                    "chunk_index": chunk_index,
                    "char_offset": char_offset,
                }
            )
            chunk_index += 1
        else:
            for i in range(0, len(words), max_words - overlap_words):
                window = " ".join(words[i : i + max_words])
                if not window.strip():
                    continue
                chunks.append(
                    {
                        "text": window,
                        "section": section_heading,
                        "chunk_index": chunk_index,
                        "char_offset": char_offset,
                    }
                )
                chunk_index += 1

    return chunks


# ---------------------------------------------------------------------------
# Embedding providers
# ---------------------------------------------------------------------------


class LocalEmbedder:
    """sentence-transformers running locally on CPU/MPS."""

    def __init__(self, model_name: str = "all-MiniLM-L6-v2"):
        from sentence_transformers import SentenceTransformer

        self.model = SentenceTransformer(model_name)
        self.dimensions = self.model.get_sentence_embedding_dimension()

    def embed(self, texts: list[str]) -> list[list[float]]:
        embeddings = self.model.encode(texts, show_progress_bar=False, convert_to_numpy=True)
        return embeddings.tolist()


class OpenAIEmbedder:
    """OpenAI text-embedding-3-small via API."""

    def __init__(self, api_key: str, model: str = "text-embedding-3-small"):
        import openai

        self.client = openai.OpenAI(api_key=api_key)
        self.model = model
        self.dimensions = 1536

    def embed(self, texts: list[str]) -> list[list[float]]:
        response = self.client.embeddings.create(model=self.model, input=texts)
        return [d.embedding for d in response.data]


def create_embedder(provider: str, api_key: str | None = None):
    """Factory for embedding providers."""
    if provider == "local":
        return LocalEmbedder()
    elif provider == "openai":
        if not api_key:
            print("Error: OpenAI provider requires --api-key or OPENAI_API_KEY", file=sys.stderr)
            sys.exit(1)
        return OpenAIEmbedder(api_key)
    else:
        print(f"Error: Unknown provider '{provider}'", file=sys.stderr)
        sys.exit(1)


# ---------------------------------------------------------------------------
# Manifest / incremental indexing
# ---------------------------------------------------------------------------

MANIFEST_FILE = "manifest.json"


def load_manifest(embeddings_dir: Path) -> dict:
    path = embeddings_dir / MANIFEST_FILE
    if path.exists():
        return json.loads(path.read_text())
    return {}


def save_manifest(embeddings_dir: Path, manifest: dict):
    path = embeddings_dir / MANIFEST_FILE
    path.write_text(json.dumps(manifest, indent=2))


# ---------------------------------------------------------------------------
# ChromaDB storage
# ---------------------------------------------------------------------------


def store_in_chroma(
    embeddings_dir: Path,
    all_ids: list[str],
    all_embeddings: list[list[float]],
    all_documents: list[str],
    all_metadatas: list[dict],
    stale_prefixes: set[str],
):
    """Store embeddings in ChromaDB, removing stale entries first."""
    import chromadb

    chroma = chromadb.PersistentClient(path=str(embeddings_dir / "chroma_db"))
    collection = chroma.get_or_create_collection(
        "vault_docs",
        metadata={"hnsw:space": "cosine"},
    )

    # Remove stale entries
    if stale_prefixes:
        try:
            existing = collection.get()
            if existing["ids"]:
                to_delete = [
                    eid
                    for eid in existing["ids"]
                    if any(eid.startswith(prefix) for prefix in stale_prefixes)
                ]
                if to_delete:
                    for i in range(0, len(to_delete), 500):
                        collection.delete(ids=to_delete[i : i + 500])
                    print(f"  Removed {len(to_delete)} stale chunks")
        except Exception:
            pass

    # Add new embeddings in batches
    if all_ids:
        batch = 500
        for i in range(0, len(all_ids), batch):
            collection.add(
                ids=all_ids[i : i + batch],
                embeddings=all_embeddings[i : i + batch],
                documents=all_documents[i : i + batch],
                metadatas=all_metadatas[i : i + batch],
            )

    return collection.count()


# ---------------------------------------------------------------------------
# JSON export for iOS
# ---------------------------------------------------------------------------


def export_for_ios(
    embeddings_dir: Path,
    model_name: str,
    dimensions: int,
    all_ids: list[str],
    all_embeddings: list[list[float]],
    all_documents: list[str],
    all_metadatas: list[dict],
):
    """Export embeddings in compact split format for iOS.

    Produces two files:
      - index.json: metadata + chunk text (small, ~2-3 MB)
      - vectors.bin: raw float32 embeddings (compact, ~9 MB for 384-dim)

    iOS loads index.json for metadata, memory-maps vectors.bin for search.
    """
    import struct

    # 1. Write vectors as raw float32 binary
    vectors_path = embeddings_dir / "vectors.bin"
    with open(vectors_path, "wb") as f:
        for emb in all_embeddings:
            vec = emb if isinstance(emb, list) else emb.tolist()
            f.write(struct.pack(f"{len(vec)}f", *vec))
    vec_mb = vectors_path.stat().st_size / (1024 * 1024)

    # 2. Write index with metadata + text (no embedding vectors)
    chunks = []
    for eid, doc, meta in zip(all_ids, all_documents, all_metadatas):
        chunks.append(
            {
                "id": eid,
                "text": doc,
                "source": meta.get("source", ""),
                "title": meta.get("title", ""),
                "section": meta.get("section", ""),
            }
        )

    index = {
        "version": 2,
        "model": model_name,
        "dimensions": dimensions,
        "chunk_count": len(chunks),
        "exported_at": datetime.now(timezone.utc).isoformat(),
        "chunks": chunks,
    }

    index_path = embeddings_dir / "index.json"
    index_path.write_text(json.dumps(index, ensure_ascii=False))
    idx_mb = index_path.stat().st_size / (1024 * 1024)

    print(f"  index.json: {idx_mb:.1f} MB ({len(chunks)} chunks)")
    print(f"  vectors.bin: {vec_mb:.1f} MB ({dimensions}-dim float32)")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main():
    args = parse_args()

    # Resolve vault path
    vault_path = Path(args.vault).expanduser().resolve()
    if not vault_path.is_dir():
        print(f"Error: Vault path does not exist: {vault_path}", file=sys.stderr)
        sys.exit(1)

    provider_info = PROVIDERS[args.provider]
    print(f"Provider:   {args.provider} ({provider_info['description']})")

    # API key — only needed for cloud providers
    api_key = args.api_key or os.environ.get("OPENAI_API_KEY")
    if not api_key:
        env_file = Path(__file__).parent / ".env"
        if env_file.exists():
            for line in env_file.read_text().splitlines():
                if line.startswith("OPENAI_API_KEY="):
                    api_key = line.split("=", 1)[1].strip().strip("\"'")
                    break

    # Resolve embeddings path — default: {vault}/.embeddings/
    if args.embeddings_path:
        embeddings_dir = Path(args.embeddings_path).expanduser().resolve()
    else:
        embeddings_dir = vault_path / ".embeddings"

    embeddings_dir.mkdir(parents=True, exist_ok=True)
    print(f"Vault:      {vault_path}")
    print(f"Embeddings: {embeddings_dir}")

    # Check if provider changed since last index
    manifest = load_manifest(embeddings_dir)
    old_model = manifest.get("model")
    new_model = provider_info["model"]
    if old_model and old_model != new_model and not args.force:
        print(f"Provider changed ({old_model} → {new_model}). Use --force to re-index.")
        sys.exit(1)

    if args.force:
        manifest = {}
        print("Force mode: re-indexing all files")

    # Discover files
    md_files = discover_md_files(vault_path)
    print(f"Found {len(md_files)} markdown files")

    # Determine which files need (re-)indexing
    files_to_index = []
    unchanged = 0
    manifest_files = manifest.get("files", {})
    for f in md_files:
        rel = str(f.relative_to(vault_path))
        if rel in manifest_files and f.stat().st_mtime <= manifest_files[rel]:
            unchanged += 1
            continue
        files_to_index.append(f)

    if not files_to_index:
        print("All files up to date — nothing to index.")
        print(f"Total chunks in store: {manifest.get('chunk_count', '?')}")
        return

    print(f"Indexing {len(files_to_index)} files ({unchanged} unchanged)")

    # Chunk all files
    all_texts = []
    all_ids = []
    all_metadatas = []
    stale_prefixes = set()
    file_mtimes = {}

    for f in files_to_index:
        rel = str(f.relative_to(vault_path))
        try:
            raw = f.read_text(encoding="utf-8", errors="replace")
        except Exception as e:
            print(f"  Skip {rel}: {e}")
            continue

        meta, body = strip_frontmatter(raw)
        title = meta.get("title", f.stem)
        body = body.strip()
        if not body:
            continue

        chunks = chunk_by_sections(body, title, max_words=args.chunk_size, overlap_words=args.chunk_overlap)
        if not chunks:
            continue

        safe_rel = rel.replace("/", "__")
        stale_prefixes.add(safe_rel)

        for chunk in chunks:
            chunk_id = f"{safe_rel}::{chunk['chunk_index']}"
            embed_text = (
                f"{title}\n\n{chunk['text']}"
                if chunk["section"] == title
                else f"{title} — {chunk['section']}\n\n{chunk['text']}"
            )

            all_ids.append(chunk_id)
            all_texts.append(embed_text)
            all_metadatas.append(
                {
                    "source": rel,
                    "title": title,
                    "section": chunk["section"],
                    "chunk_index": chunk["chunk_index"],
                    "char_offset": chunk["char_offset"],
                }
            )

        file_mtimes[rel] = f.stat().st_mtime

    print(f"Generated {len(all_texts)} chunks from {len(files_to_index)} files")

    if args.dry_run:
        avg_words = sum(len(t.split()) for t in all_texts) / max(len(all_texts), 1)
        print(f"\n[DRY RUN] Would embed {len(all_texts)} chunks (avg {avg_words:.0f} words)")
        if args.provider == "openai":
            est_tokens = int(avg_words * 1.3 * len(all_texts))
            print(f"[DRY RUN] Estimated cost: ${est_tokens * 0.02 / 1_000_000:.4f}")
        else:
            print("[DRY RUN] Local provider — no API cost")
        return

    # Create embedder
    print(f"Loading {args.provider} model ({new_model})...")
    embedder = create_embedder(args.provider, api_key)
    dimensions = embedder.dimensions

    # Generate embeddings in batches
    print("Generating embeddings...")
    all_embeddings = []
    batch_size = args.batch_size
    t0 = time.time()

    for i in range(0, len(all_texts), batch_size):
        batch_texts = all_texts[i : i + batch_size]
        batch_embs = embedder.embed(batch_texts)
        all_embeddings.extend(batch_embs)

        done = min(i + batch_size, len(all_texts))
        elapsed = time.time() - t0
        rate = done / elapsed if elapsed > 0 else 0
        print(f"  {done}/{len(all_texts)} chunks ({rate:.0f}/s)")

    elapsed = time.time() - t0
    print(f"Embeddings complete in {elapsed:.1f}s")

    # Store in ChromaDB
    print("Storing in ChromaDB...")
    total_chunks = store_in_chroma(
        embeddings_dir, all_ids, all_embeddings, all_texts, all_metadatas, stale_prefixes
    )
    print(f"  ChromaDB total: {total_chunks} chunks")

    # Export JSON for iOS
    print("Exporting for iOS...")
    import chromadb

    chroma = chromadb.PersistentClient(path=str(embeddings_dir / "chroma_db"))
    collection = chroma.get_collection("vault_docs")
    full_data = collection.get(include=["embeddings", "documents", "metadatas"])
    export_for_ios(
        embeddings_dir,
        new_model,
        dimensions,
        full_data["ids"],
        full_data["embeddings"],
        full_data["documents"],
        full_data["metadatas"],
    )

    # Update manifest
    updated_files = manifest.get("files", {})
    updated_files.update(file_mtimes)
    current_rels = {str(f.relative_to(vault_path)) for f in md_files}
    updated_files = {k: v for k, v in updated_files.items() if k in current_rels}

    save_manifest(
        embeddings_dir,
        {
            "version": 1,
            "model": new_model,
            "dimensions": dimensions,
            "indexed_at": datetime.now(timezone.utc).isoformat(),
            "file_count": len(md_files),
            "chunk_count": total_chunks,
            "vault_path": str(vault_path),
            "embeddings_path": str(embeddings_dir),
            "files": updated_files,
        },
    )

    print(f"\nDone! {len(md_files)} files → {total_chunks} chunks indexed.")


if __name__ == "__main__":
    main()
