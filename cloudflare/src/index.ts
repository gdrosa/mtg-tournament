import { DurableObject } from "cloudflare:workers";

const PROTOCOL_VERSION = 1;
const ROOM_LIFETIME_MS = 24 * 60 * 60 * 1000;
const RATE_WINDOW_MS = 60 * 1000;
const PROVISION_WINDOW_MS = 60 * 60 * 1000;

export const LIMITS = Object.freeze({
  maxPlayers: 128,
  maxPendingHosts: 4,
  maxPlayerMessagesPerMinute: 60,
  maxPlayerBytesPerMinute: 1024 * 1024,
  maxRoomPlayerMessagesPerMinute: 1_200,
  maxRoomPlayerBytesPerMinute: 16 * 1024 * 1024,
  // The authenticated phone sends one tailored snapshot per connected player
  // after each mutation. This budget accommodates a busy 64-player lobby while
  // retaining a hard ceiling if hostile player traffic causes excessive fanout.
  maxHostMessagesPerMinute: 20_000,
  maxHostBytesPerMinute: 256 * 1024 * 1024,
  maxPlayerMessageBytes: 256 * 1024,
  maxHostMessageBytes: 1024 * 1024,
  maxRoomsPerIpPerHour: 20,
});

interface Env {
  ROOMS: DurableObjectNamespace<RelayRoom>;
  PROVISION_LIMITERS: DurableObjectNamespace<ProvisionLimiter>;
  ASSETS: Fetcher;
  /// Comma-separated list of accepted provisioning keys, set with
  /// `wrangler secret put PROVISION_KEYS`. Unset means anyone may create rooms.
  PROVISION_KEYS?: string;
}

interface RoomMeta {
  createdAt: number;
  expiresAt: number;
  secretHash: string;
}

interface BaseAttachment {
  connectedAt: number;
  connectionId: string;
  rateBytes: number;
  rateMessages: number;
  rateWindowAt: number;
}

interface PendingHostAttachment extends BaseAttachment {
  role: "host-pending";
}

interface HostAttachment extends BaseAttachment {
  role: "host";
  roomPlayerRateBytes: number;
  roomPlayerRateMessages: number;
  roomPlayerRateWindowAt: number;
}

interface PlayerAttachment extends BaseAttachment {
  authForwarded: boolean;
  authGeneration: string;
  clientId: string;
  reauthAllowed: boolean;
  role: "player";
}

type SocketAttachment =
  | PendingHostAttachment
  | HostAttachment
  | PlayerAttachment;

type JsonObject = Record<string, unknown>;

interface ProvisionBucket {
  count: number;
  windowAt: number;
}

function json(data: unknown, init: ResponseInit = {}): Response {
  const headers = new Headers(init.headers);
  headers.set("content-type", "application/json; charset=utf-8");
  headers.set("cache-control", "no-store");
  return new Response(JSON.stringify(data), { ...init, headers });
}

function errorResponse(status: number, code: string, message: string): Response {
  return json({ error: { code, message } }, { status });
}

function randomToken(byteLength: number): string {
  const bytes = crypto.getRandomValues(new Uint8Array(byteLength));
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary)
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
}

async function sha256(value: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(value),
  );
  return Array.from(new Uint8Array(digest), (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
}

function constantTimeEqual(left: string, right: string): boolean {
  if (left.length !== right.length) return false;
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) {
    difference |= left.charCodeAt(index) ^ right.charCodeAt(index);
  }
  return difference === 0;
}

function parseObject(message: string | ArrayBuffer): JsonObject | null {
  if (typeof message !== "string") return null;
  try {
    const parsed: unknown = JSON.parse(message);
    if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
      return null;
    }
    return parsed as JsonObject;
  } catch {
    return null;
  }
}

function messageByteLength(message: string | ArrayBuffer): number {
  return typeof message === "string"
    ? new TextEncoder().encode(message).byteLength
    : message.byteLength;
}

function socketIsOpen(socket: WebSocket): boolean {
  return socket.readyState === 1;
}

function safeSend(socket: WebSocket, value: unknown, direct = false): boolean {
  if (!socketIsOpen(socket)) return false;
  try {
    const message =
      direct && typeof value === "string" ? value : JSON.stringify(value);
    socket.send(message);
    return true;
  } catch {
    return false;
  }
}

