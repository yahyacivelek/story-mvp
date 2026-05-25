#!/usr/bin/env python3
"""
prewarm_audio.py — Pre-warm audio assets with vector-similarity deduplication.

For every audio prompt found in assets/stories/*.json:
  1. Exact cache hit (sha1 already in manifest.json)  → skip, no API call
  2. Vector similarity ≥ THRESHOLD against Qdrant     → copy existing MP3, skip API
  3. No similar match                                 → call ElevenLabs, save MP3

On each run the script also syncs any manifest entries that are missing from
Qdrant so the index stays consistent after manual edits.

Qdrant runs in local file mode by default (no Docker required).
Vector index is persisted in tools/qdrant_storage/.

Usage:
    uv run tools/prewarm_audio.py
    uv run tools/prewarm_audio.py --threshold 0.88
    uv run tools/prewarm_audio.py --dry-run

    # Optional: use a remote Qdrant server instead of local file mode
    uv run tools/prewarm_audio.py --qdrant-url http://localhost:6333

Requirements:
    - ELEVENLABS_API_KEY set in .env at project root
"""

# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "qdrant-client[fastembed]>=1.9.0",
#   "requests>=2.32.0",
#   "python-dotenv>=1.0.0",
# ]
# ///

import argparse
import hashlib
import json
import os
import shutil
import sys
import uuid
from pathlib import Path
from typing import NamedTuple

import requests
from dotenv import load_dotenv
from qdrant_client import QdrantClient
from qdrant_client.models import Distance, VectorParams, PointStruct

# ---------------------------------------------------------------------------
# Paths & constants
# ---------------------------------------------------------------------------

PROJECT_ROOT = Path(__file__).resolve().parent.parent
AUDIO_DIR    = PROJECT_ROOT / "assets" / "audio"
STORIES_DIR  = PROJECT_ROOT / "assets" / "stories"
MANIFEST     = AUDIO_DIR / "manifest.json"

COLLECTION          = "audio_prompts"
VECTOR_DIM          = 384   # BAAI/bge-small-en-v1.5
MODEL_NAME          = "BAAI/bge-small-en-v1.5"
DEFAULT_THRESHOLD   = 0.85
DEFAULT_QDRANT_PATH = str(Path(__file__).resolve().parent / "qdrant_storage")
ELEVENLABS_URL      = "https://api.elevenlabs.io/v1/sound-generation"

_UUID_NS = uuid.UUID("6ba7b810-9dad-11d1-80b4-00c04fd430c8")


# ---------------------------------------------------------------------------
# Data types
# ---------------------------------------------------------------------------

class AudioPrompt(NamedTuple):
    prompt: str
    type: str            # ambience | music | sfx
    duration_seconds: float


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def sha1_hex(text: str) -> str:
    return hashlib.sha1(text.encode()).hexdigest()


def point_id(sha1: str) -> str:
    """Deterministic UUID from sha1 string, usable as Qdrant point ID."""
    return str(uuid.uuid5(_UUID_NS, sha1))


def infer_type(prompt: str) -> str:
    if "background ambience" in prompt:
        return "ambience"
    if "background music" in prompt:
        return "music"
    return "sfx"


def infer_duration(prompt: str) -> float:
    return {"ambience": 15.0, "music": 22.0, "sfx": 4.0}[infer_type(prompt)]


# ---------------------------------------------------------------------------
# Prompt extraction — mirrors prewarm_audio.dart logic exactly
# ---------------------------------------------------------------------------

def _build_ambience_prompt(
    variant: str,
    primary_sound: str,
    texture: str,
    sec_variant: str | None = None,
    sec_primary_sound: str | None = None,
) -> str:
    base = (
        f"{variant} {primary_sound} background ambience feeling {texture}, "
        "continuous seamless ambient audio loop"
    )
    if sec_variant and sec_primary_sound:
        return (
            f"{sec_variant} {sec_primary_sound} and {variant} {primary_sound} "
            f"background ambience feeling {texture}, continuous seamless ambient audio loop"
        )
    return base


def _build_music_prompt(theme: str) -> str:
    return f"background music theme {theme}, cinematic instrumental loop"


