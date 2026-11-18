"""Build a document tree from Amazon Textract output.

Input: the Block list from Textract AnalyzeDocument / GetDocumentAnalysis run
with FeatureTypes=["LAYOUT", "TABLES"].

Output: (tree, sections)
  * tree     - nested list of nodes: {node_id, number, title, level,
               page_start, children, has_text}. Summaries and keywords are
               added later by the summarizer step.
  * sections - {node_id: {"title", "text", "pages"}} for every node that has
               its own text. These become the payload documents.

Heading levels normally come from the manual's own numbering ("4", "4.4", "4.4.1"),
which is far more reliable than font size. Unnumbered headings are kept as
inline sub-headings inside the current section rather than new nodes. When a
document has no numbered headings, each page becomes a section using its first
layout title or section header. This fallback supports slide decks and reports
without inventing a hierarchy that is not present in the source.

Pure Python, no AWS dependencies, so it is unit-testable offline.
"""

import re

NUMBERED_HEADING = re.compile(r"^\s*(\d{1,2}(?:\.\d{1,2}){0,4})\.?\s+(\S.*?)\s*$")
TOC_LINE = re.compile(r"(\.{4,}|\s{2,})\s*\d{1,4}\s*$")
HEADING_TYPES = {"LAYOUT_TITLE", "LAYOUT_SECTION_HEADER"}
SKIP_TYPES = {"LAYOUT_HEADER", "LAYOUT_FOOTER", "LAYOUT_PAGE_NUMBER"}
TEXT_TYPES = {"LAYOUT_TEXT", "LAYOUT_LIST", "LAYOUT_KEY_VALUE", "LAYOUT_FIGURE"}
FRONT_ID = "S_0"
MIN_FIGURE_AREA = 0.01  # skip icons/logos smaller than 1% of the page


def node_id_for(number):
    return "S_" + number.replace(".", "_")


def _child_ids(block, rel_type="CHILD"):
    for rel in block.get("Relationships", []) or []:
        if rel.get("Type") == rel_type:
            return rel.get("Ids", [])
    return []


def _text_of(block, by_id):
    """Text for a LAYOUT block: its child LINE blocks joined in order."""
    lines = []
    for cid in _child_ids(block):
        child = by_id.get(cid)
        if child and child.get("BlockType") == "LINE":
            lines.append(child.get("Text", ""))
    return "\n".join(t for t in lines if t.strip())


def _render_table(table, by_id):
    """Render a TABLE block as pipe-separated rows so values stay aligned."""
    cells = {}
    for cid in _child_ids(table):
        cell = by_id.get(cid)
        if not cell or cell.get("BlockType") not in ("CELL", "MERGED_CELL"):
            continue
        words = [by_id[w].get("Text", "") for w in _child_ids(cell) if w in by_id]
        cells[(cell.get("RowIndex", 0), cell.get("ColumnIndex", 0))] = " ".join(words)
    if not cells:
        return ""
    rows = sorted({r for r, _ in cells})
    cols = sorted({c for _, c in cells})
    return "\n".join(
        " | ".join(cells.get((r, c), "") for c in cols) for r in rows
    )


def _tables_by_page(blocks, by_id):
    """TABLE blocks per page, top to bottom, rendered to text."""
    out = {}
    for b in blocks:
        if b.get("BlockType") == "TABLE":
            top = b.get("Geometry", {}).get("BoundingBox", {}).get("Top", 0)
            out.setdefault(b.get("Page", 1), []).append((top, _render_table(b, by_id)))
    return {p: [t for _, t in sorted(v)] for p, v in out.items()}


def _parse_heading(text):
    """Return (number, title) for a numbered heading, else None.

    Lines are joined first because some vendors (SEW) put the number and the
    title on separate lines: "4.4" / "Tightening torques".
    """
    first = " ".join(line.strip() for line in text.strip().splitlines() if line.strip())
    if TOC_LINE.search(first):
        return None  # table-of-contents entry, not a real heading
    m = NUMBERED_HEADING.match(first)
    if not m:
        return None
    return m.group(1), m.group(2)


def _build_page_tree(blocks, by_id, tables):
    """Build a one-level page tree for documents without numbered headings.

    The first layout title or section header on each page names the section.
    Later headings stay inside that page's text. Figures remain attached to the
    page where they appeared, preserving the source document's actual structure.
    """
    page_titles = {}
    texts = {}
    pages_seen = set()
    figures = {}
    table_cursor = {}

    for b in blocks:
        btype = b.get("BlockType", "")
        if not btype.startswith("LAYOUT_") or btype in SKIP_TYPES:
            continue
        page = b.get("Page", 1)
        pages_seen.add(page)
        nid = f"P_{page}"

        if btype == "LAYOUT_FIGURE":
            bb = b.get("Geometry", {}).get("BoundingBox", {})
            if bb.get("Width", 0) * bb.get("Height", 0) >= MIN_FIGURE_AREA:
                figures.setdefault(nid, []).append({
                    "page": page,
                    "bbox": {k: round(bb.get(k, 0), 4)
                             for k in ("Left", "Top", "Width", "Height")},
                })

        if btype == "LAYOUT_TABLE":
            idx = table_cursor.get(page, 0)
            page_tables = tables.get(page, [])
            text = page_tables[idx] if idx < len(page_tables) else _text_of(b, by_id)
            table_cursor[page] = idx + 1
        else:
            text = _text_of(b, by_id)
        if not text.strip():
            continue

        if btype in HEADING_TYPES:
            heading = " ".join(line.strip() for line in text.splitlines() if line.strip())
            if page not in page_titles:
                page_titles[page] = heading
            elif heading != page_titles[page]:
                texts.setdefault(nid, []).append(f"## {heading}")
            continue

        if btype in TEXT_TYPES or btype == "LAYOUT_TABLE":
            texts.setdefault(nid, []).append(text.strip())

    tree, sections = [], {}
    for page in sorted(pages_seen):
        nid = f"P_{page}"
        title = page_titles.get(page, f"Page {page}")
        tree.append({
            "node_id": nid,
            "number": str(page),
            "title": title,
            "level": 1,
            "page_start": page,
            "children": [],
        })
        sections[nid] = {
            "title": title,
            "text": "\n".join(texts.get(nid, [])),
            "pages": [page],
            "figures": figures.get(nid, []),
        }
    return tree, sections


