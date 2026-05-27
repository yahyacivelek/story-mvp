#!/usr/bin/env python3
"""
Check a story JSON's trigger keywords against a Vosk model's lexicon.

Vosk's grammar-constrained recognizer (``vosk_recognizer_new_grm``) silently
drops words whose pronunciation isn't in the acoustic model's lexicon. The
result: an STT trigger like ``"kalede yaşardı"`` can never fire if the model
doesn't know ``yaşardı``, no matter how clearly the user says it. The Vosk
``small-tr-0.3`` lexicon in particular omits many common inflected forms.

This script extracts every trigger keyword from the given story (or every
story under a directory), tokenises them, then asks Vosk which tokens are
out-of-vocabulary (OOV) for the given model. The report tells you exactly
which trigger keywords will fail and which words to rewrite.

Usage:

    python3 tools/check_story_vocab.py \
        --model assets/vosk_models/vosk-model-small-tr-0.3.zip \
        --story assets/stories/

Exit codes:
    0 — every trigger token is in the lexicon
    1 — one or more triggers contain OOV tokens
    2 — usage / IO error

The model argument accepts either an extracted model directory or a ``.zip``
that this script will extract to a temp folder on demand.
"""

from __future__ import annotations

import argparse
import contextlib
import io
import json
import os
import re
import shutil
import sys
import tempfile
import zipfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable

try:
    from vosk import KaldiRecognizer, Model, SetLogLevel
except ImportError:  # pragma: no cover
    sys.stderr.write(
        "vosk python package not installed.\n"
        "  python3 -m venv .venv && .venv/bin/pip install vosk\n"
    )
    sys.exit(2)


WORD_RE = re.compile(r"[\w\u00C0-\u024F']+", re.UNICODE)


@dataclass
class TriggerSource:
    """One textual location in the story that contributes vocabulary."""

    story: str
    scene_id: str
    role: str  # entry_cue / exit_cue / ao_primary / ao_secondary / ao_anchor
    text: str
    tokens: list[str] = field(default_factory=list)


def tokenize(phrase: str) -> list[str]:
    return [m.group(0) for m in WORD_RE.finditer(phrase.lower()) if m.group(0)]


def _g(obj: dict, *keys, default=None):
    """Return obj[k] for the first ``k`` in [keys] that exists. Helps tolerate
    both snake_case (raw JSON) and camelCase (Dart-serialised) spellings."""
    for k in keys:
        if k in obj:
            return obj[k]
    return default


def collect_triggers(story_path: Path) -> tuple[str, list[TriggerSource]]:
    data = json.loads(story_path.read_text(encoding="utf-8"))
    book = _g(data, "book", default={}) or {}
    story_title = (
        _g(book, "detectedTitle", "detected_title", "title")
        or story_path.stem
    )

    sources: list[TriggerSource] = []
    for scene in _g(data, "sceneGraph", "scene_graph", default=[]) or []:
        sid = _g(scene, "sceneId", "scene_id", default="?")
        activation = _g(scene, "sceneActivation", "scene_activation", default={}) or {}
        for cue_key, role in (
            (("entryCues", "entry_cues"), "entry_cue"),
            (("exitCues", "exit_cues"), "exit_cue"),
        ):
            for cue in _g(activation, *cue_key, default=[]) or []:
                for kw in _g(cue, "primaryKeywords", "primary_keywords", default=[]) or []:
                    sources.append(_make_src(story_title, sid, role + "_primary", kw))
                for kw in _g(cue, "secondaryKeywords", "secondary_keywords", default=[]) or []:
                    sources.append(
                        _make_src(story_title, sid, role + "_secondary", kw)
                    )
        for ao in _g(scene, "audioOpportunities", "audio_opportunities", default=[]) or []:
            for kw in _g(
                ao, "triggerPrimaryKeywords", "trigger_primary_keywords", default=[]
            ) or []:
                sources.append(_make_src(story_title, sid, "ao_primary", kw))
            for kw in _g(
                ao, "triggerSecondaryKeywords", "trigger_secondary_keywords", default=[]
            ) or []:
                sources.append(_make_src(story_title, sid, "ao_secondary", kw))
            anchor_obj = _g(ao, "triggerAnchor", "trigger_anchor", default={}) or {}
            anchor = _g(anchor_obj, "value")
            if anchor:
                sources.append(_make_src(story_title, sid, "ao_anchor", anchor))

    return story_title, sources


