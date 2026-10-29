
import installSh from "./install.sh";

export default {
  async fetch(request) {
    const { pathname } = new URL(request.url);

    if (pathname === "/box/install" || pathname === "/" || pathname === "/install.sh") {
      return new Response(installSh, {
        status: 200,
        headers: { "content-type": "text/x-shellscript" },
      });
    }

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