def build_tree(blocks):
    by_id = {b["Id"]: b for b in blocks if "Id" in b}
    tables = _tables_by_page(blocks, by_id)

    has_numbered_headings = any(
        b.get("BlockType") in HEADING_TYPES and _parse_heading(_text_of(b, by_id))
        for b in blocks
    )
    if not has_numbered_headings:
        return _build_page_tree(blocks, by_id, tables)

    table_cursor = {}

    nodes = {}  # number -> node
    order = []  # numbers in first-seen order
    texts = {}  # node_id -> list of text chunks
    pages = {}  # node_id -> set of pages
    figures = {}  # node_id -> [{page, bbox}]
    current = FRONT_ID

    def ensure(number, title, page):
        if number in nodes:
            return nodes[number]
        parent = number.rsplit(".", 1)[0] if "." in number else None
        if parent and parent not in nodes:
            ensure(parent, f"Section {parent}", page)
        node = {
            "node_id": node_id_for(number),
            "number": number,
            "title": f"{number} {title}",
            "level": number.count(".") + 1,
            "page_start": page,
            "parent": parent,
        }
        nodes[number] = node
        order.append(number)
        return node

    for b in blocks:
        btype = b.get("BlockType", "")
        if not btype.startswith("LAYOUT_") or btype in SKIP_TYPES:
            continue
        page = b.get("Page", 1)

        if btype == "LAYOUT_FIGURE":
            bb = b.get("Geometry", {}).get("BoundingBox", {})
            if bb.get("Width", 0) * bb.get("Height", 0) >= MIN_FIGURE_AREA:
                figures.setdefault(current, []).append({
                    "page": page,
                    "bbox": {k: round(bb.get(k, 0), 4) for k in ("Left", "Top", "Width", "Height")}})
                texts.setdefault(current, [])
                pages.setdefault(current, set()).add(page)

        if btype == "LAYOUT_TABLE":
            idx = table_cursor.get(page, 0)
            page_tables = tables.get(page, [])
            text = page_tables[idx] if idx < len(page_tables) else _text_of(b, by_id)
            table_cursor[page] = idx + 1
        else:
            text = _text_of(b, by_id)
        if not text.strip():
            continue

        if btype in HEADING_TYPES:
            parsed = _parse_heading(text)
            if parsed:
                node = ensure(parsed[0], parsed[1], page)
                current = node["node_id"]
                pages.setdefault(current, set()).add(page)
                continue
            text = f"## {text.strip()}"  # unnumbered heading stays inline

        if btype in TEXT_TYPES or btype in HEADING_TYPES or btype == "LAYOUT_TABLE":
            texts.setdefault(current, []).append(text.strip())
            pages.setdefault(current, set()).add(page)

    return _assemble(nodes, order, texts, pages, figures)


def _assemble(nodes, order, texts, pages, figures=None):
    figures = figures or {}
    sections = {}
    title_by_node_id = {node["node_id"]: node["title"] for node in nodes.values()}
    for nid, chunks in texts.items():
        title = "Front matter" if nid == FRONT_ID else title_by_node_id[nid]
        sections[nid] = {
            "title": title,
            "text": "\n".join(chunks),
            "pages": sorted(pages.get(nid, [])),
            "figures": figures.get(nid, []),
        }

    children = {}
    for number in order:
        children.setdefault(nodes[number]["parent"], []).append(number)

    def make(number):
        n = nodes[number]
        kids = [make(c) for c in children.get(number, [])]
        nid = n["node_id"]
        if kids and nid in sections:
            # A heading with intro text AND sub-sections: move the intro text
            # into a synthetic first child so every routing target is a leaf.
            intro_id = f"{nid}_INTRO"
            sections[intro_id] = dict(sections.pop(nid), title=f"{n['title']} (overview)")
            kids.insert(0, {
                "node_id": intro_id, "number": number, "title": f"{n['title']} (overview)",
                "level": n["level"] + 1, "page_start": n["page_start"], "children": [],
            })
        return {
            "node_id": nid, "number": number, "title": n["title"], "level": n["level"],
            "page_start": n["page_start"], "children": kids,
        }

    tree = [make(num) for num in children.get(None, [])]
    if FRONT_ID in sections:
        tree.insert(0, {"node_id": FRONT_ID, "number": "0", "title": "Front matter",
                        "level": 1, "page_start": 1, "children": []})
    return tree, sections


def leaf_ids(tree):
    """All leaf node ids (the only valid payload targets)."""
    out = []
    for n in tree:
        out.extend(leaf_ids(n["children"]) if n["children"] else [n["node_id"]])
    return out
