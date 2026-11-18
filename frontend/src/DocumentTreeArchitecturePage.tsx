import ContentLayout from "@cloudscape-design/components/content-layout";
import Header from "@cloudscape-design/components/header";
import Container from "@cloudscape-design/components/container";
import SpaceBetween from "@cloudscape-design/components/space-between";
import Box from "@cloudscape-design/components/box";
import Table from "@cloudscape-design/components/table";
import Badge from "@cloudscape-design/components/badge";
import { BLUE, GREEN, Node, ORANGE } from "./DiagramPrimitives";

// Arrow with a drawn head: the line stops at the head's base and the tip lands exactly on (x2, y2),
// so there is no gap before the box and no line poking through the head.
function Arrow({
  x1,
  y1,
  x2,
  y2,
  label,
  lx,
  ly,
  color = "#5f6b7a",
}: {
  x1: number;
  y1: number;
  x2: number;
  y2: number;
  label?: string;
  lx?: number;
  ly?: number;
  color?: string;
}) {
  const len = Math.hypot(x2 - x1, y2 - y1) || 1;
  const ux = (x2 - x1) / len,
    uy = (y2 - y1) / len;
  const head = 11,
    half = 5.5;
  const bx = x2 - ux * head,
    by = y2 - uy * head;
  const pts = `${x2},${y2} ${bx - uy * half},${by + ux * half} ${bx + uy * half},${by - ux * half}`;
  const cx = lx ?? (x1 + x2) / 2;
  const cy = ly ?? (y1 + y2) / 2 - 8;
  const w = label ? label.length * 6.3 + 10 : 0;
  return (
    <g>
      <line x1={x1} y1={y1} x2={bx} y2={by} stroke={color} strokeWidth={2} />
      <polygon points={pts} fill={color} />
      {label && (
        <>
          <rect
            x={cx - w / 2}
            y={cy - 11}
            width={w}
            height={16}
            rx={3}
            fill="#ffffff"
          />
          <text
            x={cx}
            y={cy + 1}
            textAnchor="middle"
            fontSize="11"
            fill="#5f6b7a"
          >
            {label}
          </text>
        </>
      )}
    </g>
  );
}

const PURPLE = "#7d3cbd";

