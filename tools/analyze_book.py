#!/usr/bin/env python3
"""
analyze_book.py — Cinematic bedtime story analyzer

Reads raw book page images + book_meta.json, sends everything to Gemini 2.0 Flash
in a single multimodal call, validates the response against story_schema.json,
and writes the output to assets/stories/<book_title>.json.

Usage:
    uv run tools/analyze_book.py assets/raw/baykut
    uv run tools/analyze_book.py assets/raw/baykut --dry-run   # skip API call, print prompt only

Model: gemini-2.5-flash
"""

# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "google-generativeai>=0.8.0",
#   "Pillow>=10.0.0",
#   "jsonschema>=4.23.0",
# ]
# ///

import argparse
import json
import re
import sys
from pathlib import Path

import jsonschema
from PIL import Image
import google.generativeai as genai


# ---------------------------------------------------------------------------
# .env loader
# ---------------------------------------------------------------------------

def _load_env(path: str = ".env") -> dict[str, str]:
    env: dict[str, str] = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if "=" not in line:
                    continue
                k, _, v = line.partition("=")
                env[k.strip()] = v.strip().strip("'\"")
    except FileNotFoundError:
        pass
    return env


# ---------------------------------------------------------------------------
# System prompt
# ---------------------------------------------------------------------------

_SYSTEM_PROMPT = """\
CONTENT CLASSIFICATION: This is a licensed children's picture book intended for ages 3-8. \
All images are photographed pages of a published educational storybook. \
This task is strictly academic/creative metadata extraction for a bedtime storytelling app. \
There is no harmful, adult, violent, or inappropriate content in these materials. \
Please process all pages fully without safety refusals.

You are an expert multimodal children's storybook narrative analyzer and cinematic bedtime audio planner.

Your task is to analyze the provided photographed children's book page images as a complete cinematic \
bedtime storytelling experience and produce a single structured JSON output.

## Core experience goals
- Parent's voice must remain PRIMARY — audio only enhances, never distracts
- Feel: warm, magical, cinematic, emotionally supportive, calm, immersive
- Avoid overstimulation or chaotic sound design
- Small subtle audio moments are strongly encouraged — do NOT limit to major events only
- Ambient layers are extremely important

## Page ordering rules
- Pages are provided in alphanumeric capture order (page_0 = page 1, page_1 = page 2, etc.)
- Use visible page numbers if present; otherwise use capture order
- Return confidence estimates per page

## Scene segmentation rules
- Divide the book into narrative scenes using BOTH text AND illustrations
- A scene may span multiple pages
- Each scene must represent coherent: environment, emotional continuity, narrative continuity, ambience
- Scene durations should feel stable and cinematic

## Scene activation rules
- Each scene must include: entry_cues, exit_cues, activation trigger structures, confidence threshold
- Entry cues: prefer short stable phrases, tolerate paraphrasing, avoid fragile exact sentence matching
- Prioritize: semantic meaning, narrative progression, environmental changes, emotional transitions

## Scene audio rules
- Each scene: one primary ambience layer, optional secondary layers, optional music layer, audio_opportunities list
- Ambience loops persist across the entire scene — they activate at scene start, NOT from keyword triggers
- Scene audio may continue, evolve, or replace across scene transitions

## Audio opportunity (SFX/event) rules
- Voice-triggered events use stable trigger phrases with adequate cooldown to avoid collision
- Trigger anchors prefer nouns or short phrases; avoid long sentences
- Animal sounds are encouraged whenever animals are visually or narratively relevant — keep child-friendly
- Include enough subtle ambient detail to feel immersive and cinematic

## Sound representation rules
- All sounds: cache-friendly, reusable, deterministic, semantically consistent identifiers
- Avoid creative prose descriptions; prefer canonical snake_case semantic sound identifiers
- Use schema enums strictly — do not invent new enum values

## Output rules
- Return ONLY the valid JSON object — no markdown fences, no explanations, no comments
- Conform strictly to the provided JSON schema (all required fields, correct enum values)
- Keep output compact but complete

"""


