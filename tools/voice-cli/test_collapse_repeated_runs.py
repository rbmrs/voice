"""Runnable self-check for collapse_repeated_runs.

Run: python3 tools/voice-cli/test_collapse_repeated_runs.py
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from voice import collapse_repeated_runs  # noqa: E402

# Runaway loops collapse to a single occurrence.
assert collapse_repeated_runs("it it it it it it") == "it"
assert (
    collapse_repeated_runs("the way that we're getting the way that we're getting right now")
    == "the way that we're getting right now"
), collapse_repeated_runs("the way that we're getting the way that we're getting right now")

# Hyphen-joined loops ("a-it-it-it..." is a single whitespace token) collapse too.
assert collapse_repeated_runs("a-it-it-it-it-it") == "a-it"

# Legit repetition is preserved (adjacent doubles, non-adjacent repeats, hyphenated words).
assert collapse_repeated_runs("no no it's fine") == "no no it's fine"
assert collapse_repeated_runs("I had had enough") == "I had had enough"
assert collapse_repeated_runs("come on come on") == "come on come on"
assert collapse_repeated_runs("well-being state-of-the-art") == "well-being state-of-the-art"
assert collapse_repeated_runs("hello world") == "hello world"
assert collapse_repeated_runs("") == ""

print("collapse_repeated_runs: all checks passed")