function RequestDiagram() {
  return (
    <svg
      viewBox="0 0 1080 470"
      width="100%"
      style={{ maxWidth: 1080 }}
      role="img"
      aria-label="Document Tree request flow diagram"
    >
      <Node
        x={20}
        y={40}
        w={150}
        h={52}
        title="Amazon Cognito"
        sub="sign in (code + PKCE)"
        stroke={PURPLE}
      />
      <Node x={20} y={200} w={150} h={56} title="Technician" sub="browser" />
      <Node x={230} y={200} w={150} h={56} title="CloudFront" sub="CDN + OAC" />
      <Node
        x={470}
        y={60}
        w={200}
        h={56}
        title="Amazon S3"
        sub="web app (private, OAC)"
      />
      <Node
        x={470}
        y={307}
        w={200}
        h={64}
        title="Tree Query Lambda"
        sub="Function URL (IAM)"
        stroke={ORANGE}
      />

      <Node
        x={872}
        y={130}
        w={200}
        h={46}
        title="Order + unit lookup"
        sub="order → part → unit manual"
        stroke={GREEN}
      />
      <Node
        x={872}
        y={192}
        w={200}
        h={46}
        title="DynamoDB + S3"
        sub="current revision → tree JSON"
        stroke={GREEN}
      />
      <Node
        x={872}
        y={254}
        w={200}
        h={46}
        title="Bedrock router"
        sub="picks a real section"
        stroke={PURPLE}
      />
      <Node
        x={872}
        y={316}
        w={200}
        h={46}
        title="Amazon S3"
        sub="section text + figure keys"
        stroke={GREEN}
      />
      <Node
        x={872}
        y={378}
        w={200}
        h={46}
        title="Bedrock answer model"
        sub="answers from that text"
        stroke={PURPLE}
      />

      {/* Sign in */}
      <Arrow x1={95} y1={200} x2={95} y2={92} color={BLUE} />
      <text x={105} y={154} fontSize="11" fill="#5f6b7a">
        0. sign in
      </text>
      <Arrow x1={170} y1={228} x2={230} y2={228} color={BLUE} />

      {/* CloudFront fans out with right-angle connectors */}
      <polyline
        points="380,215 420,215 420,88"
        fill="none"
        stroke={BLUE}
        strokeWidth={2}
      />
      <Arrow x1={420} y1={88} x2={470} y2={88} color={BLUE} />
      <text x={412} y={150} textAnchor="end" fontSize="11" fill="#5f6b7a">
        web app
      </text>
      <polyline
        points="380,241 420,241 420,339"
        fill="none"
        stroke={BLUE}
        strokeWidth={2}
      />
      <Arrow x1={420} y1={339} x2={470} y2={339} color={BLUE} />
      <text x={412} y={292} textAnchor="end" fontSize="11" fill="#5f6b7a">
        /api/ask + token
      </text>

      {/* Lambda -> spine -> one straight arrow per step */}
      <line x1={670} y1={339} x2={710} y2={339} stroke={BLUE} strokeWidth={2} />
      <line x1={710} y1={153} x2={710} y2={401} stroke={BLUE} strokeWidth={2} />
      <Arrow
        x1={710}
        y1={153}
        x2={872}
        y2={153}
        label="1. order → manual"
        lx={787}
        ly={145}
        color={BLUE}
      />
      <Arrow
        x1={710}
        y1={215}
        x2={872}
        y2={215}
        label="2. tree (projection)"
        lx={787}
        ly={207}
        color={BLUE}
      />
      <Arrow
        x1={710}
        y1={277}
        x2={872}
        y2={277}
        label="3. route"
        lx={787}
        ly={269}
        color={BLUE}
      />
      <Arrow
        x1={710}
        y1={339}
        x2={872}
        y2={339}
        label="4. section by key"
        lx={787}
        ly={331}
        color={BLUE}
      />
      <Arrow
        x1={710}
        y1={401}
        x2={872}
        y2={401}
        label="5. answer"
        lx={787}
        ly={393}
        color={BLUE}
      />
    </svg>
  );
}

function IngestDiagram() {
  return (
    <svg
      viewBox="0 0 1080 350"
      width="100%"
      style={{ maxWidth: 1080 }}
      role="img"
      aria-label="Document Tree ingest flow diagram"
    >
      <Node
        x={20}
        y={108}
        w={150}
        h={54}
        title="Manual PDF"
        sub="part or unit manual"
      />
      <Node
        x={250}
        y={108}
        w={180}
        h={54}
        title="Amazon S3"
        sub="manuals/ or units/ prefix"
      />
      <Node
        x={530}
        y={104}
        w={170}
        h={62}
        title="Tree Ingest Lambda"
        sub="builds the section tree"
        stroke={ORANGE}
      />
      <Node
        x={880}
        y={20}
        w={190}
        h={52}
        title="Amazon Textract"
        sub="LAYOUT + TABLES (async)"
        stroke={PURPLE}
      />
      <Node
        x={880}
        y={109}
        w={190}
        h={52}
        title="Amazon Bedrock"
        sub="summary + synonyms per node"
        stroke={PURPLE}
      />
      <Node
        x={880}
        y={198}
        w={190}
        h={52}
        title="Amazon S3"
        sub="tree, sections, PDFs, figures"
        stroke={GREEN}
      />
      <Node
        x={880}
        y={287}
        w={190}
        h={52}
        title="Amazon DynamoDB"
        sub="metadata + current revision"
        stroke={GREEN}
      />

      <Arrow
        x1={170}
        y1={135}
        x2={250}
        y2={135}
        label="upload"
        lx={206}
        ly={127}
        color={ORANGE}
      />
      <Arrow
        x1={430}
        y1={135}
        x2={530}
        y2={135}
        label="S3 event"
        lx={476}
        ly={127}
        color={ORANGE}
      />

      {/* Lambda -> spine -> one straight arrow per step */}
      <line
        x1={700}
        y1={135}
        x2={730}
        y2={135}
        stroke={ORANGE}
        strokeWidth={2}
      />
      <line
        x1={730}
        y1={46}
        x2={730}
        y2={313}
        stroke={ORANGE}
        strokeWidth={2}
      />
      <Arrow
        x1={730}
        y1={46}
        x2={880}
        y2={46}
        label="1. layout + tables"
        lx={801}
        ly={38}
        color={ORANGE}
      />
      <Arrow
        x1={730}
        y1={135}
        x2={880}
        y2={135}
        label="2. summaries"
        lx={801}
        ly={127}
        color={ORANGE}
      />
      <Arrow
        x1={730}
        y1={224}
        x2={880}
        y2={224}
        label="3. store payloads"
        lx={801}
        ly={216}
        color={ORANGE}
      />
      <Arrow
        x1={730}
        y1={313}
        x2={880}
        y2={313}
        label="4. set pointer"
        lx={801}
        ly={305}
        color={ORANGE}
      />
    </svg>
  );
}

