// kit-install.mjs — the install host at kit.cafaye.com.
//
// Serves templates/substrate/install.sh — the customer one-command install —
// at GET / and GET /install.sh: the exact bytes, content-type
// text/x-shellscript, no transformation. `curl | sh` executes whatever bytes
// arrive, so a Worker that reformats, wraps or minifies the script is a
// Worker that breaks the install.
//
// The script is IMPORTED, not copied. wrangler's Text-module rule
// (wrangler.jsonc, `rules`) bundles install.sh's bytes into this Worker at
// deploy time, so the served bytes and the file are one fact with one
// author — there is no hand-copied string in this tree. kit's gate proves
// the equality offline: `check_install_host` in tests/validate.sh imports
// this module with a loader hook standing in for the Text rule and compares
// the served body's SHA-256 against the file's, with a control that
// truncates one byte and must go red.
//
// WHY .mjs AND NOT .ts: the gate imports the handler as a plain module and
// calls it with no wrangler, no network and no account — the cheapest proof
// the packet names. A .ts Worker would need a type-stripping loader to be
// testable that way; plain ESM needs none.
//
// NO SECRET IS HELD HERE. install.sh reads KIT_SUBSTRATE_PULL_SECRET and
// KIT_SUBSTRATE_ACME_EMAIL from the operator's environment at run time;
// this Worker serves bytes and holds nothing.

import installSh from "./install.sh";

export default {
  async fetch(request) {
    const { pathname } = new URL(request.url);

    // Exactly two paths serve the script. The URL parser has already
    // resolved `..` and `%2e%2e` by the time pathname is read, so
    // `/install.sh/../secrets` arrives as `/secrets` and 404s like every
    // other path that is not exactly `/` or `/install.sh`.
    if (pathname === "/" || pathname === "/install.sh") {
      return new Response(installSh, {
        status: 200,
        headers: { "content-type": "text/x-shellscript" },
      });
    }

    // The host itself is observable — the fleet's own convention.
    if (pathname === "/healthz") {
      return new Response("ok\n", {
        status: 200,
        headers: { "content-type": "text/plain" },
      });
    }

    return new Response("not found\n", {
      status: 404,
      headers: { "content-type": "text/plain" },
    });
  },
};
