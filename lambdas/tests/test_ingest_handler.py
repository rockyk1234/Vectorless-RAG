"""Offline tests for bounded Textract polling and shared summarization."""

import os
import sys
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tree"))

import ingest_handler  # noqa: E402


class TestTextractPolling(unittest.TestCase):
    def test_polling_stops_at_deadline(self):
        textract = Mock()
        textract.start_document_analysis.return_value = {"JobId": "job-1"}
        textract.get_document_analysis.return_value = {"JobStatus": "IN_PROGRESS"}

        with patch("ingest_handler.aws_client", return_value=textract), \
                patch("ingest_handler.TEXTRACT_MAX_WAIT_SECONDS", 10), \
                patch("ingest_handler.time.monotonic", side_effect=[0, 6]):
            with self.assertRaisesRegex(TimeoutError, "exceeded 10 seconds"):
                ingest_handler.run_textract("bucket", "manuals/PART/r1.pdf")

    def test_successful_result_pagination_is_collected(self):
        textract = Mock()
        textract.start_document_analysis.return_value = {"JobId": "job-1"}
        textract.get_document_analysis.side_effect = [
            {
                "JobStatus": "SUCCEEDED",
                "Blocks": [{"Id": "one"}],
                "NextToken": "next",
                "DocumentMetadata": {"Pages": 2},
            },
            {
                "JobStatus": "SUCCEEDED",
                "Blocks": [{"Id": "two"}],
                "DocumentMetadata": {"Pages": 2},
            },
        ]

        with patch("ingest_handler.aws_client", return_value=textract), \
                patch("ingest_handler.TEXTRACT_MAX_WAIT_SECONDS", 10), \
                patch("ingest_handler.time.monotonic", return_value=0):
            blocks, pages, status = ingest_handler.run_textract(
                "bucket", "manuals/PART/r1.pdf"
            )

        self.assertEqual([block["Id"] for block in blocks], ["one", "two"])
        self.assertEqual((pages, status), (2, "SUCCEEDED"))


class TestParallelSummaries(unittest.TestCase):
    def test_leaf_results_use_shared_annotation_walk(self):
        tree = [{"node_id": "S_1", "title": "Safety", "children": []}]
        sections = {"S_1": {"text": "Wear eye protection."}}
        llm = Mock()
        llm.summarize.return_value = {"summary": "Safety guidance", "keywords": ["PPE"]}

        with patch("ingest_handler.adapters.annotate_tree", return_value=tree) as annotate:
            result = ingest_handler.summarize_parallel(tree, sections, llm)

        self.assertIs(result, tree)
        annotate.assert_called_once()
        self.assertEqual(
            annotate.call_args.kwargs["precomputed"]["S_1"]["summary"],
            "Safety guidance",
        )


if __name__ == "__main__":
    unittest.main()