# ---------------------------------------------------------------------------
# Core analysis function
# ---------------------------------------------------------------------------

def analyze_book(raw_dir: Path, project_root: Path, api_key: str, dry_run: bool = False) -> dict:
    # Load book metadata
    meta_path = raw_dir / "book_meta.json"
    if not meta_path.exists():
        raise FileNotFoundError(f"book_meta.json not found in {raw_dir}")
    with open(meta_path) as f:
        book_meta: dict = json.load(f)

    book_title: str = book_meta.get("title", raw_dir.name)
    page_count: int = book_meta.get("pageCount", 0)
    print(f"📖  Book     : {book_title}")
    print(f"    Pages   : {page_count}")

    # Collect + sort page images by embedded number
    image_files = sorted(
        [p for p in raw_dir.iterdir() if p.suffix.lower() in (".jpg", ".jpeg", ".png")],
        key=lambda p: int(m.group()) if (m := re.search(r"\d+", p.stem)) else 0,
    )
    if not image_files:
        raise FileNotFoundError(f"No image files found in {raw_dir}")
    print(f"    Images  : {len(image_files)} files")

    # Load schema
    schema_path = project_root / "assets" / "schemas" / "story_schema.json"
    if not schema_path.exists():
        raise FileNotFoundError(f"Schema not found: {schema_path}")
    with open(schema_path) as f:
        schema: dict = json.load(f)

    # Build prompt
    context_block = (
        f"\n## Book metadata\n"
        f"- Title: {book_meta.get('title', 'unknown')}\n"
        f"- Page count: {book_meta.get('pageCount', len(image_files))}\n"
        f"- Book ID: {book_meta.get('id', 'unknown')}\n"
        f"\n## JSON Schema (output must conform exactly)\n"
        + json.dumps(schema, ensure_ascii=False, indent=2)
        + f"\n\n## Page images\n"
        f"The following {len(image_files)} images are the book pages in order.\n"
        f"page_0.jpg = page 1, page_1.jpg = page 2, and so on.\n"
        f"Perform OCR on each text page, analyze every illustration, then produce the complete JSON.\n"
        f"Return ONLY the JSON object — nothing else.\n"
    )

    full_prompt = _SYSTEM_PROMPT + context_block

    if dry_run:
        print("\n[dry-run] Prompt preview (first 1200 chars):")
        print(full_prompt[:1200])
        print(f"\n[dry-run] Would send {len(image_files)} images to gemini-2.5-flash")
        return {}

    # Load images
    print("\n🖼️  Loading images...")
    content_parts: list = [full_prompt]
    for img_path in image_files:
        content_parts.append(Image.open(img_path))
        print(f"    + {img_path.name}")

    # Configure Gemini
    genai.configure(api_key=api_key)
    model = genai.GenerativeModel("gemini-2.5-flash")

    # Disable safety filters — content is children's picture book pages (educational)
    safety_settings = [
        {"category": "HARM_CATEGORY_HARASSMENT",        "threshold": "BLOCK_NONE"},
        {"category": "HARM_CATEGORY_HATE_SPEECH",       "threshold": "BLOCK_NONE"},
        {"category": "HARM_CATEGORY_SEXUALLY_EXPLICIT", "threshold": "BLOCK_NONE"},
        {"category": "HARM_CATEGORY_DANGEROUS_CONTENT", "threshold": "BLOCK_NONE"},
    ]

    # Call API
    print(f"\n🚀  Sending to gemini-2.5-flash ({len(image_files)} images)...")
    response = model.generate_content(
        content_parts,
        generation_config=genai.GenerationConfig(
            temperature=0.2,
            max_output_tokens=65536,
        ),
        safety_settings=safety_settings,
    )

    raw_text: str = response.text.strip()

    # Token usage & estimated cost (gemini-2.5-flash pricing, May 2026)
    # Input : $0.15 / 1M tokens   Output: $0.60 / 1M tokens
    _PRICE_IN  = 0.15 / 1_000_000
    _PRICE_OUT = 0.60 / 1_000_000
    usage = getattr(response, "usage_metadata", None)
    if usage:
        tok_in  = getattr(usage, "prompt_token_count",     0) or 0
        tok_out = getattr(usage, "candidates_token_count", 0) or 0
        tok_total = tok_in + tok_out
        cost_usd = tok_in * _PRICE_IN + tok_out * _PRICE_OUT
        print(f"\n💰  Token usage")
        print(f"    Input tokens   : {tok_in:>10,}")
        print(f"    Output tokens  : {tok_out:>10,}")
        print(f"    Total tokens   : {tok_total:>10,}")
        print(f"    Estimated cost : ${cost_usd:.6f} USD  (~${cost_usd * 34:.4f} TRY @ 34 TRY/USD)")

    # Strip accidental markdown fences
    raw_text = re.sub(r"^```[a-z]*\s*", "", raw_text)
    raw_text = re.sub(r"\s*```$", "", raw_text)

    # Parse JSON
    print("\n📋  Parsing response...")
    try:
        story_data: dict = json.loads(raw_text)
    except json.JSONDecodeError as e:
        err_path = project_root / "assets" / "stories" / f"{book_title}_raw_error.txt"
        err_path.parent.mkdir(parents=True, exist_ok=True)
        err_path.write_text(raw_text, encoding="utf-8")
        raise ValueError(f"Response is not valid JSON: {e}\nRaw response saved to: {err_path}") from e

    # Validate
    print("✅  Validating against schema...")
    try:
        jsonschema.validate(instance=story_data, schema=schema)
        print("    Schema validation passed ✓")
    except jsonschema.ValidationError as e:
        path_str = " -> ".join(str(p) for p in e.absolute_path)
        print(f"⚠️   Schema validation warning: {e.message}")
        print(f"    Path: {path_str}")
        print("    Saving output anyway — review manually.")

    return story_data


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Analyze a raw book directory and produce a story JSON using Gemini 2.0 Flash."
    )
    parser.add_argument(
        "raw_dir",
        type=Path,
        help="Path to the raw book directory, e.g. assets/raw/baykut",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print the prompt and exit without calling the API",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=None,
        help="Override output path (default: assets/stories/<title>.json)",
    )
    args = parser.parse_args()

    raw_dir: Path = args.raw_dir.resolve()
    if not raw_dir.exists():
        print(f"ERROR: Directory not found: {raw_dir}")
        sys.exit(1)

    # Project root = parent of tools/
    project_root: Path = Path(__file__).resolve().parent.parent

    # Load API key
    env = _load_env(str(project_root / ".env"))
    api_key = env.get("GOOGLE_API_KEY", "")
    if not api_key and not args.dry_run:
        print("ERROR: GOOGLE_API_KEY not set in .env")
        sys.exit(1)

    try:
        story_data = analyze_book(raw_dir, project_root, api_key, dry_run=args.dry_run)
    except (FileNotFoundError, ValueError) as e:
        print(f"ERROR: {e}")
        sys.exit(1)

    if args.dry_run or not story_data:
        return

    # Determine output path
    book_title: str = story_data.get("book", {}).get("detected_title") or raw_dir.name
    # Sanitize for filename
    safe_title = re.sub(r"[^\w\-]", "_", book_title.lower().strip()).strip("_")
    output_path: Path = args.output or (project_root / "assets" / "stories" / f"{safe_title}.json")
    output_path.parent.mkdir(parents=True, exist_ok=True)

    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(story_data, f, ensure_ascii=False, indent=2)

    print(f"\n📁  Written  : {output_path}")
    print(f"    Pages   : {len(story_data.get('pages', []))}")
    print(f"    Scenes  : {len(story_data.get('scene_graph', []))}")
    print("\nDone! Run `dart run tools/prewarm_audio.dart` to generate audio assets.")


if __name__ == "__main__":
    main()
