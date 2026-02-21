#!/usr/bin/env python3
"""Convert REPORT.md to styled Korean PDF using markdown + weasyprint."""

import os
import sys
import markdown
from weasyprint import HTML

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(SCRIPT_DIR)
INPUT = os.path.join(PROJECT_DIR, "REPORT.md")
OUTPUT = os.path.join(PROJECT_DIR, "REPORT.pdf")

CSS = """
@page {
    size: A4;
    margin: 20mm 18mm 20mm 18mm;
    @top-center {
        content: "CRAM + AWS Mountpoint S3 PoC 결과 보고서";
        font-size: 8pt;
        color: #888;
        font-family: 'Noto Sans CJK KR', sans-serif;
    }
    @bottom-center {
        content: counter(page) " / " counter(pages);
        font-size: 8pt;
        color: #888;
        font-family: 'Noto Sans CJK KR', sans-serif;
    }
}

body {
    font-family: 'Noto Sans CJK KR', 'Noto Sans', sans-serif;
    font-size: 9.5pt;
    line-height: 1.6;
    color: #1a1a1a;
}

h1 {
    font-size: 18pt;
    font-weight: 700;
    color: #0d1b2a;
    border-bottom: 3px solid #1b4965;
    padding-bottom: 6pt;
    margin-top: 20pt;
    margin-bottom: 10pt;
    page-break-before: auto;
}

h2 {
    font-size: 14pt;
    font-weight: 700;
    color: #1b4965;
    border-bottom: 1.5px solid #bee9e8;
    padding-bottom: 4pt;
    margin-top: 18pt;
    margin-bottom: 8pt;
}

h3 {
    font-size: 11pt;
    font-weight: 700;
    color: #2c7da0;
    margin-top: 14pt;
    margin-bottom: 6pt;
}

p {
    margin-bottom: 6pt;
    text-align: justify;
}

table {
    width: 100%;
    border-collapse: collapse;
    margin: 8pt 0 12pt 0;
    font-size: 8.5pt;
    page-break-inside: avoid;
}

thead {
    background-color: #1b4965;
    color: white;
}

th {
    padding: 5pt 6pt;
    text-align: left;
    font-weight: 600;
    border: 1px solid #1b4965;
}

td {
    padding: 4pt 6pt;
    border: 1px solid #ccc;
    vertical-align: top;
}

tbody tr:nth-child(even) {
    background-color: #f0f7fa;
}

tbody tr:hover {
    background-color: #e0eff5;
}

code {
    font-family: 'Noto Sans Mono CJK KR', 'Source Code Pro', 'Consolas', monospace;
    font-size: 8pt;
    background-color: #f4f4f4;
    padding: 1pt 3pt;
    border-radius: 2pt;
    color: #c7254e;
}

pre {
    background-color: #f8f8f8;
    border: 1px solid #ddd;
    border-left: 3px solid #1b4965;
    padding: 8pt 10pt;
    font-size: 7.5pt;
    line-height: 1.45;
    overflow-x: auto;
    white-space: pre-wrap;
    word-wrap: break-word;
    page-break-inside: avoid;
    margin: 6pt 0 10pt 0;
}

pre code {
    background: none;
    padding: 0;
    color: #333;
    font-size: 7.5pt;
}

blockquote {
    border-left: 3px solid #bee9e8;
    margin: 8pt 0;
    padding: 4pt 12pt;
    color: #555;
    background-color: #fafcfd;
}

strong {
    font-weight: 700;
    color: #0d1b2a;
}

ul, ol {
    margin: 4pt 0 8pt 0;
    padding-left: 18pt;
}

li {
    margin-bottom: 2pt;
}

hr {
    border: none;
    border-top: 1px solid #ccc;
    margin: 14pt 0;
}

a {
    color: #2c7da0;
    text-decoration: none;
}
"""

with open(INPUT, "r", encoding="utf-8") as f:
    md_text = f.read()

# Convert markdown to HTML
html_body = markdown.markdown(
    md_text,
    extensions=["tables", "fenced_code", "codehilite", "toc"],
    extension_configs={
        "codehilite": {"css_class": "highlight", "guess_lang": False}
    },
)

full_html = f"""<!DOCTYPE html>
<html lang="ko">
<head>
<meta charset="utf-8">
<style>{CSS}</style>
</head>
<body>
{html_body}
</body>
</html>"""

HTML(string=full_html).write_pdf(OUTPUT)
print(f"PDF generated: {OUTPUT}")
