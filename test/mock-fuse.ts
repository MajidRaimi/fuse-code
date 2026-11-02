import modelFixture from "./fixtures/models.json" with { type: "json" };

type ModelEntry = {
  id: string;
  owned_by: string;
  max_model_len?: number;
  preset?: { model: string; name: string };
};

type MessagesRequest = {
  model?: unknown;
  stream?: unknown;
};

type ServerEvent = {
  name: string;
  payload: Record<string, unknown>;
};

type IncomingRequest = {
  method: string;
  pathname: string;
  search: string;
  authorization: string | null;
  beta: string | null;
  body: MessagesRequest | null;
};

const MODEL_CATALOG: { data: ModelEntry[] } = modelFixture;

const LISTEN_HOSTNAME = "127.0.0.1";
const DEFAULT_PORT = 8787;
const DEFAULT_KEY = "test-fuse-key";
const LOGGING_FLAG = "1";
const LONG_CONTEXT_SUFFIX = "[1m]";
const TOOL_CHOICE_REJECTING_MODEL = "tarjama/llmx-1.0";
const REPLY_TEXT = "ok";
const INPUT_TOKENS = 10;
const OUTPUT_TOKENS = 1;
const ARCHIVE_PATHNAME = "/fuse-code.zip";

const listenPort = Number(Bun.env.MOCK_FUSE_PORT ?? DEFAULT_PORT);
const validKey = Bun.env.MOCK_FUSE_KEY ?? DEFAULT_KEY;
const loggingEnabled = Bun.env.MOCK_FUSE_LOG === LOGGING_FLAG;
const archivePath = Bun.env.MOCK_FUSE_ARCHIVE ?? "";

const knownModelIds = new Set(MODEL_CATALOG.data.map((model) => model.id));

function errorResponse(status: number, type: string, message: string): Response {
  return Response.json({ type: "error", error: { type, message } }, { status });
}

function isAuthorized(incoming: IncomingRequest): boolean {
  return incoming.authorization === `Bearer ${validKey}`;
}

function baseModelId(model: string): string {
  return model.endsWith(LONG_CONTEXT_SUFFIX) ? model.slice(0, -LONG_CONTEXT_SUFFIX.length) : model;
}

async function readJsonBody(request: Request): Promise<MessagesRequest | null> {
  const body: unknown = await request.json().catch(() => null);
  return typeof body === "object" && body !== null ? (body as MessagesRequest) : null;
}

function newMessageId(): string {
  return `msg_mock_${crypto.randomUUID().replaceAll("-", "")}`;
}

function usage(): Record<string, number> {
  return {
    input_tokens: INPUT_TOKENS,
    output_tokens: OUTPUT_TOKENS,
    cache_creation_input_tokens: 0,
    cache_read_input_tokens: 0,
  };
}

function completeMessage(model: string): Record<string, unknown> {
  return {
    id: newMessageId(),
    type: "message",
    role: "assistant",
    model,
    content: [{ type: "text", text: REPLY_TEXT }],
    stop_reason: "end_turn",
    stop_sequence: null,
    usage: usage(),
  };
}

function streamEvents(model: string): ServerEvent[] {
  return [
    {
      name: "message_start",
      payload: {
        type: "message_start",
        message: {
          id: newMessageId(),
          type: "message",
          role: "assistant",
          model,
          content: [],
          stop_reason: null,
          stop_sequence: null,
          usage: { ...usage(), output_tokens: 0 },
        },
      },
    },
    {
      name: "content_block_start",
      payload: { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } },
    },
    {
      name: "content_block_delta",
      payload: { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: REPLY_TEXT } },
    },
    { name: "content_block_stop", payload: { type: "content_block_stop", index: 0 } },
    {
      name: "message_delta",
      payload: {
        type: "message_delta",
        delta: { stop_reason: "end_turn", stop_sequence: null },
        usage: { output_tokens: OUTPUT_TOKENS },
      },
    },
    { name: "message_stop", payload: { type: "message_stop" } },
  ];
}

function encodeServerEvent(event: ServerEvent): string {
  return `event: ${event.name}\ndata: ${JSON.stringify(event.payload)}\n\n`;
}

function streamingResponse(model: string): Response {
  return new Response(streamEvents(model).map(encodeServerEvent).join(""), {
    headers: { "content-type": "text/event-stream", "cache-control": "no-cache" },
  });
}

function handleMessages(body: MessagesRequest | null): Response {
  if (body === null) {
    return errorResponse(400, "invalid_request_error", "The request body must be a JSON object.");
  }
  if (typeof body.model !== "string") {
    return errorResponse(400, "invalid_request_error", "model: Field required");
  }
  const model = baseModelId(body.model);
  if (model === TOOL_CHOICE_REJECTING_MODEL) {
    return errorResponse(400, "invalid_request_error", '"auto" tool choice requires --enable-auto-tool-choice');
  }
  if (!knownModelIds.has(model)) {
    return errorResponse(404, "not_found_error", `model: ${body.model}`);
  }
  return body.stream === true ? streamingResponse(model) : Response.json(completeMessage(model));
}

function isArchiveRequest(incoming: IncomingRequest): boolean {
  return archivePath !== "" && incoming.method === "GET" && incoming.pathname === ARCHIVE_PATHNAME;
}

function archiveResponse(): Response {
  return new Response(Bun.file(archivePath), { headers: { "content-type": "application/zip" } });
}

function route(incoming: IncomingRequest): Response {
  if (isArchiveRequest(incoming)) {
    return archiveResponse();
  }
  if (!isAuthorized(incoming)) {
    return errorResponse(401, "authentication_error", "Invalid bearer token.");
  }
  const { method, pathname } = incoming;
  if (method === "GET" && pathname === "/v1/models") {
    return Response.json(MODEL_CATALOG);
  }
  if (method === "POST" && pathname === "/v1/messages") {
    return handleMessages(incoming.body);
  }
  if (method === "POST" && pathname === "/v1/messages/count_tokens") {
    return Response.json({ input_tokens: INPUT_TOKENS });
  }
  return errorResponse(404, "not_found_error", `No route for ${method} ${pathname}.`);
}

async function readIncoming(request: Request): Promise<IncomingRequest> {
  const url = new URL(request.url);
  return {
    method: request.method,
    pathname: url.pathname,
    search: url.search,
    authorization: request.headers.get("authorization"),
    beta: request.headers.get("anthropic-beta"),
    body: request.method === "POST" ? await readJsonBody(request) : null,
  };
}

function describeBody(incoming: IncomingRequest): string {
  if (incoming.method !== "POST") {
    return "";
  }
  if (incoming.body === null) {
    return " body=invalid";
  }
  return ` model=${JSON.stringify(incoming.body.model)} stream=${incoming.body.stream === true}`;
}

function describeRequest(incoming: IncomingRequest, status: number): string {
  const betaPart = incoming.beta === null ? "" : ` beta=${incoming.beta}`;
  return `mock-fuse ${status} ${incoming.method} ${incoming.pathname}${incoming.search}${describeBody(incoming)}${betaPart}`;
}

async function handleRequest(request: Request): Promise<Response> {
  const incoming = await readIncoming(request);
  const response = route(incoming);
  if (loggingEnabled) {
    console.error(describeRequest(incoming, response.status));
  }
  return response;
}

const server = Bun.serve({
  hostname: LISTEN_HOSTNAME,
  port: listenPort,
  fetch: handleRequest,
});

console.log(`mock-fuse listening on http://${LISTEN_HOSTNAME}:${server.port}`);