def extract_prompts(story: dict) -> list[AudioPrompt]:
    seen: dict[str, AudioPrompt] = {}

    for scene in story.get("scene_graph", []):
        sa = scene.get("scene_audio", {})

        # --- Ambience ---
        primary = sa.get("primary_ambience", {})
        sp = primary.get("sound_profile", {})
        sec_variant = sec_primary = None
        for layer in sa.get("secondary_layers", [])[:1]:
            sec_sp = layer.get("sound_profile", {})
            sec_variant = sec_sp.get("variant")
            sec_primary = sec_sp.get("primary_sound")

        ambience = _build_ambience_prompt(
            sp.get("variant", ""),
            sp.get("primary_sound", ""),
            sp.get("texture", ""),
            sec_variant,
            sec_primary,
        )
        seen.setdefault(ambience, AudioPrompt(ambience, "ambience", 15.0))

        # --- Music ---
        ml = sa.get("music_layer", {})
        if ml.get("enabled", False):
            music = _build_music_prompt(ml["music_theme"])
            seen.setdefault(music, AudioPrompt(music, "music", 22.0))

        # --- SFX ---
        for ao in scene.get("audio_opportunities", []):
            event = ao.get("event_summary", "").strip()
            if event:
                seen.setdefault(event, AudioPrompt(event, "sfx", 4.0))

    return list(seen.values())


# ---------------------------------------------------------------------------
# ElevenLabs API
# ---------------------------------------------------------------------------

def fetch_elevenlabs(api_key: str, prompt: str, duration_seconds: float) -> bytes:
    duration = max(0.5, min(22.0, duration_seconds))
    resp = requests.post(
        ELEVENLABS_URL,
        headers={
            "xi-api-key": api_key,
            "Content-Type": "application/json",
            "Accept": "audio/mpeg",
        },
        json={"text": prompt, "duration_seconds": duration, "prompt_influence": 0.3},
        timeout=90,
    )
    resp.raise_for_status()
    return resp.content


# ---------------------------------------------------------------------------
# Qdrant helpers
# ---------------------------------------------------------------------------

def ensure_collection(client: QdrantClient) -> None:
    existing = {c.name for c in client.get_collections().collections}
    if COLLECTION not in existing:
        client.create_collection(
            COLLECTION,
            vectors_config=VectorParams(size=VECTOR_DIM, distance=Distance.COSINE),
        )
        print(f"  Created Qdrant collection '{COLLECTION}'")


