import { useEffect, useState } from "react";
import ContentLayout from "@cloudscape-design/components/content-layout";
import Header from "@cloudscape-design/components/header";
import Container from "@cloudscape-design/components/container";
import SpaceBetween from "@cloudscape-design/components/space-between";
import FormField from "@cloudscape-design/components/form-field";
import Select from "@cloudscape-design/components/select";
import Textarea from "@cloudscape-design/components/textarea";
import Button from "@cloudscape-design/components/button";
import Box from "@cloudscape-design/components/box";
import Alert from "@cloudscape-design/components/alert";
import StatusIndicator from "@cloudscape-design/components/status-indicator";
import ExpandableSection from "@cloudscape-design/components/expandable-section";
import ColumnLayout from "@cloudscape-design/components/column-layout";
import KeyValuePairs from "@cloudscape-design/components/key-value-pairs";
import { ask, listOrders, type AskResponse, type Order } from "./api";

type Opt = { label: string; value: string; description?: string };

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : "Request failed";
}

// Every example below was run against the live system on 2026-10-22 and returns a verified answer.
// hasFigure means the answer also returns at least one figure from the manual (checked live).
type Example = { question: string; hasFigure: boolean };
const EXAMPLES: Record<string, Example[]> = {
  "ORD-1001": [
    { question: "What torque do I use for the mains terminals?", hasFigure: false },
    { question: "What are the tightening parameters for the ground connection on a K4 enclosure?", hasFigure: false },
    { question: "How much clearance do I need above and below the drive for cooling?", hasFigure: true },
    { question: "Which terminals do I connect the RS485 serial cable to?", hasFigure: true },
  ],
};
const UNIT_EXAMPLES: Record<string, Example[]> = {};

const SOURCE_LABEL: Record<string, string> = {
  work_order: "from the work order",
  technician: "selected by technician",
  auto_single: "only compatible unit",
};

const REASONS: Record<string, string> = {
  ORDER_NOT_FOUND: "No order with that ID.",
  MANUAL_NOT_FOUND: "No manual is loaded for this part.",
  NO_MATCHING_SECTION: "No section of this manual covers the question.",
  SECTION_MISSING: "The chosen section could not be loaded.",
  NOT_IN_SECTION: "The section was found, but it does not state the answer.",
  NO_QUOTE: "The model gave no supporting quote, so the answer was withheld.",
  INVALID_UNIT: "That unit is not compatible with this part.",
  UNIT_MISMATCH: "The selected unit does not match the unit on the work order.",
  UNVERIFIED_QUOTE: "The supporting quote did not match the manual word for word, so the answer was withheld.",
};

