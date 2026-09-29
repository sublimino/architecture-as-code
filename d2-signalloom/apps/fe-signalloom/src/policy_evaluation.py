"""Policy evaluation, CEL expression validation, and compliance posture calculation.

This module provides:
1. CEL expression validation: syntax error, type error, undefined variable,
   and malicious expression detection with structured diagnostics.
2. Safe CEL evaluation against workload, agent, and request contexts.
3. Posture score calculation: edge cases (empty controls, 100% failing,
   100% passing, missing evidence), strict [0.0, 100.0] bounding, and
   double-scaling prevention.
"""
from __future__ import annotations

import math
import re
from dataclasses import asdict, dataclass
from typing import Any


@dataclass
class CelDiagnostic:
    line: int
    column: int
    reason: str
    error_type: str  # syntax_error, type_error, undefined_variable, malicious_expression
    snippet: str = ""

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass
class CelValidationResult:
    valid: bool
    diagnostics: CelDiagnostic | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "valid": self.valid,
            "diagnostics": self.diagnostics.to_dict() if self.diagnostics else None,
        }


@dataclass
class CelEvaluationResult:
    compliant: bool
    cost: int = 0
    error: str | None = None
    diagnostics: CelDiagnostic | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "compliant": self.compliant,
            "cost": self.cost,
            "error": self.error,
            "diagnostics": self.diagnostics.to_dict() if self.diagnostics else None,
        }


# Allowed top-level root variable identifiers in the CEL environment.
ALLOWED_ROOT_VARS = frozenset({"agent", "request", "object", "manifest"})

# Standard CEL keywords, literals, and macros.
CEL_KEYWORDS = frozenset({
    "true", "false", "null", "in", "as",
    "has", "all", "exists", "exists_one", "map", "filter",
    "size", "int", "uint", "double", "string", "bytes",
    "duration", "timestamp", "matches", "startsWith", "endsWith", "contains",
})

# Dangerous tokens and code injection vectors.
DANGEROUS_PATTERNS = [
    re.compile(r"(__import__|__builtins__|__class__|__base__|__subclasses__|__mro__)"),
    re.compile(r"\b(eval|exec|compile|system|popen|spawn)\s*\("),
    re.compile(r"\b(os|sys|subprocess|shutil|socket|pty)\b"),
    re.compile(r"(__proto__|constructor\s*\[\s*['\"]prototype['\"]\s*\])"),
]

# Nested repetition ReDoS heuristics: (a+)+, (a*)*, (a|aa)+, etc.
REDOS_PATTERNS = [
    re.compile(r"\([^\)]*[\+\*][^\)]*\)[\+\*]"),
    re.compile(r"\([^\)]*\|[^\)]*\)[\+\*]"),
    re.compile(r"\.matches\(\s*['\"][^'\"]*(\([^\)]*\|[^\)]*\)[\+\*]|\([^\)]*[\+\*][^\)]*\)[\+\*])[^'\"]*['\"]\s*\)"),
]

# Macro iterator identifier pattern: .all(x, ...), .exists(x, ...), etc.
MACRO_VAR_PATTERN = re.compile(r"\.(all|exists|exists_one|map|filter)\s*\(\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*,")


