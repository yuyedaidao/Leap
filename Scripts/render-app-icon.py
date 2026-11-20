#!/usr/bin/env python3
"""渲染 Leap 袋鼠剪影图标。

SVG 是唯一真源，rsvg-convert 出位图，actool 出 .icns。
剪影由旋转椭圆 + 锥形胶囊（多次叠圆近似）拼成同色并集：
改参数不会破坏轮廓连续性，且耳朵/口鼻/尾尖能逐处收细——
均匀 stroke 画不出动物特征。

主体与起跳线一起做自适应适配（fit）：脚本先低分辨率量出实际 bbox，
再把内容等比缩放平移到目标框内。因此改几何无须手算比例，
也不会再出现主体偏左上或越出 squircle 安全区。
"""

import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "Resources/Leap/IconCandidates/redesign"

# 背景渐变端点经 WCAG 实算：白剪影 #F7F2FF 对顶端 4.59:1、对底端 8.19:1
BG_TOP = "#6E5BE0"
BG_BOTTOM = "#43319E"
SUBJECT = "#F7F2FF"
HOP = "#FFFFFF"
HOP_ALPHA = 0.42

# 内容目标框：占画布 76%（含起跳线），主体自身约 69%，与系统图标占比一致
# 中心略高于画布中心——起跳线在下方加重，视觉重量需要反向补偿
FIT_SIDE = 780
FIT_CENTER = (512, 492)


@dataclass
class Variant:
    """坐标为 32x32 网格上的小数，渲染时乘 32 放大到 1024。"""

    key: str
    title: str
    ellipses: list  # (cx, cy), (rx, ry), rotate_deg
    tapers: list  # (x1, y1), (x2, y2), width_start, width_end
    hop: tuple  # x1, x2, y, width


VARIANTS = {
    "V1": Variant(
        key="V1",
        title="弧线主导",
        ellipses=[
            ((13.0, 11.8), (5.0, 5.4), -12),
            ((15.2, 16.8), (3.6, 3.2), -6),
            ((19.2, 7.6), (2.9, 2.6), -10),
        ],
        tapers=[
            ((18.0, 9.4), (16.6, 12.0), 3.2, 3.6),
            ((20.9, 8.1), (24.6, 8.9), 2.6, 1.3),
            ((18.4, 5.2), (17.4, 1.8), 1.5, 1.1),
            ((17.0, 5.5), (15.8, 2.2), 1.4, 1.0),
            ((13.0, 12.2), (15.8, 15.4), 1.7, 1.4),
            ((15.0, 17.6), (18.4, 21.6), 3.0, 2.2),
            ((18.4, 21.6), (23.8, 22.6), 2.2, 1.7),
            ((11.0, 17.2), (7.0, 19.4), 3.4, 2.6),
            ((7.2, 19.5), (3.6, 18.2), 2.6, 1.5),
        ],
        hop=(5.2, 24.8, 25.2, 1.5),
    ),
    "V2": Variant(
        key="V2",
        title="体块主导",
        ellipses=[
            ((13.2, 11.6), (5.6, 5.6), -10),
            ((15.0, 16.6), (4.2, 3.6), -4),
            ((19.4, 7.4), (3.4, 3.0), -10),
        ],
        tapers=[
            ((18.2, 9.4), (16.4, 12.2), 3.8, 4.2),
            ((21.2, 8.0), (24.6, 8.8), 3.0, 1.6),
            ((18.6, 5.0), (17.8, 2.2), 1.8, 1.3),
            ((17.0, 5.4), (15.8, 2.6), 1.7, 1.2),
            ((13.2, 12.0), (16.0, 15.2), 2.0, 1.7),
            ((14.8, 17.4), (18.0, 21.2), 3.4, 2.6),
            ((18.0, 21.2), (22.8, 22.2), 2.5, 1.9),
            ((11.0, 17.0), (7.4, 19.0), 3.8, 3.0),
            ((7.6, 19.2), (4.4, 18.4), 3.0, 1.9),
        ],
        hop=(5.6, 24.4, 25.4, 1.7),
    ),
    "V3": Variant(
        key="V3",
        title="拉伸主导",
        ellipses=[
            ((12.6, 11.8), (4.6, 5.8), -16),
            ((15.0, 16.4), (3.4, 3.4), -8),
            ((19.8, 7.2), (2.7, 2.8), -6),
        ],
        tapers=[
            ((18.4, 9.2), (16.4, 11.8), 3.0, 3.2),
            ((21.6, 7.8), (25.4, 7.6), 2.4, 1.0),
            ((19.0, 4.8), (18.6, 1.6), 1.4, 0.9),
            ((17.6, 5.0), (16.8, 2.0), 1.3, 0.9),
            ((12.6, 12.4), (16.4, 15.6), 1.6, 1.2),
            ((14.6, 17.2), (19.2, 21.2), 2.8, 2.0),
            ((19.2, 21.2), (25.4, 22.4), 2.0, 1.4),
            ((10.6, 17.2), (6.4, 18.6), 3.0, 2.2),
            ((6.6, 18.6), (3.0, 17.0), 2.2, 1.2),
        ],
        hop=(6.0, 23.6, 25.0, 1.3),
    ),
}