def sync_manifest(client: QdrantClient, manifest: dict[str, str], embed) -> int:
    """Upsert any manifest entries not yet in Qdrant. Returns count added."""
    existing_ids: set[str] = set()
    offset = None
    while True:
        results, offset = client.scroll(
            COLLECTION, offset=offset, limit=256,
            with_payload=False, with_vectors=False,
        )
        existing_ids.update(str(r.id) for r in results)
        if offset is None:
            break

    missing = [
        (sha1, prompt) for sha1, prompt in manifest.items()
        if point_id(sha1) not in existing_ids
    ]
    if not missing:
        return 0

    print(f"  Syncing {len(missing)} manifest entries into Qdrant…")
    texts = [p for _, p in missing]
    vectors = embed(texts)

    points = [
        PointStruct(
            id=point_id(sha1),
            vector=vec,
            payload={
                "prompt": prompt,
                "sha1": sha1,
                "type": infer_type(prompt),
                "duration_seconds": infer_duration(prompt),
            },
        )
        for (sha1, prompt), vec in zip(missing, vectors)
    ]
    client.upsert(COLLECTION, points=points)
    return len(missing)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Pre-warm audio assets with vector-similarity deduplication."
    )
    parser.add_argument(
        "--threshold", type=float, default=DEFAULT_THRESHOLD,
        help=f"Cosine similarity threshold for reuse (default {DEFAULT_THRESHOLD})",
    )
    parser.add_argument(
        "--qdrant-url", default=None,
        help="Use a remote Qdrant server instead of local file mode (e.g. http://localhost:6333)",
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Show what would happen without writing files or calling ElevenLabs",
    )
    args = parser.parse_args()

    # Load credentials
    load_dotenv(PROJECT_ROOT / ".env")
    api_key = os.getenv("ELEVENLABS_API_KEY", "")
    if not api_key and not args.dry_run:
        sys.exit("ERROR: ELEVENLABS_API_KEY not set in .env")
    if api_key:
        print(f"API key: {api_key[:8]}…")

    # Connect to Qdrant (local file mode by default, remote if --qdrant-url given)
    if args.qdrant_url:
        print(f"Connecting to Qdrant at {args.qdrant_url}…")
        try:
            client = QdrantClient(url=args.qdrant_url)
            client.get_collections()
        except Exception as exc:
            sys.exit(f"ERROR: Cannot reach Qdrant — {exc}")
    else:
        print(f"Using local Qdrant storage at {DEFAULT_QDRANT_PATH}")
        client = QdrantClient(path=DEFAULT_QDRANT_PATH)

    # Load embedding model
    print(f"Loading embedding model ({MODEL_NAME})…")
    from fastembed import TextEmbedding  # noqa: PLC0415 — lazy import after arg parse
    _model = TextEmbedding(model_name=MODEL_NAME)

    def embed(texts: list[str]) -> list[list[float]]:
        return [v.tolist() for v in _model.embed(texts)]

    def embed_one(text: str) -> list[float]:
        return embed([text])[0]

    # Prepare collection and manifest
    ensure_collection(client)
    AUDIO_DIR.mkdir(parents=True, exist_ok=True)
    manifest: dict[str, str] = {}
    if MANIFEST.exists():
        manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    print(f"Manifest: {len(manifest)} existing entries")

    # Sync existing manifest into Qdrant
    synced = sync_manifest(client, manifest, embed)
    if synced:
        print(f"  Synced {synced} new entries into Qdrant")

    # Collect all prompts from every story JSON
    all_prompts: dict[str, AudioPrompt] = {}
    for story_file in sorted(STORIES_DIR.glob("*.json")):
        if story_file.name == "manifest.json":
            continue
        story = json.loads(story_file.read_text(encoding="utf-8"))
        prompts = extract_prompts(story)
        for ap in prompts:
            all_prompts.setdefault(ap.prompt, ap)
        counts = {t: sum(1 for p in prompts if p.type == t) for t in ("ambience", "music", "sfx")}
        print(f"  {story_file.name}: {len(prompts)} prompts "
              f"({counts['ambience']} ambience, {counts['music']} music, {counts['sfx']} sfx)")

    total = len(all_prompts)
    print(f"\nTotal unique prompts across all stories: {total}")
    if args.dry_run:
        print("  (dry-run: no files written, no API calls)")

    # Process each prompt
    generated = reused = skipped = 0

    for i, ap in enumerate(all_prompts.values(), 1):
        sha1 = sha1_hex(ap.prompt)
        prefix = f"[{i:3}/{total}]"
        short = ap.prompt[:65]

        # 1. Exact cache hit
        if sha1 in manifest:
            print(f"{prefix} ✓ cached   {sha1[:8]}… {ap.type}: {short!r}")
            skipped += 1
            continue

        # 2. Vector similarity search
        vector = embed_one(ap.prompt)
        hits = client.query_points(
            collection_name=COLLECTION,
            query=vector,
            limit=1,
            score_threshold=args.threshold,
        ).points

        if hits:
            best = hits[0]
            src_sha1: str = best.payload["sha1"]
            score: float = best.score
            src_file = AUDIO_DIR / f"{src_sha1}.mp3"
            dst_file = AUDIO_DIR / f"{sha1}.mp3"

            print(f"{prefix} ♻ reused   {src_sha1[:8]}→{sha1[:8]}… "
                  f"score={score:.3f} {ap.type}: {short!r}")

            if not args.dry_run:
                if src_file.exists():
                    shutil.copy2(src_file, dst_file)
                    manifest[sha1] = ap.prompt
                    client.upsert(COLLECTION, points=[PointStruct(
                        id=point_id(sha1),
                        vector=vector,
                        payload={"prompt": ap.prompt, "sha1": sha1,
                                 "type": ap.type, "duration_seconds": ap.duration_seconds},
                    )])
                    reused += 1
                    continue
                else:
                    print(f"  WARNING: source {src_file.name} missing — will generate instead")

        # 3. Generate via ElevenLabs
        print(f"{prefix} + generate {sha1[:8]}… {ap.type}: {short!r}")
        if not args.dry_run:
            try:
                data = fetch_elevenlabs(api_key, ap.prompt, ap.duration_seconds)
                (AUDIO_DIR / f"{sha1}.mp3").write_bytes(data)
                manifest[sha1] = ap.prompt
                client.upsert(COLLECTION, points=[PointStruct(
                    id=point_id(sha1),
                    vector=vector,
                    payload={"prompt": ap.prompt, "sha1": sha1,
                             "type": ap.type, "duration_seconds": ap.duration_seconds},
                )])
                print(f"       saved {len(data):,} bytes")
            except Exception as exc:
                print(f"  ERROR: {exc}")
                continue
        generated += 1

    # Write manifest
    if not args.dry_run:
        MANIFEST.write_text(
            json.dumps(manifest, indent=2, ensure_ascii=False),
            encoding="utf-8",
        )
        print(f"\nManifest written: {len(manifest)} entries → {MANIFEST}")

    tag = "(dry-run) " if args.dry_run else ""
    print(f"\n{tag}Done — cached: {skipped}  reused: {reused}  generated: {generated}")


if __name__ == "__main__":
    main()
