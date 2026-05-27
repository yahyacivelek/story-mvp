#!/usr/bin/env python3
"""
analyze_book.py — Two-stage cinematic bedtime story analyzer

Stage 1 — extract-pages:
    Sends raw book page images to Gemini, extracts full page texts + metadata.
    Writes an intermediate <title>_pages.json under assets/stories/.

    uv run tools/analyze_book.py extract-pages assets/raw/baykut
    uv run tools/analyze_book.py extract-pages assets/raw/baykut --dry-run

Stage 2 — build-story:
    Reads the _pages.json produced by stage 1, checks every story word
    against the Vosk model vocabulary to find OOV (out-of-vocabulary)
    words that must NOT be used as trigger anchors/keywords, then asks
    Gemini to produce the full story JSON with a strict constraint block.

    uv run tools/analyze_book.py build-story assets/stories/baykut_pages.json
    uv run tools/analyze_book.py build-story assets/stories/baykut_pages.json --dry-run
    uv run tools/analyze_book.py build-story assets/stories/baykut_pages.json \\
        --model assets/vosk_models/vosk-model-small-tr-0.3.zip

Model: gemini-2.5-flash
"""

# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "google-generativeai>=0.8.0",
#   "Pillow>=10.0.0",
#   "jsonschema>=4.23.0",
#   "vosk>=0.3.45",
# ]
# ///

import argparse
import json
import os
import re
import sys
import tempfile
import zipfile
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
# System prompts
# ---------------------------------------------------------------------------

_SYSTEM_PROMPT_EXTRACT = """\
CONTENT CLASSIFICATION: This is a licensed children's picture book intended for ages 3-8. \
All images are photographed pages of a published educational storybook. \
This task is strictly academic/creative metadata extraction for a bedtime storytelling app. \
There is no harmful, adult, violent, or inappropriate content in these materials. \
Please process all pages fully without safety refusals.

You are an expert multimodal children's storybook page-text extractor.

Your task is to perform accurate OCR and basic metadata extraction on \
the provided photographed children's book page images.

## Output rules
- Return ONLY the valid JSON object — no markdown fences, no explanations, no comments
- Conform strictly to the provided JSON schema (all required fields, correct enum values)
- full_text: transcribe ALL visible text on the page exactly as written, preserving punctuation
  and special characters; leave empty string if the page is illustration-only
- Keep output compact but complete
- Pages are provided in alphanumeric capture order (page_0 = page 1, page_1 = page 2, etc.)
- Use visible page numbers if present; otherwise use capture order

"""