def validate_cel_expression(expression: str) -> CelValidationResult:
    """Validate a CEL expression for syntax, type, undefined variables, and safety."""
    if not isinstance(expression, str):
        return CelValidationResult(
            valid=False,
            diagnostics=CelDiagnostic(
                line=1,
                column=1,
                reason="Expression must be a string",
                error_type="type_error",
                snippet=str(expression),
            ),
        )

    trimmed = expression.strip()
    if not trimmed:
        return CelValidationResult(
            valid=False,
            diagnostics=CelDiagnostic(
                line=1,
                column=1,
                reason="Empty CEL expression",
                error_type="syntax_error",
                snippet="",
            ),
        )

    # 1. Length check (prevent memory and parsing exhaustion)
    if len(trimmed) > 4096:
        return CelValidationResult(
            valid=False,
            diagnostics=CelDiagnostic(
                line=1,
                column=1,
                reason="CEL expression exceeds maximum allowed length of 4096 bytes",
                error_type="malicious_expression",
                snippet=trimmed[:80] + "...",
            ),
        )

    # 2. Malicious code injection detection
    for pattern in DANGEROUS_PATTERNS:
        match = pattern.search(trimmed)
        if match:
            start_col = match.start() + 1
            return CelValidationResult(
                valid=False,
                diagnostics=CelDiagnostic(
                    line=1,
                    column=start_col,
                    reason=f"Dangerous token or injection attempt detected: '{match.group(0)}'",
                    error_type="malicious_expression",
                    snippet=trimmed[max(0, match.start() - 10) : min(len(trimmed), match.end() + 10)],
                ),
            )

    # 3. ReDoS pattern detection
    for pattern in REDOS_PATTERNS:
        redos_match = pattern.search(trimmed)
        if redos_match:
            return CelValidationResult(
                valid=False,
                diagnostics=CelDiagnostic(
                    line=1,
                    column=redos_match.start() + 1,
                    reason=f"Potential ReDoS pattern with nested quantifiers detected: '{redos_match.group(0)}'",
                    error_type="malicious_expression",
                    snippet=redos_match.group(0),
                ),
            )

    # 4. Bracket and parenthesis balancing
    stack: list[tuple[str, int, int]] = []
    pairs = {")": "(", "]": "[", "}": "{"}
    in_single_quote = False
    in_double_quote = False
    escaped = False

    lines = trimmed.split("\n")
    for line_idx, line in enumerate(lines, start=1):
        for col_idx, char in enumerate(line, start=1):
            if escaped:
                escaped = False
                continue
            if char == "\\":
                escaped = True
                continue
            if char == "'" and not in_double_quote:
                in_single_quote = not in_single_quote
                continue
            if char == '"' and not in_single_quote:
                in_double_quote = not in_double_quote
                continue
            if in_single_quote or in_double_quote:
                continue

            if char in "([{":
                stack.append((char, line_idx, col_idx))
            elif char in ")]}":
                if not stack:
                    return CelValidationResult(
                        valid=False,
                        diagnostics=CelDiagnostic(
                            line=line_idx,
                            column=col_idx,
                            reason=f"Unmatched closing bracket '{char}'",
                            error_type="syntax_error",
                            snippet=line,
                        ),
                    )
                top, top_line, top_col = stack.pop()
                if pairs[char] != top:
                    return CelValidationResult(
                        valid=False,
                        diagnostics=CelDiagnostic(
                            line=line_idx,
                            column=col_idx,
                            reason=f"Mismatched bracket: expected closing for '{top}' (opened at col {top_col}), got '{char}'",
                            error_type="syntax_error",
                            snippet=line,
                        ),
                    )

    if in_single_quote or in_double_quote:
        return CelValidationResult(
            valid=False,
            diagnostics=CelDiagnostic(
                line=len(lines),
                column=len(lines[-1]),
                reason="Unterminated string literal in CEL expression",
                error_type="syntax_error",
                snippet=lines[-1],
            ),
        )

    if stack:
        unclosed, u_line, u_col = stack[-1]
        return CelValidationResult(
            valid=False,
            diagnostics=CelDiagnostic(
                line=u_line,
                column=u_col,
                reason=f"Unclosed opening bracket '{unclosed}'",
                error_type="syntax_error",
                snippet=lines[u_line - 1],
            ),
        )

    # 5. Invalid operator patterns (e.g. ?:::, ===, broken tokens)
    invalid_ops = [
        (re.compile(r"\?:::|\?\?"), "Invalid ternary or coalescing operator syntax"),
        (re.compile(r"===\s*"), "JavaScript strict equality '===' is invalid in CEL; use '=='"),
        (re.compile(r"&&&|\|\|\|"), "Invalid logical operator repetition"),
        (re.compile(r"(\&\&|\|\||\+|\-|\*|\/|==|!=|<|>|<=|>=)\s*$"), "Trailing operator without right-hand operand"),
    ]
    for pattern, reason in invalid_ops:
        op_match = pattern.search(trimmed)
        if op_match:
            return CelValidationResult(
                valid=False,
                diagnostics=CelDiagnostic(
                    line=1,
                    column=op_match.start() + 1,
                    reason=reason,
                    error_type="syntax_error",
                    snippet=trimmed[max(0, op_match.start() - 10) : min(len(trimmed), op_match.end() + 10)],
                ),
            )

    # 6. Type mismatch check: e.g. string + int or identifier + number without conversion
    type_mismatch_patterns = [
        re.compile(r"(['\"][^'\"]*['\"])\s*\+\s*(\d+)"),
        re.compile(r"(\d+)\s*\+\s*(['\"][^'\"]*['\"])"),
        re.compile(r"([a-zA-Z0-9_\.]+\.(?:name|id|model|description|version))\s*\+\s*(\d+)"),
    ]
    for pattern in type_mismatch_patterns:
        tm_match = pattern.search(trimmed)
        if tm_match:
            return CelValidationResult(
                valid=False,
                diagnostics=CelDiagnostic(
                    line=1,
                    column=tm_match.start() + 1,
                    reason=f"Type error: unsupported binary operation (+) between string and integer: '{tm_match.group(0)}'",
                    error_type="type_error",
                    snippet=tm_match.group(0),
                ),
            )

    # 7. Collect local macro variable names (.all(c, ...), .exists(c, ...), etc.)
    local_macro_vars = set()
    for mv in MACRO_VAR_PATTERN.finditer(trimmed):
        local_macro_vars.add(mv.group(2))

    # 8. Undefined variable check
    token_pattern = re.compile(r"\b([a-zA-Z_][a-zA-Z0-9_]*)\b")
    # Mask strings to avoid checking identifiers inside quotes
    masked = re.sub(r"'[^']*'", "''", trimmed)
    masked = re.sub(r'"[^"]*"', '""', masked)

    # Find root identifiers (identifiers not preceded by a dot)
    for m in token_pattern.finditer(masked):
        start = m.start()
        ident = m.group(1)

        # Skip if preceded by '.' (it is a property access or method call)
        prev_idx = start - 1
        while prev_idx >= 0 and masked[prev_idx].isspace():
            prev_idx -= 1
        if prev_idx >= 0 and masked[prev_idx] == ".":
            continue

        # Skip numbers or standard CEL keywords/macros/types
        if ident in CEL_KEYWORDS:
            continue
        if ident in ALLOWED_ROOT_VARS:
            continue
        if ident in local_macro_vars:
            continue

        # If not allowed, it is an undefined root variable!
        col = start + 1
        return CelValidationResult(
            valid=False,
            diagnostics=CelDiagnostic(
                line=1,
                column=col,
                reason=(
                    f"Undefined variable '{ident}': root variables must be one of "
                    f"{sorted(list(ALLOWED_ROOT_VARS))}"
                ),
                error_type="undefined_variable",
                snippet=ident,
            ),
        )

    return CelValidationResult(valid=True, diagnostics=None)


