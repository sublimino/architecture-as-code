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


def _split_top_level(s: str, op: str) -> list[str]:
    """Split string by operator at top syntactic depth outside quotes/brackets."""
    parts = []
    depth = 0
    in_quote = None
    escaped = False
    curr: list[str] = []
    i = 0
    n = len(s)
    op_len = len(op)
    while i < n:
        c = s[i]
        if escaped:
            curr.append(c)
            escaped = False
            i += 1
            continue
        if c == "\\":
            escaped = True
            curr.append(c)
            i += 1
            continue
        if in_quote:
            curr.append(c)
            if c == in_quote:
                in_quote = None
            i += 1
            continue
        if c in ("'", '"'):
            in_quote = c
            curr.append(c)
            i += 1
            continue
        if c in "([{":
            depth += 1
            curr.append(c)
            i += 1
            continue
        if c in ")]}":
            depth -= 1
            curr.append(c)
            i += 1
            continue
        if depth == 0 and s[i : i + op_len] == op:
            if op == "in":
                before = s[i - 1] if i > 0 else " "
                after = s[i + op_len] if i + op_len < n else " "
                if (before.isalnum() or before == "_") or (after.isalnum() or after == "_"):
                    curr.append(c)
                    i += 1
                    continue
            parts.append("".join(curr).strip())
            curr = []
            i += op_len
            continue
        curr.append(c)
        i += 1
    if curr:
        parts.append("".join(curr).strip())
    return parts


def _parse_literal_or_path(expr: str, scope: dict[str, Any]) -> Any:
    """Parse literal value, list, or resolve identifier path against scope."""
    expr = expr.strip()
    if expr == "true":
        return True
    if expr == "false":
        return False
    if expr == "null":
        return None
    if (expr.startswith('"') and expr.endswith('"')) or (expr.startswith("'") and expr.endswith("'")):
        return expr[1:-1]
    if expr.isdigit() or (expr.startswith("-") and expr[1:].isdigit()):
        return int(expr)
    if expr.startswith("[") and expr.endswith("]"):
        inner = expr[1:-1].strip()
        if not inner:
            return []
        items = _split_top_level(inner, ",")
        return [_parse_literal_or_path(it, scope) for it in items]
    return _resolve_path(scope, expr)


def _eval_cel_ast(expr: str, scope: dict[str, Any]) -> Any:
    """Recursively evaluate validated CEL expression tree against scope dictionary."""
    expr = expr.strip()
    if not expr:
        return False

    # Strip outer matching parentheses
    while expr.startswith("(") and expr.endswith(")"):
        depth = 0
        wraps_all = True
        for c in expr[:-1]:
            if c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
            if depth == 0:
                wraps_all = False
                break
        if wraps_all:
            expr = expr[1:-1].strip()
        else:
            break

    # 1. Top-level Ternary: cond ? then_expr : else_expr
    q_parts = _split_top_level(expr, "?")
    if len(q_parts) == 2:
        cond_str = q_parts[0]
        colon_parts = _split_top_level(q_parts[1], ":")
        if len(colon_parts) == 2:
            return _eval_cel_ast(colon_parts[0], scope) if _eval_cel_ast(cond_str, scope) else _eval_cel_ast(colon_parts[1], scope)

    # 2. Top-level ||
    or_parts = _split_top_level(expr, "||")
    if len(or_parts) > 1:
        return any(bool(_eval_cel_ast(p, scope)) for p in or_parts)

    # 3. Top-level &&
    and_parts = _split_top_level(expr, "&&")
    if len(and_parts) > 1:
        return all(bool(_eval_cel_ast(p, scope)) for p in and_parts)

    # 4. Top-level !
    if expr.startswith("!") and not expr.startswith("!="):
        return not bool(_eval_cel_ast(expr[1:].strip(), scope))

    # 5. Top-level == and !=
    eq_parts = _split_top_level(expr, "==")
    if len(eq_parts) == 2:
        left = _parse_literal_or_path(eq_parts[0], scope)
        right = _parse_literal_or_path(eq_parts[1], scope)
        return left == right

    neq_parts = _split_top_level(expr, "!=")
    if len(neq_parts) == 2:
        left = _parse_literal_or_path(neq_parts[0], scope)
        right = _parse_literal_or_path(neq_parts[1], scope)
        return left != right

    # 6. Top-level 'in'
    in_parts = _split_top_level(expr, "in")
    if len(in_parts) == 2:
        val = _parse_literal_or_path(in_parts[0], scope)
        container = _parse_literal_or_path(in_parts[1], scope)
        if isinstance(container, (list, tuple, set)):
            return val in container
        return False

    # 7. has(path)
    has_match = re.match(r"^has\(\s*([a-zA-Z0-9_\.]+)\s*\)$", expr)
    if has_match:
        return _resolve_path(scope, has_match.group(1)) is not None

    # 8. Macros: .all(var, cond) and .exists(var, cond)
    macro_match = re.search(r"\.(all|exists)\(\s*([a-zA-Z0-9_]+)\s*,\s*(.+)\)$", expr)
    if macro_match:
        mtype = macro_match.group(1)
        var_name = macro_match.group(2)
        cond_body = macro_match.group(3)
        target_expr = expr[: macro_match.start()]
        target_list = _parse_literal_or_path(target_expr, scope)
        if not isinstance(target_list, list):
            return False
        if mtype == "all":
            for item in target_list:
                inner_scope = dict(scope)
                inner_scope[var_name] = item
                if not _eval_cel_ast(cond_body, inner_scope):
                    return False
            return True
        elif mtype == "exists":
            for item in target_list:
                inner_scope = dict(scope)
                inner_scope[var_name] = item
                if _eval_cel_ast(cond_body, inner_scope):
                    return True
            return False

    # Fallback to truthiness of path or literal
    val = _parse_literal_or_path(expr, scope)
    return bool(val)


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

    scope = dict(context)
    if "object" in scope and "manifest" not in scope:
        scope["manifest"] = scope["object"]
    elif "manifest" in scope and "object" not in scope:
        scope["object"] = scope["manifest"]

    try:
        compliant = bool(_eval_cel_ast(expression, scope))
        return CelEvaluationResult(compliant=compliant, cost=5)
    except Exception as exc:
        return CelEvaluationResult(compliant=False, cost=0, error=str(exc))


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
