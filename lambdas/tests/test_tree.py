"""Offline tests for the tree retrieval PoC (no AWS, no third-party packages).

Run:  python3 -m unittest discover -s lambdas/tests -v
"""

import io
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tree"))

import adapters  # noqa: E402
import runtime  # noqa: E402
import tree_builder as tb  # noqa: E402


def _blocks(spec):
    """spec: list of (page, layout_type, text). Builds LAYOUT + LINE blocks."""
    blocks, n = [], 0
    for page, btype, text in spec:
        line_ids = []
        for line in text.split("\n"):
            n += 1
            lid = f"L{n}"
            blocks.append({"Id": lid, "BlockType": "LINE", "Text": line, "Page": page})
            line_ids.append(lid)
        n += 1
        blocks.append({"Id": f"B{n}", "BlockType": btype, "Page": page,
                       "Relationships": [{"Type": "CHILD", "Ids": line_ids}]})
    return blocks


MANUAL = _blocks([
    (1, "LAYOUT_TITLE", "Operating Instructions"),
    (1, "LAYOUT_TEXT", "Read this manual before installation."),
    (2, "LAYOUT_TEXT", "3 Mechanical Installation ........ 7"),  # TOC line, not heading
    (3, "LAYOUT_SECTION_HEADER", "3 Mechanical Installation"),
    (3, "LAYOUT_TEXT", "This chapter covers mounting."),
    (3, "LAYOUT_SECTION_HEADER", "3.1 Unpacking"),
    (3, "LAYOUT_TEXT", "Check the delivery for damage."),
    (3, "LAYOUT_PAGE_NUMBER", "3"),
    (4, "LAYOUT_SECTION_HEADER", "3.2 Tightening torques"),
    (4, "LAYOUT_SECTION_HEADER", "Flange bolts"),  # unnumbered: stays inline
    (4, "LAYOUT_TEXT", "Flange bolts must be cross-torqued to exactly 25 Nm."),
    (5, "LAYOUT_SECTION_HEADER", "4 Electrical Installation"),
    (5, "LAYOUT_TEXT", "Connect the mains cable to terminals L1, L2, L3."),
])


