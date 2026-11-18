"""Tree ingest Lambda: S3 manual PDF -> Textract -> tree -> S3 and DynamoDB.

Trigger: s3:ObjectCreated on keys like manuals/<PART-SLUG>/<revision>.pdf.
Can also be invoked directly with {"bucket": ..., "key": ...}.
"""

import os
import re
import tempfile
import time
import urllib.parse
from concurrent.futures import ThreadPoolExecutor

import adapters
import tree_builder

KEY_RE = re.compile(r"^(manuals|units)/([A-Za-z0-9][A-Za-z0-9._-]{0,63})/([A-Za-z0-9._-]{1,32})\.pdf$")
REGION = os.environ.get("AWS_REGION_NAME")
TEXTRACT_POLL_SECONDS = 5  # Avoid tight polling while keeping ingest progress visible.
TEXTRACT_MAX_WAIT_SECONDS = (
    int(os.environ["TEXTRACT_MAX_WAIT_SECONDS"])
    if os.environ.get("TEXTRACT_MAX_WAIT_SECONDS") else None
)
SUMMARY_WORKERS = 6  # Bound concurrent Bedrock calls within account quotas.
MIN_FIGURE_DIMENSION_PX = 40  # Discard tiny icons that are not useful evidence.
MAX_FIGURES = int(os.environ["MAX_FIGURES"]) if os.environ.get("MAX_FIGURES") else None
RENDER_SCALE = 2.0  # Approximately 144 dpi.
PAD = 0.01  # One percent padding around Textract's figure box.


def _required_positive(name, value):
    if value is None or value < 1:
        raise RuntimeError(f"{name} must be configured as a positive integer")
    return value


def aws_client(service):
    """Create an AWS client lazily so parsing tests stay dependency-free."""
    if not REGION:
        raise RuntimeError("AWS_REGION_NAME must be configured")
    import boto3
    from botocore.config import Config
    config = Config(retries={"max_attempts": 4, "mode": "adaptive"}, read_timeout=90)
    return boto3.client(service, region_name=REGION, config=config)


def log(msg):
    print(f"[tree-ingest] {msg}", flush=True)


def parse_key(key):
    """manuals/<PART>/<rev>.pdf -> PART#<PART>; units/<UNIT>/<rev>.pdf -> UNIT#<UNIT>."""
    match = KEY_RE.match(key)
    if not match:
        raise ValueError(
            "key must look like manuals/<PART>/<rev>.pdf or units/<UNIT>/<rev>.pdf, "
            f"got {key!r}"
        )
    prefix = "PART" if match.group(1) == "manuals" else "UNIT"
    return f"{prefix}#{match.group(2).upper()}", match.group(3)


def run_textract(bucket, key):
    """Run Textract with one deadline covering status and result pagination."""
    textract = aws_client("textract")
    job = textract.start_document_analysis(
        DocumentLocation={"S3Object": {"Bucket": bucket, "Name": key}},
        FeatureTypes=["LAYOUT", "TABLES"],
    )["JobId"]
    log(f"textract job {job} started")
    max_wait_seconds = _required_positive(
        "TEXTRACT_MAX_WAIT_SECONDS", TEXTRACT_MAX_WAIT_SECONDS
    )
    deadline = time.monotonic() + max_wait_seconds

    while True:
        response = textract.get_document_analysis(JobId=job, MaxResults=1000)
        status = response["JobStatus"]
        if status in ("SUCCEEDED", "PARTIAL_SUCCESS"):
            break
        if status == "FAILED":
            raise RuntimeError(f"textract failed: {response.get('StatusMessage')}")
        if time.monotonic() + TEXTRACT_POLL_SECONDS >= deadline:
            raise TimeoutError(
                f"textract job exceeded {max_wait_seconds} seconds"
            )
        time.sleep(TEXTRACT_POLL_SECONDS)

    blocks = list(response["Blocks"])
    token = response.get("NextToken")
    while token:
        if time.monotonic() >= deadline:
            raise TimeoutError(
                f"textract result pagination exceeded {max_wait_seconds} seconds"
            )
        response = textract.get_document_analysis(
            JobId=job,
            MaxResults=1000,
            NextToken=token,
        )
        blocks.extend(response["Blocks"])
        token = response.get("NextToken")
    pages = response["DocumentMetadata"]["Pages"]
    log(f"textract {status}: {pages} pages, {len(blocks)} blocks")
    return blocks, pages, status


def summarize_parallel(tree, sections, llm):
    """Summarize leaves in parallel, then use the shared annotation walk."""
    leaves = {}

    def collect(nodes):
        for node in nodes:
            if node["children"]:
                collect(node["children"])
            else:
                leaves[node["node_id"]] = node

    collect(tree)

    def summarize_leaf(node):
        text = sections.get(node["node_id"], {}).get("text", "")
        result = llm.summarize(node["title"], text) if text else {}
        return node["node_id"], result

    with ThreadPoolExecutor(max_workers=SUMMARY_WORKERS) as pool:
        leaf_summaries = dict(pool.map(summarize_leaf, leaves.values()))

    return adapters.annotate_tree(
        tree,
        sections,
        llm,
        precomputed=leaf_summaries,
    )


