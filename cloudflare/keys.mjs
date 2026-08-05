#!/usr/bin/env node
/**
 * Create and revoke relay provisioning keys.
 *
 *   node keys.mjs list
 *   node keys.mjs add [key]       # generates one when omitted
 *   node keys.mjs remove <key>
 *
 * Cloudflare secrets are write-only, so the authoritative list lives in
 * `provision-keys.txt` next to this script. That file is gitignored and is the
 * only copy: losing it means re-issuing every key and rebuilding the app.
 */
import { execFileSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const FILE = fileURLToPath(new URL("provision-keys.txt", import.meta.url));

function read() {
  if (!existsSync(FILE)) return [];
  return readFileSync(FILE, "utf8")
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.length > 0);
}

function write(keys) {
  writeFileSync(FILE, `${keys.join("\n")}\n`);
  execFileSync("npx", ["wrangler", "secret", "put", "PROVISION_KEYS"], {
    cwd: fileURLToPath(new URL(".", import.meta.url)),
    input: keys.join(","),
    shell: process.platform === "win32",
    stdio: ["pipe", "inherit", "inherit"],
  });
}

const [command, argument] = process.argv.slice(2);
const keys = read();

switch (command) {
  case "list":
    console.log(keys.length === 0 ? "(no keys — the relay is open)" : keys.join("\n"));
    break;

  case "add": {
    const key = argument ?? randomBytes(24).toString("base64url");
    if (keys.includes(key)) {
      console.log("Key already present.");
      break;
    }
    write([...keys, key]);
    console.log(`\nAdded key: ${key}`);
    console.log("Build the app with --dart-define=MTG_RELAY_KEY=<key>");
    break;
  }

  case "remove": {
    if (!argument) throw new Error("Usage: node keys.mjs remove <key>");
    if (!keys.includes(argument)) {
      console.log("No such key.");
      break;
    }
    const remaining = keys.filter((key) => key !== argument);
    if (remaining.length === 0) {
      // An empty secret reads as "unset", which reopens the relay to everyone.
      throw new Error(
        "Refusing to remove the last key: the relay would accept rooms from " +
          "anyone. Add a replacement key first, or run " +
          "`npx wrangler secret delete PROVISION_KEYS` deliberately.",
      );
    }
    write(remaining);
    console.log(`\nRevoked key: ${argument}`);
    console.log("Builds carrying that key can no longer create rooms.");
    break;
  }

  default:
    console.log("Usage: node keys.mjs list | add [key] | remove <key>");
}
