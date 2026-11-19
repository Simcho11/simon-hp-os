// HP-OS update downloads: hands devices the ready-built parts in the private R2 bucket, read-only, and only to
// devices that know the download password (HTTP Basic, user "hp-os"). Nothing can be listed, written or deleted.
export default {
  async fetch(request, env) {
    if (request.method !== "GET" && request.method !== "HEAD")
      return new Response(null, { status: 405, headers: { Allow: "GET, HEAD" } });
    if (!(await allowed(request.headers.get("Authorization") ?? "", env.DOWNLOAD_PASSWORD ?? "")))
      return new Response(null, { status: 401, headers: { "WWW-Authenticate": 'Basic realm="HP-OS updates"' } });
    let key;
    try {
      key = decodeURIComponent(new URL(request.url).pathname.slice(1));
    } catch {
      return new Response(null, { status: 400 });
    }
    // A Nix binary cache only ever asks for these.
    if (!/^(nix-cache-info|[0-9a-z]{32}\.narinfo|nar\/[0-9a-z]+\.nar(\.(xz|zst|bz2))?)$/.test(key))
      return new Response(null, { status: 404 });
    const object = request.method === "HEAD" ? await env.BUCKET.head(key) : await env.BUCKET.get(key);
    if (!object) return new Response(null, { status: 404 });
    const headers = new Headers();
    object.writeHttpMetadata(headers);
    headers.set("ETag", object.httpEtag);
    headers.set("Content-Length", String(object.size));
    headers.set("Cache-Control", "private, no-store");
    return new Response(request.method === "HEAD" ? null : object.body, { headers });
  },
};

async function allowed(given, password) {
  if (password.length < 20) return false;
  const encoder = new TextEncoder();
  const [a, b] = await Promise.all([given, "Basic " + btoa("hp-os:" + password)]
    .map(text => crypto.subtle.digest("SHA-256", encoder.encode(text))));
  return crypto.subtle.timingSafeEqual(a, b);
}
