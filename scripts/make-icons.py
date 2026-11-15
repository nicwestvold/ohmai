#!/usr/bin/env python3
"""Generates ohmai's Ω face artwork from one set of path definitions.

Source of truth: the "Ω face: personality" design (24-unit grid). Outputs, all committed:
  App/AppIcon.icon/Assets/face.png          app icon layer (icon.json paints it amber on ink)
  App/Assets.xcassets/Face-*.imageset       vector PDF template images for the menu bar and header

Needs rsvg-convert (brew install librsvg). Run from the repo root: scripts/make-icons.py
"""
import json
import pathlib
import subprocess
import tempfile


def circle(x, y, r):
    return f"M{x - r} {y}a{r} {r} 0 1 0 {2 * r} 0a{r} {r} 0 1 0 {-2 * r} 0"


OM = "M4 20H8.4V16.7A7 7 0 1 1 15.6 16.7V20H20"
DISC = "M8.4 16.7A7 7 0 1 1 15.6 16.7Z"
BADGE = circle(20.8, 3.2, 2.6)
SHUT = "M8 10.5q1.3 1.2 2.6 0M13.4 10.5q1.3 1.2 2.6 0"
Z = "M17.6 1.6h2.8l-2.8 2.8h2.8"
LOOK = circle(8.9, 10.6, 1.3) + circle(14.3, 10.6, 1.3)
EYES = circle(9.3, 10, 1.3) + circle(14.7, 10, 1.3)
WIDE = circle(9.2, 9.4, 1.6) + circle(14.8, 9.4, 1.6) + circle(12, 13.9, 1.15)
SHADES = "M6.9 8.4H11.1V10.8Q9 12.6 6.9 10.8ZM12.9 8.4H17.1V10.8Q15 12.6 12.9 10.8Z"
DROWSY = "M8 10.4H10.6M13.4 10.4H16M10.6 14.2H13.4"

# name: (stroked lines, filled shapes). Holes (eyes) come from the even-odd fill.
FACES = {
    # Menu bar, 16 pt: four glanceable states.
    "Face-asleep": (OM + SHUT, ""),
    "Face-working": (OM, DISC + EYES),
    "Face-waiting": (OM, DISC + EYES + BADGE),
    "Face-shades": (OM, DISC + SHADES),
    # Dropdown header: the fuller expressions.
    "Face-header-asleep": (OM + SHUT + Z, ""),
    "Face-header-focused": (OM, DISC + LOOK),
    "Face-header-oh": (OM, DISC + WIDE),
    "Face-header-drowsy": (OM + DROWSY, ""),
}


def svg(lines, solid, stroke=2.0, size=24, view=(0, 0, 24, 24)):
    vx, vy, vw, vh = view
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="{vx} {vy} {vw} {vh}">']
    if lines:
        parts.append(f'<path d="{lines}" fill="none" stroke="#000" stroke-width="{stroke}" stroke-linecap="round" stroke-linejoin="round"/>')
    if solid:
        parts.append(f'<path d="{solid}" fill="#000" fill-rule="evenodd"/>')
    parts.append("</svg>")
    return "\n".join(parts)


def rsvg(svg_text, out, fmt, size):
    with tempfile.NamedTemporaryFile("w", suffix=".svg", delete=False) as f:
        f.write(svg_text)
    subprocess.run(["rsvg-convert", "-f", fmt, "-w", str(size), "-h", str(size), f.name, "-o", str(out)], check=True)


def main():
    root = pathlib.Path(__file__).resolve().parent.parent

    # App icon layer: the face spans 92/128 of the canvas, centered, stroke 1.6.
    span = 24 * 128 / 92
    off = -(span - 24) / 2
    rsvg(svg(OM, DISC + EYES, stroke=1.6, size=1024, view=(off, off, span, span)),
         root / "App/AppIcon.icon/Assets/face.png", "png", 1024)

    catalog = root / "App/Assets.xcassets"
    catalog.mkdir(exist_ok=True)
    (catalog / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    for name, (lines, solid) in FACES.items():
        folder = catalog / f"{name}.imageset"
        folder.mkdir(exist_ok=True)
        rsvg(svg(lines, solid), folder / f"{name}.pdf", "pdf", 24)
        (folder / "Contents.json").write_text(json.dumps({
            "images": [{"filename": f"{name}.pdf", "idiom": "universal"}],
            "info": {"author": "xcode", "version": 1},
            "properties": {"preserves-vector-representation": True, "template-rendering-intent": "template"},
        }, indent=2) + "\n")
    print(f"wrote face.png and {len(FACES)} imagesets")


if __name__ == "__main__":
    main()
