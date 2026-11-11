#!/usr/bin/env python3
"""Driver documentation generation (no Node, no browser).

Subcommands:
  docs.py md2html  <input.md>   <output-dir>   # styled HTML -> <output-dir>/index.html
  docs.py html2pdf <input.html> <output.pdf>   # HTML -> PDF
  docs.py readme   <input.md>   <output.md>    # driver docs -> repo README.md

Every driver's documentation is an INTERACTIVE MANUAL: one self-contained
index.html (styles, script and screenshots inside it, so it works in Composer's
documentation viewer and from a file) with a contents list that follows the
page, search, walkthroughs that keep their place, and screenshots that
enlarge. Without script (the PDF, a locked viewer) it is the plain document.

Authoring, in a driver's www/documentation/index.md:
  - a screenshot: `![What it shows](images/properties.jpg)` on its own line.
    Files live in www/documentation/images/, are embedded in the page, and are
    left out of the shipped folder. The alt text is the caption.
  - a walkthrough: `<!-- walkthrough: Title -->` on the line before a numbered
    list. Each top-level item becomes a step the reader ticks.
  - a drawn chat (an illustration, never passed off as a screenshot):
    `<div class="chat"><p class="me">…</p><p class="them">…</p></div>`.

Pipeline:
  - Markdown -> HTML via markdown-it-py (GitHub-flavored, HTML passthrough),
    with syntax highlighting by Pygments. Wrapped in a vendored github-markdown
    stylesheet plus print rules and written to the driver's www/documentation
    (shipped in the driver and shown by Control4's documentation viewer).
  - HTML -> PDF via WeasyPrint, a CSS Paged Media engine. Page size/margins come
    from the @page rule; pagination is automatic and content-aware (headings
    kept with their content, tables/code never split, orphan/widow control), so
    no hand-placed page-break markers are required.
  - README is the driver docs markdown with <style> blocks stripped, then
    normalized with mdformat.
"""

import base64
import html as html_lib
import mimetypes
import re
import shutil
import sys
from pathlib import Path

from markdown_it import MarkdownIt
from mdit_py_plugins.anchors import anchors_plugin
from pygments import highlight
from pygments.formatters import HtmlFormatter
from pygments.lexers import get_lexer_by_name, guess_lexer
from pygments.util import ClassNotFound

TOOLS_DIR = Path(__file__).resolve().parent
GITHUB_CSS = (TOOLS_DIR / "github-markdown.css").read_text(encoding="utf-8")
MANUAL_CSS = (TOOLS_DIR / "manual.css").read_text(encoding="utf-8")
MANUAL_JS = (TOOLS_DIR / "manual.js").read_text(encoding="utf-8")
# Pygments highlight CSS, scoped under .highlight (its default wrapper class).
PYGMENTS_CSS = HtmlFormatter(style="default").get_style_defs(".highlight")

# Screen layout matches the Control4 documentation viewer; print layout matches
# the previous electron-pdf output (Letter, 0.4in margins) and adds automatic
# content-aware pagination.
LAYOUT_CSS = """
.markdown-body { box-sizing: border-box; min-width: 200px; max-width: 980px; margin: 0 auto; padding: 45px; }
@media (max-width: 767px) { .markdown-body { padding: 15px; } }
/* github-markdown-css ends its font stack with color-emoji fonts. On Linux
   (CI) fontconfig matches digit codepoints to the emoji font (it carries keycap
   digits), and WeasyPrint can't render color-emoji as text, so digits vanish.
   Override with a text-only stack that resolves on Linux (DejaVu/Noto) and mac.
   Symbola (monochrome) sits last so symbol chars the docs use in tables/callouts
   (check/cross/warning) render as glyphs instead of blank color-emoji boxes. */
.markdown-body {
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, "Liberation Sans", "DejaVu Sans", "Noto Sans", "Symbola", sans-serif;
}
.markdown-body code, .markdown-body pre, .markdown-body tt {
  font-family: "SFMono-Regular", Consolas, "Liberation Mono", "DejaVu Sans Mono", Menlo, monospace;
}
/* The docs index is authored in a small-font <div>. Preprocessor #ifdef blocks
   can leave a blank line in the list for some distributions, which makes markdown
   render it "loose": each <li> wrapped in a <p> whose paragraph margins add
   large vertical gaps. Keep the index compact regardless. */
.markdown-body div[style*="font-size"] li > p { margin: 0; }
/* The browser default 3rd-level (and deeper) list marker is a heavy full-size
   black square that reads as clunky next to the level 1/2 disc & circle. Use a
   small square instead so deep index nesting stays clean. */
.markdown-body ul ul ul { list-style-type: "▪ "; }
@page { size: Letter; margin: 0.4in; }
@media print {
  .markdown-body { max-width: none; padding: 0 45px; margin: 0; }
  h1, h2, h3, h4, h5, h6 { break-after: avoid; }
  /* Keep code, images and individual rows intact, but let long tables split
     across pages (WeasyPrint repeats <thead>). Pinning the whole table with
     break-inside:avoid strands big blank gaps and orphans the heading above it. */
  pre, figure, tr { break-inside: avoid; }
  p, li { orphans: 3; widows: 3; }
}
"""


