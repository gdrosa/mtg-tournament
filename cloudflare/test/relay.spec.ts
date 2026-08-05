import { env, runInDurableObject, SELF } from "cloudflare:test";
import { afterEach, describe, expect, it } from "vitest";

import { LIMITS, type RelayRoom } from "../src/index";

interface TestEnv {
  ASSETS: Fetcher;
  PROVISION_LIMITERS: DurableObjectNamespace;
  ROOMS: DurableObjectNamespace<RelayRoom>;
}

declare global {
  namespace Cloudflare {
    interface Env extends TestEnv {}
  }
}

interface ProvisionedRoom {
  expiresAt: number;
  hostSecret: string;
  joinUrl: string;
  protocol: number;
  roomId: string;
}

interface OpenSocket {
  initial: Record<string, unknown>;
  socket: WebSocket;
}

const sockets: WebSocket[] = [];

afterEach(async () => {
  await Promise.all(sockets.splice(0).map(closeAndWait));
});

function closeAndWait(socket: WebSocket): Promise<void> {
  if (socket.readyState >= 2) return Promise.resolve();
  return new Promise((resolve) => {
    const timeout = setTimeout(resolve, 250);
    socket.addEventListener(
      "close",
      () => {
        clearTimeout(timeout);
        resolve();
      },
      { once: true },
    );
    try {
      socket.close(1000, "Test complete");
    } catch {
      clearTimeout(timeout);
      resolve();
    }
  });
}

async function provision(ip = crypto.randomUUID()): Promise<ProvisionedRoom> {
  const response = await SELF.fetch("https://relay.test/v1/rooms", {
    method: "POST",
    headers: {
      "CF-Connecting-IP": `test-${ip}`,
      "Content-Type": "application/json",
      "X-MTG-Relay-Protocol": "1",
    },
    body: "{}",
  });
  expect(response.status).toBe(201);
  return response.json<ProvisionedRoom>();
}

function nextJson(socket: WebSocket): Promise<Record<string, unknown>> {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error("WebSocket timed out")), 2_000);
    socket.addEventListener(
      "message",
      (event) => {
        clearTimeout(timeout);
        try {
          resolve(JSON.parse(String(event.data)) as Record<string, unknown>);
        } catch (error) {
          reject(error);
        }
      },
      { once: true },
    );
  });
}

function nextJsonMessages(
  socket: WebSocket,
  count: number,
): Promise<Array<Record<string, unknown>>> {
  return new Promise((resolve, reject) => {
    const messages: Array<Record<string, unknown>> = [];
    const timeout = setTimeout(() => {
      socket.removeEventListener("message", onMessage);
      reject(new Error("WebSocket timed out"));
    }, 2_000);
    const onMessage = (event: MessageEvent) => {
      try {
        messages.push(JSON.parse(String(event.data)) as Record<string, unknown>);
        if (messages.length === count) {
          clearTimeout(timeout);
          socket.removeEventListener("message", onMessage);
          resolve(messages);
        }
      } catch (error) {
        clearTimeout(timeout);
        socket.removeEventListener("message", onMessage);
        reject(error);
      }
    };
    socket.addEventListener("message", onMessage);
  });
}

function expectNoJson(socket: WebSocket, durationMs = 100): Promise<void> {
  return new Promise((resolve, reject) => {
    const onMessage = (event: MessageEvent) => {
      clearTimeout(timeout);
      socket.removeEventListener("message", onMessage);
      reject(new Error(`Unexpected WebSocket message: ${String(event.data)}`));
    };
    const timeout = setTimeout(() => {
      socket.removeEventListener("message", onMessage);
      resolve();
    }, durationMs);
    socket.addEventListener("message", onMessage);
  });
}

async function setSocketAttachment(
  room: ProvisionedRoom,
  tag: "host" | "player",
  values: Record<string, unknown>,
): Promise<void> {
  const stub = env.ROOMS.get(env.ROOMS.idFromName(room.roomId));
  await runInDurableObject(stub, async (_instance, state) => {
    const socket = state.getWebSockets(tag)[0];
    if (!socket) throw new Error(`Missing ${tag} socket`);
    const attachment = socket.deserializeAttachment() as Record<string, unknown>;
    socket.serializeAttachment({ ...attachment, ...values });
  });
}

async function openSocket(
  url: string,
  headers: Record<string, string> = {},
): Promise<OpenSocket> {
  const response = await SELF.fetch(url, {
    headers: { Upgrade: "websocket", ...headers },
  });
  expect(response.status).toBe(101);
  expect(response.webSocket).not.toBeNull();
  const socket = response.webSocket!;
  sockets.push(socket);
  const initial = nextJson(socket);
  socket.accept();
  return { initial: await initial, socket };
}

