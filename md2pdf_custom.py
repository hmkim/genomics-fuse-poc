#!/usr/bin/env python3
"""Convert REPORT.md to a well-styled PDF using markdown + weasyprint."""

import os
import markdown
from weasyprint import HTML

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
MD_PATH = os.path.join(SCRIPT_DIR, "REPORT.md")
PDF_PATH = os.path.join(SCRIPT_DIR, "REPORT.pdf")

CSS = """
@page {
    size: A4;
    margin: 18mm 14mm 20mm 14mm;
    @bottom-center {
        content: counter(page) " / " counter(pages);
        font-size: 9pt;
        color: #888;
        font-family: 'Noto Sans KR', 'Malgun Gothic', sans-serif;
    }
}

body {
    font-family: 'Noto Sans KR', 'Malgun Gothic', 'Apple SD Gothic Neo', sans-serif;
    font-size: 10.5pt;
    line-height: 1.65;
    color: #1a1a2e;
    max-width: 100%;
}

h1 {
    font-size: 22pt;
    color: #0D1B2A;
    border-bottom: 3px solid #BEE9E8;
    padding-bottom: 8px;
    margin-top: 30px;
    page-break-before: auto;
}

h2 {
    font-size: 16pt;
    color: #1B4965;
    border-bottom: 2px solid #CAE9FF;
    padding-bottom: 5px;
    margin-top: 25px;
    page-break-before: auto;
    page-break-after: avoid;
}

h3 {
    font-size: 13pt;
    color: #2C7DA0;
    margin-top: 18px;
    page-break-after: avoid;
}

h4 {
    font-size: 11.5pt;
    color: #468FAF;
    margin-top: 14px;
    page-break-after: avoid;
}

p {
    margin-bottom: 8px;
    text-align: justify;
    orphans: 3;
    widows: 3;
}

strong {
    color: #0D1B2A;
}

/* Tables */
table {
    border-collapse: collapse;
    width: 100%;
    margin: 12px 0 16px 0;
    font-size: 8.5pt;
    page-break-inside: auto;
    table-layout: auto;
    word-wrap: break-word;
}

thead {
    display: table-header-group;
}

tr {
    page-break-inside: avoid;
    page-break-after: auto;
}

th {
    background-color: #0D1B2A;
    color: #FFFFFF;
    font-weight: bold;
    padding: 6px 6px;
    text-align: left;
    border: 1px solid #0D1B2A;
    white-space: normal;
    word-wrap: break-word;
    font-size: 8pt;
}

td {
    padding: 5px 6px;
    border: 1px solid #D0D5DD;
    vertical-align: top;
    white-space: normal;
    word-wrap: break-word;
}

tr:nth-child(even) td {
    background-color: #F7F9FC;
}

tr:nth-child(odd) td {
    background-color: #FFFFFF;
}

/* Right-align numeric columns */
td:last-child, th:last-child {
    text-align: right;
}

/* Special styling for comparison result tables */
tr td:first-child {
    font-weight: 500;
}

/* Code blocks */
code {
    font-family: 'Noto Sans Mono', 'D2Coding', 'Consolas', 'DejaVu Sans Mono', monospace;
    font-size: 9pt;
    background-color: #F0F4F8;
    padding: 1px 4px;
    border-radius: 3px;
    color: #1B4965;
}

pre {
    background-color: #0D1B2A;
    color: #BEE9E8;
    padding: 14px 16px;
    border-radius: 6px;
    font-size: 7.5pt;
    line-height: 1.45;
    overflow-x: hidden;
    overflow-wrap: break-word;
    white-space: pre-wrap;
    page-break-inside: avoid;
    margin: 10px 0 14px 0;
}

pre code {
    font-family: 'Noto Sans Mono', 'D2Coding', 'Consolas', 'DejaVu Sans Mono', monospace;
    background-color: transparent;
    color: inherit;
    padding: 0;
    font-size: inherit;
    white-space: pre-wrap;
    word-wrap: break-word;
}

/* Blockquote */
blockquote {
    border-left: 4px solid #2C7DA0;
    margin: 12px 0;
    padding: 8px 16px;
    background-color: #EBF5FB;
    color: #1B4965;
    font-size: 10pt;
    page-break-inside: avoid;
}

blockquote p {
    margin: 4px 0;
}

/* Lists */
ul, ol {
    margin: 6px 0 10px 0;
    padding-left: 24px;
}

li {
    margin-bottom: 3px;
}

/* Horizontal rule */
hr {
    border: none;
    border-top: 1px solid #D0D5DD;
    margin: 20px 0;
}

/* Links */
a {
    color: #2C7DA0;
    text-decoration: none;
}
"""

def main():
    with open(MD_PATH, "r", encoding="utf-8") as f:
        md_text = f.read()

    # Convert markdown to HTML with table support
    html_body = markdown.markdown(
        md_text,
        extensions=["tables", "fenced_code", "toc", "nl2br"],
        extension_configs={
            "toc": {"permalink": False},
        },
    )

    # Wrap in full HTML document
    html_doc = f"""<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="utf-8">
    <style>{CSS}</style>
</head>
<body>
{html_body}
</body>
</html>"""

    # Generate PDF
    HTML(string=html_doc).write_pdf(PDF_PATH)
    print(f"PDF generated: {PDF_PATH}")


if __name__ == "__main__":
    main()
