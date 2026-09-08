#!/usr/bin/env python3
"""
kb_index.py — Embeddings + búsqueda semántica en el vault de Obsidian (KB).
Uso local, sin nube. Basado en sentence-transformers (all-MiniLM-L6-v2).
"""

import os
import json
import sqlite3
import hashlib
from pathlib import Path
from typing import List, Dict, Optional, Tuple
import numpy as np

try:
    from sentence_transformers import SentenceTransformer
except ImportError:
    raise RuntimeError("Falta sentence-transformers: pip install sentence-transformers")


class KBIndex:
    """
    Índice semántico del vault de Obsidian.
    - Embeddings con all-MiniLM-L6-v2 (384 dims, rápido, local).
    - SQLite con extensiones vec para búsqueda (o fallback numpy).
    - Indexa .md, ignora frontmatter.
    """

    MODEL_NAME = "sentence-transformers/all-MiniLM-L6-v2"
    EMBED_DIM = 384
    CHUNK_SIZE = 512
    CHUNK_OVERLAP = 64

    def __init__(self, vault_path: str, db_path: Optional[str] = None, model_name: str = MODEL_NAME):
        self.vault_path = Path(vault_path).expanduser().resolve()
        if db_path is None:
            self.db_path = self.vault_path / ".kb_index.sqlite"
        else:
            self.db_path = Path(db_path).expanduser().resolve()

        self.model = SentenceTransformer(model_name)
        self._init_db()

    def _init_db(self):
        """Crea esquema: chunks, embeddings (blob), metadatos."""
        with sqlite3.connect(self.db_path) as conn:
            conn.execute("""
                CREATE TABLE IF NOT EXISTS chunks (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    file_path TEXT NOT NULL,
                    chunk_idx INTEGER NOT NULL,
                    content TEXT NOT NULL,
                    file_mtime REAL NOT NULL,
                    chunk_hash TEXT NOT NULL,
                    embedding BLOB NOT NULL,
                    UNIQUE(file_path, chunk_idx)
                )
            """)
            conn.execute("CREATE INDEX IF NOT EXISTS idx_chunks_file ON chunks(file_path)")
            conn.execute("CREATE INDEX IF NOT EXISTS idx_chunks_hash ON chunks(chunk_hash)")
            conn.commit()

    def _file_hash(self, path: Path) -> float:
        return path.stat().st_mtime

    def _chunk_text(self, text: str) -> List[str]:
        """Divide texto en chunks con overlap."""
        words = text.split()
        chunks = []
        for i in range(0, len(words), self.CHUNK_SIZE - self.CHUNK_OVERLAP):
            chunk = " ".join(words[i:i + self.CHUNK_SIZE])
            if chunk.strip():
                chunks.append(chunk)
        return chunks

    def _embedding_to_blob(self, emb: np.ndarray) -> bytes:
        return emb.astype(np.float32).tobytes()

    def _blob_to_embedding(self, blob: bytes) -> np.ndarray:
        return np.frombuffer(blob, dtype=np.float32)

    def _content_hash(self, content: str) -> str:
        return hashlib.sha256(content.encode()).hexdigest()[:32]

    def index_vault(self, paths: Optional[List[str]] = None, force: bool = False) -> int:
        """
        Indexa (o re-indexa) el vault.
        Si paths se da, solo esas carpetas/archivos (relativos al vault).
        Retorna número de chunks indexados/nuevos.
        """
        if paths:
            targets = [self.vault_path / p for p in paths]
        else:
            targets = [self.vault_path]

        md_files = []
        for t in targets:
            if t.is_file() and t.suffix == ".md":
                md_files.append(t)
            elif t.is_dir():
                md_files.extend(t.rglob("*.md"))

        indexed = 0
        for f in md_files:
            try:
                mtime = f.stat().st_mtime
                rel = f.relative_to(self.vault_path)
                with open(f, "r", encoding="utf-8") as fp:
                    content = fp.read()

                # Saltar frontmatter YAML (--- ... ---)
                if content.startswith("---"):
                    parts = content.split("---", 2)
                    if len(parts) >= 3:
                        content = parts[2]

                chunks = self._chunk_text(content)
                for idx, chunk in enumerate(chunks):
                    chunk_hash = self._content_hash(chunk)
                    emb = self.model.encode(chunk, normalize_embeddings=True)

                    with sqlite3.connect(self.db_path) as conn:
                        cur = conn.execute(
                            "SELECT file_mtime, chunk_hash FROM chunks WHERE file_path=? AND chunk_idx=?",
                            (str(rel), idx)
                        )
                        row = cur.fetchone()
                        if row and not force:
                            old_mtime, old_hash = row
                            if old_mtime == f.stat().st_mtime and old_hash == chunk_hash:
                                continue  # sin cambios
                            # actualizar
                            conn.execute(
                                "UPDATE chunks SET content=?, file_mtime=?, chunk_hash=?, embedding=? WHERE file_path=? AND chunk_idx=?",
                                (chunk, mtime, chunk_hash, self._embedding_to_blob(emb), str(rel), idx)
                            )
                        else:
                            conn.execute(
                                "INSERT OR REPLACE INTO chunks (file_path, chunk_idx, content, file_mtime, chunk_hash, embedding) VALUES (?,?,?,?,?,?)",
                                (str(rel), idx, chunk, mtime, chunk_hash, self._embedding_to_blob(emb))
                            )
                        indexed += 1
                        conn.commit()
            except Exception as e:
                print(f"⚠️ Error indexando {f}: {e}")

        return indexed

    def search(self, query: str, top_k: int = 5, min_score: float = 0.3) -> List[Dict]:
        """
        Busca semánticamente en el índice.
        Retorna lista de dicts: {file_path, chunk_idx, content, score, file_mtime}
        """
        q_emb = self.model.encode(query, normalize_embedding=True)
        q_emb = q_emb.astype(np.float32)

        with sqlite3.connect(self.db_path) as conn:
            rows = conn.execute(
                "SELECT file_path, chunk_idx, content, file_mtime, embedding FROM chunks"
            ).fetchall()

        if not rows:
            return []

        # Cosine similarity (embeddings ya normalizados)
        scores = []
        for file_path, chunk_idx, content, mtime, emb_blob in rows:
            emb = self._blob_to_embedding(emb_blob)
            score = float(np.dot(q_emb, emb))
            if score >= min_score:
                scores.append({
                    "file_path": file_path,
                    "chunk_idx": chunk_idx,
                    "content": content[:500],  # truncado
                    "score": score,
                    "file_mtime": mtime
                })

        scores.sort(key=lambda x: x["score"], reverse=True)
        return scores[:top_k]

    def stats(self) -> Dict:
        with sqlite3.connect(self.db_path) as conn:
            cur = conn.execute("SELECT COUNT(*) FROM chunks")
            total = cur.fetchone()[0]
            cur = conn.execute("SELECT COUNT(DISTINCT file_path) FROM chunks")
            files = cur.fetchone()[0]
        return {"total_chunks": total, "files_indexed": files, "db_path": str(self.db_path)}


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="KB Index CLI")
    parser.add_argument("vault", help="Path al vault de Obsidian")
    parser.add_argument("--db", help="Path al SQLite index (opcional)")
    parser.add_argument("--paths", nargs="*", help="Carpetas/archivos específicos a indexar")
    parser.add_argument("--search", help="Query de búsqueda")
    parser.add_argument("--top-k", type=int, default=5)
    parser.add_argument("--min-score", type=float, default=0.3)
    parser.add_argument("--force", action="store_true", help="Re-indexar aunque no cambie mtime")
    parser.add_argument("--stats", action="store_true", help="Mostrar stats")

    args = parser.parse_args()
    kb = KBIndex(args.vault, args.db)

    if args.stats:
        print(json.dumps(kb.stats(), indent=2))
    elif args.search:
        results = kb.search(args.search, args.top_k, args.min_score)
        for r in results:
            print(f"[{r['score']:.3f}] {r['file_path']}:{r['chunk_idx']} — {r['content'][:120]}...")
    else:
        n = kb.index_vault(args.paths, force=args.force)
        print(f"✅ Indexados {n} chunks")
        print(json.dumps(kb.stats(), indent=2))