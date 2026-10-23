// kit-install.mjs — the install host: the Worker that serves install.sh at
// https://anywaye.com/box/install.
//
// Serves templates/substrate/install.sh — the customer one-command install —
// at GET /box/install: the exact bytes, content-type text/x-shellscript, no
// transformation. `curl | sh` executes whatever bytes arrive, so a Worker that
// reformats, wraps or minifies the script is a Worker that breaks the install.
//
// THE PATH IS THE PRODUCT'S FRONT DOOR and it lives under anywaye.com now, not
// on a host of its own: `curl https://anywaye.com/box/install | sh`. kit.anywaye.com
// is retired, so the Worker is bound to a route on anywaye.com rather than to a
// hostname — the same deployment, a different binding, and the binding stays an
// operator action (see wrangler.jsonc).
//
// TWO OTHER PATHS are served and they are the cutover, not a second contract:
// GET / and GET /install.sh answer the same bytes, so a Worker bound to a
// hostname of its own still behaves exactly as it did before the move. They are
// NOT the front door and nothing in this repository documents them as one.
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
// NO SECRET IS HELD HERE — and none is asked for. install.sh takes the box's
// enrolled identity and a short-lived capability from the operator's
// environment at run time, redeems one short-lived registry credential with
// it, and generates everything else on the box itself; this Worker serves
// bytes and holds nothing.

import installSh from "./install.sh";

export default {
  async fetch(request) {
    const { pathname } = new URL(request.url);

    // The front door is /box/install, on anywaye.com. The URL parser has
    // already resolved `..` and `%2e%2e` by the time pathname is read, so
    // `/box/install/../secrets` arrives as `/secrets` and 404s like every
    // other path that is not one of the three named here.
    if (pathname === "/box/install" || pathname === "/" || pathname === "/install.sh") {
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