def extract_figures(bucket, key, part_id, revision, sections):
    """Crop detected figures from the PDF and save them as encrypted PNGs."""
    import io
    import pypdfium2 as pdfium

    wanted = [
        (node_id, figure)
        for node_id, section in sections.items()
        for figure in section.get("figures", [])
    ]
    if not wanted:
        return 0
    s3 = aws_client("s3")
    owner = os.environ.get("AWS_ACCOUNT_ID")
    owner_args = {"ExpectedBucketOwner": owner} if owner else {}
    kms_key_arn = os.environ.get("KMS_KEY_ARN")
    max_figures = _required_positive("MAX_FIGURES", MAX_FIGURES)
    prefix = f"figures/{part_id.replace('#', '_')}/{revision}"
    rendered, saved, counter = {}, 0, {}

    with tempfile.TemporaryDirectory(prefix="vectorless-ingest-") as directory:
        local_path = os.path.join(directory, "manual.pdf")
        if owner_args:
            s3.download_file(bucket, key, local_path, ExtraArgs=owner_args)
        else:
            s3.download_file(bucket, key, local_path)
        pdf = pdfium.PdfDocument(local_path)
        try:
            for node_id, figure in wanted[:max_figures]:
                try:
                    page_number = figure["page"]
                    if page_number not in rendered:
                        if len(rendered) > 4:
                            rendered.clear()  # Keep image memory bounded.
                        rendered[page_number] = pdf[page_number - 1].render(
                            scale=RENDER_SCALE
                        ).to_pil()
                    image = rendered[page_number]
                    width, height = image.size
                    box_data = figure["bbox"]
                    box = (
                        max(0, int((box_data["Left"] - PAD) * width)),
                        max(0, int((box_data["Top"] - PAD) * height)),
                        min(width, int((box_data["Left"] + box_data["Width"] + PAD) * width)),
                        min(height, int((box_data["Top"] + box_data["Height"] + PAD) * height)),
                    )
                    if (box[2] - box[0] < MIN_FIGURE_DIMENSION_PX
                            or box[3] - box[1] < MIN_FIGURE_DIMENSION_PX):
                        continue
                    counter[(node_id, page_number)] = counter.get(
                        (node_id, page_number), 0
                    ) + 1
                    figure_key = (
                        f"{prefix}/{node_id}_p{page_number}_"
                        f"{counter[(node_id, page_number)]}.png"
                    )
                    buffer = io.BytesIO()
                    image.crop(box).save(buffer, format="PNG", optimize=True)
                    put_args = {
                        "Bucket": bucket,
                        "Key": figure_key,
                        "Body": buffer.getvalue(),
                        "ContentType": "image/png",
                        **owner_args,
                    }
                    if kms_key_arn:
                        put_args.update(
                            ServerSideEncryption="aws:kms",
                            SSEKMSKeyId=kms_key_arn,
                        )
                    s3.put_object(**put_args)
                    figure["key"] = figure_key
                    saved += 1
                except Exception as error:  # One bad figure must not fail the manual.
                    log(
                        f"figure skipped ({node_id} p{figure.get('page')}): "
                        f"{type(error).__name__}"
                    )
        finally:
            pdf.close()

    if len(wanted) > max_figures:
        log(f"figure cap reached: {len(wanted)} detected, {max_figures} processed")
    return saved


def lambda_handler(event, context):
    if "Records" in event:
        record = event["Records"][0]["s3"]
        bucket = record["bucket"]["name"]
        key = urllib.parse.unquote_plus(record["object"]["key"])
    else:
        bucket, key = event["bucket"], event["key"]

    part_id, revision = parse_key(key)
    log(f"ingesting s3://{bucket}/{key} as {part_id} {revision}")

    blocks, pages, textract_status = run_textract(bucket, key)
    tree, sections = tree_builder.build_tree(blocks)
    leaves = tree_builder.leaf_ids(tree)
    log(f"tree: {len(tree)} top-level nodes, {len(leaves)} leaves, {len(sections)} payloads")

    llm = adapters.BedrockLLM()
    summarize_parallel(tree, sections, llm)

    figures = extract_figures(bucket, key, part_id, revision, sections)
    log(f"figures saved: {figures}")

    store = adapters.S3DynamoStore()
    tree_id = store.put_manual(
        part_id,
        revision,
        {
            "title": key.rsplit("/", 1)[-1],
            "source": f"s3://{bucket}/{key}",
            "pages": pages,
            "textract_status": textract_status,
            "ingested_at": int(time.time()),
        },
        tree,
        sections,
    )
    log(f"stored {tree_id}")
    return {
        "tree_id": tree_id,
        "pages": pages,
        "top_level": len(tree),
        "leaves": len(leaves),
        "figures": figures,
        "textract_status": textract_status,
    }
