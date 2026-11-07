"""Rule-based transcript cleanup.

This is the cheap half of what Wispr Flow's "AI cleanup" does: fillers,
stutters, spoken punctuation, capitalization and custom vocabulary. It runs in
well under a millisecond and holds no model in memory. Grammar and tone polish
is a separate, optional pass that lives in the Swift app on Apple's
system-managed on-device model.
"""

from __future__ import annotations

import re
from typing import Any

# Spoken punctuation. Ordered longest-first so "question mark" wins over "mark".
SPOKEN_COMMANDS: list[tuple[str, str]] = [
    ("new paragraph", "\n\n"),
    ("new line", "\n"),
    ("newline", "\n"),
    ("exclamation point", "!"),
    ("exclamation mark", "!"),
    ("question mark", "?"),
    ("open parenthesis", "("),
    ("close parenthesis", ")"),
    ("open paren", "("),
    ("close paren", ")"),
    ("semicolon", ";"),
    ("ellipsis", "..."),
    ("bullet point", "\n- "),
    ("period", "."),
    ("comma", ","),
    ("colon", ":"),
]

# Transcribers emit these as real punctuation, so a spoken command arrives as
# the literal word wrapped in whatever punctuation the model guessed at.
_TRAILING_PUNCT = ".,!?;:"


def _apply_vocabulary(text: str, vocabulary: dict[str, str]) -> str:
    for phrase, replacement in sorted(vocabulary.items(), key=lambda kv: -len(kv[0])):
        if not phrase.strip():
            continue
        pattern = re.compile(r"\b" + re.escape(phrase) + r"\b", re.IGNORECASE)
        text = pattern.sub(replacement.replace("\\", r"\\"), text)
    return text


def _remove_fillers(text: str, fillers: list[str]) -> str:
    words = [f for f in (w.strip().lower() for w in fillers) if f]
    if not words:
        return text
    alts = "|".join(re.escape(w) for w in words)
    # A filler plus the punctuation the model hung off it, as a whole token.
    text = re.sub(
        rf"(?<![\w'])(?:{alts})(?![\w'])[{re.escape(_TRAILING_PUNCT)}]*\s*",
        "",
        text,
        flags=re.IGNORECASE,
    )
    return text


def _dedupe_stutters(text: str) -> str:
    """Collapse "we should, we should ship" and "the the file"."""
    # Repeated 1-4 word phrase, tolerating punctuation between the two copies.
    phrase = re.compile(
        r"\b((?:[\w']+(?:\s+[\w']+){0,3}))"      # first copy
        r"\s*[,.;:!?]*\s+"                        # separator the model inserted
        r"\1\b",                                  # immediate repeat
        re.IGNORECASE,
    )
    for _ in range(3):  # a triple stutter needs more than one pass
        collapsed = phrase.sub(r"\1", text)
        if collapsed == text:
            break
        text = collapsed
    return text


def _apply_spoken_commands(text: str) -> str:
    for phrase, replacement in SPOKEN_COMMANDS:
        pattern = re.compile(
            rf"(?<![\w']){re.escape(phrase)}(?![\w'])[{re.escape(_TRAILING_PUNCT)}]*",
            re.IGNORECASE,
        )
        text = pattern.sub(lambda _m, r=replacement: r, text)
    return text


_ELLIPSIS = "\x00ELLIPSIS\x00"


def _collapse_punctuation(text: str) -> str:
    """Removing a filler can orphan its comma: "Hey, um, so" -> "Hey,, so"."""
    text = text.replace("...", _ELLIPSIS)
    # Of two adjacent punctuation marks, the later one is the real one.
    text = re.sub(r"[,.;:!?]\s*(?=[,.;:!?])", "", text)
    return text.replace(_ELLIPSIS, "...")


def _fix_spacing(text: str) -> str:
    text = re.sub(r"[ \t]+", " ", text)
    text = _collapse_punctuation(text)
    # A filler at the very start leaves dangling punctuation behind.
    text = re.sub(r"\A[\s,.;:!?]+", "", text)
    text = re.sub(r" *\n *", "\n", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    # No space before punctuation that hugs the previous word.
    text = re.sub(r"\s+([,.;:!?)])", r"\1", text)
    text = re.sub(r"([(])\s+", r"\1", text)
    # But do keep a space after sentence punctuation.
    text = re.sub(r"([,.;:!?])(?=[A-Za-z0-9])", r"\1 ", text)
    text = re.sub(r"(\d)[.,] (\d)", r"\1.\2", text)  # undo split decimals
    return text.strip()


def _fix_capitalization(text: str) -> str:
    text = re.sub(r"\bi\b", "I", text)
    text = re.sub(r"\bi'(m|ve|ll|d)\b", lambda m: "I'" + m.group(1), text)

    def upper_after(match: re.Match[str]) -> str:
        return match.group(1) + match.group(2).upper()

    # Start of the transcript, and the start of each sentence or line.
    text = re.sub(r"\A(\s*)([a-z])", upper_after, text)
    text = re.sub(r"([.!?]\s+|\n+\s*|\n- )([a-z])", upper_after, text)
    return text


def clean(text: str, cfg: dict[str, Any]) -> str:
    """Run the enabled cleanup passes over a raw transcript."""
    if not text or not text.strip():
        return ""
    if not cfg.get("enabled", True):
        return text.strip()

    if cfg.get("spoken_commands", True):
        text = _apply_spoken_commands(text)
    if cfg.get("remove_fillers", True):
        text = _remove_fillers(text, cfg.get("fillers", []))
    if cfg.get("dedupe_stutters", True):
        text = _dedupe_stutters(text)
    text = _apply_vocabulary(text, cfg.get("vocabulary", {}) or {})
    text = _fix_spacing(text)
    if cfg.get("fix_capitalization", True):
        text = _fix_capitalization(text)
    return text
