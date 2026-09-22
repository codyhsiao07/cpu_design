#!/usr/bin/env python3
"""Generate the CSR / Interrupt and FreeRTOS core-results diagram.

The SVG and HTML outputs have no runtime dependencies.  A PNG preview is
rendered when Chrome or Edge is available.
"""

from __future__ import annotations

import html
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = ROOT / "docs" / "01-architecture" / "diagrams"
SVG_PATH = OUT_DIR / "csr-interrupt-freertos-core-results.svg"
HTML_PATH = OUT_DIR / "csr-interrupt-freertos-core-results.html"
PNG_PATH = OUT_DIR / "csr-interrupt-freertos-core-results.png"

WIDTH = 1600
HEIGHT = 920


def rect(x: int, y: int, w: int, h: int, fill: str, stroke: str,
         radius: int = 14, stroke_width: int = 2, css_class: str = "") -> str:
    cls = f' class="{css_class}"' if css_class else ""
    return (
        f'<rect{cls} x="{x}" y="{y}" width="{w}" height="{h}" '
        f'rx="{radius}" fill="{fill}" stroke="{stroke}" '
        f'stroke-width="{stroke_width}"/>'
    )


def label(x: int, y: int, lines: list[str], size: int = 18,
          weight: int = 500, color: str = "#172033",
          anchor: str = "middle", gap: int | None = None,
          css_class: str = "") -> str:
    line_gap = gap if gap is not None else round(size * 1.35)
    cls = f' class="{css_class}"' if css_class else ""
    tspans = []
    for index, line in enumerate(lines):
        dy = 0 if index == 0 else line_gap
        tspans.append(
            f'<tspan x="{x}" dy="{dy}">{html.escape(line)}</tspan>'
        )
    return (
        f'<text{cls} x="{x}" y="{y}" text-anchor="{anchor}" '
        f'font-size="{size}" font-weight="{weight}" fill="{color}">'
        + "".join(tspans)
        + "</text>"
    )


def path(points: list[tuple[int, int]], color: str = "#253047",
         width: int = 2, dashed: bool = False, arrow: bool = True,
         css_class: str = "") -> str:
    commands = [f"M {points[0][0]} {points[0][1]}"]
    commands.extend(f"L {x} {y}" for x, y in points[1:])
    dash = ' stroke-dasharray="8 7"' if dashed else ""
    marker = ' marker-end="url(#arrow)"' if arrow else ""
    cls = f' class="{css_class}"' if css_class else ""
    return (
        f'<path{cls} d="{" ".join(commands)}" fill="none" '
        f'stroke="{color}" stroke-width="{width}"{dash}{marker}/>'
    )


def box(x: int, y: int, w: int, h: int, lines: list[str],
        fill: str, stroke: str, size: int = 17,
        css_class: str = "") -> str:
    total_height = size + (len(lines) - 1) * round(size * 1.35)
    first_baseline = y + (h - total_height) // 2 + size
    return (
        rect(x, y, w, h, fill, stroke, 12, 2, css_class)
        + label(x + w // 2, first_baseline, lines, size=size,
                css_class=css_class)
    )