def _highlight(code: str, lang: str, _attrs) -> str:
    try:
        lexer = get_lexer_by_name(lang) if lang else guess_lexer(code)
    except ClassNotFound:
        lexer = None
    if lexer is None:
        # No known lexer: return empty so markdown-it emits its default escaped
        # <pre><code> block.
        return ""
    return highlight(code, lexer, HtmlFormatter(nowrap=False))


def _make_md() -> MarkdownIt:
    md = MarkdownIt(
        "gfm-like", {"html": True, "linkify": True, "highlight": _highlight}
    )
    md.use(anchors_plugin, max_level=6, permalink=False)
    return md


_IMG_TAG_RE = re.compile(r"<img\b[^>]*>", re.I)
_IMG_DIM_RE = re.compile(r'\s(width|height)\s*=\s*"(\d+)"', re.I)


def _img_dims_to_style(html: str) -> str:
    """Move presentational width/height attrs on <img> into inline styles.

    WeasyPrint ignores the HTML width/height *attributes* on images (it uses the
    intrinsic pixel size), so authored sizes like width="300" are lost in the
    PDF: the image renders full-bleed and only max-width:100% reins it in.
    WeasyPrint does honor inline CSS, so rewrite `width="N"` -> `width: Npx`.
    Browsers honor both forms, so the on-screen docs are unaffected.
    """

    def repl(m: "re.Match[str]") -> str:
        tag = m.group(0)
        dims = _IMG_DIM_RE.findall(tag)
        if not dims:
            return tag
        tag = _IMG_DIM_RE.sub("", tag)
        css = "".join(f"{name.lower()}: {value}px; " for name, value in dims)
        style_at = re.search(r'\sstyle\s*=\s*"', tag, re.I)
        if style_at:
            i = style_at.end()
            return tag[:i] + css + tag[i:]
        return re.sub(r"^<img\b", f'<img style="{css.strip()}"', tag, flags=re.I)

    return _IMG_TAG_RE.sub(repl, html)


_ALIGN_TAG_RE = re.compile(
    r'<(?!img\b|/)[a-zA-Z][\w-]*\b[^>]*\balign\s*=\s*"[^"]*"[^>]*>', re.I
)
_ALIGN_ATTR_RE = re.compile(r'\salign\s*=\s*"(left|right|center|justify)"', re.I)


def _align_to_style(html: str) -> str:
    """Move the presentational `align` attribute into an inline text-align style.

    Like width/height, WeasyPrint ignores the `align` attribute, so authored
    `<p align="center">` blocks (centered headers, logos, captions) render
    left-aligned in the PDF. Rewrite to `text-align`, which WeasyPrint honors.
    `<img align>` (float) is left alone, since the docs don't use it.
    """

    def repl(m: "re.Match[str]") -> str:
        tag = m.group(0)
        am = _ALIGN_ATTR_RE.search(tag)
        if not am:
            return tag
        tag = _ALIGN_ATTR_RE.sub("", tag)
        css = f"text-align: {am.group(1).lower()};"
        style_at = re.search(r'\sstyle\s*=\s*"', tag, re.I)
        if style_at:
            i = style_at.end()
            return tag[:i] + css + " " + tag[i:]
        return re.sub(r"^(<[a-zA-Z][\w-]*)", rf'\1 style="{css}"', tag, flags=re.I)

    return _ALIGN_TAG_RE.sub(repl, html)


_STATUS_SYMBOLS = {
    "✅": '<span style="color:#1a7f37">✓</span>',  # ✅ -> green ✓
    "❌": '<span style="color:#cf222e">✗</span>',  # ❌ -> red ✗
}
# ⚠ optionally followed by the emoji-presentation selector U+FE0F.
_WARN_RE = re.compile("⚠️?")


def _status_symbols(html: str) -> str:
    """Render status emoji as text glyphs so the PDF shows them legibly.

    ✅/❌ carry default *emoji presentation* and ⚠️ an explicit emoji selector
    (U+FE0F), so the shaper forces a color-emoji font, which WeasyPrint can't
    rasterize, collapsing them to illegible specks. Map to text-presentation
    glyphs (✓ ✗ ⚠, present in DejaVu/Symbola) with GitHub-style semantic colors;
    browsers render these the same, so the Control4 viewer stays consistent.
    """
    for emoji, replacement in _STATUS_SYMBOLS.items():
        html = html.replace(emoji, replacement)
    return _WARN_RE.sub('<span style="color:#9a6700">⚠</span>', html)


_PAGE_BREAK_RE = re.compile(r"<div\b[^>]*\bpage-break[^>]*>\s*</div>\s*", re.I)


def _drop_manual_page_breaks(html: str) -> str:
    """Remove hand-placed page-break separators.

    Docs authored `<div style="page-break-after: always"></div>` to force breaks
    at fixed spots. Pagination is now automatic and content-aware (headings kept
    with their content, rows/images/code never split, tables split with a
    repeated header), so these hard breaks only fight the layout. Drop them.
    """
    return _PAGE_BREAK_RE.sub("", html)