async function openAuthenticatedHost(room: ProvisionedRoom): Promise<WebSocket> {
  const connection = await openSocket(
    `https://relay.test/v1/rooms/${room.roomId}/host`,
  );
  expect(connection.initial).toMatchObject({
    type: "host.auth_required",
    protocol: 1,
  });
  const ready = nextJson(connection.socket);
  connection.socket.send(
    JSON.stringify({
      type: "host.auth",
      secret: room.hostSecret,
      protocol: 1,
    }),
  );
  await expect(ready).resolves.toMatchObject({
    type: "host.ready",
    protocol: 1,
  });
  return connection.socket;
}

describe("room provisioning", () => {
  it("accepts only native protocol-marked JSON requests", async () => {
    const endpoint = "https://relay.test/v1/rooms";

    const browserRequest = await SELF.fetch(endpoint, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Origin: "https://attacker.test",
        "X-MTG-Relay-Protocol": "1",
      },
      body: "{}",
    });
    expect(browserRequest.status).toBe(403);
    await expect(browserRequest.json()).resolves.toMatchObject({
      error: { code: "origin_forbidden" },
    });

    const nonJson = await SELF.fetch(endpoint, {
      method: "POST",
      headers: { "X-MTG-Relay-Protocol": "1" },
    });
    expect(nonJson.status).toBe(415);
    await expect(nonJson.json()).resolves.toMatchObject({
      error: { code: "unsupported_media_type" },
    });

    const missingProtocol = await SELF.fetch(endpoint, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "{}",
    });
    expect(missingProtocol.status).toBe(400);
    await expect(missingProtocol.json()).resolves.toMatchObject({
      error: { code: "protocol_required" },
    });
  });

  it("creates an unguessable room and stores only the host-secret hash", async () => {
    const room = await provision();

    expect(room.protocol).toBe(1);
    expect(room.roomId).toMatch(/^[A-Za-z0-9_-]{24}$/);
    expect(room.hostSecret).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(room.joinUrl).toBe(`https://relay.test/r/${room.roomId}/`);
    expect(room.expiresAt).toBeGreaterThan(Date.now());

    const stub = env.ROOMS.get(env.ROOMS.idFromName(room.roomId));
    const stored = await runInDurableObject(
      stub,
      async (_instance, state) => state.storage.get("meta"),
    );
    const serialized = JSON.stringify(stored);
    expect(serialized).not.toContain(room.hostSecret);
    expect(serialized).toMatch(/"secretHash":"[0-9a-f]{64}"/);
  });

  it("serves the browser app below the room-scoped join URL", async () => {
    const room = await provision();

    const index = await SELF.fetch(room.joinUrl);
    expect(index.status).toBe(200);
    const contentSecurityPolicy = index.headers.get("content-security-policy");
    expect(contentSecurityPolicy).toContain("default-src 'self'");
    expect(contentSecurityPolicy).toContain("connect-src 'self'");
    expect(contentSecurityPolicy).not.toMatch(/connect-src[^;]*(?:wss:|ws:)/);
    expect(index.headers.get("x-content-type-options")).toBe("nosniff");
    await expect(index.text()).resolves.toContain("MTG Tournament");

    const script = await SELF.fetch(`${room.joinUrl}app.js`);
    expect(script.status).toBe(200);
    const scriptText = await script.text();
    expect(scriptText).toContain("WebSocket");
    // Inline event handlers would be blocked by the strict script-src above.
    expect(scriptText).not.toMatch(/\son(?:click|error)\s*=/i);
  });
});