def build_svg() -> str:
    pieces: list[str] = []
    add = pieces.append

    add(f'''<svg xmlns="http://www.w3.org/2000/svg" width="{WIDTH}" height="{HEIGHT}"
  viewBox="0 0 {WIDTH} {HEIGHT}" role="img"
  aria-labelledby="diagram-title diagram-desc">
<title id="diagram-title">CSR／Interrupt 與 FreeRTOS 核心成果系統流程圖</title>
<desc id="diagram-desc">同步例外、machine timer 與 UART 中斷進入 machine-mode trap，
經 FreeRTOS port 形成 1 kHz tick、搶占式排程、context switch、Task 與 Queue，
最後驅動 UART、VGA 多工展示並由 performance counters 觀察。</desc>
<defs>
  <marker id="arrow" markerWidth="10" markerHeight="10" refX="8" refY="3"
          orient="auto" markerUnits="strokeWidth">
    <path d="M0,0 L0,6 L9,3 z" fill="#253047"/>
  </marker>
  <filter id="shadow" x="-20%" y="-20%" width="140%" height="140%">
    <feDropShadow dx="0" dy="4" stdDeviation="7" flood-color="#0F172A"
                  flood-opacity="0.09"/>
  </filter>
  <style>
    text {{ font-family: "Microsoft JhengHei", "Noto Sans CJK TC", Arial, sans-serif; }}
    .panel {{ filter: url(#shadow); }}
    .stage {{ filter: url(#shadow); }}
  </style>
</defs>
<rect width="1600" height="920" fill="#F8FAFC"/>
''')

    add(label(800, 49, ["CSR／Interrupt 與 FreeRTOS"], size=34,
              weight=500, color="#10213D"))
    add(label(800, 82, ["核心成果區塊｜RV32IM FPGA SoC 系統流程"],
              size=17, weight=400, color="#5B667A"))

    # Three high-level sections.
    add(rect(28, 128, 330, 742, "#FFFFFF", "#7B8798", 18, 2, "panel"))
    add(rect(28, 128, 330, 54, "#F1F4F8", "#7B8798", 18, 2))
    add(label(193, 162, ["Trap／Interrupt 事件來源"], 19))

    add(rect(390, 102, 820, 790, "#F7FAFF", "#4F81D8", 20, 2, "panel"))
    add(rect(390, 102, 820, 54, "#EAF2FF", "#4F81D8", 20, 2))
    add(label(800, 137, ["FPGA SoC：Machine-mode Control 與 RTOS"], 19))

    add(rect(1242, 128, 330, 742, "#FFFFFF", "#E59B18", 18, 2, "panel"))
    add(rect(1242, 128, 330, 54, "#FFF7E6", "#E59B18", 18, 2))
    add(label(1407, 162, ["可觀察的核心成果"], 19))

    # Event sources.
    add(box(58, 226, 270, 104,
            ["同步例外", "Illegal／Misaligned／ECALL"],
            "#F2EEFF", "#8A63C5", 17, "stage"))
    add(box(58, 402, 270, 104,
            ["Machine Timer Interrupt", "mtime ≥ mtimecmp"],
            "#EAF7F2", "#4A9D7C", 17, "stage"))
    add(box(58, 578, 270, 104,
            ["UART RX", "Machine External Interrupt"],
            "#FFF5E6", "#E59B18", 17, "stage"))

    # CPU pipeline.
    add(rect(426, 183, 748, 153, "#FFFFFF", "#6C92D6", 24, 2))
    add(label(800, 213, ["RV32IM 五級 Pipeline Core"], 18))
    stage_x = [454, 562, 670, 778, 886, 994]
    stage_labels = ["PC", "IF", "ID", "EX", "MEM", "WB"]
    stage_fills = ["#F3EAF7", "#E8F1FE", "#E8F1FE", "#E8F1FE", "#E8F1FE", "#E8F1FE"]
    stage_strokes = ["#9B6CAA", "#6C92D6", "#6C92D6", "#6C92D6", "#6C92D6", "#6C92D6"]
    for x, name, fill, stroke in zip(stage_x, stage_labels, stage_fills, stage_strokes):
        width = 78
        add(box(x, 244, width, 58, [name], fill, stroke, 17, "stage"))
    for index in range(len(stage_x) - 1):
        add(path([(stage_x[index] + 78, 273), (stage_x[index + 1], 273)]))
    add(label(1111, 266, ["retire"], 14, 400, "#566176"))
    add(path([(1072, 273), (1143, 273)], color="#253047"))

    # CSR and trap control.
    add(rect(446, 361, 708, 159, "#FFF7F7", "#D76363", 16, 2, "stage"))
    add(label(800, 391, ["CSR／Machine-mode Trap"], 19, color="#8B2F3B"))
    add(box(468, 414, 204, 78,
            ["Machine CSR", "mstatus · mie · mtvec"],
            "#FFFFFF", "#D98B8B", 15))
    add(box(697, 414, 206, 78,
            ["Precise Trap", "mepc · mcause · mtval"],
            "#FFFFFF", "#D98B8B", 15))
    add(box(928, 414, 204, 78,
            ["Exception／mret", "mtvec ↔ mepc redirect"],
            "#FFFFFF", "#D98B8B", 15))
    add(path([(672, 453), (697, 453)]))
    add(path([(903, 453), (928, 453)]))
    add(label(800, 510, ["IRQ gate／priority：External  >  Software  >  Timer"],
              14, 400, "#6B3840"))

    # Pipeline-to-trap and mret return paths.
    add(path([(817, 302), (817, 361)], color="#D14F5C"))
    add(label(835, 342, ["exception"], 13, 400, "#9C3945", anchor="start"))
    add(path([(1030, 414), (1030, 329), (1086, 329), (1086, 302)],
             color="#D14F5C"))
    add(label(1044, 348, ["mret"], 13, 400, "#9C3945", anchor="start"))

    # FreeRTOS region.
    add(rect(426, 547, 748, 308, "#F2FBF8", "#3B9A7A", 20, 2, "stage"))
    add(label(800, 579, ["FreeRTOS Port／Kernel"], 19, color="#1F735D"))
    row_x = [450, 628, 806, 984]
    row_text = [
        ["Trap Handler", "mcause 分流"],
        ["FreeRTOS 1 kHz Tick", "xTaskIncrementTick"],
        ["Preemptive Scheduler", "選擇最高 priority"],
        ["Context Switch", "save／restore → mret"],
    ]
    for x, lines in zip(row_x, row_text):
        add(box(x, 602, 162, 82, lines, "#FFFFFF", "#58A98D", 14, "stage"))
    for index in range(3):
        add(path([(row_x[index] + 162, 643), (row_x[index + 1], 643)],
                 color="#236D5B"))

    add(box(530, 738, 162, 76, ["Task A", "Producer"],
            "#FFFFFF", "#58A98D", 15, "stage"))
    add(box(719, 738, 162, 76, ["Task／Queue", "IPC／blocking"],
            "#FFFFFF", "#58A98D", 15, "stage"))
    add(box(908, 738, 184, 76, ["Task B", "Renderer／Worker"],
            "#FFFFFF", "#58A98D", 15, "stage"))
    add(path([(692, 776), (719, 776)], color="#236D5B"))
    add(path([(881, 776), (908, 776)], color="#236D5B"))
    add(path([(887, 684), (887, 711), (611, 711), (611, 738)],
             color="#236D5B"))
    add(path([(1065, 684), (1065, 713), (1000, 713), (1000, 738)],
             color="#236D5B"))

    # Trap handler communicates with the machine trap block; context restore
    # returns execution to the CPU pipeline.
    add(path([(800, 492), (800, 535), (531, 535), (531, 602)],
             color="#D14F5C"))
    add(path([(1146, 643), (1184, 643), (1184, 316), (1108, 316), (1108, 302)],
             color="#236D5B"))

    # Connections from event sources into trap logic.
    add(path([(328, 278), (390, 278), (390, 440), (446, 440)], color="#8A63C5"))
    add(path([(328, 454), (374, 454), (374, 474), (446, 474)], color="#4A9D7C"))
    add(path([(328, 630), (382, 630), (382, 493), (446, 493)], color="#E59B18"))

    # Observable outcomes.
    add(box(1272, 226, 270, 112,
            ["UART Interrupt", "RX event → ISR／Task"],
            "#FFF9EE", "#E59B18", 17, "stage"))
    add(box(1272, 424, 270, 126,
            ["VGA Multi-task Demo", "Producer → Queue → Renderer", "獨立 Heartbeat Task"],
            "#FFF9EE", "#E59B18", 16, "stage"))
    add(box(1272, 646, 270, 126,
            ["Performance Counters", "cycle／instret／stall", "exception／interrupt／flush"],
            "#FFF9EE", "#E59B18", 16, "stage"))

    add(path([(1154, 470), (1220, 470), (1220, 282), (1272, 282)], color="#E59B18"))
    add(path([(1092, 776), (1202, 776), (1202, 487), (1272, 487)], color="#E59B18"))
    add(path([(1143, 273), (1226, 273), (1226, 692), (1272, 692)],
             color="#58657A", dashed=True))
    add(path([(1154, 497), (1192, 497), (1192, 729), (1272, 729)],
             color="#58657A", dashed=True))

    # Compact visual legend.
    add(path([(54, 842), (96, 842)], color="#253047"))
    add(label(108, 848, ["控制／資料流程"], 13, 400, "#667085", anchor="start"))
    add(path([(214, 842), (256, 842)], color="#58657A", dashed=True))
    add(label(268, 848, ["觀測事件"], 13, 400, "#667085", anchor="start"))

    add("</svg>\n")
    return "".join(pieces)


