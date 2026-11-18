"""Runtime answer loop for tree-based vectorless retrieval.

Flow (Sridhar's design, with code-enforced guards):
  1. Order ID -> PartId (structured lookup).
  2. Fetch only the tree for that PartId (projection, no payloads).
  3. LLM routes level by level. Every choice is validated against the node
     ids that actually exist at that level; anything else is discarded.
  4. Fetch only the chosen leaf payloads by exact key.
  5. LLM answers from those payloads and must return verbatim quotes.
     Each quote is checked as an exact substring of its payload. If any
     check fails, or the LLM says the answer is not present, return null.

The LLM, order lookup, and store are injected, so this module has no AWS
dependencies and the whole loop is unit-testable.
"""

import unicodedata

NOT_FOUND = "The information is not available in the manual for this part."
MIN_QUOTE_CHARS = 8


def normalize(text):
    """NFKC + collapse whitespace. Case and punctuation are kept as-is."""
    return " ".join(unicodedata.normalize("NFKC", text or "").split())


def quote_in_text(quote, text):
    q = normalize(quote)
    return len(q) >= MIN_QUOTE_CHARS and q in normalize(text)


def _quote_pages(section, quote):
    """Return exact pages containing the quote when per-page text is available."""
    section_pages = section.get("pages", [])
    page_texts = section.get("page_texts") or {}
    matches = []
    for raw_page, page_text in page_texts.items():
        try:
            page = int(raw_page)
        except (TypeError, ValueError):
            continue
        source = page_text
        if section_pages and page == section_pages[0]:
            source = f"{section['title']}\n{source}"
        if quote_in_text(quote, source):
            matches.append(page)
    return sorted(set(matches)) or section_pages


def _citation(node_id, section, quote):
    return {
        "node_id": node_id,
        "title": section["title"],
        "pages": _quote_pages(section, quote),
        "quote": quote,
        "figures": [figure for figure in section.get("figures", []) if figure.get("key")],
    }


def verified_quote_citations(quote_record, sections):
    """Verify one contiguous quote, or split newline-delimited cross-section evidence."""
    if isinstance(quote_record, str):
        quote = quote_record
        declared_node = None
    elif isinstance(quote_record, dict):
        quote = quote_record.get("quote", "")
        declared_node = quote_record.get("node_id")
    else:
        return []
    declared_section = sections.get(declared_node)
    if declared_section:
        source = f"{declared_section['title']}\n{declared_section['text']}"
        if quote_in_text(quote, source):
            return [_citation(declared_node, declared_section, quote)]
    else:
        for node_id, section in sections.items():
            source = f"{section['title']}\n{section['text']}"
            if quote_in_text(quote, source):
                return [_citation(node_id, section, quote)]

    fragments = [fragment.strip() for fragment in quote.splitlines() if fragment.strip()]
    if len(fragments) < 2:
        return []
    node_order = [declared_node] + [node_id for node_id in sections if node_id != declared_node]
    citations = []
    for fragment in fragments:
        matched = None
        for node_id in node_order:
            section = sections.get(node_id)
            if not section:
                continue
            source = f"{section['title']}\n{section['text']}"
            if quote_in_text(fragment, source):
                matched = _citation(node_id, section, fragment)
                break
        if not matched:
            return []
        citations.append(matched)
    return citations


UNIT_MESSAGES = {
    "UNIT_MISMATCH": "The selected unit does not match the unit on the work order.",
    "INVALID_UNIT": "That unit is not compatible with this part. Select one from the list.",
}


def null_response(reason, **extra):
    return {"status": "NOT_FOUND", "answer": None,
            "message": UNIT_MESSAGES.get(reason, NOT_FOUND), "reason": reason, **extra}


