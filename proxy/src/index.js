function timingSafeEqual(a, b) {
  const encoder = new TextEncoder();
  const bufA = encoder.encode(a);
  const bufB = encoder.encode(b);
  if (bufA.byteLength !== bufB.byteLength) return false;
  return crypto.subtle.timingSafeEqual(bufA, bufB);
}

export default {
  async fetch(request, env) {
    const authHeader = request.headers.get("X-Proxy-Secret");
    if (!authHeader || !timingSafeEqual(authHeader, env.PROXY_SECRET)) {
      return new Response("Unauthorized", { status: 401 });
    }

    const targetUrl = request.headers.get("X-Target-URL");
    if (!targetUrl) {
      return new Response("Missing X-Target-URL header", { status: 400 });
    }

    try {
      const response = await fetch(targetUrl, {
        headers: {
          "User-Agent": request.headers.get("User-Agent") || "feeeed/1.0",
          Accept: request.headers.get("Accept") || "*/*",
        },
        redirect: "follow",
      });

      return new Response(response.body, {
        status: response.status,
        headers: {
          "Content-Type": response.headers.get("Content-Type") || "application/octet-stream",
          "X-Original-URL": response.url,
        },
      });
    } catch (e) {
      return new Response(`Fetch failed: ${e.message}`, { status: 502 });
    }
  },
};
