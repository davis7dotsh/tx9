import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import worker from "../src/index.ts";

function fixture({ latest = "1.2.3\n" } = {}) {
	const calls = [];
	const objects = new Map([
		["latest.txt", latest],
		["1.2.3/tx9_linux_amd64", "binary fixture"],
		["1.2.3/checksums.txt", "checksum fixture\n"],
	]);
	const metadata = (key) => ({
		key,
		size: new TextEncoder().encode(objects.get(key)).length,
		httpEtag: '"fixture-etag"',
	});
	const env = {
		RELEASES: {
			async head(key) {
				calls.push(["head", key]);
				return objects.has(key) ? metadata(key) : null;
			},
			async get(key, options) {
				calls.push(["get", key]);
				if (!objects.has(key)) return null;
				const object = metadata(key);
				const condition = options?.onlyIf?.get("If-None-Match");
				if (condition === "*" || condition === object.httpEtag) return object;
				const response = new Response(objects.get(key));
				return { ...object, body: response.body, text: () => response.text() };
			},
		},
		ASSETS: {
			async fetch() {
				calls.push(["assets"]);
				return new Response("homepage");
			},
		},
	};
	const request = (path, init) =>
		worker.fetch(new Request(`https://releases.invalid${path}`, init), env);
	return { calls, request };
}

test("installer is the exact repository script and never cached", async () => {
	const { request, calls } = fixture();
	for (const path of ["/install", "/install.sh"]) {
		const response = await request(path);
		assert.equal(response.headers.get("Cache-Control"), "no-store");
		assert.equal(
			await response.text(),
			readFileSync(new URL("../../scripts/install.sh", import.meta.url), "utf8"),
		);
	}
	assert.deepEqual(calls, []);
});

test("latest pointer and redirects are never cached", async () => {
	const { request } = fixture();
	const latest = await request("/releases/latest");
	assert.equal(await latest.text(), "1.2.3\n");
	assert.equal(latest.headers.get("Cache-Control"), "no-store");
	const redirect = await request("/releases/latest/tx9_linux_amd64");
	assert.equal(redirect.status, 302);
	assert.equal(redirect.headers.get("Location"), "/releases/1.2.3/tx9_linux_amd64");
	assert.equal(redirect.headers.get("Cache-Control"), "no-store");
});

test("unknown assets and malformed versions never access R2", async () => {
	const { request, calls } = fixture();
	for (const path of [
		"/releases/latest/secrets.json",
		"/releases/1.2.3/secrets.json",
		"/releases/1.2/tx9_linux_amd64",
		"/releases/%2e%2e%2fsecrets/tx9_linux_amd64",
	]) {
		assert.equal((await request(path)).status, 404);
	}
	assert.deepEqual(calls, []);
});

test("malformed stored latest pointers fail closed", async () => {
	for (const latest of ["../private", "", "1.2.3-rc1", "1.2.3\n4.5.6"]) {
		const { request } = fixture({ latest });
		const response = await request("/releases/latest");
		assert.equal(response.status, 404);
		assert.equal(response.headers.get("Cache-Control"), "no-store");
	}
});

test("release downloads stream with immutable caching and metadata", async () => {
	const { request } = fixture();
	const response = await request("/releases/1.2.3/tx9_linux_amd64");
	assert.equal(response.status, 200);
	assert.equal(await response.text(), "binary fixture");
	assert.equal(response.headers.get("Content-Length"), "14");
	assert.equal(response.headers.get("ETag"), '"fixture-etag"');
	assert.match(response.headers.get("Cache-Control"), /immutable/);
	assert.equal(response.headers.get("X-Content-Type-Options"), "nosniff");
});

test("HEAD reads metadata only and matching validators return 304", async () => {
	const { request, calls } = fixture();
	const head = await request("/releases/1.2.3/tx9_linux_amd64", { method: "HEAD" });
	assert.equal(head.status, 200);
	assert.equal(head.body, null);
	const unchanged = await request("/releases/1.2.3/tx9_linux_amd64", {
		method: "HEAD",
		headers: { "If-None-Match": '"old", W/"fixture-etag"' },
	});
	assert.equal(unchanged.status, 304);
	assert.equal(unchanged.body, null);
	assert.deepEqual(
		calls.map(([method]) => method),
		["head", "head"],
	);
});

test("GET uses conditional R2 reads without sending an unchanged body", async () => {
	const { request } = fixture();
	for (const validator of ['"fixture-etag"', "*"]) {
		const response = await request("/releases/1.2.3/tx9_linux_amd64", {
			headers: { "If-None-Match": validator },
		});
		assert.equal(response.status, 304);
		assert.equal(response.body, null);
		assert.equal(response.headers.get("ETag"), '"fixture-etag"');
		assert.equal(response.headers.get("Content-Length"), null);
	}
	const changed = await request("/releases/1.2.3/tx9_linux_amd64", {
		headers: { "If-None-Match": '"old"' },
	});
	assert.equal(changed.status, 200);
	assert.equal(await changed.text(), "binary fixture");
});

test("unsupported methods and missing release objects fail cleanly", async () => {
	const { request, calls } = fixture();
	const response = await request("/releases/latest", { method: "POST" });
	assert.equal(response.status, 405);
	assert.equal(response.headers.get("Allow"), "GET, HEAD");
	assert.deepEqual(calls, []);
	assert.equal((await request("/releases/9.9.9/checksums.txt")).status, 404);
	assert.equal(await (await request("/")).text(), "homepage");
});