const STEPS = [
  [
    "0. Sign in",
    "The technician signs in with Amazon Cognito (admin-created users only). " +
      "Every API call carries the login token, and the query Lambda rejects " +
      "any request without a valid one.",
  ],
  [
    "1. Order to manual",
    "The order gives the part. If that part installs differently per unit, " +
      "the unit comes from the work order or the technician picks it from the " +
      "compatible list; it is never guessed from the question. The chosen manual " +
      "is the partition wall: nothing outside it can be read.",
  ],
  [
    "2. Tree only",
    "The Lambda reads the current revision pointer from DynamoDB, then fetches " +
      "only that manual's tree JSON from S3. The tree contains section titles " +
      "and short summaries, while section payloads remain in separate S3 objects.",
  ],
  [
    "3. Route",
    "The configured Bedrock router reads the question and summaries and picks " +
      "a section, level by level, until it reaches a leaf. Any pick that is not " +
      "a real node id at that level is discarded.",
  ],
  [
    "4. Section by key",
    "Only the chosen sections are fetched from S3 by an encoded, exact object key.",
  ],
  [
    "5. Answer",
    "The configured Bedrock answer model uses only that text and must return verbatim quotes, or found=false.",
  ],
  [
    "6. Verify",
    "The Lambda checks every quote is an exact substring of the stored section. " +
      "If any check fails, or the answer is not stated, the response is null " +
      "with a reason.",
  ],
  [
    "7. Show figures",
    "Diagrams from the cited section are returned as short-lived links and shown " +
      "beside the quote. They are reference only: the answer always comes from " +
      "verified text.",
  ],
];

const GUARDS = [
  {
    guard: "Cognito login on every API call",
    stops:
      "Anonymous use, scraping orders or manuals, and runaway Bedrock cost",
  },
  {
    guard: "Partition by manual (part or unit)",
    stops: "Answers drawn from another part's or unit's manual",
  },
  {
    guard: "Unit from work order or explicit pick only",
    stops:
      "Guessing the unit from free text; picks outside the compatible list or conflicting with the order",
  },
  {
    guard: "Router can only pick existing node ids",
    stops: "Invented sections or key poisoning",
  },
  {
    guard: "Exact-key section fetch",
    stops: "Fuzzy or similarity-based retrieval",
  },
  {
    guard: "Forced tool call, temperature 0",
    stops: "Free-form, unparseable output",
  },
  {
    guard: "Verbatim quote check in code",
    stops: "Hallucinated values (e.g. a made-up torque)",
  },
  {
    guard: "Null with a reason",
    stops: "Best-guess answers when the manual is silent",
  },
  {
    guard: "Figures are display-only",
    stops:
      "Answers based on model descriptions of images, which cannot be verified word for word",
  },
  {
    guard: "Audit log per request",
    stops: "Untraceable answers: route, section, and quote are logged",
  },
];