def route(question, nodes, llm, path, max_nodes=3, max_depth=6):
    """Walk the tree. Returns (leaf_nodes, path). Path records every hop."""
    if max_depth <= 0 or not nodes:
        return [], path
    options = {n["node_id"]: n for n in nodes}
    picked = llm.route(question, [
        {"node_id": n["node_id"], "title": n["title"], "summary": n.get("summary", "")}
        for n in nodes
    ])
    valid = [p for p in picked if p in options][:max_nodes]
    path.append({"options": list(options), "picked": picked, "accepted": valid,
                 "accepted_titles": [options[v]["title"] for v in valid]})
    leaves = []
    for nid in valid:
        node = options[nid]
        if node["children"]:
            sub, _ = route(question, node["children"], llm, path, max_nodes, max_depth - 1)
            leaves.extend(sub)
        else:
            leaves.append(node)
    return leaves[:max_nodes], path


def resolve_manual(order, unit_id, compat):
    """Pick the manual deterministically. Never inferred from the question text.

    Returns (manual_id, unit, None) on success, or (None, None, response) when the
    unit is missing, invalid, or conflicts with the work order.
    Rules:
      * Part has no unit manuals -> the part's own manual.
      * Unit on the work order   -> that unit (a different technician pick is rejected).
      * Technician pick          -> must be one of the compatible units.
      * Exactly one option       -> picked automatically.
      * Several options, no pick -> NEEDS_UNIT with the list; nothing is answered.
    """
    part_id = order["part_id"]
    options = compat.units_for(part_id) if compat else []
    if not options:
        return part_id, None, None

    by_id = {u["unit_id"]: u for u in options}
    fixed = order.get("unit_id")
    if fixed and unit_id and unit_id != fixed:
        return None, None, null_response("UNIT_MISMATCH", part_id=part_id,
                                         order_unit=fixed, requested_unit=unit_id)
    chosen = fixed or unit_id
    if chosen:
        unit = by_id.get(chosen)
        if not unit:
            return None, None, null_response("INVALID_UNIT", part_id=part_id, requested_unit=chosen,
                                             unit_options=options)
        return unit["manual_id"], dict(unit, source="work_order" if fixed else "technician"), None
    if len(options) == 1:
        return options[0]["manual_id"], dict(options[0], source="auto_single"), None
    return None, None, {"status": "NEEDS_UNIT", "answer": None, "part_id": part_id,
                        "message": "This part is installed differently in different units. Select the unit.",
                        "reason": "NEEDS_UNIT", "unit_options": options}


def answer(order_id, question, *, orders, store, llm, compat=None, unit_id=None):
    order = orders.get_order(order_id)
    if not order:
        return null_response("ORDER_NOT_FOUND", order_id=order_id)

    manual_id, unit, stop = resolve_manual(order, unit_id, compat)
    if stop:
        return stop

    tree_doc = store.get_tree(manual_id)
    if not tree_doc:
        return null_response("MANUAL_NOT_FOUND", part_id=order["part_id"], manual_id=manual_id)

    part_id = manual_id  # store key for the manual actually used (part or unit manual)
    audit = {"order_id": order_id, "part_id": order["part_id"], "manual_id": manual_id,
             "unit": unit, "revision": tree_doc.get("revision"),
             "source": tree_doc.get("source"), "route": []}
    leaves, _ = route(question, tree_doc["document_tree"], llm, audit["route"])
    if not leaves:
        return null_response("NO_MATCHING_SECTION", audit=audit)

    sections = store.get_sections(part_id, tree_doc.get("revision"),
                                  [n["node_id"] for n in leaves])
    if not sections:
        return null_response("SECTION_MISSING", audit=audit)

    result = llm.answer(question, sections)
    if not result or not result.get("found") or not result.get("answer"):
        return null_response("NOT_IN_SECTION", audit=audit)

    quotes = result.get("quotes") or []
    if not quotes:
        return null_response("NO_QUOTE", audit=audit)
    citations = []
    for quote_record in quotes:
        verified = verified_quote_citations(quote_record, sections)
        if not verified:
            return null_response("UNVERIFIED_QUOTE", audit=audit, rejected=quote_record)
        citations.extend(verified)

    return {"status": "ANSWERED", "answer": result["answer"],
            "citations": citations, "audit": audit}
