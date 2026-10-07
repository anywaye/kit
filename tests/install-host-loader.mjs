// install-host-loader.mjs — resolves `.sh` imports as text modules.
//
// This is the stand-in for wrangler's Text-module rule (declared in
// templates/substrate/wrangler.jsonc) when kit's gate imports the Worker
// with no wrangler, no network and no account: the rule bundles install.sh's
// bytes into the Worker at deploy time, and this hook resolves the same
// import to the same bytes at test time. The bytes the handler serves are
// the bytes of the file, read through the Worker's own import — which is
// what makes the gate's hash comparison a proof about the tree rather than
// about a copy.

import { readFileSync } from "node:fs";

export async function load(url, context, nextLoad) {
  if (url.endsWith(".sh")) {
    const source = readFileSync(new URL(url), "utf8");
    return {
      format: "module",
      source: `export default ${JSON.stringify(source)};`,
      shortCircuit: true,
    };
  }
  return nextLoad(url, context);
}
