import assert from "node:assert/strict";
import test from "node:test";

async function render() {
  const workerUrl = new URL("../dist/server/index.js", import.meta.url);
  workerUrl.searchParams.set("test", `${process.pid}-${Date.now()}`);
  const { default: worker } = await import(workerUrl.href);

  return worker.fetch(
    new Request("http://localhost/", { headers: { accept: "text/html" } }),
    { ASSETS: { fetch: async () => new Response("Not found", { status: 404 }) } },
    { waitUntil() {}, passThroughOnException() {} },
  );
}

test("server-renders the VoxLocal product showcase", async () => {
  const response = await render();
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type") ?? "", /^text\/html\b/i);

  const html = await response.text();
  assert.match(html, /VoxLocal/);
  assert.match(html, /La médecine parle/);
  assert.match(html, /Remote Scribe/);
  assert.match(html, /Whisper/);
  assert.doesNotMatch(html, /Your site is taking shape|Building your site/i);
});

test("renders every product section heading", async () => {
  const html = await (await render()).text();
  for (const heading of [
    /<h2[^>]*>Le produit aujourd’hui\.<\/h2>/,
    /<h2[^>]*>Comment ça marche\.<\/h2>/,
    /<h2[^>]*>Sécurité\./,
    /<h2[^>]*>Déploiement\./,
    /<h3[^>]*>Pilote hospitalier<\/h3>/,
  ]) {
    assert.match(html, heading);
  }
  assert.match(html, /Nous contacter/);
  assert.match(html, /mailto:contact@voxlocal\.ai/);
});

test("security grid has six cards, each linking to the whitepaper", async () => {
  const html = await (await render()).text();
  const links = html.match(/href="[^"]*security-whitepaper\.md#[^"]+"/g) ?? [];
  assert.equal(links.length, 6);
});

test("public copy never mentions Superwhisper", async () => {
  const html = await (await render()).text();
  assert.ok(!/superwhisper/i.test(html), "Superwhisper appears in the rendered HTML");
});

test("the prototype 8 mark is gone", async () => {
  const html = await (await render()).text();
  assert.ok(!/brand-eight|Prototype mark/.test(html), "the prototype 8 mark is still rendered");
});

test("every image reserves its dimensions", async () => {
  const html = await (await render()).text();
  const images = html.match(/<img\b[^>]*>/g) ?? [];
  assert.ok(images.length >= 3, `expected at least 3 <img>, got ${images.length}`);
  for (const image of images) {
    assert.match(image, /\swidth="\d+"/, image);
    assert.match(image, /\sheight="\d+"/, image);
  }
  assert.match(html, /src="\/screenshots\/mac-main\.png"/);
  assert.match(html, /src="\/screenshots\/ios-home\.png"/);
});

test("no invented price appears in the visible copy", async () => {
  const html = await (await render()).text();
  const body = html.slice(html.indexOf("<body"));
  const text = body.replace(/<script\b[\s\S]*?<\/script>/g, " ").replace(/<[^>]+>/g, " ");
  const price = text.match(/\d[\d\s.,]*\s?(€|EUR|\$|euros?)|(€|\$)\s?\d/i);
  assert.equal(price, null, `unexpected price: ${price?.[0]}`);
});
