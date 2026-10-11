// install-host-driver.mjs — probe a kit-install Worker and compare what it
// serves against the real install.sh.
//
//   node tests/install-host-driver.mjs <worker.mjs> <real-install.sh>
//
// Registers tests/install-host-loader.mjs — the stand-in for wrangler's
// Text-module rule, which resolves `.sh` imports to the file's text — then
// imports the Worker as a plain module and calls its handler with no
// wrangler, no network and no account. The cheapest proof the packet names.
//
// The comparison is by SHA-256 over the served body, not by a prefix: a
// truncated or re-encoded body is the defect `curl | sh` would execute, and
// only a whole-body hash sees it.
//
// Exit 0: every assertion held. Exit 1: a mismatch (the check's red).
// Exit 78: the environment cannot run this (node too old for
// module.register) — an environment verdict, reported as SKIP, never as a
// pass and never as a tree defect.

import { register } from "node:module";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

if (typeof register !== "function") {
  console.error("install-host-driver: this node has no module.register (needs >= 20.6)");
  process.exit(78);
}

register(new URL("./install-host-loader.mjs", import.meta.url));

const [, , workerPath, scriptPath] = process.argv;
if (!workerPath || !scriptPath) {
  console.error("usage: install-host-driver.mjs <worker.mjs> <real-install.sh>");
  process.exit(78);
}

const realHash = createHash("sha256").update(readFileSync(scriptPath)).digest("hex");

const handler = (await import(pathToFileURL(workerPath).href)).default;
if (!handler || typeof handler.fetch !== "function") {
  console.error(`install-host-driver: ${workerPath} has no default export with fetch()`);
  process.exit(1);
}

// The front door the plan pins: cafaye.com/box/install. The base is the site's
// host, not a host of the Worker's own — kit.cafaye.com is retired, so the
// Worker is bound to a route under cafaye.com and this probe answers the
// question that binding will answer.
const base = "https://cafaye.com";
let failures = 0;

function check(label, ok, detail) {
  if (ok) {
    console.log(`ok: ${label}`);
  } else {
    console.error(`FAIL install host: ${label} — ${detail}`);
    failures += 1;
  }
}

async function probe(pathname) {
  const res = await handler.fetch(new Request(base + pathname));
  const body = await res.text();
  return {
    status: res.status,
    contentType: res.headers.get("content-type"),
    bodyHash: createHash("sha256").update(Buffer.from(body, "utf8")).digest("hex"),
  };
}

// GET /box/install — THE FRONT DOOR. The plan's path, under cafaye.com, and
// the only path this repository documents as the product's front door. It is
// asserted first and by the same whole-body hash as the rest: the byte-equality
// guarantee is about whatever path a customer types into `curl | sh`, and that
// path moved.
let r = await probe("/box/install");
check("GET /box/install is 200", r.status === 200, `status ${r.status}`);
check(
  "GET /box/install content-type is text/x-shellscript",
  r.contentType === "text/x-shellscript",
  `content-type is ${r.contentType}`,
);
check(
  "GET /box/install body is the exact bytes of install.sh (sha256)",
  r.bodyHash === realHash,
  `served ${r.bodyHash}, file ${realHash}`,
);

// GET / and GET /install.sh — the same bytes, under whatever host the Worker
// is bound to. Not the front door; the cutover, so a hostname-bound Worker
// still answers the spelling it answered before the move.
r = await probe("/");
check("GET / is 200", r.status === 200, `status ${r.status}`);
check(
  "GET / content-type is text/x-shellscript",
  r.contentType === "text/x-shellscript",
  `content-type is ${r.contentType}`,
);
check(
  "GET / body is the exact bytes of install.sh (sha256)",
  r.bodyHash === realHash,
  `served ${r.bodyHash}, file ${realHash}`,
);

// GET /install.sh — the same bytes.
r = await probe("/install.sh");
check("GET /install.sh is 200", r.status === 200, `status ${r.status}`);
check(
  "GET /install.sh content-type is text/x-shellscript",
  r.contentType === "text/x-shellscript",
  `content-type is ${r.contentType}`,
);
check(
  "GET /install.sh body is the exact bytes of install.sh (sha256)",
  r.bodyHash === realHash,
  `served ${r.bodyHash}, file ${realHash}`,
);

// GET /healthz — the host itself is observable, the fleet's convention.
r = await probe("/healthz");
check("GET /healthz is 200", r.status === 200, `status ${r.status}`);

// Everything else 404s — including traversal, which the URL parser has
// already resolved to an ordinary path by the time the handler reads it.
for (const pathname of [
  "/anything-else",
  "/box/install/../secrets",
  "/install.sh/../secrets",
  "/%2e%2e/secrets",
  "/secrets",
  "/install.sh.bak",
  "//install.sh",
  "/box",
  "/box/",
  "/box/install.sh",
]) {
  r = await probe(pathname);
  check(`GET ${pathname} is 404`, r.status === 404, `status ${r.status}`);
}

if (failures > 0) {
  console.error(`install-host-driver: ${failures} assertion(s) failed`);
  process.exit(1);
}
console.log(
  "install host: cafaye.com/box/install serves install.sh byte-exact; every other path 404s; /healthz is 200",
);