class TestTreeBuilder(unittest.TestCase):
    def setUp(self):
        self.tree, self.sections = tb.build_tree(MANUAL)

    def test_top_level_structure(self):
        self.assertEqual([n["node_id"] for n in self.tree], ["S_0", "S_3", "S_4"])

    def test_nested_children_and_intro_leaf(self):
        s3 = self.tree[1]
        self.assertEqual([c["node_id"] for c in s3["children"]], ["S_3_INTRO", "S_3_1", "S_3_2"])
        self.assertIn("This chapter covers mounting.", self.sections["S_3_INTRO"]["text"])
        self.assertNotIn("S_3", self.sections)  # parent text moved into the intro leaf

    def test_unnumbered_heading_inline_and_text_kept(self):
        text = self.sections["S_3_2"]["text"]
        self.assertIn("## Flange bolts", text)
        self.assertIn("exactly 25 Nm", text)
        self.assertEqual(self.sections["S_3_2"]["pages"], [4])

    def test_toc_line_not_a_heading_and_page_numbers_dropped(self):
        self.assertIn("........ 7", self.sections["S_0"]["text"])
        self.assertNotIn("\n3\n", "\n" + self.sections["S_3_1"]["text"] + "\n")

    def test_every_leaf_has_a_payload(self):
        for nid in tb.leaf_ids(self.tree):
            self.assertIn(nid, self.sections)

    def test_figures_attached_to_their_section_and_icons_skipped(self):
        blocks = _blocks([
            (1, "LAYOUT_SECTION_HEADER", "4.4 Tightening torques"),
            (1, "LAYOUT_TEXT", "Tighten the cover screws to 3.0 Nm."),
        ])
        blocks.append({"Id": "F1", "BlockType": "LAYOUT_FIGURE", "Page": 1,
                       "Geometry": {"BoundingBox": {"Left": 0.1, "Top": 0.3, "Width": 0.4, "Height": 0.2}}})
        blocks.append({"Id": "F2", "BlockType": "LAYOUT_FIGURE", "Page": 1,  # tiny icon
                       "Geometry": {"BoundingBox": {"Left": 0.1, "Top": 0.6, "Width": 0.02, "Height": 0.02}}})
        _, sections = tb.build_tree(blocks)
        figs = sections["S_4_4"]["figures"]
        self.assertEqual(len(figs), 1)
        self.assertEqual(figs[0]["page"], 1)
        self.assertEqual(figs[0]["bbox"]["Width"], 0.4)

    def test_number_and_title_on_separate_lines(self):
        tree, sections = tb.build_tree(_blocks([
            (1, "LAYOUT_TITLE", "4\nMechanical Installation"),
            (1, "LAYOUT_SECTION_HEADER", "4.4\nTightening torques"),
            (1, "LAYOUT_TEXT", "Tighten the cable glands to 2.5 Nm."),
        ]))
        self.assertEqual(tree[0]["children"][0]["title"], "4.4 Tightening torques")
        self.assertIn("2.5 Nm", sections["S_4_4"]["text"])

    def test_table_rendered_as_rows(self):
        blocks = [
            {"Id": "w1", "BlockType": "WORD", "Text": "M4"},
            {"Id": "w2", "BlockType": "WORD", "Text": "1.5 Nm"},
            {"Id": "c1", "BlockType": "CELL", "RowIndex": 1, "ColumnIndex": 1,
             "Relationships": [{"Type": "CHILD", "Ids": ["w1"]}]},
            {"Id": "c2", "BlockType": "CELL", "RowIndex": 1, "ColumnIndex": 2,
             "Relationships": [{"Type": "CHILD", "Ids": ["w2"]}]},
            {"Id": "t1", "BlockType": "TABLE", "Page": 1, "Geometry": {"BoundingBox": {"Top": 0.5}},
             "Relationships": [{"Type": "CHILD", "Ids": ["c1", "c2"]}]},
        ]
        by_id = {b["Id"]: b for b in blocks}
        self.assertEqual(tb._render_table(blocks[-1], by_id), "M4 | 1.5 Nm")

    def test_slide_deck_falls_back_to_one_section_per_page(self):
        blocks = _blocks([
            (1, "LAYOUT_TITLE", "Pump Performance Review"),
            (1, "LAYOUT_TEXT", "The test ran at 75 percent load."),
            (2, "LAYOUT_TITLE", "Results Summary"),
            (2, "LAYOUT_SECTION_HEADER", "Outlet pressure"),
            (2, "LAYOUT_TEXT", "The measured pressure was 42 bar."),
        ])
        blocks.append({
            "Id": "F-slide",
            "BlockType": "LAYOUT_FIGURE",
            "Page": 2,
            "Geometry": {"BoundingBox": {"Left": 0.1, "Top": 0.2, "Width": 0.7, "Height": 0.5}},
        })

        tree, sections = tb.build_tree(blocks)

        self.assertEqual([n["node_id"] for n in tree], ["P_1", "P_2"])
        self.assertEqual([n["title"] for n in tree], ["Pump Performance Review", "Results Summary"])
        self.assertIn("75 percent load", sections["P_1"]["text"])
        self.assertIn("## Outlet pressure", sections["P_2"]["text"])
        self.assertIn("42 bar", sections["P_2"]["text"])
        self.assertEqual(sections["P_2"]["pages"], [2])
        self.assertEqual(sections["P_2"]["figures"][0]["page"], 2)


class FakeLLM:
    def __init__(self, routes, result):
        self.routes, self.result, self.calls = list(routes), result, []

    def route(self, question, options):
        self.calls.append([o["node_id"] for o in options])
        return self.routes.pop(0) if self.routes else []

    def answer(self, question, sections):
        return self.result


class FakeStore:
    def __init__(self, tree, sections):
        self.tree, self.sections, self.fetched = tree, sections, None

    def get_tree(self, part_id):
        return {"document_tree": self.tree, "revision": "r1"} if part_id == "PART#X" else None

    def get_sections(self, part_id, revision, node_ids):
        self.fetched = node_ids
        return {n: self.sections[n] for n in node_ids if n in self.sections}