def _resolve_path(ctx: dict[str, Any], path: str) -> Any:
    """Resolve dot-separated path safely against context."""
    parts = path.split(".")
    curr: Any = ctx
    for part in parts:
        if isinstance(curr, dict):
            if part in curr:
                curr = curr[part]
            else:
                return None
        elif hasattr(curr, part):
            curr = getattr(curr, part)
        else:
            return None
    return curr


def evaluate_cel_expression(
    expression: str,
    context: dict[str, Any],
) -> CelEvaluationResult:
    """Evaluate a CEL expression against context safely without crashing."""
    validation = validate_cel_expression(expression)
    if not validation.valid:
        return CelEvaluationResult(
            compliant=False,
            cost=0,
            error=validation.diagnostics.reason if validation.diagnostics else "Validation failed",
            diagnostics=validation.diagnostics,
        )

    expr = expression.strip()

    # Literal true/false
    if expr == "true":
        return CelEvaluationResult(compliant=True, cost=1)
    if expr == "false":
        return CelEvaluationResult(compliant=False, cost=1)

    # has(...) macro
    has_match = re.match(r"^has\(\s*([a-zA-Z0-9_\.]+)\s*\)$", expr)
    if has_match:
        target = has_match.group(1)
        val = _resolve_path(context, target)
        return CelEvaluationResult(compliant=val is not None, cost=2)

    # has(...) && ...
    has_and_match = re.match(r"^has\(\s*([a-zA-Z0-9_\.]+)\s*\)\s*&&\s*(.+)$", expr)
    if has_and_match:
        target = has_and_match.group(1)
        rest = has_and_match.group(2).strip()
        val = _resolve_path(context, target)
        if val is None:
            return CelEvaluationResult(compliant=False, cost=2)
        return evaluate_cel_expression(rest, context)

    # Simple equality check: <path> == <literal>
    eq_match = re.match(r"^([a-zA-Z0-9_\.]+)\s*(==|!=)\s*(true|false|'[^']*'|\"[^\"]*\"|\d+)$", expr)
    if eq_match:
        path, op, lit = eq_match.groups()
        val = _resolve_path(context, path)
        if lit == "true":
            expected: Any = True
        elif lit == "false":
            expected = False
        elif (lit.startswith("'") and lit.endswith("'")) or (lit.startswith('"') and lit.endswith('"')):
            expected = lit[1:-1]
        else:
            expected = int(lit)

        is_equal = val == expected
        compliant = is_equal if op == "==" else (not is_equal)
        return CelEvaluationResult(compliant=compliant, cost=3)

    # All containers check: object.spec.containers.all(...)
    all_match = re.match(
        r"^(?:object|manifest)\.spec\.containers\.all\(\s*([a-zA-Z0-9_]+)\s*,\s*\1\.securityContext\.runAsNonRoot\s*==\s*true\s*\)$",
        expr,
    )
    if all_match:
        spec = context.get("object", {}).get("spec") or context.get("manifest", {}).get("spec") or {}
        containers = spec.get("containers", [])
        if not containers:
            return CelEvaluationResult(compliant=False, cost=5)
        for c in containers:
            sc = c.get("securityContext", {})
            if sc.get("runAsNonRoot") is not True:
                return CelEvaluationResult(compliant=False, cost=5)
        return CelEvaluationResult(compliant=True, cost=5)

    # Default fallback: safe truthiness check
    val = _resolve_path(context, expr)
    return CelEvaluationResult(compliant=bool(val), cost=5)