function safeClose(socket: WebSocket, code: number, reason: string): void {
  if (socket.readyState > 1) return;
  try {
    socket.close(code, reason.slice(0, 120));
  } catch {
    // The peer may have closed between the readyState check and close().
  }
}

function attachmentOf(socket: WebSocket): SocketAttachment | null {
  try {
    const attachment: unknown = socket.deserializeAttachment();
    if (!attachment || typeof attachment !== "object") return null;
    const role = (attachment as { role?: unknown }).role;
    if (role !== "host-pending" && role !== "host" && role !== "player") {
      return null;
    }
    return attachment as SocketAttachment;
  } catch {
    return null;
  }
}

function newBaseAttachment(): BaseAttachment {
  const now = Date.now();
  return {
    connectedAt: now,
    connectionId: crypto.randomUUID(),
    rateBytes: 0,
    rateMessages: 0,
    rateWindowAt: now,
  };
}

function validRoomId(value: string): boolean {
  return /^[A-Za-z0-9_-]{20,64}$/.test(value);
}

function validClientId(value: unknown): value is string {
  return typeof value === "string" && /^[0-9a-f-]{36}$/.test(value);
}

export class ProvisionLimiter extends DurableObject<Env> {
  override async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (request.method !== "POST" || url.pathname !== "/take") {
      return errorResponse(404, "not_found", "Route not found");
    }

    const now = Date.now();
    const outcome = await this.ctx.storage.transaction(async (transaction) => {
      let bucket = await transaction.get<ProvisionBucket>("bucket");
      if (!bucket || now - bucket.windowAt >= PROVISION_WINDOW_MS) {
        bucket = { count: 0, windowAt: now };
      }

      if (bucket.count >= LIMITS.maxRoomsPerIpPerHour) {
        return {
          allowed: false,
          retryAfterSeconds: Math.max(
            1,
            Math.ceil(
              (bucket.windowAt + PROVISION_WINDOW_MS - now) / 1000,
            ),
          ),
        };
      }

      bucket.count += 1;
      await transaction.put("bucket", bucket);
      return { allowed: true, retryAfterSeconds: 0 };
    });

    if (!outcome.allowed) {
      return json(
        {
          error: {
            code: "provision_rate_limited",
            message: "Too many rooms were created from this address",
          },
        },
        {
          status: 429,
          headers: { "retry-after": String(outcome.retryAfterSeconds) },
        },
      );
    }

    await this.ctx.storage.setAlarm(now + PROVISION_WINDOW_MS);
    return json({ ok: true });
  }

  override async alarm(): Promise<void> {
    await this.ctx.storage.deleteAll();
  }
}