def build_html(svg: str) -> str:
    return f'''<!doctype html>
<html lang="zh-Hant">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>CSR／Interrupt 與 FreeRTOS 核心成果</title>
  <style>
    html, body {{ margin: 0; background: #f8fafc; }}
    main {{ display: grid; place-items: start center; min-height: 100vh; }}
    svg {{ display: block; width: min(100%, 1600px); height: auto; }}
  </style>
</head>
<body>
  <main>{svg}</main>
</body>
</html>
'''


def find_browser() -> Path | None:
    candidates = (
        Path(r"C:\Program Files\Google\Chrome\Application\chrome.exe"),
        Path(r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"),
        Path(r"C:\Program Files\Microsoft\Edge\Application\msedge.exe"),
        Path(r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"),
    )
    return next((path for path in candidates if path.exists()), None)


def render_png(browser: Path) -> None:
    command = [
        str(browser),
        "--headless=new",
        "--disable-gpu",
        "--hide-scrollbars",
        "--force-device-scale-factor=1",
        f"--window-size={WIDTH},{HEIGHT}",
        f"--screenshot={PNG_PATH}",
        HTML_PATH.as_uri(),
    ]
    subprocess.run(command, check=True, stdout=subprocess.PIPE,
                   stderr=subprocess.STDOUT, timeout=30)


def main() -> int:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    svg = build_svg()
    SVG_PATH.write_text(svg, encoding="utf-8")
    HTML_PATH.write_text(build_html(svg), encoding="utf-8")

    browser = find_browser()
    if browser is not None:
        render_png(browser)

    print(f"SVG:  {SVG_PATH}")
    print(f"HTML: {HTML_PATH}")
    if PNG_PATH.exists():
        print(f"PNG:  {PNG_PATH}")
    else:
        print("PNG:  skipped (Chrome/Edge not found)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