_WALKTHROUGH_RE = re.compile(
    r"<!--\s*walkthrough(?:\s*:\s*(.*?))?\s*-->\s*<ol>", re.I | re.S
)
_SHOT_RE = re.compile(r"<p>\s*(<img\b[^>]*>)\s*</p>", re.I)
_SRC_RE = re.compile(r'\bsrc\s*=\s*"([^"]+)"', re.I)
_ALT_RE = re.compile(r'\balt\s*=\s*"([^"]*)"', re.I)
_H1_RE = re.compile(r"<h1\b[^>]*>(.*?)</h1>", re.I | re.S)


def _walkthroughs(html: str) -> str:
    """`<!-- walkthrough: Title -->` before a numbered list marks its steps."""

    def repl(m: "re.Match[str]") -> str:
        title = html_lib.escape((m.group(1) or "Walkthrough").strip(), quote=True)
        return f'<ol class="walkthrough" data-title="{title}">'

    return _WALKTHROUGH_RE.sub(repl, html)


def _embed_images(html: str, base_dir: Path) -> tuple[str, set[Path]]:
    """Inline local images as data URIs, so the manual is one file.

    Returns the HTML and the files that were inlined. A remote image, or a
    path that is not a file under the documentation folder, is left alone.
    """
    used: set[Path] = set()
    root = base_dir.resolve()

    def repl(m: "re.Match[str]") -> str:
        tag = m.group(0)
        src = _SRC_RE.search(tag)
        if not src or re.match(r"^(?:[a-z]+:|//|#)", src.group(1), re.I):
            return tag
        path = (base_dir / src.group(1)).resolve()
        if root not in path.parents or not path.is_file():
            return tag
        mime = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
        data = base64.b64encode(path.read_bytes()).decode("ascii")
        used.add(path)
        return tag[: src.start(1)] + f"data:{mime};base64,{data}" + tag[src.end(1) :]

    return _IMG_TAG_RE.sub(repl, html), used


def _figures(html: str) -> str:
    """An image alone in a paragraph is a screenshot: a figure with a caption."""

    def repl(m: "re.Match[str]") -> str:
        tag = m.group(1)
        alt = _ALT_RE.search(tag)
        caption = alt.group(1).strip() if alt else ""
        figcaption = f"<figcaption>{caption}</figcaption>" if caption else ""
        return f'<figure class="shot">{tag}{figcaption}</figure>'

    return _SHOT_RE.sub(repl, html)


def md2html(input_path: Path, output_dir: Path) -> None:
    source = input_path.read_text(encoding="utf-8")
    body = _drop_manual_page_breaks(
        _status_symbols(_align_to_style(_img_dims_to_style(_make_md().render(source))))
    )
    body = _walkthroughs(body)
    body, embedded = _embed_images(body, input_path.parent)
    body = _figures(body)
    h1 = _H1_RE.search(body)
    title = re.sub(r"<[^>]+>", "", h1.group(1)).strip() if h1 else input_path.stem
    # The script sits at the end of the body, so the document is complete
    # before it runs, and is the last thing a viewer without script ignores.
    script = MANUAL_JS.replace("</script", "<\\/script")
    html = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html_lib.escape(title)}</title>
<style>
{GITHUB_CSS}
{PYGMENTS_CSS}
{LAYOUT_CSS}
{MANUAL_CSS}
</style>
</head>
<body>
<main class="markdown-body">
{body}
</main>
<script>
{script}
</script>
</body>
</html>
"""
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "index.html").write_text(html, encoding="utf-8")
    # The screenshots are inside the page now: do not ship them twice. Only a
    # build copy is ever touched (the Makefile runs this under build/), never
    # the sources in drivers/.
    if (
        output_dir.resolve() == input_path.parent.resolve()
        and "build" in output_dir.resolve().parts
    ):
        images = output_dir / "images"
        if images.is_dir() and all(
            p in embedded for p in images.rglob("*") if p.is_file()
        ):
            shutil.rmtree(images)


def html2pdf(input_path: Path, output_path: Path) -> None:
    # Imported lazily so md2html works on machines without WeasyPrint's native
    # libs (e.g. HTML-only preview).
    from weasyprint import HTML

    HTML(filename=str(input_path)).write_pdf(str(output_path))


def readme(input_path: Path, output_path: Path) -> None:
    import mdformat

    text = input_path.read_text(encoding="utf-8")
    # Strip <style> blocks (screen-only chrome), then normalize.
    text = re.sub(r"<style\b[^>]*>.*?</style>", "", text, flags=re.S | re.I)
    text = mdformat.text(text, options={"wrap": 80}, extensions={"gfm"})
    output_path.write_text(text, encoding="utf-8")


_COMMANDS = {"md2html": md2html, "html2pdf": html2pdf, "readme": readme}


def main() -> int:
    if len(sys.argv) != 4 or sys.argv[1] not in _COMMANDS:
        print(__doc__, file=sys.stderr)
        return 1
    _COMMANDS[sys.argv[1]](Path(sys.argv[2]).resolve(), Path(sys.argv[3]).resolve())
    return 0


if __name__ == "__main__":
    sys.exit(main())