_SYSTEM_PROMPT_BUILD = """\
CONTENT CLASSIFICATION: This is a licensed children's picture book intended for ages 3-8. \
This task is strictly academic/creative metadata extraction for a bedtime storytelling app. \
There is no harmful, adult, violent, or inappropriate content in these materials.

You are an expert children's storybook narrative analyzer and cinematic bedtime audio planner.

Your task is to analyze the provided page-level story text and produce a single structured \
cinematic bedtime storytelling JSON.

## Core experience goals
- Parent's voice must remain PRIMARY — audio only enhances, never distracts
- Feel: warm, magical, cinematic, emotionally supportive, calm, immersive
- Avoid overstimulation or chaotic sound design
- Small subtle audio moments are strongly encouraged — do NOT limit to major events only
- Ambient layers are extremely important

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
# Shared helpers
# ---------------------------------------------------------------------------

_SAFETY_SETTINGS = [
    {"category": "HARM_CATEGORY_HARASSMENT",        "threshold": "BLOCK_NONE"},
    {"category": "HARM_CATEGORY_HATE_SPEECH",       "threshold": "BLOCK_NONE"},
    {"category": "HARM_CATEGORY_SEXUALLY_EXPLICIT", "threshold": "BLOCK_NONE"},
    {"category": "HARM_CATEGORY_DANGEROUS_CONTENT", "threshold": "BLOCK_NONE"},
]


def _call_gemini(api_key: str, content_parts: list, max_tokens: int = 65536) -> tuple[str, object]:
    genai.configure(api_key=api_key)
    model = genai.GenerativeModel("gemini-2.5-flash")
    response = model.generate_content(
        content_parts,
        generation_config=genai.GenerationConfig(
            temperature=0.2,
            max_output_tokens=max_tokens,
        ),
        safety_settings=_SAFETY_SETTINGS,
    )
    return response.text.strip(), response


def _print_token_usage(response: object) -> None:
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


def _parse_json_response(raw_text: str, save_error_path: Path) -> dict:
    raw_text = re.sub(r"^```[a-z]*\s*", "", raw_text)
    raw_text = re.sub(r"\s*```$", "", raw_text)
    try:
        return json.loads(raw_text)
    except json.JSONDecodeError as e:
        save_error_path.parent.mkdir(parents=True, exist_ok=True)
        save_error_path.write_text(raw_text, encoding="utf-8")
        raise ValueError(f"Response is not valid JSON: {e}\nRaw response saved to: {save_error_path}") from e


_WORD_RE = re.compile(r"[\w\u00C0-\u024F']+", re.UNICODE)


def _extract_words(text: str) -> set[str]:
    return {m.group(0).lower() for m in _WORD_RE.finditer(text) if m.group(0)}


# ---------------------------------------------------------------------------
# Stage 1: extract-pages  (images → page texts)
# ---------------------------------------------------------------------------

_PAGES_SCHEMA = {
    "$schema": "http://json-schema.org/draft-07/schema#",
    "type": "object",
    "required": ["book", "page_ordering", "pages"],
    "properties": {
        "book": {
            "type": "object",
            "required": ["language", "analysis_confidence"],
            "properties": {
                "detected_title": {"type": ["string", "null"]},
                "language": {"type": "string"},
                "analysis_confidence": {"type": "number"}
            }
        },
        "page_ordering": {
            "type": "object",
            "required": ["ordering_method", "confidence"],
            "properties": {
                "ordering_method": {"type": "string"},
                "confidence": {"type": "number"}
            }
        },
        "pages": {
            "type": "array",
            "minItems": 1,
            "items": {
                "type": "object",
                "required": ["page_id", "page_number", "order_index", "order_confidence",
                              "full_text", "primary_scene_hint", "dominant_visual", "mood"],
                "properties": {
                    "page_id": {"type": "string"},
                    "page_number": {"type": "integer"},
                    "order_index": {"type": "integer"},
                    "order_confidence": {"type": "number"},
                    "full_text": {"type": "string"},
                    "primary_scene_hint": {"type": "string"},
                    "dominant_visual": {"type": "string"},
                    "mood": {"type": "string"}
                }
            }
        }
    }
}


def extract_pages(raw_dir: Path, project_root: Path, api_key: str, dry_run: bool = False) -> dict:
    meta_path = raw_dir / "book_meta.json"
    if not meta_path.exists():
        raise FileNotFoundError(f"book_meta.json not found in {raw_dir}")
    with open(meta_path) as f:
        book_meta: dict = json.load(f)

    book_title: str = book_meta.get("title", raw_dir.name)
    page_count: int = book_meta.get("pageCount", 0)
    print(f"📖  Book     : {book_title}")
    print(f"    Pages   : {page_count}")

    image_files = sorted(
        [p for p in raw_dir.iterdir() if p.suffix.lower() in (".jpg", ".jpeg", ".png")],
        key=lambda p: int(m.group()) if (m := re.search(r"\d+", p.stem)) else 0,
    )
    if not image_files:
        raise FileNotFoundError(f"No image files found in {raw_dir}")
    print(f"    Images  : {len(image_files)} files")

    context_block = (
        f"\n## Book metadata\n"
        f"- Title: {book_meta.get('title', 'unknown')}\n"
        f"- Page count: {book_meta.get('pageCount', len(image_files))}\n"
        f"- Book ID: {book_meta.get('id', 'unknown')}\n"
        f"- Language: {book_meta.get('language', 'auto-detect')}\n"
        f"\n## JSON Schema (output must conform exactly)\n"
        + json.dumps(_PAGES_SCHEMA, ensure_ascii=False, indent=2)
        + f"\n\n## Instructions\n"
        f"The following {len(image_files)} images are the book pages in order.\n"
        f"page_0.jpg = page 1, page_1.jpg = page 2, and so on.\n"
        f"Perform accurate OCR on every text page.\n"
        f"Return ONLY the JSON object — nothing else.\n"
    )

    full_prompt = _SYSTEM_PROMPT_EXTRACT + context_block

    if dry_run:
        print("\n[dry-run] Prompt preview (first 1200 chars):")
        print(full_prompt[:1200])
        print(f"\n[dry-run] Would send {len(image_files)} images to gemini-2.5-flash")
        return {}

    print("\n🖼️  Loading images...")
    content_parts: list = [full_prompt]
    for img_path in image_files:
        content_parts.append(Image.open(img_path))
        print(f"    + {img_path.name}")

    print(f"\n🚀  Sending to gemini-2.5-flash ({len(image_files)} images) [stage 1: extract-pages]...")
    raw_text, response = _call_gemini(api_key, content_parts, max_tokens=16384)
    _print_token_usage(response)

    print("\n📋  Parsing response...")
    err_path = project_root / "assets" / "stories" / f"{raw_dir.name}_pages_raw_error.txt"
    pages_data = _parse_json_response(raw_text, err_path)

    print("✅  Validating pages schema...")
    try:
        jsonschema.validate(instance=pages_data, schema=_PAGES_SCHEMA)
        print("    Schema validation passed ✓")
    except jsonschema.ValidationError as e:
        print(f"⚠️   Schema validation warning: {e.message}")
        print("    Saving output anyway — review manually.")

    return pages_data


# ---------------------------------------------------------------------------
# Stage 2 helper: Vosk vocabulary checker
# ---------------------------------------------------------------------------

_LANG_NAME_TO_CODE: dict[str, str] = {
    "turkish": "tr", "english": "en", "german": "de", "french": "fr",
    "spanish": "es", "russian": "ru", "türkçe": "tr", "ingilizce": "en",
}


def _normalize_lang(language: str) -> str:
    code = language.strip().lower()
    return _LANG_NAME_TO_CODE.get(code, code[:2])


def _find_vosk_model_zip(language: str, project_root: Path, model_zip_override: Path | None) -> Path | None:
    if model_zip_override:
        return model_zip_override
    import glob
    lang_code = _normalize_lang(language)
    candidates = [
        project_root / "assets" / "vosk_models" / f"vosk-model-small-{lang_code}-*.zip",
    ]
    for pattern in candidates:
        matches = glob.glob(str(pattern))
        if matches:
            return Path(sorted(matches)[-1])
    return None


def check_vosk_oov(words: set[str], model_zip: Path) -> set[str]:
    """
    Returns the subset of *words* that the Vosk model does NOT know.

    Works by creating a KaldiRecognizer with a grammar that includes all
    candidate words and parsing Vosk's own "Ignoring word missing in
    vocabulary" warnings from stderr.
    """
    try:
        from vosk import Model as VoskModel, KaldiRecognizer
    except ImportError:
        print("⚠️   vosk Python package not found — skipping OOV check.")
        print("    Install with: pip install vosk")
        return set()

    with tempfile.TemporaryDirectory() as tmpdir:
        print(f"\n🔍  Extracting Vosk model: {model_zip.name}")
        with zipfile.ZipFile(model_zip) as z:
            z.extractall(tmpdir)

        model_dirs = [d for d in Path(tmpdir).iterdir() if d.is_dir()]
        if not model_dirs:
            print("⚠️   Could not find model directory inside zip — skipping OOV check.")
            return set()
        model_path = str(model_dirs[0])

        print(f"    Model path : {model_path}")
        print(f"    Testing    : {len(words)} unique words from story text")

        vmodel = VoskModel(model_path)

        word_list = sorted(words) + ["[unk]"]
        grammar_json = json.dumps(word_list)

        log_file = os.path.join(tmpdir, "vosk_vocab_check.log")
        log_fd = os.open(log_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        old_stderr_fd = os.dup(2)
        os.dup2(log_fd, 2)
        os.close(log_fd)
        try:
            KaldiRecognizer(vmodel, 16000, grammar_json)
        finally:
            os.dup2(old_stderr_fd, 2)
            os.close(old_stderr_fd)

        with open(log_file) as f:
            log = f.read()

    oov: set[str] = set()
    oov_pattern = re.compile(
        r"Ignoring word missing in vocabulary: '(.+?)'"
    )
    for line in log.splitlines():
        m = oov_pattern.search(line)
        if m:
            raw_word = m.group(1)
            decoded = re.sub(
                r"\\\\u([0-9a-fA-F]{4})",
                lambda mo: chr(int(mo.group(1), 16)),
                raw_word,
            )
            oov.add(decoded.lower())

    return oov


# ---------------------------------------------------------------------------
# Stage 2: build-story  (page texts + OOV check → full story JSON)
# ---------------------------------------------------------------------------

def build_story(
    pages_path: Path,
    project_root: Path,
    api_key: str,
    model_zip: Path | None = None,
    dry_run: bool = False,
) -> dict:
    if not pages_path.exists():
        raise FileNotFoundError(f"Pages file not found: {pages_path}")
    with open(pages_path, encoding="utf-8") as f:
        pages_data: dict = json.load(f)

    language: str = pages_data.get("book", {}).get("language", "tr")
    book_title: str = pages_data.get("book", {}).get("detected_title") or pages_path.stem.replace("_pages", "")
    print(f"📖  Book     : {book_title}")
    print(f"    Language : {language}")
    print(f"    Pages    : {len(pages_data.get('pages', []))}")

    # Collect all story words for OOV check
    all_text = " ".join(
        p.get("full_text", "") for p in pages_data.get("pages", [])
    )
    story_words = _extract_words(all_text)
    print(f"    Unique words in story text: {len(story_words)}")

    # OOV check
    oov_words: set[str] = set()
    found_zip = _find_vosk_model_zip(language, project_root, model_zip)
    if found_zip:
        oov_words = check_vosk_oov(story_words, found_zip)
        in_vocab = story_words - oov_words
        print(f"\n📊  Vosk vocabulary check")
        print(f"    Model zip       : {found_zip.name}")
        print(f"    Story words     : {len(story_words)}")
        print(f"    In-vocabulary   : {len(in_vocab)}")
        print(f"    Out-of-vocabulary (OOV): {len(oov_words)}")
        if oov_words:
            print(f"    OOV words       : {sorted(oov_words)}")
    else:
        print(f"\n⚠️   No Vosk model zip found for language '{language}' — OOV check skipped.")
        print(f"    Pass --model <path/to/vosk-model.zip> to enable.")

    # Load story schema
    schema_path = project_root / "assets" / "schemas" / "story_schema.json"
    if not schema_path.exists():
        raise FileNotFoundError(f"Schema not found: {schema_path}")
    with open(schema_path) as f:
        schema: dict = json.load(f)

    # Build OOV constraint block for the prompt
    oov_block = ""
    if oov_words:
        oov_list = ", ".join(f'"{w}"' for w in sorted(oov_words))
        oov_block = (
            f"\n## CRITICAL CONSTRAINT — Vosk speech recognition vocabulary\n"
            f"The following words appear in the story text but are MISSING from the "
            f"Vosk speech recognition model's vocabulary for language '{language}'.\n"
            f"These words WILL NOT be recognised by the speech recogniser — if used as "
            f"trigger keywords or trigger anchors they will NEVER fire.\n"
            f"\n"
            f"**You MUST NOT use any of these words in:**\n"
            f"- entry_cues.primary_keywords\n"
            f"- entry_cues.secondary_keywords\n"
            f"- exit_cues.keywords\n"
            f"- trigger_structure.primary_keywords\n"
            f"- trigger_structure.secondary_keywords\n"
            f"- trigger_anchor.value\n"
            f"\n"
            f"OOV words (absolutely forbidden as triggers): {oov_list}\n"
            f"\n"
            f"Instead, always choose synonyms or simpler words from the story that "
            f"ARE recognised by the model (i.e. not in the list above).\n"
        )

    context_block = (
        f"\n## Book metadata\n"
        f"- Title: {book_title}\n"
        f"- Language: {language}\n"
        f"\n## Page data (OCR output from stage 1)\n"
        + json.dumps(pages_data, ensure_ascii=False, indent=2)
        + oov_block
        + f"\n\n## JSON Schema (output must conform exactly)\n"
        + json.dumps(schema, ensure_ascii=False, indent=2)
        + f"\n\nReturn ONLY the JSON object — nothing else.\n"
    )

    full_prompt = _SYSTEM_PROMPT_BUILD + context_block

    if dry_run:
        print("\n[dry-run] Prompt preview (first 2000 chars):")
        print(full_prompt[:2000])
        if oov_words:
            print(f"\n[dry-run] OOV constraint block included ({len(oov_words)} words).")
        print(f"\n[dry-run] Would send text-only prompt to gemini-2.5-flash")
        return {}

    print(f"\n🚀  Sending to gemini-2.5-flash [stage 2: build-story]...")
    raw_text, response = _call_gemini(api_key, [full_prompt], max_tokens=65536)
    _print_token_usage(response)

    print("\n📋  Parsing response...")
    safe_title = re.sub(r"[^\w\-]", "_", book_title.lower().strip()).strip("_")
    err_path = project_root / "assets" / "stories" / f"{safe_title}_raw_error.txt"
    story_data = _parse_json_response(raw_text, err_path)

    print("✅  Validating against story schema...")
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

def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Two-stage cinematic bedtime story analyzer.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Examples:\n"
            "  uv run tools/analyze_book.py extract-pages assets/raw/baykut\n"
            "  uv run tools/analyze_book.py build-story assets/stories/baykut_pages.json\n"
            "  uv run tools/analyze_book.py build-story assets/stories/baykut_pages.json \\\n"
            "      --model assets/vosk_models/vosk-model-small-tr-0.3.zip\n"
        ),
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    # --- extract-pages ---
    ep = subparsers.add_parser(
        "extract-pages",
        help="Stage 1: send page images to Gemini and extract page texts.",
    )
    ep.add_argument(
        "raw_dir",
        type=Path,
        help="Path to raw book directory, e.g. assets/raw/baykut",
    )
    ep.add_argument("--dry-run", action="store_true", help="Print prompt and exit without calling API")
    ep.add_argument(
        "--output",
        type=Path,
        default=None,
        help="Override output path (default: assets/stories/<title>_pages.json)",
    )

    # --- build-story ---
    bs = subparsers.add_parser(
        "build-story",
        help="Stage 2: build full story JSON from page texts, with Vosk OOV constraints.",
    )
    bs.add_argument(
        "pages_file",
        type=Path,
        help="Path to _pages.json produced by extract-pages",
    )
    bs.add_argument("--dry-run", action="store_true", help="Print prompt and exit without calling API")
    bs.add_argument(
        "--model",
        type=Path,
        default=None,
        dest="model_zip",
        help="Override Vosk model zip path (auto-detected from assets/vosk_models/ by default)",
    )
    bs.add_argument(
        "--output",
        type=Path,
        default=None,
        help="Override output path (default: assets/stories/<title>.json)",
    )

    return parser


def main() -> None:
    parser = _build_parser()
    args = parser.parse_args()

    project_root: Path = Path(__file__).resolve().parent.parent

    env = _load_env(str(project_root / ".env"))
    api_key = env.get("GOOGLE_API_KEY", "")
    if not api_key and not args.dry_run:
        print("ERROR: GOOGLE_API_KEY not set in .env")
        sys.exit(1)

    if args.command == "extract-pages":
        raw_dir: Path = args.raw_dir.resolve()
        if not raw_dir.exists():
            print(f"ERROR: Directory not found: {raw_dir}")
            sys.exit(1)

        try:
            pages_data = extract_pages(raw_dir, project_root, api_key, dry_run=args.dry_run)
        except (FileNotFoundError, ValueError) as e:
            print(f"ERROR: {e}")
            sys.exit(1)

        if args.dry_run or not pages_data:
            return

        book_title: str = pages_data.get("book", {}).get("detected_title") or raw_dir.name
        safe_title = re.sub(r"[^\w\-]", "_", book_title.lower().strip()).strip("_")
        output_path: Path = args.output or (project_root / "assets" / "stories" / f"{safe_title}_pages.json")
        output_path.parent.mkdir(parents=True, exist_ok=True)
        with open(output_path, "w", encoding="utf-8") as f:
            json.dump(pages_data, f, ensure_ascii=False, indent=2)
        print(f"\n📁  Written  : {output_path}")
        print(f"    Pages   : {len(pages_data.get('pages', []))}")
        print("\nNext step: uv run tools/analyze_book.py build-story " + str(output_path))

    elif args.command == "build-story":
        pages_path: Path = args.pages_file.resolve()
        if not pages_path.exists():
            print(f"ERROR: Pages file not found: {pages_path}")
            sys.exit(1)

        try:
            story_data = build_story(
                pages_path,
                project_root,
                api_key,
                model_zip=args.model_zip,
                dry_run=args.dry_run,
            )
        except (FileNotFoundError, ValueError) as e:
            print(f"ERROR: {e}")
            sys.exit(1)

        if args.dry_run or not story_data:
            return

        book_title = story_data.get("book", {}).get("detected_title") or pages_path.stem.replace("_pages", "")
        safe_title = re.sub(r"[^\w\-]", "_", book_title.lower().strip()).strip("_")
        output_path = args.output or (project_root / "assets" / "stories" / f"{safe_title}.json")
        output_path.parent.mkdir(parents=True, exist_ok=True)
        with open(output_path, "w", encoding="utf-8") as f:
            json.dump(story_data, f, ensure_ascii=False, indent=2)
        print(f"\n📁  Written  : {output_path}")
        print(f"    Pages   : {len(story_data.get('pages', []))}")
        print(f"    Scenes  : {len(story_data.get('scene_graph', []))}")
        print("\nDone! Run `dart run tools/prewarm_audio.dart` to generate audio assets.")


if __name__ == "__main__":
    main()