export default function AskPage() {
  const [orders, setOrders] = useState<Order[]>([]);
  const [order, setOrder] = useState<Opt | null>(null);
  const [unit, setUnit] = useState<Opt | null>(null);
  const [question, setQuestion] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [result, setResult] = useState<AskResponse | null>(null);
  const [elapsed, setElapsed] = useState<number | null>(null);

  useEffect(() => {
    listOrders()
      .then((loadedOrders) => {
        setOrders(loadedOrders);
        if (loadedOrders.length) setOrder(toOpt(loadedOrders[0]));
      })
      .catch((requestError: unknown) => setError(errorMessage(requestError)));
  }, []);

  const current = orders.find((candidate) => candidate.order_id === order?.value);
  const partId = current?.part_id ?? "";
  const unitOptions = current?.unit_options ?? [];
  const fixedUnit = current?.unit_id;
  const needsPick = !fixedUnit && unitOptions.length > 1;
  const examples = needsPick
    ? unit
      ? UNIT_EXAMPLES[unit.value] ?? []
      : []
    : EXAMPLES[order?.value ?? ""] ?? [];

  async function run(questionText = question) {
    if (!order || !questionText.trim()) return;
    setQuestion(questionText);
    setLoading(true);
    setError(null);
    setResult(null);
    const startedAt = performance.now();
    try {
      setResult(await ask(order.value, questionText.trim(), needsPick ? unit?.value : undefined));
      setElapsed((performance.now() - startedAt) / 1000);
    } catch (requestError: unknown) {
      setError(errorMessage(requestError));
    } finally {
      setLoading(false);
    }
  }

  return (
    <ContentLayout
      header={
        <Header
          variant="h1"
        >
          Ask a Manual
        </Header>
      }
    >
      <SpaceBetween size="l">
        <Container header={<Header variant="h2">Question</Header>}>
          <SpaceBetween size="m">
            <ColumnLayout columns={2}>
              <FormField label="Order ID" description={partId ? `Part: ${partId}` : undefined}>
                <Select
                  selectedOption={order}
                  onChange={(event) => {
                    setOrder(event.detail.selectedOption as Opt);
                    setUnit(null);
                    setResult(null);
                  }}
                  options={orders.map(toOpt)}
                  placeholder="Select an order"
                />
              </FormField>
              <FormField label="Try an example" description={needsPick && !unit ? "Select a unit first to see examples." : undefined}>
                <SpaceBetween size="xs" direction="horizontal">
                  {examples.map((example) => (
                    <Button key={example.question} variant="inline-link" onClick={() => run(example.question)}>
                      {example.hasFigure ? <WithIcon text={example.question} /> : example.question}
                    </Button>
                  ))}
                </SpaceBetween>
              </FormField>
            </ColumnLayout>
            {unitOptions.length > 0 && (
              <FormField
                label="Unit being installed into"
                description={
                  fixedUnit
                    ? "Set on the work order. Cannot be changed here."
                    : needsPick
                    ? "This part installs differently per unit. Pick the unit so the right installation manual is used."
                    : "Only one compatible unit."
                }
              >
                {needsPick ? (
                  <Select
                    selectedOption={unit}
                    onChange={(event) => {
                      setUnit(event.detail.selectedOption as Opt);
                      setResult(null);
                    }}
                    options={unitOptions.map((unitOption) => ({ label: unitOption.unit_id, value: unitOption.unit_id, description: unitOption.name }))}
                    placeholder="Select a unit"
                  />
                ) : (
                  <Box>
                    <b>{fixedUnit ?? unitOptions[0].unit_id}</b>{" "}
                    {unitOptions.find((unitOption) => unitOption.unit_id === (fixedUnit ?? unitOptions[0].unit_id))?.name}
                  </Box>
                )}
              </FormField>
            )}
            <FormField label="Technician question">
              <Textarea
                value={question}
                rows={2}
                placeholder="How tight do I screw the bolts?"
                onChange={(event) => setQuestion(event.detail.value)}
              />
            </FormField>
            <Button variant="primary" loading={loading} onClick={() => run()} disabled={!order || !question.trim()}>
              Ask
            </Button>
          </SpaceBetween>
        </Container>

        {error && (
          <Alert type="error" header="Request error">
            {error}
          </Alert>
        )}

        {result && (
          <ResultView
            response={result}
            elapsed={elapsed}
            onPickUnit={(unitId) => {
              const selectedUnit = { label: unitId, value: unitId };
              setUnit(selectedUnit);
              if (order && question.trim()) {
                setLoading(true);
                setResult(null);
                const startedAt = performance.now();
                ask(order.value, question.trim(), unitId)
                  .then((response) => {
                    setResult(response);
                    setElapsed((performance.now() - startedAt) / 1000);
                  })
                  .catch((requestError: unknown) => setError(errorMessage(requestError)))
                  .finally(() => setLoading(false));
              }
            }}
          />
        )}
      </SpaceBetween>
    </ContentLayout>
  );
}

// Small colourful flower: marks examples whose answer includes a picture from the manual.
const PETALS = ["#f9a825", "#fb8c00", "#e53935", "#d81b60", "#8e24aa", "#3949ab", "#039be5", "#43a047"];
function PhotoIcon() {
  return (
    <svg
      width="14"
      height="14"
      viewBox="0 0 24 24"
      role="img"
      aria-label="Answer includes a picture"
      style={{ verticalAlign: "-2px", marginLeft: 6 }}
    >
      <title>Answer includes a picture from the manual</title>
      {PETALS.map((color, index) => (
        <ellipse key={color} cx="12" cy="6.5" rx="3.2" ry="5.5" fill={color} opacity="0.9" transform={`rotate(${index * 45} 12 12)`} />
      ))}
    </svg>
  );
}

// Keeps the icon glued to the last word so it never wraps onto a line by itself.
function WithIcon({ text }: { text: string }) {
  const cut = text.lastIndexOf(" ");
  return (
    <>
      {cut > 0 ? text.slice(0, cut + 1) : ""}
      <span style={{ whiteSpace: "nowrap" }}>
        {cut > 0 ? text.slice(cut + 1) : text}
        <PhotoIcon />
      </span>
    </>
  );
}

function dedupeFigures(citations: NonNullable<AskResponse["citations"]>) {
  const seen = new Set<string>();
  return citations.map((citation) => ({
    ...citation,
    figures: (citation.figures ?? []).filter((figure) => {
      if (seen.has(figure.key)) return false;
      seen.add(figure.key);
      return true;
    }),
  }));
}

function toOpt(order: Order): Opt {
  return {
    label: order.label ?? order.order_id,
    value: order.order_id,
    description: order.description,
  };
}