const VECTOR_COMPARE = [
  {
    aspect: "How the source is chosen",
    vector: "Similarity search across every chunk of every document",
    tree: "The order (and unit) fixes one manual; nothing else is searched",
  },
  {
    aspect: "How the section is found",
    vector: "Chunks whose embeddings score closest to the question",
    tree: "The LLM picks a real section from the table of contents by title and summary",
  },
  {
    aspect: "How text is fetched",
    vector: "Top-k chunks by similarity score",
    tree: "The chosen section by exact key",
  },
  {
    aspect: "Wrong manual or unit",
    vector: "Possible: near-identical text from another unit can score higher",
    tree: "Not possible: other manuals are outside the partition",
  },
  {
    aspect: "Exact codes and values",
    vector:
      "Weak: 1.2 Nm and 1.5 Nm, or E-2044 and E-2045, embed almost the same",
    tree: "Values come from the cited section and are checked word for word",
  },
  {
    aspect: "When the answer is missing",
    vector: "Always returns the closest chunks, so it tends to answer anyway",
    tree: "Returns null with a reason",
  },
  {
    aspect: "Explainability",
    vector: "A similarity score (e.g. 0.83)",
    tree: "Order, unit, route through the sections, page, and exact quote",
  },
  {
    aspect: "Different vendor terms",
    vector: "Handled by embedding similarity",
    tree: "Handled by summaries and synonyms written at ingest",
  },
  {
    aspect: "Best fit",
    vector:
      "Open-ended search when you do not know which document holds the answer",
    tree: "A known part or unit with a structured manual, where a wrong answer is costly",
  },
];

const RESOURCES = [
  {
    layer: "Security",
    service: "Amazon Cognito",
    detail:
      "User pool with admin-created users only; Managed Login page; ID token checked by the query Lambda on every request",
  },
  {
    layer: "Web",
    service: "CloudFront",
    detail:
      "Serves the private SPA and sends /api/* to the IAM-protected Lambda Function URL through Lambda OAC",
  },
  {
    layer: "Web",
    service: "Amazon S3 (web)",
    detail:
      "Private, versioned bucket holding the Cloudscape SPA; readable only through CloudFront OAC",
  },
  {
    layer: "Compute",
    service: "Tree Query Lambda",
    detail:
      "Runs outside a VPC. Order → unit → tree → route → section → answer → verify → figures",
  },
  {
    layer: "Compute",
    service: "Tree Ingest Lambda",
    detail:
      "S3 manuals/ and units/ triggers. Textract → tree builder → Bedrock summaries → S3 payloads → DynamoDB pointer",
  },
  {
    layer: "AI",
    service: "Amazon Textract",
    detail: "Regional async document analysis with LAYOUT and TABLES",
  },
  {
    layer: "AI",
    service: "Amazon Bedrock",
    detail:
      "Configurable router and answer model IDs, validated in the selected Region before deployment",
  },
  {
    layer: "Data",
    service: "Amazon DynamoDB",
    detail:
      "On-demand table for current-revision pointers, revision metadata, and the Cognito client identifier",
  },
  {
    layer: "Data",
    service: "Amazon S3 (documents)",
    detail:
      "KMS-encrypted, versioned PDFs, tree JSON, section JSON, and figure crops",
  },
  {
    layer: "Data",
    service: "Order + compatibility tables",
    detail:
      "Mock data bundled with the Lambda; replace with the customer's regional order and part systems",
  },
  {
    layer: "Security",
    service: "AWS KMS",
    detail:
      "Customer managed key for documents and DynamoDB metadata; key rotation enabled",
  },
  {
    layer: "Network",
    service: "Regional public AWS APIs",
    detail:
      "No VPC, NAT gateway, or interface endpoints. CloudFront edge delivery does not replicate application data stores",
  },
];