def _make_src(story: str, scene_id: str, role: str, text: str) -> TriggerSource:
    return TriggerSource(
        story=story,
        scene_id=scene_id,
        role=role,
        text=text,
        tokens=tokenize(text),
    )


def find_oov_tokens(model: Model, tokens: Iterable[str]) -> set[str]:
    """Return the subset of [tokens] that the model's lexicon doesn't know."""
    unique = sorted({t for t in tokens if t and t != "[unk]"})
    if not unique:
        return set()
    grammar = json.dumps(unique + ["[unk]"], ensure_ascii=False)

    # Vosk emits "Ignoring word missing in vocabulary: 'X'" to stderr at
    # WARNING level (vlog 0). We hijack stderr (and bump the verbosity) for
    # the duration of the grammar build to capture the diagnostic.
    SetLogLevel(0)
    buf = io.BytesIO()
    saved_fd = os.dup(2)
    try:
        r_fd, w_fd = os.pipe()
        os.dup2(w_fd, 2)
        try:
            KaldiRecognizer(model, 16000, grammar)
        finally:
            os.dup2(saved_fd, 2)
            os.close(w_fd)
        with os.fdopen(r_fd, "rb") as r:
            buf.write(r.read())
    finally:
        os.close(saved_fd)

    text = buf.getvalue().decode("utf-8", errors="replace")
    oov: set[str] = set()
    for m in re.finditer(r"Ignoring word missing in vocabulary: '([^']+)'", text):
        oov.add(m.group(1))
    return oov


def extract_model_if_zip(model_arg: Path) -> tuple[Path, Path | None]:
    """Return (model_dir, tmp_dir_to_clean). tmp_dir is None for directories."""
    if model_arg.is_dir():
        return model_arg, None
    if model_arg.suffix != ".zip":
        raise SystemExit(f"--model must be a directory or .zip, got {model_arg}")
    tmp = Path(tempfile.mkdtemp(prefix="voskmodel_"))
    with zipfile.ZipFile(model_arg) as zf:
        zf.extractall(tmp)
    # Vosk zips wrap the model in a single top-level directory.
    children = [p for p in tmp.iterdir() if p.is_dir()]
    if len(children) != 1:
        raise SystemExit(f"unexpected model zip layout: {[p.name for p in children]}")
    return children[0], tmp


def iter_story_files(story_arg: Path) -> Iterable[Path]:
    if story_arg.is_file():
        yield story_arg
        return
    if story_arg.is_dir():
        for p in sorted(story_arg.rglob("*.json")):
            try:
                with p.open("r", encoding="utf-8") as fh:
                    obj = json.load(fh)
            except (json.JSONDecodeError, UnicodeDecodeError, OSError):
                continue
            if isinstance(obj, dict) and (
                "sceneGraph" in obj or "scene_graph" in obj
            ):
                yield p
        return
    raise SystemExit(f"--story path not found: {story_arg}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", required=True, type=Path,
                    help="Path to Vosk model dir or .zip")
    ap.add_argument("--story", required=True, type=Path,
                    help="Path to a story JSON file or a directory of stories")
    ap.add_argument("--quiet-vosk", action="store_true",
                    help="Silence Vosk's own INFO logs (warnings still captured)")
    args = ap.parse_args()

    if args.quiet_vosk:
        SetLogLevel(-1)

    model_dir, tmp = extract_model_if_zip(args.model)
    try:
        print(f"Model: {model_dir}", file=sys.stderr)
        model = Model(str(model_dir))

        any_oov = False
        for story_file in iter_story_files(args.story):
            story_title, sources = collect_triggers(story_file)
            all_tokens = {t for s in sources for t in s.tokens}
            oov = find_oov_tokens(model, all_tokens)

            broken = [s for s in sources if any(t in oov for t in s.tokens)]
            print()
            print(f"=== {story_title} ({story_file}) ===")
            print(f"  triggers scanned : {len(sources)}")
            print(f"  unique tokens    : {len(all_tokens)}")
            print(f"  OOV tokens       : {len(oov)}")

            if oov:
                any_oov = True
                print(f"  missing words    : {', '.join(sorted(oov))}")
                print("  affected triggers:")
                for s in broken:
                    missing = [t for t in s.tokens if t in oov]
                    print(
                        f"    [{s.scene_id}] {s.role}: "
                        f'"{s.text}"  → missing {missing}'
                    )
            else:
                print("  all trigger tokens are in the model lexicon.")

        return 1 if any_oov else 0
    finally:
        if tmp is not None:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
