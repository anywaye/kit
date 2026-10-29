
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

const base = "https://anywaye.com";
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

r = await probe("/healthz");
check("GET /healthz is 200", r.status === 200, `status ${r.status}`);

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
  "install host: anywaye.com/box/install serves install.sh byte-exact; every other path 404s; /healthz is 200",
);