function ResultView({
  response,
  elapsed,
  onPickUnit,
}: {
  response: AskResponse;
  elapsed: number | null;
  onPickUnit: (unitId: string) => void;
}) {
  const answered = response.status === "ANSWERED";
  if (response.status === "NEEDS_UNIT") {
    return (
      <Alert type="info" header="Which unit is this going into?">
        <SpaceBetween size="s">
          <Box>{response.message} The system will not guess the unit from the question.</Box>
          <SpaceBetween size="xs" direction="horizontal">
            {(response.unit_options ?? []).map((unitOption) => (
              <Button key={unitOption.unit_id} onClick={() => onPickUnit(unitOption.unit_id)}>
                {unitOption.unit_id}: {unitOption.name}
              </Button>
            ))}
          </SpaceBetween>
        </SpaceBetween>
      </Alert>
    );
  }
  return (
    <SpaceBetween size="l">
      <Container
        header={
          <Header
            variant="h2"
            description={elapsed ? `Answered in ${elapsed.toFixed(1)}s` : undefined}
          >
            <StatusIndicator type={answered ? "success" : "warning"}>
              {answered ? "Verified" : "No answer (null)"}
            </StatusIndicator>
          </Header>
        }
      >
        {answered ? (
          <Box variant="p">
            <span style={{ whiteSpace: "pre-wrap" }}>{response.answer}</span>
          </Box>
        ) : (
          <SpaceBetween size="xs">
            <Box variant="p">{response.message}</Box>
            {response.reason && (
              <Box color="text-status-inactive" fontSize="body-s">
                Reason: {REASONS[response.reason] ?? response.reason} ({response.reason})
              </Box>
            )}
          </SpaceBetween>
        )}
      </Container>

      {answered && response.citations?.length ? (
        <Container header={<Header
                variant="h2"
                counter={`(${response.citations.length})`}
                actions={
                  response.audit?.manual_url ? (
                    <Button href={response.audit.manual_url} target="_blank" iconName="external" iconAlign="right">
                      Show manual
                    </Button>
                  ) : undefined
                }
              >
                Evidence from the manual
              </Header>}>
          <SpaceBetween size="m">
            {dedupeFigures(response.citations).map((citation, citationIndex) => (
              <div key={citationIndex}>
                <Box variant="h4">
                  {citation.title} <Box variant="span" color="text-status-inactive">page {citation.pages.join(", ")}</Box>
                </Box>
                <Box variant="code">
                  <span style={{ whiteSpace: "pre-wrap" }}>{citation.quote}</span>
                </Box>
                {response.audit?.manual_url && citation.pages.length > 0 && (
                  <Box margin={{ top: "xs" }}>
                    <Button
                      variant="inline-link"
                      iconName="external"
                      iconAlign="right"
                      href={`${response.audit.manual_url}#page=${citation.pages[0]}`}
                      target="_blank"
                    >
                      Open manual at page {citation.pages[0]}
                    </Button>
                  </Box>
                )}
                {citation.figures?.some((figure) => figure.url) && (
                  <div style={{ marginTop: 12 }}>
                    <Box variant="small" color="text-status-inactive">
                      Figures from this section (for reference, not used to produce the answer)
                    </Box>
                    <div style={{ display: "flex", flexWrap: "wrap", gap: 12, marginTop: 6 }}>
                      {citation.figures
                        .filter((figure) => figure.url)
                        .map((figure) => (
                          <a key={figure.key} href={figure.url} target="_blank" rel="noopener noreferrer" style={{ textAlign: "center" }}>
                            <img
                              src={figure.url}
                              alt={`Figure from ${citation.title}, page ${figure.page}`}
                              style={{ maxWidth: 260, maxHeight: 200, border: "1px solid #d1d5db", borderRadius: 6, background: "#fff", padding: 4 }}
                            />
                            <Box variant="small" color="text-status-inactive">page {figure.page}</Box>
                          </a>
                        ))}
                    </div>
                  </div>
                )}
              </div>
            ))}
          </SpaceBetween>
        </Container>
      ) : null}

      {response.audit && (
        <ExpandableSection headerText="Audit trail: how the answer was found" variant="container">
          <SpaceBetween size="m">
            <KeyValuePairs
              columns={4}
              items={[
                { label: "Order", value: response.audit.order_id },
                { label: "Part", value: response.audit.part_id },
                {
                  label: "Unit",
                  value: response.audit.unit
                    ? `${response.audit.unit.unit_id} (${SOURCE_LABEL[response.audit.unit.source ?? ""] ?? response.audit.unit.source})`
                    : "Not unit-specific",
                },
                { label: "Manual used (partition)", value: `${response.audit.manual_id ?? response.audit.part_id} ${response.audit.revision ?? ""}` },
              ]}
            />
            {response.audit.route.map((hop, routeIndex) => (
              <Box key={routeIndex}>
                <b>Step {routeIndex + 1}:</b> {hop.options.length} sections offered, chose{" "}
                {hop.accepted_titles?.length ? hop.accepted_titles.join("; ") : "none"}
                {hop.picked.length !== hop.accepted.length && (
                  <Box variant="span" color="text-status-error">
                    {" "}(rejected invalid picks: {hop.picked.filter((pickedNodeId) => !hop.accepted.includes(pickedNodeId)).join(", ")})
                  </Box>
                )}
              </Box>
            ))}
          </SpaceBetween>
        </ExpandableSection>
      )}
    </SpaceBetween>
  );
}