export class RelayRoom extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.ctx.setWebSocketAutoResponse(
      new WebSocketRequestResponsePair("ping", "pong"),
    );
  }

  override async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/provision") return this.provision(request);

    const meta = await this.ctx.storage.get<RoomMeta>("meta");
    if (!meta) {
      return errorResponse(404, "room_not_found", "Room does not exist");
    }
    if (Date.now() >= meta.expiresAt) {
      await this.expireRoom();
      return errorResponse(410, "room_expired", "Room has expired");
    }

    if (url.pathname === "/host") return this.openHost(request, meta);
    if (url.pathname === "/player") return this.openPlayer(request, meta);
    return errorResponse(404, "not_found", "Route not found");
  }

  override async webSocketMessage(
    socket: WebSocket,
    message: string | ArrayBuffer,
  ): Promise<void> {
    const attachment = attachmentOf(socket);
    if (!attachment) {
      safeClose(socket, 1008, "Missing connection state");
      return;
    }

    const meta = await this.ctx.storage.get<RoomMeta>("meta");
    if (!meta || Date.now() >= meta.expiresAt) {
      safeSend(socket, { type: "relay.error", message: "Room expired" });
      await this.expireRoom();
      return;
    }

    const frameBytes = messageByteLength(message);
    const frameLimit =
      attachment.role === "player"
        ? LIMITS.maxPlayerMessageBytes
        : LIMITS.maxHostMessageBytes;
    if (frameBytes > frameLimit) {
      safeSend(socket, {
        type: "relay.error",
        message: "Message is too large",
      });
      safeClose(socket, 1009, "Message is too large");
      return;
    }

    const messageLimit =
      attachment.role === "player"
        ? LIMITS.maxPlayerMessagesPerMinute
        : LIMITS.maxHostMessagesPerMinute;
    const byteLimit =
      attachment.role === "player"
        ? LIMITS.maxPlayerBytesPerMinute
        : LIMITS.maxHostBytesPerMinute;
    if (
      !this.consumeMessageAllowance(
        socket,
        attachment,
        messageLimit,
        byteLimit,
        frameBytes,
      )
    ) {
      return;
    }

    if (attachment.role === "player") {
      const host = this.hostSocket();
      if (!host) {
        safeSend(socket, {
          type: "relay.error",
          message: "The tournament host disconnected",
        });
        safeClose(socket, 1012, "Host disconnected");
        return;
      }
      if (!this.consumeRoomPlayerAllowance(host, frameBytes)) {
        safeSend(socket, {
          type: "relay.error",
          message: "The tournament room is receiving too much traffic",
        });
        safeClose(socket, 1008, "Room traffic limit exceeded");
        return;
      }
    }

    const payload = parseObject(message);
    if (!payload) {
      safeSend(socket, {
        type: "relay.error",
        message: "Messages must be JSON objects",
      });
      safeClose(socket, 1003, "Expected a JSON object");
      return;
    }

    if (attachment.role === "host-pending") {
      await this.authenticateHost(socket, attachment, payload, meta);
      return;
    }

    if (attachment.role === "host") {
      await this.handleHostMessage(socket, payload);
      return;
    }

    this.handlePlayerMessage(socket, attachment, payload);
  }

  override async webSocketClose(
    socket: WebSocket,
    code: number,
    reason: string,
    wasClean: boolean,
  ): Promise<void> {
    const attachment = attachmentOf(socket);
    if (!attachment) return;

    if (attachment.role === "host") {
      const replacement = this.hostSocket(socket);
      if (!replacement) {
        for (const player of this.playerSockets()) {
          safeSend(player.socket, {
            type: "relay.error",
            message: "The tournament host disconnected",
          });
          safeClose(player.socket, 1012, "Host disconnected");
        }
      }
      return;
    }

    if (attachment.role === "player") {
      const host = this.hostSocket();
      if (host) {
        safeSend(host.socket, {
          type: "player.close",
          clientId: attachment.clientId,
          code,
          reason,
          wasClean,
        });
      }
    }
  }

  override webSocketError(socket: WebSocket): void {
    safeClose(socket, 1011, "Relay connection error");
  }

  override async alarm(): Promise<void> {
    await this.expireRoom();
  }

  private async provision(request: Request): Promise<Response> {
    if (request.method !== "POST") {
      return errorResponse(405, "method_not_allowed", "Expected POST");
    }

    const existing = await this.ctx.storage.get<RoomMeta>("meta");
    if (existing && existing.expiresAt > Date.now()) {
      return errorResponse(409, "room_exists", "Room is already provisioned");
    }

    let input: unknown;
    try {
      input = await request.json();
    } catch {
      return errorResponse(400, "invalid_request", "Invalid JSON body");
    }

    if (
      !input ||
      typeof input !== "object" ||
      typeof (input as { secretHash?: unknown }).secretHash !== "string" ||
      !/^[0-9a-f]{64}$/.test(
        (input as { secretHash: string }).secretHash,
      ) ||
      !Number.isSafeInteger((input as { createdAt?: unknown }).createdAt) ||
      !Number.isSafeInteger((input as { expiresAt?: unknown }).expiresAt)
    ) {
      return errorResponse(400, "invalid_request", "Invalid room metadata");
    }

    const { createdAt, expiresAt, secretHash } = input as RoomMeta;
    const now = Date.now();
    if (
      createdAt > now + 60_000 ||
      expiresAt <= now ||
      expiresAt - createdAt > ROOM_LIFETIME_MS
    ) {
      return errorResponse(400, "invalid_expiry", "Invalid room expiry");
    }

    const meta: RoomMeta = { createdAt, expiresAt, secretHash };
    await this.ctx.storage.put("meta", meta);
    await this.ctx.storage.setAlarm(expiresAt);
    return json({ ok: true }, { status: 201 });
  }

  private openHost(request: Request, meta: RoomMeta): Response {
    if (!this.isWebSocketUpgrade(request)) {
      return errorResponse(426, "upgrade_required", "Expected WebSocket upgrade");
    }

    const pending = this.hostSockets().filter(
      ({ attachment }) => attachment.role === "host-pending",
    );
    if (pending.length >= LIMITS.maxPendingHosts) {
      pending.sort(
        (left, right) =>
          left.attachment.connectedAt - right.attachment.connectedAt,
      );
      const oldest = pending[0];
      if (oldest) safeClose(oldest.socket, 1013, "Superseded by a new login");
    }

    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    const attachment: PendingHostAttachment = {
      ...newBaseAttachment(),
      role: "host-pending",
    };
    server.serializeAttachment(attachment);
    this.ctx.acceptWebSocket(server, ["host"]);
    safeSend(server, {
      type: "host.auth_required",
      protocol: PROTOCOL_VERSION,
      expiresAt: meta.expiresAt,
    });
    return new Response(null, { status: 101, webSocket: client });
  }

  private openPlayer(request: Request, meta: RoomMeta): Response {
    if (!this.isWebSocketUpgrade(request)) {
      return errorResponse(426, "upgrade_required", "Expected WebSocket upgrade");
    }

    const host = this.hostSocket();
    if (!host) {
      return errorResponse(
        503,
        "host_offline",
        "The tournament host is not connected",
      );
    }

    if (this.playerSockets().length >= LIMITS.maxPlayers) {
      return errorResponse(503, "room_full", "The tournament room is full");
    }

    if (!this.consumeRoomPlayerAllowance(host, 0)) {
      return errorResponse(
        429,
        "room_rate_limited",
        "The tournament room is receiving too much traffic",
      );
    }

    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    const attachment: PlayerAttachment = {
      ...newBaseAttachment(),
      authForwarded: false,
      authGeneration: host.attachment.connectionId,
      clientId: crypto.randomUUID(),
      reauthAllowed: false,
      role: "player",
    };
    server.serializeAttachment(attachment);
    this.ctx.acceptWebSocket(server, ["player"]);

    safeSend(server, {
      type: "relay.ready",
      protocol: PROTOCOL_VERSION,
      clientId: attachment.clientId,
      expiresAt: meta.expiresAt,
    });
    if (
      !safeSend(host.socket, {
        type: "player.open",
        clientId: attachment.clientId,
      })
    ) {
      safeClose(server, 1012, "Host disconnected");
    }

    return new Response(null, { status: 101, webSocket: client });
  }

  private async authenticateHost(
    socket: WebSocket,
    attachment: PendingHostAttachment,
    payload: JsonObject,
    meta: RoomMeta,
  ): Promise<void> {
    const secret = payload.secret;
    if (
      payload.type !== "host.auth" ||
      payload.protocol !== PROTOCOL_VERSION ||
      typeof secret !== "string" ||
      secret.length < 20 ||
      secret.length > 256
    ) {
      safeSend(socket, {
        type: "relay.error",
        message: "The first host message must authenticate protocol 1",
      });
      safeClose(socket, 1008, "Host authentication required");
      return;
    }

    const candidateHash = await sha256(secret);
    if (!constantTimeEqual(candidateHash, meta.secretHash)) {
      safeSend(socket, {
        type: "relay.error",
        message: "Host authentication failed",
      });
      safeClose(socket, 1008, "Host authentication failed");
      return;
    }

    const previousHost = this.hostSocket(socket);
    const authenticated: HostAttachment = {
      ...attachment,
      role: "host",
      roomPlayerRateBytes: previousHost?.attachment.roomPlayerRateBytes ?? 0,
      roomPlayerRateMessages:
        previousHost?.attachment.roomPlayerRateMessages ?? 0,
      roomPlayerRateWindowAt:
        previousHost?.attachment.roomPlayerRateWindowAt ?? Date.now(),
    };
    socket.serializeAttachment(authenticated);

    // A correctly authenticated reconnect replaces stale and unauthenticated
    // host sockets without disconnecting players.
    for (const candidate of this.hostSockets()) {
      if (candidate.socket !== socket) {
        safeClose(candidate.socket, 1012, "Host reconnected");
      }
    }

    safeSend(socket, {
      type: "host.ready",
      protocol: PROTOCOL_VERSION,
      expiresAt: meta.expiresAt,
    });

    // Recreate the phone's virtual connections after a host reconnect.
    for (const player of this.playerSockets()) {
      player.attachment.authForwarded = false;
      player.attachment.authGeneration = authenticated.connectionId;
      player.attachment.reauthAllowed = false;
      player.socket.serializeAttachment(player.attachment);
      safeSend(socket, {
        type: "player.open",
        clientId: player.attachment.clientId,
        reconnected: true,
      });
      // A correctly authenticated replacement can arrive before the old host's
      // close event, so the player socket may survive. Prompt that browser to
      // re-send its session token to the phone's newly-created Connection.
      safeSend(player.socket, {
        type: "relay.ready",
        protocol: PROTOCOL_VERSION,
        clientId: player.attachment.clientId,
        hostOnline: true,
        reconnected: true,
      });
    }
  }

  private async handleHostMessage(
    socket: WebSocket,
    payload: JsonObject,
  ): Promise<void> {
    if (payload.type === "host.ping") {
      safeSend(socket, { type: "host.pong" });
      return;
    }

    if (payload.type === "room.close") {
      safeSend(socket, { type: "room.closed" });
      await this.expireRoom("Tournament ended");
      return;
    }

    if (
      payload.type !== "player.send" &&
      payload.type !== "player.response" &&
      payload.type !== "player.close"
    ) {
      safeSend(socket, {
        type: "host.error",
        message: "Unknown host message type",
      });
      return;
    }

    if (!validClientId(payload.clientId)) {
      safeSend(socket, {
        type: "host.error",
        message: "A valid clientId is required",
      });
      return;
    }

    const target = this.findPlayer(payload.clientId);
    if (!target) {
      safeSend(socket, {
        type: "host.error",
        clientId: payload.clientId,
        message: "Player is no longer connected",
      });
      return;
    }

    if (this.hostMessageAllowsReauthentication(payload)) {
      target.attachment.reauthAllowed = true;
      target.socket.serializeAttachment(target.attachment);
    }

    if (payload.type === "player.close") {
      safeClose(target.socket, 1000, "Closed by tournament host");
      return;
    }

    if (payload.type === "player.send") {
      if (!("payload" in payload)) {
        safeSend(socket, {
          type: "host.error",
          clientId: payload.clientId,
          message: "player.send requires payload",
        });
        return;
      }
      safeSend(target.socket, payload.payload, true);
      return;
    }

    // player.response is a convenience for command/reply clients. Hosts can
    // alternatively send the same object through player.send.
    if ("payload" in payload) {
      safeSend(target.socket, payload.payload, true);
      return;
    }
    const { clientId: _clientId, type: _type, ...response } = payload;
    safeSend(target.socket, { type: "response", ...response });
  }

  private handlePlayerMessage(
    socket: WebSocket,
    attachment: PlayerAttachment,
    payload: JsonObject,
  ): void {
    const host = this.hostSocket();
    if (!host) {
      safeSend(socket, {
        type: "relay.error",
        message: "The tournament host disconnected",
      });
      safeClose(socket, 1012, "Host disconnected");
      return;
    }

    if (attachment.authGeneration !== host.attachment.connectionId) {
      attachment.authForwarded = false;
      attachment.authGeneration = host.attachment.connectionId;
      attachment.reauthAllowed = false;
      socket.serializeAttachment(attachment);
    }

    if (payload.type === "auth") {
      const token = payload.token;
      if (token !== null && token !== undefined && typeof token !== "string") {
        safeSend(socket, {
          type: "relay.error",
          message: "Authentication tokens must be strings",
        });
        safeClose(socket, 1008, "Invalid authentication token");
        return;
      }
      if (typeof token === "string" && token.length > 1024) {
        safeSend(socket, {
          type: "relay.error",
          message: "Authentication token is too large",
        });
        safeClose(socket, 1008, "Invalid authentication token");
        return;
      }
      if (attachment.authForwarded && !attachment.reauthAllowed) return;
      attachment.authForwarded = true;
      attachment.reauthAllowed = false;
      socket.serializeAttachment(attachment);
    }

    if (
      !safeSend(host.socket, {
        type: "player.message",
        clientId: attachment.clientId,
        payload,
      })
    ) {
      safeClose(socket, 1012, "Host disconnected");
    }
  }

  private hostMessageAllowsReauthentication(payload: JsonObject): boolean {
    let candidate: unknown;
    if ("payload" in payload) {
      candidate = payload.payload;
    } else if (payload.type === "player.response") {
      candidate = payload;
    } else {
      return false;
    }

    const response =
      typeof candidate === "string"
        ? parseObject(candidate)
        : candidate && typeof candidate === "object" && !Array.isArray(candidate)
          ? (candidate as JsonObject)
          : null;
    if (!response) return false;
    if (response.type !== "response" && response.type !== "player.response") {
      return false;
    }
    const status = response.status;
    if (typeof status !== "number" || status < 200 || status >= 300) return false;
    const body = response.body;
    if (!body || typeof body !== "object" || Array.isArray(body)) return false;
    const token = (body as JsonObject).token;
    return typeof token === "string" && token.length > 0 && token.length <= 1024;
  }

  private consumeMessageAllowance(
    socket: WebSocket,
    attachment: SocketAttachment,
    messageLimit: number,
    byteLimit: number,
    messageBytes: number,
  ): boolean {
    const now = Date.now();
    if (
      !Number.isFinite(attachment.rateWindowAt) ||
      now - attachment.rateWindowAt >= RATE_WINDOW_MS
    ) {
      attachment.rateBytes = 0;
      attachment.rateMessages = 0;
      attachment.rateWindowAt = now;
    }
    if (!Number.isFinite(attachment.rateBytes) || attachment.rateBytes < 0) {
      attachment.rateBytes = 0;
    }
    if (
      !Number.isFinite(attachment.rateMessages) ||
      attachment.rateMessages < 0
    ) {
      attachment.rateMessages = 0;
    }
    attachment.rateBytes += messageBytes;
    attachment.rateMessages += 1;
    socket.serializeAttachment(attachment);

    if (
      attachment.rateMessages <= messageLimit &&
      attachment.rateBytes <= byteLimit
    ) {
      return true;
    }
    safeSend(socket, {
      type: "relay.error",
      message: "Connection traffic limit exceeded",
    });
    safeClose(socket, 1008, "Connection traffic limit exceeded");
    return false;
  }

  private consumeRoomPlayerAllowance(
    host: { attachment: HostAttachment; socket: WebSocket },
    messageBytes: number,
  ): boolean {
    const attachment = host.attachment;
    const now = Date.now();
    if (
      !Number.isFinite(attachment.roomPlayerRateWindowAt) ||
      now - attachment.roomPlayerRateWindowAt >= RATE_WINDOW_MS
    ) {
      attachment.roomPlayerRateBytes = 0;
      attachment.roomPlayerRateMessages = 0;
      attachment.roomPlayerRateWindowAt = now;
    }
    if (
      !Number.isFinite(attachment.roomPlayerRateBytes) ||
      attachment.roomPlayerRateBytes < 0
    ) {
      attachment.roomPlayerRateBytes = 0;
    }
    if (
      !Number.isFinite(attachment.roomPlayerRateMessages) ||
      attachment.roomPlayerRateMessages < 0
    ) {
      attachment.roomPlayerRateMessages = 0;
    }
    attachment.roomPlayerRateBytes += messageBytes;
    attachment.roomPlayerRateMessages += 1;
    host.socket.serializeAttachment(attachment);
    return (
      attachment.roomPlayerRateMessages <=
        LIMITS.maxRoomPlayerMessagesPerMinute &&
      attachment.roomPlayerRateBytes <= LIMITS.maxRoomPlayerBytesPerMinute
    );
  }

  private hostSockets(): Array<{
    attachment: HostAttachment | PendingHostAttachment;
    socket: WebSocket;
  }> {
    const result: Array<{
      attachment: HostAttachment | PendingHostAttachment;
      socket: WebSocket;
    }> = [];
    for (const socket of this.ctx.getWebSockets("host")) {
      if (!socketIsOpen(socket)) continue;
      const attachment = attachmentOf(socket);
      if (
        attachment?.role === "host" ||
        attachment?.role === "host-pending"
      ) {
        result.push({ attachment, socket });
      }
    }
    return result;
  }

  private hostSocket(exclude?: WebSocket): {
    attachment: HostAttachment;
    socket: WebSocket;
  } | null {
    for (const candidate of this.hostSockets()) {
      if (
        candidate.socket !== exclude &&
        candidate.attachment.role === "host"
      ) {
        return candidate as { attachment: HostAttachment; socket: WebSocket };
      }
    }
    return null;
  }

  private playerSockets(): Array<{
    attachment: PlayerAttachment;
    socket: WebSocket;
  }> {
    const result: Array<{
      attachment: PlayerAttachment;
      socket: WebSocket;
    }> = [];
    for (const socket of this.ctx.getWebSockets("player")) {
      if (!socketIsOpen(socket)) continue;
      const attachment = attachmentOf(socket);
      if (attachment?.role === "player") result.push({ attachment, socket });
    }
    return result;
  }

  private findPlayer(clientId: string): {
    attachment: PlayerAttachment;
    socket: WebSocket;
  } | null {
    return (
      this.playerSockets().find(
        ({ attachment }) => attachment.clientId === clientId,
      ) ?? null
    );
  }

  private isWebSocketUpgrade(request: Request): boolean {
    return (
      request.method === "GET" &&
      request.headers.get("upgrade")?.toLowerCase() === "websocket"
    );
  }

  private async expireRoom(reason = "Room expired"): Promise<void> {
    for (const socket of this.ctx.getWebSockets()) {
      safeSend(socket, { type: "relay.error", message: reason });
      safeClose(socket, 1001, reason);
    }
    await this.ctx.storage.deleteAll();
  }
}