class TestS3DynamoStore(unittest.TestCase):
    def test_round_trip_uses_s3_payloads_and_dynamodb_pointer(self):
        class S3:
            def __init__(self):
                self.objects = {}
                self.puts = []
                self.gets = []

            def put_object(self, **kwargs):
                self.objects[kwargs["Key"]] = kwargs["Body"]
                self.puts.append(kwargs)

            def get_object(self, **kwargs):
                self.gets.append(kwargs)
                return {"Body": io.BytesIO(self.objects[kwargs["Key"]])}

        class Table:
            def __init__(self):
                self.items = {}

            def put_item(self, Item):
                self.items[(Item["pk"], Item["sk"])] = Item

            def get_item(self, Key, ConsistentRead=False):
                return {"Item": self.items[(Key["pk"], Key["sk"])]}

        s3, table = S3(), Table()
        store = adapters.S3DynamoStore(
            s3=s3,
            table=table,
            bucket="documents",
            account_id="123456789012",
        )
        store.kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/test"
        tree = [{"node_id": "S_1", "title": "1 Safety", "children": []}]
        sections = {"S_1": {"title": "1 Safety", "text": "Wear eye protection.",
                              "pages": [1], "figures": []}}

        tree_id = store.put_manual(
            "PART#X", "r1", {"title": "Manual", "source": "s3://documents/manuals/X/r1.pdf",
                              "ingested_at": 123}, tree, sections)

        self.assertEqual(tree_id, "PART#X#r1")
        self.assertEqual(store.get_tree("PART#X")["document_tree"], tree)
        self.assertEqual(store.get_sections("PART#X", "r1", ["S_1"])["S_1"]["text"],
                         "Wear eye protection.")
        self.assertTrue(all(p["ExpectedBucketOwner"] == "123456789012" for p in s3.puts))
        self.assertTrue(all(g["ExpectedBucketOwner"] == "123456789012" for g in s3.gets))
        self.assertTrue(all(p["ServerSideEncryption"] == "aws:kms" for p in s3.puts))
        self.assertIn(("MANUAL#PART#X", "CURRENT"), table.items)