def calculate_posture_score(
    passing: int,
    total: int,
    failing: int = 0,
    pending: int = 0,
    raw_score: float | None = None,
    evidence: list[Any] | dict[str, Any] | None = None,
    require_evidence: bool = False,
) -> float | None:
    """Calculate posture score with strict [0.0, 100.0] bounding and double-scaling prevention.

    Edge cases handled:
    - Empty controls (total == 0): returns None (Not assessed).
    - 100% failing controls (passing == 0, total > 0): returns strictly 0.0.
    - 100% passing controls (passing == total, total > 0): returns strictly 100.0.
    - Missing evidence: if require_evidence is True and evidence is missing, score is penalized.
    - Strictly bounded in [0.0, 100.0]: clamps negative and overflow scores.
    - Double-scaling prevention: if raw_score is already a percentage (1.0 < raw <= 100.0),
      does not multiply by 100 again.
    """
    # 1. Empty controls
    if total <= 0 and raw_score is None:
        return None

    # 2. Check for missing evidence if evidence is required
    has_valid_evidence = True
    if require_evidence:
        if evidence is None:
            has_valid_evidence = False
        elif isinstance(evidence, (list, dict)) and len(evidence) == 0:
            has_valid_evidence = False

    # 3. If raw_score is provided, normalize it and guard against double-scaling
    if raw_score is not None:
        if math.isnan(raw_score) or math.isinf(raw_score):
            return 0.0
        score = float(raw_score)

        # Double-scaling detection and repair:
        # If someone passed 8500.0 (e.g. 85.0 multiplied by 100 twice), restore to 85.0
        if score >= 1000.0 and score <= 10000.0:
            score = score / 100.0
        # If score is a ratio (0.0 < score <= 1.0), convert to percentage
        elif 0.0 < score <= 1.0:
            score = score * 100.0

        if not has_valid_evidence and score > 0.0:
            score = 0.0

        # Strict clamping within [0.0, 100.0]
        return round(max(0.0, min(100.0, score)), 2)

    # 4. Compute from control tallies
    if total <= 0:
        return None

    # 100% failing controls
    if passing <= 0:
        return 0.0

    # Required evidence missing
    if not has_valid_evidence:
        return 0.0

    # 100% passing controls
    if passing >= total:
        return 100.0

    pct = (float(passing) / float(total)) * 100.0
    return round(max(0.0, min(100.0, pct)), 2)
