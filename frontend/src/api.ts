import { getToken, login } from "./auth";

// API client for the query Lambda through CloudFront. CloudFront signs the
// origin request, while the Lambda validates the Cognito ID token separately.

// Document-tree answers through the CloudFront /api origin.

export interface UnitOption {
  unit_id: string;
  name: string;
  manual_id: string;
  source?: string;
}

export interface Order {
  order_id: string;
  label?: string;
  part_id: string;
  unit_id?: string;
  status: string;
  description: string;
  unit_options: UnitOption[];
}

export interface Figure {
  key: string;
  page: number;
  url?: string;
}

export interface Citation {
  node_id: string;
  title: string;
  pages: number[];
  quote: string;
  figures?: Figure[];
}

export interface RouteHop {
  options: string[];
  picked: string[];
  accepted: string[];
  accepted_titles?: string[];
}

export interface AskResponse {
  status: "ANSWERED" | "NOT_FOUND" | "NEEDS_UNIT";
  answer: string | null;
  message?: string;
  reason?: string;
  citations?: Citation[];
  unit_options?: UnitOption[];
  audit?: {
    order_id: string;
    part_id: string;
    manual_id?: string;
    unit?: UnitOption | null;
    revision?: string;
    manual_url?: string;
    route: RouteHop[];
  };
}

async function authedFetch(url: string, init: RequestInit = {}): Promise<Response> {
  const token = getToken();
  if (!token) {
    await login();
    throw new Error("Signing in...");
  }
  const headers = new Headers(init.headers);
  headers.set("accept", "application/json");
  headers.set("x-id-token", token);
  const res = await fetch(url, { ...init, headers });
  if (res.status === 401) {
    await login();
    throw new Error("Session expired, signing in again...");
  }
  return res;
}

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export async function listOrders(): Promise<Order[]> {
  const res = await authedFetch(`/api/ask/orders`);
  if (!res.ok) throw new Error(`Could not load orders (${res.status})`);
  return (await res.json()).orders;
}

export async function ask(order_id: string, question: string, unit_id?: string): Promise<AskResponse> {
  const payload: Record<string, string> = { order_id, question };
  if (unit_id) payload.unit_id = unit_id;
  const body = JSON.stringify(payload);
  const res = await authedFetch(`/api/ask`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-amz-content-sha256": await sha256Hex(body),
    },
    body,
  });
  if (!res.ok) throw new Error(`Ask failed (${res.status})`);
  return res.json();
}
