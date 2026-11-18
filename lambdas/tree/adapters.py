"""AWS-backed adapters for the tree retrieval loop.

  * BedrockLLM   - routing, answering, and node summaries via the Converse API
                   with a forced tool call, so outputs are schema-shaped JSON.
  * S3DynamoStore - low-cost regional store. DynamoDB keeps the current-revision
                    pointer and metadata; S3 keeps trees and section payloads.
  * MockOrders   - stand-in for the SQL order lookup until a real DB exists.

boto3 is imported lazily so runtime.py tests stay offline.
"""

import json
import os
from urllib.parse import quote

ROUTER_PROMPT = (
    "You route a technician's question to sections of ONE equipment manual. "
    "Pick the node_ids whose title or summary most likely contains the answer. "
    "Pick at most 3. Only use node_ids from the list. If none fit, return an "
    "empty list. Do not answer the question."
)
ANSWER_PROMPT = (
    "Answer the technician's question using ONLY the provided manual sections. "
    "Each quote must be one contiguous substring copied character for character "
    "from one section. Never combine table labels or rows, insert separators, or "
    "reconstruct text across sections. Return separate quotes when evidence spans "
    "more than one source line or section. If the answer is not explicitly stated, "
    "set found=false and leave answer empty. Never use outside knowledge and never "
    "estimate values."
)
SUMMARY_PROMPT = (
    "Summarize this manual section in one sentence for a search router, then "
    "list the technical terms and synonyms a technician might use for its "
    "content (for example torque, tightening torque, tightening parameters). "
    "Base it only on the text given."
)

ROUTE_TOOL = {"toolSpec": {"name": "select_nodes", "description": "Return chosen node ids.",
    "inputSchema": {"json": {"type": "object", "required": ["node_ids"], "properties": {
        "node_ids": {"type": "array", "items": {"type": "string"}, "maxItems": 3}}}}}}
ANSWER_TOOL = {"toolSpec": {"name": "give_answer", "description": "Return the grounded answer.",
    "inputSchema": {"json": {"type": "object", "required": ["found", "answer", "quotes"], "properties": {
        "found": {"type": "boolean"},
        "answer": {"type": "string"},
        "quotes": {"type": "array", "items": {"type": "object", "required": ["node_id", "quote"],
            "properties": {"node_id": {"type": "string"}, "quote": {"type": "string"}}}}}}}}}
SUMMARY_TOOL = {"toolSpec": {"name": "summarize", "description": "Return summary and terms.",
    "inputSchema": {"json": {"type": "object", "required": ["summary", "keywords"], "properties": {
        "summary": {"type": "string"},
        "keywords": {"type": "array", "items": {"type": "string"}, "maxItems": 15}}}}}}


class BedrockLLM:
    def __init__(self, router_model=None, answer_model=None, region=None, client=None):
        self.router_model = router_model or os.environ["ROUTER_MODEL_ID"]
        self.answer_model = answer_model or os.environ["ANSWER_MODEL_ID"]
        if client is None:
            import boto3
            client = boto3.client(
                "bedrock-runtime",
                region_name=region or os.environ["AWS_REGION_NAME"],
            )
        self.client = client

    def _call(self, model, system, user, tool):
        resp = self.client.converse(
            modelId=model,
            system=[{"text": system}],
            messages=[{"role": "user", "content": [{"text": user}]}],
            inferenceConfig={"temperature": 0, "maxTokens": 1500},
            toolConfig={"tools": [tool], "toolChoice": {"tool": {"name": tool["toolSpec"]["name"]}}},
        )
        for block in resp["output"]["message"]["content"]:
            if "toolUse" in block:
                return block["toolUse"]["input"]
        return {}

    def route(self, question, options):
        out = self._call(self.router_model, ROUTER_PROMPT,
                         f"Question: {question}\n\nNodes:\n{json.dumps(options, indent=1)}", ROUTE_TOOL)
        return [str(x) for x in out.get("node_ids", [])]

    def answer(self, question, sections):
        body = "\n\n".join(f"[node_id={nid}] {s['title']}\n{s['text']}" for nid, s in sections.items())
        return self._call(self.answer_model, ANSWER_PROMPT,
                          f"Question: {question}\n\nSections:\n{body}", ANSWER_TOOL)

    def summarize(self, title, text):
        return self._call(self.router_model, SUMMARY_PROMPT,
                          f"Section title: {title}\n\nText:\n{text[:12000]}", SUMMARY_TOOL)


MAX_KEYWORDS_PER_NODE = 25  # Keep router metadata compact while preserving useful terms.


def annotate_tree(tree, sections, llm, precomputed=None):
    """Add summaries and keywords, optionally using precomputed leaf results."""
    precomputed = precomputed or {}
    for node in tree:
        if node["children"]:
            annotate_tree(node["children"], sections, llm, precomputed)
            child_text = "\n".join(
                f"{child['title']}: {child.get('summary', '')}"
                for child in node["children"]
            )
            out = llm.summarize(node["title"], child_text)
            node["keywords"] = sorted(
                {keyword for child in node["children"]
                 for keyword in child.get("keywords", [])}
                | set(out.get("keywords", []))
            )[:MAX_KEYWORDS_PER_NODE]
        else:
            node_id = node["node_id"]
            text = sections.get(node_id, {}).get("text", "")
            if node_id in precomputed:
                out = precomputed[node_id]
            else:
                out = llm.summarize(node["title"], text) if text else {}
            node["keywords"] = out.get("keywords", [])[:MAX_KEYWORDS_PER_NODE]
        summary = out.get("summary", "")
        if node.get("keywords"):
            summary = f"{summary} Terms: {', '.join(node['keywords'])}."
        node["summary"] = summary.strip()
    return tree


