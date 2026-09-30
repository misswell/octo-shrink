#!/usr/bin/env python3
"""Convert the frontend SVG icon sprites into a SwiftUI path-data table.

Source of truth: frontend/index.html and frontend/compare.html (the inline
`<svg class="icon-library">` sprites). Specification shared by both pages:
24-grid, 1.8 stroke, round caps/joins, `fill="currentColor"` marks solid dots.

The generated file mirrors the exact path data (arcs converted to cubic
segments per the SVG spec's endpoint->center parameterization) so the Swift
native line renders the same glyphs as the Tauri frontend.

Run from the repository root:  python3 scripts/gen_swift_icons.py
"""

from __future__ import annotations

import math
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SOURCES = [REPO / "frontend" / "index.html", REPO / "frontend" / "compare.html"]
OUT = REPO / "swift" / "Sources" / "OctoShrinkSwift" / "Views" / "OctoIconLibrary.swift"


def fmt(value: float) -> str:
    text = f"{value:.3f}".rstrip("0").rstrip(".")
    return "0" if text in ("-0", "") else text


# ─── SVG path parsing ───────────────────────────────────────────


def arc_to_cubics(x1, y1, rx, ry, phi_deg, large, sweep, x2, y2):
    """SVG spec F.6.5: endpoint -> center parameterization, split <=90°, cubic."""
    if rx == 0 or ry == 0 or (x1 == x2 and y1 == y2):
        return [("L", x2, y2)]
    phi = math.radians(phi_deg % 360)
    cos_p, sin_p = math.cos(phi), math.sin(phi)
    dx2, dy2 = (x1 - x2) / 2.0, (y1 - y2) / 2.0
    x1p = cos_p * dx2 + sin_p * dy2
    y1p = -sin_p * dx2 + cos_p * dy2
    rx, ry = abs(rx), abs(ry)
    lam = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
    if lam > 1:
        scale = math.sqrt(lam)
        rx *= scale
        ry *= scale
    num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
    den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
    factor = math.sqrt(max(0.0, num / den)) if den else 0.0
    if large == sweep:
        factor = -factor
    cxp = factor * rx * y1p / ry
    cyp = -factor * ry * x1p / rx
    cx = cos_p * cxp - sin_p * cyp + (x1 + x2) / 2.0
    cy = sin_p * cxp + cos_p * cyp + (y1 + y2) / 2.0

    def angle(ux, uy, vx, vy):
        dot = ux * vx + uy * vy
        norm = math.hypot(ux, uy) * math.hypot(vx, vy)
        value = max(-1.0, min(1.0, dot / norm)) if norm else 1.0
        a = math.acos(value)
        return -a if (ux * vy - uy * vx) < 0 else a

    theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
    delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
    if not sweep and delta > 0:
        delta -= 2 * math.pi
    elif sweep and delta < 0:
        delta += 2 * math.pi

    segments = max(1, int(math.ceil(abs(delta) / (math.pi / 2))))
    step = delta / segments
    out = []
    t = theta1
    for _ in range(segments):
        alpha = 4.0 / 3.0 * math.tan(step / 4.0)
        cos1, sin1 = math.cos(t), math.sin(t)
        cos2, sin2 = math.cos(t + step), math.sin(t + step)

        def point(c, s):
            return (
                cx + rx * cos_p * c - ry * sin_p * s,
                cy + rx * sin_p * c + ry * cos_p * s,
            )

        def derivative(c, s):
            return (
                -rx * cos_p * s - ry * sin_p * c,
                -rx * sin_p * s + ry * cos_p * c,
            )

        p1 = point(cos1, sin1)
        p2 = point(cos2, sin2)
        d1 = derivative(cos1, sin1)
        d2 = derivative(cos2, sin2)
        c1 = (p1[0] + alpha * d1[0], p1[1] + alpha * d1[1])
        c2 = (p2[0] - alpha * d2[0], p2[1] - alpha * d2[1])
        out.append(("C", c1[0], c1[1], c2[0], c2[1], p2[0], p2[1]))
        t += step
    return out


def parse_path(d: str):
    """Parse an SVG path 'd' into a list of ops: M/L/C/Z with absolute coords."""
    tokens = re.findall(r"[MmLlHhVvCcAaZz]|[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?", d)
    ops = []
    i = 0
    cur = (0.0, 0.0)
    start = (0.0, 0.0)
    cmd = None
    while i < len(tokens):
        tok = tokens[i]
        if tok.isalpha():
            cmd = tok
            i += 1
            if cmd in "Zz":
                ops.append(("Z",))
                cur = start
            continue

        def take(n):
            nonlocal i
            vals = [float(tokens[i + k]) for k in range(n)]
            i += n
            return vals

        rel = cmd.islower()
        if cmd in "Mm":
            x, y = take(2)
            if rel:
                x, y = cur[0] + x, cur[1] + y
            ops.append(("M", x, y))
            cur = start = (x, y)
        elif cmd in "Ll":
            x, y = take(2)
            if rel:
                x, y = cur[0] + x, cur[1] + y
            ops.append(("L", x, y))
            cur = (x, y)
        elif cmd in "Hh":
            (x,) = take(1)
            x = cur[0] + x if rel else x
            ops.append(("L", x, cur[1]))
            cur = (x, cur[1])
        elif cmd in "Vv":
            (y,) = take(1)
            y = cur[1] + y if rel else y
            ops.append(("L", cur[0], y))
            cur = (cur[0], y)
        elif cmd in "Cc":
            x1, y1, x2, y2, x, y = take(6)
            if rel:
                x1, y1 = cur[0] + x1, cur[1] + y1
                x2, y2 = cur[0] + x2, cur[1] + y2
                x, y = cur[0] + x, cur[1] + y
            ops.append(("C", x1, y1, x2, y2, x, y))
            cur = (x, y)
        elif cmd in "Aa":
            rx, ry, rot, large, sweep, x, y = take(7)
            if rel:
                x, y = cur[0] + x, cur[1] + y
            ops.extend(arc_to_cubics(cur[0], cur[1], rx, ry, rot, bool(large), bool(sweep), x, y))
            cur = (x, y)
        else:
            raise ValueError(f"unsupported command {cmd} in {d!r}")
        # implicit command repetition: extra coordinate pairs after M are lines
        if cmd in "Mm":
            cmd = "L" if cmd == "M" else "l"
    return ops


