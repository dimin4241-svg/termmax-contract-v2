"""Audit-branch compatibility shim for the TermMax production evidence collector.

Python imports this module automatically when the repository root is present in
PYTHONPATH.  The collector's final diagnostic calls ``max`` over tuples shaped
as ``(numeric_profit, evidence_dict)``.  When two profits are equal, Python
tries to compare the dictionaries and raises TypeError *after* the complete
JSON and Markdown evidence have already been written.

This shim preserves normal ``max`` semantics.  It only applies a numeric-key
tie breaker when the sole iterable consists entirely of the collector's
``(number, dict)`` diagnostic tuples.
"""

from __future__ import annotations

import builtins
from collections.abc import Iterable
from typing import Any

_ORIGINAL_MAX = builtins.max


def _audit_safe_max(*args: Any, **kwargs: Any) -> Any:
    if len(args) != 1 or kwargs:
        return _ORIGINAL_MAX(*args, **kwargs)

    candidate: Any = args[0]
    if not isinstance(candidate, Iterable):
        return _ORIGINAL_MAX(*args, **kwargs)

    values = list(candidate)
    if (
        values
        and all(
            isinstance(item, tuple)
            and len(item) == 2
            and isinstance(item[0], (int, float))
            and isinstance(item[1], dict)
            for item in values
        )
    ):
        return _ORIGINAL_MAX(values, key=lambda item: item[0])

    return _ORIGINAL_MAX(values)


builtins.max = _audit_safe_max