async function applyProvisionLimit(
  request: Request,
  env: Env,
): Promise<Response | null> {
  const address = request.headers.get("CF-Connecting-IP") ?? "local-development";
  const limiterName = await sha256(address);
  const limiterId = env.PROVISION_LIMITERS.idFromName(limiterName);
  const response = await env.PROVISION_LIMITERS.get(limiterId).fetch(
    "https://limiter.internal/take",
    { method: "POST" },
  );
  return response.ok ? null : response;
}

/// Provisioning keys gate who may create rooms. The relay stays open while
/// PROVISION_KEYS is unset, which is what `wrangler dev` and the tests use; a
/// deployment that should not host strangers must set the secret.
/// ponytail: a comma-separated secret, not a database — `keys.mjs` rewrites the
/// whole list, and revoking one is a redeploy of that secret.
function provisionKeyAccepted(request: Request, env: Env): boolean {
  const configured = (env.PROVISION_KEYS ?? "")
    .split(",")
    .map((key) => key.trim())
    .filter((key) => key.length > 0);
  if (configured.length === 0) return true;
  const presented = request.headers.get("x-mtg-relay-key") ?? "";
  return configured.some((key) => constantTimeEqual(key, presented));
}

async function provisionRoom(request: Request, env: Env): Promise<Response> {
  if (request.headers.has("origin")) {
    return errorResponse(
      403,
      "origin_forbidden",
      "Room provisioning is available only to the organizer app",
    );
  }

  const contentType = request.headers.get("content-type") ?? "";
  if (contentType.split(";", 1)[0]?.trim().toLowerCase() !== "application/json") {
    return errorResponse(
      415,
      "unsupported_media_type",
      "Room provisioning requires application/json",
    );
  }

  if (
    request.headers.get("x-mtg-relay-protocol") !== String(PROTOCOL_VERSION)
  ) {
    return errorResponse(
      400,
      "protocol_required",
      `Room provisioning requires relay protocol ${PROTOCOL_VERSION}`,
    );
  }

  const contentLength = Number(request.headers.get("content-length") ?? "0");
  if (Number.isFinite(contentLength) && contentLength > 1024) {
    return errorResponse(413, "request_too_large", "Request body is too large");
  }

  // Checked before the rate limiter so unauthorized traffic is the cheapest
  // path through the Worker and cannot exhaust a legitimate organizer's budget.
  if (!provisionKeyAccepted(request, env)) {
    return errorResponse(
      401,
      "provision_key_required",
      "This relay requires a provisioning key",
    );
  }

  const limited = await applyProvisionLimit(request, env);
  if (limited) return limited;

  for (let attempt = 0; attempt < 3; attempt += 1) {
    const roomId = randomToken(18);
    const hostSecret = randomToken(32);
    const createdAt = Date.now();
    const expiresAt = createdAt + ROOM_LIFETIME_MS;
    const secretHash = await sha256(hostSecret);
    const id = env.ROOMS.idFromName(roomId);
    const initialized = await env.ROOMS.get(id).fetch(
      "https://room.internal/provision",
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ createdAt, expiresAt, secretHash }),
      },
    );

    if (initialized.status === 409) continue;
    if (!initialized.ok) {
      return errorResponse(
        503,
        "provision_failed",
        "The relay could not create a room",
      );
    }

    const origin = new URL(request.url).origin;
    return json(
      {
        protocol: PROTOCOL_VERSION,
        roomId,
        hostSecret,
        joinUrl: `${origin}/r/${roomId}/`,
        expiresAt,
      },
      { status: 201 },
    );
  }

  return errorResponse(
    503,
    "provision_failed",
    "The relay could not allocate a unique room",
  );
}