KAPPA = 0.5522847498307936


def circle_ops(cx, cy, r):
    c = KAPPA * r
    return [
        ("M", cx + r, cy),
        ("C", cx + r, cy + c, cx + c, cy + r, cx, cy + r),
        ("C", cx - c, cy + r, cx - r, cy + c, cx - r, cy),
        ("C", cx - r, cy - c, cx - c, cy - r, cx, cy - r),
        ("C", cx + c, cy - r, cx + r, cy - c, cx + r, cy),
        ("Z",),
    ]


def rect_ops(x, y, w, h, rx):
    rx = min(rx, w / 2, h / 2)
    if rx <= 0:
        return [
            ("M", x, y),
            ("L", x + w, y),
            ("L", x + w, y + h),
            ("L", x, y + h),
            ("Z",),
        ]
    c = KAPPA * rx
    return [
        ("M", x + rx, y),
        ("L", x + w - rx, y),
        ("C", x + w - rx + c, y, x + w, y + rx - c, x + w, y + rx),
        ("L", x + w, y + h - rx),
        ("C", x + w, y + h - rx + c, x + w - rx + c, y + h, x + w - rx, y + h),
        ("L", x + rx, y + h),
        ("C", x + rx - c, y + h, x, y + h - rx + c, x, y + h - rx),
        ("L", x, y + rx),
        ("C", x, y + rx - c, x + rx - c, y, x + rx, y),
        ("Z",),
    ]


ATTR = re.compile(r'([\w:-]+)="([^"]*)"')


def parse_element(tag, attrs_text):
    attrs = dict(ATTR.findall(attrs_text))
    filled = attrs.get("fill") == "currentColor"
    stroked = attrs.get("stroke") != "none"  # default stroke comes from CSS
    if tag == "path":
        ops = parse_path(attrs["d"])
    elif tag == "circle":
        ops = circle_ops(float(attrs["cx"]), float(attrs["cy"]), float(attrs["r"]))
    elif tag == "rect":
        ops = rect_ops(
            float(attrs["x"]), float(attrs["y"]),
            float(attrs["width"]), float(attrs["height"]),
            float(attrs.get("rx", 0)),
        )
    else:
        raise ValueError(f"unsupported element <{tag}>")
    return ops, stroked, filled


def main() -> int:
    symbols: dict[str, str] = {}
    for page in SOURCES:
        html = page.read_text(encoding="utf-8")
        sprite = html[html.index('<svg class="icon-library"'):]
        sprite = sprite[:sprite.index("</svg>")]
        for match in re.finditer(r'<symbol id="([^"]+)"[^>]*>(.*?)</symbol>', sprite, re.S):
            name, inner = match.group(1), match.group(2)
            if name in symbols and symbols[name] != inner:
                print(f"conflict for {name} between pages", file=sys.stderr)
                return 1
            symbols[name] = inner

    blocks = []
    for name in sorted(symbols):
        elements = re.findall(r"<(\w+)((?:\s+[\w:-]+=\"[^\"]*\")*)\s*/?>", symbols[name])
        entries = []
        for tag, attrs_text in elements:
            ops, stroked, filled = parse_element(tag, attrs_text)
            body = ", ".join(
                {
                    "M": lambda o: f".move({fmt(o[1])}, {fmt(o[2])})",
                    "L": lambda o: f".line({fmt(o[1])}, {fmt(o[2])})",
                    "C": lambda o: (
                        f".curve({fmt(o[1])}, {fmt(o[2])}, {fmt(o[3])}, {fmt(o[4])}, {fmt(o[5])}, {fmt(o[6])})"
                    ),
                    "Z": lambda o: ".close",
                }[op[0]](op)
                for op in ops
            )
            if filled:
                entries.append(f"                .fill([{body}]),")
            if stroked:
                entries.append(f"                .stroke([{body}]),")
        blocks.append(f'        "{name}": [\n' + "\n".join(entries) + "\n        ],")

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(
        "// Auto-generated by scripts/gen_swift_icons.py — do not edit by hand.\n"
        "// Source: frontend/index.html + frontend/compare.html icon sprites\n"
        "// (24-grid, 1.8 stroke, round caps/joins; fill = solid dot).\n"
        "import SwiftUI\n"
        "\n"
        "enum OctoPathOp {\n"
        "    case move(CGFloat, CGFloat)\n"
        "    case line(CGFloat, CGFloat)\n"
        "    case curve(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)\n"
        "    case close\n"
        "}\n"
        "\n"
        "enum OctoIconElement {\n"
        "    case stroke([OctoPathOp])\n"
        "    case fill([OctoPathOp])\n"
        "}\n"
        "\n"
        "enum OctoIconLibrary {\n"
        "    static let icons: [String: [OctoIconElement]] = [\n"
        + "\n".join(blocks)
        + "\n    ]\n"
        "}\n",
        encoding="utf-8",
    )
    print(f"wrote {OUT} with {len(symbols)} icons")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