describe("relay sockets", () => {
  it("rejects players while their host is offline", async () => {
    const room = await provision();
    const response = await SELF.fetch(
      `https://relay.test/v1/rooms/${room.roomId}/player`,
      {
        headers: {
          Origin: "https://relay.test",
          Upgrade: "websocket",
        },
      },
    );

    expect(response.status).toBe(503);
    await expect(response.json()).resolves.toMatchObject({
      error: { code: "host_offline" },
    });
  });

  it("isolates a room and relays player messages and host snapshots", async () => {
    const room = await provision();
    const otherRoom = await provision();
    const host = await openAuthenticatedHost(room);

    const otherResponse = await SELF.fetch(
      `https://relay.test/v1/rooms/${otherRoom.roomId}/player`,
      {
        headers: {
          Origin: "https://relay.test",
          Upgrade: "websocket",
        },
      },
    );
    expect(otherResponse.status).toBe(503);

    const opened = nextJson(host);
    const player = await openSocket(
      `https://relay.test/v1/rooms/${room.roomId}/player`,
      { Origin: "https://relay.test" },
    );
    expect(player.initial).toMatchObject({ type: "relay.ready", protocol: 1 });
    const playerOpen = await opened;
    expect(playerOpen).toMatchObject({ type: "player.open" });
    expect(playerOpen.clientId).toBe(player.initial.clientId);

    const fromPlayer = nextJson(host);
    player.socket.send(JSON.stringify({ type: "auth", token: "player-token" }));
    await expect(fromPlayer).resolves.toEqual({
      type: "player.message",
      clientId: player.initial.clientId,
      payload: { type: "auth", token: "player-token" },
    });

    const snapshot = {
      type: "snapshot",
      data: { round: 2, status: "running" },
    };
    const toPlayer = nextJson(player.socket);
    host.send(
      JSON.stringify({
        type: "player.send",
        clientId: player.initial.clientId,
        payload: snapshot,
      }),
    );
    await expect(toPlayer).resolves.toEqual(snapshot);
  });

  it("forwards auth once, permits token issuance, and resets for a new host", async () => {
    const room = await provision();
    const firstHost = await openAuthenticatedHost(room);
    const opened = nextJson(firstHost);
    const player = await openSocket(
      `https://relay.test/v1/rooms/${room.roomId}/player`,
      { Origin: "https://relay.test" },
    );
    const playerOpen = await opened;
    const clientId = playerOpen.clientId as string;

    const firstAuth = nextJson(firstHost);
    player.socket.send(JSON.stringify({ type: "auth", token: null }));
    await expect(firstAuth).resolves.toMatchObject({
      type: "player.message",
      clientId,
      payload: { type: "auth", token: null },
    });

    const duplicateAuth = expectNoJson(firstHost);
    player.socket.send(JSON.stringify({ type: "auth", token: null }));
    await duplicateAuth;

    const tokenResponse = nextJson(player.socket);
    firstHost.send(
      JSON.stringify({
        type: "player.send",
        clientId,
        payload: {
          type: "response",
          requestId: "join-1",
          status: 200,
          body: { token: "server-issued-player-token" },
        },
      }),
    );
    await expect(tokenResponse).resolves.toMatchObject({
      type: "response",
      body: { token: "server-issued-player-token" },
    });

    const issuedAuth = nextJson(firstHost);
    player.socket.send(
      JSON.stringify({ type: "auth", token: "server-issued-player-token" }),
    );
    await expect(issuedAuth).resolves.toMatchObject({
      type: "player.message",
      clientId,
      payload: { type: "auth", token: "server-issued-player-token" },
    });

    const repeatedIssuedAuth = expectNoJson(firstHost);
    player.socket.send(
      JSON.stringify({ type: "auth", token: "server-issued-player-token" }),
    );
    await repeatedIssuedAuth;

    const replacement = await openSocket(
      `https://relay.test/v1/rooms/${room.roomId}/host`,
    );
    const replacementMessages = nextJsonMessages(replacement.socket, 2);
    const playerPrompt = nextJson(player.socket);
    replacement.socket.send(
      JSON.stringify({
        type: "host.auth",
        secret: room.hostSecret,
        protocol: 1,
      }),
    );
    await expect(replacementMessages).resolves.toEqual([
      expect.objectContaining({ type: "host.ready" }),
      expect.objectContaining({ type: "player.open", clientId }),
    ]);
    await expect(playerPrompt).resolves.toMatchObject({
      type: "relay.ready",
      reconnected: true,
    });

    const replacementAuth = nextJson(replacement.socket);
    player.socket.send(
      JSON.stringify({ type: "auth", token: "server-issued-player-token" }),
    );
    await expect(replacementAuth).resolves.toMatchObject({
      type: "player.message",
      clientId,
      payload: { type: "auth", token: "server-issued-player-token" },
    });
  });

  it("enforces per-connection and room-wide player traffic budgets", async () => {
    const room = await provision();
    const host = await openAuthenticatedHost(room);
    const opened = nextJson(host);
    const player = await openSocket(
      `https://relay.test/v1/rooms/${room.roomId}/player`,
      { Origin: "https://relay.test" },
    );
    await opened;

    await setSocketAttachment(room, "player", {
      rateBytes: 0,
      rateMessages: LIMITS.maxPlayerMessagesPerMinute,
      rateWindowAt: Date.now(),
    });
    const connectionRejected = nextJson(player.socket);
    const playerClosedAtHost = nextJson(host);
    player.socket.send(JSON.stringify({ type: "noop" }));
    await expect(connectionRejected).resolves.toMatchObject({
      type: "relay.error",
      message: "Connection traffic limit exceeded",
    });
    await expect(playerClosedAtHost).resolves.toMatchObject({
      type: "player.close",
      clientId: player.initial.clientId,
    });
    expect(host.readyState).toBe(WebSocket.OPEN);

    const secondOpened = nextJson(host);
    const secondPlayer = await openSocket(
      `https://relay.test/v1/rooms/${room.roomId}/player`,
      { Origin: "https://relay.test" },
    );
    await secondOpened;
    await setSocketAttachment(room, "host", {
      roomPlayerRateBytes: LIMITS.maxRoomPlayerBytesPerMinute,
      roomPlayerRateMessages: 0,
      roomPlayerRateWindowAt: Date.now(),
    });
    const roomRejected = nextJson(secondPlayer.socket);
    secondPlayer.socket.send(JSON.stringify({ type: "noop" }));
    await expect(roomRejected).resolves.toMatchObject({
      type: "relay.error",
      message: "The tournament room is receiving too much traffic",
    });
    expect(host.readyState).toBe(WebSocket.OPEN);
  });

  it("applies the room-wide message budget to connection churn", async () => {
    const room = await provision();
    const host = await openAuthenticatedHost(room);
    await setSocketAttachment(room, "host", {
      roomPlayerRateBytes: 0,
      roomPlayerRateMessages: LIMITS.maxRoomPlayerMessagesPerMinute,
      roomPlayerRateWindowAt: Date.now(),
    });

    const response = await SELF.fetch(
      `https://relay.test/v1/rooms/${room.roomId}/player`,
      {
        headers: {
          Origin: "https://relay.test",
          Upgrade: "websocket",
        },
      },
    );
    expect(response.status).toBe(429);
    await expect(response.json()).resolves.toMatchObject({
      error: { code: "room_rate_limited" },
    });
    expect(host.readyState).toBe(WebSocket.OPEN);
  });

  it("allows 64-player fanout volume but bounds host bytes", async () => {
    expect(LIMITS.maxHostMessagesPerMinute).toBeGreaterThanOrEqual(64 * 64 * 3);

    const room = await provision();
    const host = await openAuthenticatedHost(room);
    await setSocketAttachment(room, "host", {
      rateBytes: 0,
      rateMessages: 1_200,
      rateWindowAt: Date.now(),
    });
    const pong = nextJson(host);
    host.send(JSON.stringify({ type: "host.ping" }));
    await expect(pong).resolves.toMatchObject({ type: "host.pong" });

    await setSocketAttachment(room, "host", {
      rateBytes: LIMITS.maxHostBytesPerMinute,
      rateMessages: 0,
      rateWindowAt: Date.now(),
    });
    const hostRejected = nextJson(host);
    host.send(JSON.stringify({ type: "host.ping" }));
    await expect(hostRejected).resolves.toMatchObject({
      type: "relay.error",
      message: "Connection traffic limit exceeded",
    });
  });

  it("prompts surviving players to re-authenticate after host replacement", async () => {
    const room = await provision();
    const firstHost = await openAuthenticatedHost(room);
    const opened = nextJson(firstHost);
    const player = await openSocket(
      `https://relay.test/v1/rooms/${room.roomId}/player`,
      { Origin: "https://relay.test" },
    );
    await opened;

    const replacement = await openSocket(
      `https://relay.test/v1/rooms/${room.roomId}/host`,
    );
    expect(replacement.initial.type).toBe("host.auth_required");
    const replacementReady = nextJson(replacement.socket);
    const playerPrompt = nextJson(player.socket);
    replacement.socket.send(
      JSON.stringify({
        type: "host.auth",
        secret: room.hostSecret,
        protocol: 1,
      }),
    );

    await expect(replacementReady).resolves.toMatchObject({
      type: "host.ready",
    });
    await expect(playerPrompt).resolves.toMatchObject({
      type: "relay.ready",
      hostOnline: true,
      reconnected: true,
    });
  });

  it("rejects a bad host secret", async () => {
    const room = await provision();
    const connection = await openSocket(
      `https://relay.test/v1/rooms/${room.roomId}/host`,
    );
    expect(connection.initial.type).toBe("host.auth_required");

    const rejected = nextJson(connection.socket);
    connection.socket.send(
      JSON.stringify({
        type: "host.auth",
        secret: "this-is-not-the-secret-value",
        protocol: 1,
      }),
    );
    await expect(rejected).resolves.toMatchObject({
      type: "relay.error",
      message: "Host authentication failed",
    });
  });

  it("rejects cross-origin player sockets", async () => {
    const room = await provision();
    await openAuthenticatedHost(room);

    const response = await SELF.fetch(
      `https://relay.test/v1/rooms/${room.roomId}/player`,
      {
        headers: {
          Origin: "https://attacker.test",
          Upgrade: "websocket",
        },
      },
    );

    expect(response.status).toBe(403);
    await expect(response.json()).resolves.toMatchObject({
      error: { code: "origin_forbidden" },
    });
  });
});