function relayRequest(
  request: Request,
  env: Env,
  roomId: string,
  endpoint: "host" | "player",
): Promise<Response> {
  const id = env.ROOMS.idFromName(roomId);
  const internalUrl = new URL(request.url);
  internalUrl.protocol = "https:";
  internalUrl.hostname = "room.internal";
  internalUrl.port = "";
  internalUrl.pathname = `/${endpoint}`;
  return env.ROOMS.get(id).fetch(new Request(internalUrl, request));
}

async function serveRoomAsset(
  request: Request,
  env: Env,
  assetPath: string,
): Promise<Response> {
  const assetUrl = new URL(request.url);
  assetUrl.pathname = `/${assetPath || "index.html"}`;
  const assetResponse = await env.ASSETS.fetch(new Request(assetUrl, request));
  const headers = new Headers(assetResponse.headers);
  headers.set(
    "content-security-policy",
    "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; " +
      "img-src 'self' data: https://cards.scryfall.io; connect-src 'self'; " +
      "object-src 'none'; base-uri 'none'; frame-ancestors 'none'",
  );
  headers.set("x-content-type-options", "nosniff");
  headers.set("referrer-policy", "same-origin");
  if (!assetPath || assetPath === "index.html") {
    headers.set("cache-control", "no-cache");
  }
  return new Response(assetResponse.body, {
    status: assetResponse.status,
    statusText: assetResponse.statusText,
    headers,
  });
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === "GET" && url.pathname === "/healthz") {
      return json({ ok: true, protocol: PROTOCOL_VERSION });
    }

    if (url.pathname === "/v1/rooms") {
      if (request.method !== "POST") {
        return errorResponse(405, "method_not_allowed", "Expected POST");
      }
      return provisionRoom(request, env);
    }

    const socketMatch = url.pathname.match(
      /^\/v1\/rooms\/([A-Za-z0-9_-]{20,64})\/(host|player)$/,
    );
    if (socketMatch) {
      const roomId = socketMatch[1];
      const endpoint = socketMatch[2];
      if (!roomId || !validRoomId(roomId)) {
        return errorResponse(400, "invalid_room", "Invalid room identifier");
      }
      if (endpoint !== "host" && endpoint !== "player") {
        return errorResponse(404, "not_found", "Route not found");
      }
      if (
        endpoint === "player" &&
        request.headers.get("origin") !== url.origin
      ) {
        return errorResponse(
          403,
          "origin_forbidden",
          "Player connections must come from this relay",
        );
      }
      return relayRequest(request, env, roomId, endpoint);
    }

    const roomAssetMatch = url.pathname.match(
      /^\/r\/([A-Za-z0-9_-]{20,64})(?:\/(.*))?$/,
    );
    if (roomAssetMatch) {
      if (request.method !== "GET" && request.method !== "HEAD") {
        return errorResponse(405, "method_not_allowed", "Expected GET or HEAD");
      }
      const roomId = roomAssetMatch[1];
      if (!roomId || !validRoomId(roomId)) {
        return errorResponse(400, "invalid_room", "Invalid room identifier");
      }
      if (!url.pathname.endsWith("/") && roomAssetMatch[2] === undefined) {
        return Response.redirect(`${url.origin}/r/${roomId}/${url.search}`, 308);
      }
      return serveRoomAsset(request, env, roomAssetMatch[2] ?? "");
    }

    return errorResponse(404, "not_found", "Route not found");
  },
} satisfies ExportedHandler<Env>;