class TestRuntime(unittest.TestCase):
    def setUp(self):
        self.tree, self.sections = tb.build_tree(MANUAL)
        self.store = FakeStore(self.tree, self.sections)
        self.orders = adapters.MockOrders({"ORD-1": {"part_id": "PART#X"}})

    def run_loop(self, routes, result, order="ORD-1"):
        llm = FakeLLM(routes, result)
        return runtime.answer(order, "How tight do I screw the flange bolts?",
                              orders=self.orders, store=self.store, llm=llm), llm

    def test_happy_path_verified_quote(self):
        out, llm = self.run_loop(
            [["S_3"], ["S_3_2"]],
            {"found": True, "answer": "25 Nm, cross-torqued.",
             "quotes": [{"node_id": "S_3_2", "quote": "cross-torqued to exactly 25 Nm"}]})
        self.assertEqual(out["status"], "ANSWERED")
        self.assertEqual(out["citations"][0]["pages"], [4])
        self.assertEqual(self.store.fetched, ["S_3_2"])  # only the chosen leaf
        self.assertEqual(llm.calls[1], ["S_3_INTRO", "S_3_1", "S_3_2"])

    def test_string_quote_is_verified_against_fetched_sections(self):
        out, _ = self.run_loop(
            [["S_3"], ["S_3_2"]],
            {
                "found": True,
                "answer": "25 Nm.",
                "quotes": ["Flange bolts must be cross-torqued to exactly 25 Nm."],
            },
        )
        self.assertEqual(out["status"], "ANSWERED")
        self.assertEqual(out["citations"][0]["node_id"], "S_3_2")

    def test_invalid_quote_shape_is_rejected_without_crashing(self):
        out, _ = self.run_loop(
            [["S_3"], ["S_3_2"]],
            {"found": True, "answer": "25 Nm.", "quotes": [42]},
        )
        self.assertEqual(out["status"], "NOT_FOUND")
        self.assertEqual(out["reason"], "UNVERIFIED_QUOTE")

    def test_cross_section_multiline_quote_splits_into_verified_citations(self):
        out, _ = self.run_loop(
            [["S_3"], ["S_3_INTRO", "S_3_2"]],
            {
                "found": True,
                "answer": "Mounting guidance includes a 25 Nm flange torque.",
                "quotes": [{
                    "node_id": "S_3_2",
                    "quote": (
                        "This chapter covers mounting.\n"
                        "Flange bolts must be cross-torqued to exactly 25 Nm."
                    ),
                }],
            },
        )
        self.assertEqual(out["status"], "ANSWERED")
        self.assertEqual(
            [citation["node_id"] for citation in out["citations"]],
            ["S_3_INTRO", "S_3_2"],
        )

    def test_cross_section_quote_rejects_any_unverified_fragment(self):
        out, _ = self.run_loop(
            [["S_3"], ["S_3_INTRO", "S_3_2"]],
            {
                "found": True,
                "answer": "30 Nm.",
                "quotes": [{
                    "node_id": "S_3_2",
                    "quote": "This chapter covers mounting.\nUse exactly 30 Nm.",
                }],
            },
        )
        self.assertEqual(out["status"], "NOT_FOUND")
        self.assertEqual(out["reason"], "UNVERIFIED_QUOTE")

    def test_quote_including_section_heading_accepted(self):
        out, _ = self.run_loop(
            [["S_3"], ["S_3_2"]],
            {"found": True, "answer": "25 Nm.",
             "quotes": [{"node_id": "S_3_2", "quote": "3.2 Tightening torques\n## Flange bolts"}]})
        self.assertEqual(out["status"], "ANSWERED")

    def test_saved_figures_returned_with_citation(self):
        self.sections["S_3_2"]["figures"] = [{"page": 4, "bbox": {}, "key": "figures/x.png"},
                                             {"page": 4, "bbox": {}}]  # second was never saved
        out, _ = self.run_loop(
            [["S_3"], ["S_3_2"]],
            {"found": True, "answer": "25 Nm.",
             "quotes": [{"node_id": "S_3_2", "quote": "cross-torqued to exactly 25 Nm"}]})
        self.assertEqual([f["key"] for f in out["citations"][0]["figures"]], ["figures/x.png"])

    def test_fabricated_quote_returns_null(self):
        out, _ = self.run_loop(
            [["S_3"], ["S_3_2"]],
            {"found": True, "answer": "30 Nm.",
             "quotes": [{"node_id": "S_3_2", "quote": "torqued to exactly 30 Nm"}]})
        self.assertEqual(out["status"], "NOT_FOUND")
        self.assertEqual(out["reason"], "UNVERIFIED_QUOTE")
        self.assertIsNone(out["answer"])

    def test_quote_citing_unfetched_node_rejected(self):
        out, _ = self.run_loop(
            [["S_3"], ["S_3_2"]],
            {"found": True, "answer": "x", "quotes": [{"node_id": "S_4", "quote": "Connect the mains cable"}]})
        self.assertEqual(out["reason"], "UNVERIFIED_QUOTE")

    def test_hallucinated_node_id_ignored(self):
        out, _ = self.run_loop([["CH_99", "S_3; DROP"]], {"found": True})
        self.assertEqual(out["reason"], "NO_MATCHING_SECTION")
        self.assertIsNone(self.store.fetched)  # nothing fetched from payloads

    def test_answer_not_in_section_returns_null(self):
        out, _ = self.run_loop([["S_4"]], {"found": False, "answer": "", "quotes": []})
        self.assertEqual(out["reason"], "NOT_IN_SECTION")

    def test_missing_quotes_returns_null(self):
        out, _ = self.run_loop([["S_4"]], {"found": True, "answer": "L1 L2 L3", "quotes": []})
        self.assertEqual(out["reason"], "NO_QUOTE")

    def test_unknown_order_and_manual(self):
        out, _ = self.run_loop([], {}, order="ORD-404")
        self.assertEqual(out["reason"], "ORDER_NOT_FOUND")
        self.orders.mapping["ORD-2"] = {"part_id": "PART#OTHER"}
        out, _ = self.run_loop([], {}, order="ORD-2")
        self.assertEqual(out["reason"], "MANUAL_NOT_FOUND")

    def test_quote_whitespace_normalized_but_short_quotes_rejected(self):
        self.assertTrue(runtime.quote_in_text("exactly\n  25 Nm", "to exactly 25 Nm."))
        self.assertFalse(runtime.quote_in_text("25 Nm", "to exactly 25 Nm."))