def taper_svg(p1, p2, w1, w2, color, alpha=None, steps=24):
    """锥形胶囊拆成一组同色圆：SVG 没有原生锥形描边。"""
    opacity = f' fill-opacity="{alpha}"' if alpha is not None else ""
    circles = []
    for i in range(steps + 1):
        t = i / steps
        x = p1[0] + (p2[0] - p1[0]) * t
        y = p1[1] + (p2[1] - p1[1]) * t
        r = (w1 + (w2 - w1) * t) / 2
        circles.append(
            f'<circle cx="{x:.2f}" cy="{y:.2f}" r="{r:.2f}" fill="{color}"{opacity}/>'
        )
    return "".join(circles)


def ellipse_svg(shape, color, scale):
    (cx, cy), (rx, ry), rot = shape
    cx, cy, rx, ry = cx * scale, cy * scale, rx * scale, ry * scale
    return (
        f'<ellipse cx="{cx:.2f}" cy="{cy:.2f}" rx="{rx:.2f}" ry="{ry:.2f}" '
        f'transform="rotate({rot} {cx:.2f} {cy:.2f})" fill="{color}"/>'
    )


DEFS = f"""<defs>
    <linearGradient id="bggrad" x1="0" y1="64" x2="0" y2="960" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="{BG_TOP}"/>
      <stop offset="1" stop-color="{BG_BOTTOM}"/>
    </linearGradient>
    <linearGradient id="topglow" x1="0" y1="0" x2="0" y2="200" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.10"/>
      <stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
    </linearGradient>
  </defs>"""


def raw_subject(v: Variant, scale: int) -> str:
    parts = [ellipse_svg(e, SUBJECT, scale) for e in v.ellipses]
    parts += [
        taper_svg((a[0] * scale, a[1] * scale), (b[0] * scale, b[1] * scale),
                  w1 * scale, w2 * scale, SUBJECT)
        for (a, b, w1, w2) in v.tapers
    ]
    return "\n  ".join(parts)


def raw_hop(v: Variant, scale: int, color=HOP, alpha=None) -> str:
    x1, x2, y, w = v.hop
    return taper_svg((x1 * scale, y * scale), (x2 * scale, y * scale),
                     w * scale, w * scale, color, alpha)


def svg_doc(body: str, defs: str = "") -> str:
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" '
        f'viewBox="0 0 1024 1024">\n  {defs}\n  {body}\n</svg>\n'
    )


def render(svg_text: str, dest: Path, size: int) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    svg_path = dest.with_suffix(".svg")
    svg_path.write_text(svg_text)
    subprocess.run(
        ["rsvg-convert", "-w", str(size), "-h", str(size), "-o", str(dest), str(svg_path)],
        check=True,
    )
    svg_path.unlink()


def measure(v: Variant) -> tuple:
    """量出「剪影 + 起跳线」的 bbox（与 1024 画布同坐标），用于计算适配变换。"""
    probe = OUT / "_probe" / f"{v.key}-probe.png"
    body = raw_subject(v, 32) + "\n  " + raw_hop(v, 32)
    render(svg_doc(body), probe, 1024)
    from PIL import Image

    bbox = Image.open(probe).convert("RGBA").split()[3].getbbox()
    probe.unlink()
    return bbox


def fit_transform(bbox, side=FIT_SIDE, center=FIT_CENTER) -> str:
    x0, y0, x1, y1 = bbox
    scale = side / max(x1 - x0, y1 - y0)
    tx = center[0] - (x0 + x1) / 2 * scale
    ty = center[1] - (y0 + y1) / 2 * scale
    return f'translate({tx:.2f} {ty:.2f}) scale({scale:.5f})'


def background_layer(v: Variant, transform: str) -> str:
    return (
        '<rect x="0" y="0" width="1024" height="1024" fill="url(#bggrad)"/>\n'
        '  <rect x="0" y="0" width="1024" height="200" fill="url(#topglow)"/>\n'
        f'  <g transform="{transform}">{raw_hop(v, 32, HOP, HOP_ALPHA)}</g>'
    )


def subject_layer(v: Variant, transform: str) -> str:
    return f'<g transform="{transform}">{raw_subject(v, 32)}</g>'


def compose(base: Path, key: str) -> None:
    for size in (1024, 32, 16):
        subprocess.run(
            ["magick", str(base / f"{key}-bg-{size}.png"),
             str(base / f"{key}-subject-{size}.png"),
             "-compose", "over", "-composite", str(base / f"{key}-{size}.png")],
            check=True,
        )


def contact_sheet() -> Path:
    """三联对比：1024 缩小看整体，32/16 用 point 放大看像素本色。"""
    tiles = []
    for key in VARIANTS:
        base = OUT / key
        for size in (1024, 32, 16):
            src = base / f"{key}-{size}.png"
            dst = base / f"{key}-{size}-tile.png"
            flt = "lanczos" if size == 1024 else "point"
            subprocess.run(["magick", str(src), "-filter", flt,
                            "-resize", "256x256", str(dst)], check=True)
            tiles.append(dst)
    sheet = OUT / "contact-sheet.png"
    subprocess.run(["magick", "montage", *map(str, tiles),
                    "-tile", "3x3", "-geometry", "264x264+8+8",
                    "-background", "#1c1c1e", str(sheet)], check=True)
    return sheet


def main() -> int:
    for v in VARIANTS.values():
        base = OUT / v.key
        transform = fit_transform(measure(v))
        for size in (1024, 32, 16):
            render(svg_doc(background_layer(v, transform), DEFS),
                   base / f"{v.key}-bg-{size}.png", size)
            render(svg_doc(subject_layer(v, transform)),
                   base / f"{v.key}-subject-{size}.png", size)
        compose(base, v.key)
        print(f"rendered {v.key} {v.title}  fit={transform}")
    print(f"contact sheet: {contact_sheet()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