class S3DynamoStore:
    """Store metadata in DynamoDB and versioned tree payloads in S3.

    DynamoDB contains only small records, so section and tree size are not
    constrained by its 400 KB item limit. Every S3 key is derived from encoded
    identifiers and every request checks the expected bucket owner when set.
    """

    def __init__(self, s3=None, table=None, bucket=None, account_id=None, region=None):
        self.bucket = bucket or os.environ["DOCUMENT_BUCKET"]
        self.account_id = account_id or os.environ.get("AWS_ACCOUNT_ID")
        self.kms_key_arn = os.environ.get("KMS_KEY_ARN")
        if s3 is None or table is None:
            import boto3
            region = region or os.environ["AWS_REGION_NAME"]
            if s3 is None:
                s3 = boto3.client("s3", region_name=region)
            if table is None:
                table = boto3.resource("dynamodb", region_name=region).Table(
                    os.environ["METADATA_TABLE"])
        self.s3 = s3
        self.table = table

    @staticmethod
    def _safe(value):
        return quote(str(value), safe="._-")

    def _prefix(self, part_id, revision):
        return f"processed/{self._safe(part_id)}/{self._safe(revision)}"

    def _owner_args(self):
        return {"ExpectedBucketOwner": self.account_id} if self.account_id else {}

    def _put_json(self, key, value):
        args = {
            "Bucket": self.bucket,
            "Key": key,
            "Body": json.dumps(value, separators=(",", ":"), ensure_ascii=False).encode("utf-8"),
            "ContentType": "application/json",
            **self._owner_args(),
        }
        if self.kms_key_arn:
            args.update(ServerSideEncryption="aws:kms", SSEKMSKeyId=self.kms_key_arn)
        self.s3.put_object(**args)

    def _get_json(self, key):
        obj = self.s3.get_object(Bucket=self.bucket, Key=key, **self._owner_args())
        return json.loads(obj["Body"].read().decode("utf-8"))

    def put_manual(self, part_id, revision, meta, tree, sections):
        prefix = self._prefix(part_id, revision)
        for nid, sec in sections.items():
            self._put_json(f"{prefix}/sections/{self._safe(nid)}.json", {
                "part_id": part_id,
                "revision": revision,
                "node_id": nid,
                **sec,
            })

        tree_key = f"{prefix}/tree.json"
        tree_doc = {
            "part_id": part_id,
            "revision": revision,
            "document_tree": tree,
            **meta,
        }
        self._put_json(tree_key, tree_doc)
        self.table.put_item(Item={
            "pk": f"MANUAL#{part_id}",
            "sk": f"REV#{revision}",
            "tree_key": tree_key,
            "source": meta.get("source", ""),
            "title": meta.get("title", ""),
            "ingested_at": int(meta.get("ingested_at", 0)),
        })
        self.table.put_item(Item={
            "pk": f"MANUAL#{part_id}",
            "sk": "CURRENT",
            "revision": revision,
            "tree_key": tree_key,
        })
        return f"{part_id}#{revision}"

    def get_tree(self, part_id):
        response = self.table.get_item(
            Key={"pk": f"MANUAL#{part_id}", "sk": "CURRENT"},
            ConsistentRead=True,
        )
        current = response.get("Item")
        return self._get_json(current["tree_key"]) if current else None

    def get_sections(self, part_id, revision, node_ids):
        prefix = self._prefix(part_id, revision)
        sections = {}
        for nid in node_ids:
            try:
                section = self._get_json(f"{prefix}/sections/{self._safe(nid)}.json")
            except Exception as error:
                code = getattr(error, "response", {}).get("Error", {}).get("Code")
                if code in ("NoSuchKey", "404"):
                    continue
                raise
            sections[nid] = section
        return sections


class MockOrders:
    """Stand-in for the SQL order table: order_id -> part_id."""

    def __init__(self, mapping=None, path=None):
        if mapping is None:
            path = path or os.environ.get("ORDERS_FILE",
                                          os.path.join(os.path.dirname(__file__), "orders.json"))
            with open(path) as f:
                mapping = json.load(f)
        self.mapping = mapping

    def get_order(self, order_id):
        row = self.mapping.get(str(order_id).strip())
        return dict(row, order_id=str(order_id).strip()) if row else None


class MockCompat:
    """Stand-in for the part-to-unit compatibility table.

    {part_id: [{"unit_id", "name", "manual_id"}, ...]}. A part with no entry has no
    unit-specific manuals and uses its own manual.
    """

    def __init__(self, mapping=None, path=None):
        if mapping is None:
            path = path or os.environ.get("COMPAT_FILE",
                                          os.path.join(os.path.dirname(__file__), "compatibility.json"))
            with open(path) as f:
                mapping = json.load(f)
        self.mapping = mapping

    def units_for(self, part_id):
        return [dict(u) for u in self.mapping.get(part_id, [])]