class TestUnitResolution(unittest.TestCase):
    COMPAT = adapters.MockCompat({"PART#F": [
        {"unit_id": "AC-1", "name": "AC 1", "manual_id": "UNIT#AC-1"},
        {"unit_id": "AC-2", "name": "AC 2", "manual_id": "UNIT#AC-2"},
    ], "PART#SOLO": [{"unit_id": "AC-9", "name": "AC 9", "manual_id": "UNIT#AC-9"}]})

    def resolve(self, order, unit_id=None):
        return runtime.resolve_manual(order, unit_id, self.COMPAT)

    def test_part_without_units_uses_part_manual(self):
        self.assertEqual(self.resolve({"part_id": "PART#X"})[0], "PART#X")

    def test_unit_from_work_order(self):
        manual, unit, stop = self.resolve({"part_id": "PART#F", "unit_id": "AC-2"})
        self.assertEqual((manual, unit["source"], stop), ("UNIT#AC-2", "work_order", None))

    def test_technician_pick_from_list(self):
        manual, unit, _ = self.resolve({"part_id": "PART#F"}, "AC-1")
        self.assertEqual((manual, unit["source"]), ("UNIT#AC-1", "technician"))

    def test_several_units_and_no_pick_asks(self):
        _, _, stop = self.resolve({"part_id": "PART#F"})
        self.assertEqual(stop["status"], "NEEDS_UNIT")
        self.assertEqual([u["unit_id"] for u in stop["unit_options"]], ["AC-1", "AC-2"])

    def test_single_unit_auto_picked(self):
        manual, unit, _ = self.resolve({"part_id": "PART#SOLO"})
        self.assertEqual((manual, unit["source"]), ("UNIT#AC-9", "auto_single"))

    def test_unknown_unit_rejected(self):
        _, _, stop = self.resolve({"part_id": "PART#F"}, "AC-7")
        self.assertEqual(stop["reason"], "INVALID_UNIT")

    def test_pick_conflicting_with_work_order_rejected(self):
        _, _, stop = self.resolve({"part_id": "PART#F", "unit_id": "AC-2"}, "AC-1")
        self.assertEqual(stop["reason"], "UNIT_MISMATCH")

    def test_needs_unit_never_calls_llm_or_store(self):
        class Boom:
            def __getattr__(self, name):
                raise AssertionError("must not be called before the unit is known")
        orders = adapters.MockOrders({"O": {"part_id": "PART#F"}})
        out = runtime.answer("O", "how do I fit it in unit AC-2?", orders=orders,
                             store=Boom(), llm=Boom(), compat=self.COMPAT)
        self.assertEqual(out["status"], "NEEDS_UNIT")  # unit named in text is ignored


class TestAnnotate(unittest.TestCase):
    def test_summaries_and_parent_keyword_rollup(self):
        tree, sections = tb.build_tree(MANUAL)

        class S:
            def summarize(self, title, text):
                return {"summary": f"About {title}.", "keywords": ["torque"] if "25 Nm" in text else []}

        adapters.annotate_tree(tree, sections, S())
        s32 = tree[1]["children"][2]
        self.assertIn("Terms: torque.", s32["summary"])
        self.assertIn("torque", tree[1]["keywords"])  # rolled up to the parent


if __name__ == "__main__":
    unittest.main()