export default function DocumentTreeArchitecturePage() {
  return (
    <ContentLayout
      header={
        <Header
          variant="h1"
          description="Regional vectorless retrieval with deterministic partitioning, tree routing, and code-verified answers."
        >
          Architecture
        </Header>
      }
    >
      <SpaceBetween size="l">
        <Container
          header={
            <Header variant="h2" description="Blue = request / read path.">
              Request flow
            </Header>
          }
        >
          <RequestDiagram />
        </Container>

        <Container
          header={
            <Header
              variant="h2"
              description="Orange = ingest / write path. Runs ahead of time, once per manual revision."
            >
              Ingest flow
            </Header>
          }
        >
          <IngestDiagram />
        </Container>

        <Container header={<Header variant="h2">How it works</Header>}>
          <SpaceBetween size="m">
            {STEPS.map(([title, body]) => (
              <Box key={title}>
                <b>{title}</b>
                <Box variant="p">{body}</Box>
              </Box>
            ))}
          </SpaceBetween>
        </Container>

        <Container header={<Header variant="h2">Ingest</Header>}>
          <SpaceBetween size="s">
            <Box>
              <b>Parse</b>: a manual uploaded to{" "}
              <code>manuals/&lt;PART&gt;/&lt;rev&gt;.pdf</code> triggers the
              ingest Lambda, which runs Textract with LAYOUT and TABLES.
            </Box>
            <Box>
              <b>Build the tree</b>: headings are nested using the manual's own
              numbering (4, 4.4, 4.4.1). Tables are kept as rows so values stay
              aligned with their labels. Table-of-contents lines and page
              numbers are dropped.
            </Box>
            <Box>
              <b>Summarize</b>: Bedrock writes a one-line summary and a list of
              terms and synonyms for each section, so a question about
              "tightening parameters" still finds a section titled "Tightening
              torques".
            </Box>
            <Box>
              <b>Figures</b>: Textract marks each figure's page and position.
              The Lambda renders that page, crops the figure, and saves it as a
              PNG in S3, linked to its section. Icons smaller than 1% of the
              page are skipped.
            </Box>
            <Box>
              <b>Store</b>: PDFs, trees, section payloads, and figure crops use
              predictable, encoded S3 keys. DynamoDB stores only small revision
              metadata and the current-revision pointer. A newly ingested
              revision becomes current, while S3 versioning and
              revision-specific keys preserve the audit trail.
            </Box>
            <Box>
              <b>Part vs unit manuals</b>: part manuals upload to{" "}
              <code>manuals/&lt;PART&gt;/&lt;rev&gt;.pdf</code>. Unit
              installation manuals upload to{" "}
              <code>units/&lt;UNIT&gt;/&lt;rev&gt;.pdf</code>, and a
              compatibility table maps each part to the units it fits.
            </Box>
          </SpaceBetween>
        </Container>

        <Table
          header={
            <Header
              variant="h2"
              description="Enforced in code, not left to the model."
            >
              Guards
            </Header>
          }
          variant="container"
          columnDefinitions={[
            {
              id: "guard",
              header: "Guard",
              cell: (i: any) => <b>{i.guard}</b>,
              width: 340,
            },
            { id: "stops", header: "Prevents", cell: (i: any) => i.stops },
          ]}
          items={GUARDS}
        />

        <Table
          header={
            <Header
              variant="h2"
              description={
                "Vector search finds text that looks like the question. " +
                "Document Tree finds the right section in the right manual and " +
                "proves the answer is in it."
              }
            >
              Why not vector search?
            </Header>
          }
          variant="container"
          wrapLines
          columnDefinitions={[
            {
              id: "aspect",
              header: "",
              cell: (i: any) => <b>{i.aspect}</b>,
              width: 220,
            },
            {
              id: "vector",
              header: "Vector search (typical RAG)",
              cell: (i: any) => i.vector,
            },
            { id: "tree", header: "Document Tree", cell: (i: any) => i.tree },
          ]}
          items={VECTOR_COMPARE}
        />
        <Table
          header={<Header variant="h2">AWS resources</Header>}
          variant="container"
          columnDefinitions={[
            {
              id: "layer",
              header: "Layer",
              cell: (i: any) => <Badge>{i.layer}</Badge>,
              width: 120,
            },
            {
              id: "service",
              header: "Service",
              cell: (i: any) => <b>{i.service}</b>,
              width: 220,
            },
            { id: "detail", header: "Purpose", cell: (i: any) => i.detail },
          ]}
          items={RESOURCES}
        />
      </SpaceBetween>
    </ContentLayout>
  );
}
