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
				calls.push(["get", key, options]);
				if (!objects.has(key)) return null;
				const object = metadata(key);
				const condition = options?.onlyIf?.get("If-None-Match");
				if (
					condition?.trim() === "*" ||
					condition?.split(",").some((tag) => tag.trim().replace(/^W\//u, "") === object.httpEtag)
				)
					return object;
				const bytes = new TextEncoder().encode(objects.get(key));
				const range = options?.range;
				const response = new Response(
					range ? bytes.subarray(range.offset, range.offset + range.length) : bytes,
				);
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
	return { calls, request, objects };
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
	for (const validator of ['"fixture-etag"', "*", 'W/"fixture-etag"', '"old", W/"fixture-etag"']) {
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

test("single ranges stream only requested bytes with correct download metadata", async () => {
	for (const [range, expected, contentRange] of [
		["bytes=0-5", "binary", "bytes 0-5/14"],
		["bytes=7-", "fixture", "bytes 7-13/14"],
		["bytes=-7", "fixture", "bytes 7-13/14"],
		["bytes=7-999999999999999999999", "fixture", "bytes 7-13/14"],
		["bytes=-999999999999999999999", "binary fixture", "bytes 0-13/14"],
	]) {
		const { request, calls } = fixture();
		const response = await request("/releases/1.2.3/tx9_linux_amd64", {
			headers: { Range: range },
		});
		assert.equal(response.status, 206, range);
		assert.equal(await response.text(), expected, range);
		assert.equal(response.headers.get("Content-Length"), String(expected.length));
		assert.equal(response.headers.get("Content-Range"), contentRange);
		assert.equal(response.headers.get("Accept-Ranges"), "bytes");
		assert.equal(response.headers.get("ETag"), '"fixture-etag"');
		assert.match(response.headers.get("Cache-Control"), /immutable/);
		assert.deepEqual(
			calls.map(([method]) => method),
			["head", "get"],
		);
		assert.equal(calls[1][2].range.length, expected.length);
	}
});

test("unsatisfiable ranges fail without retrieving the binary", async () => {
	for (const range of [
		"bytes=14-",
		"bytes=99-100",
		"bytes=5-4",
		"bytes=-0",
		"bytes=999999999999999999999-",
	]) {
		const { request, calls } = fixture();
		const response = await request("/releases/1.2.3/tx9_linux_amd64", {
			headers: { Range: range },
		});
		assert.equal(response.status, 416, range);
		assert.equal(response.headers.get("Content-Range"), "bytes */14");
		assert.equal(response.headers.get("Cache-Control"), "no-store");
		assert.deepEqual(calls, [["head", "1.2.3/tx9_linux_amd64"]]);
	}
	const { request, objects } = fixture();
	objects.set("1.2.3/tx9_linux_amd64", "");
	const empty = await request("/releases/1.2.3/tx9_linux_amd64", {
		headers: { Range: "bytes=0-0" },
	});
	assert.equal(empty.status, 416);
	assert.equal(empty.headers.get("Content-Range"), "bytes */0");
});

test("malformed, unsupported, and multipart ranges preserve ordinary downloads", async () => {
	for (const range of ["bytes=", "bytes=-", "bytes=foo-bar", "items=0-1", "bytes=0-1,4-5"]) {
		const { request } = fixture();
		const response = await request("/releases/1.2.3/tx9_linux_amd64", {
			headers: { Range: range },
		});
		assert.equal(response.status, 200, range);
		assert.equal(response.headers.get("Content-Range"), null);
		assert.equal(await response.text(), "binary fixture");
	}
});

test("matching cache validators take precedence over ranges without retrieving a body", async () => {
	for (const range of ["bytes=0-5", "bytes=99-100"]) {
		const { request, calls } = fixture();
		const response = await request("/releases/1.2.3/tx9_linux_amd64", {
			headers: { Range: range, "If-None-Match": '"old", W/"fixture-etag"' },
		});
		assert.equal(response.status, 304);
		assert.equal(response.body, null);
		assert.equal(response.headers.get("Content-Range"), null);
		assert.deepEqual(calls, [["head", "1.2.3/tx9_linux_amd64"]]);
	}
});

test("If-Range resumes only when its strong validator matches", async () => {
	for (const [validator, status, expected] of [
		['"fixture-etag"', 206, "fixture"],
		['"old"', 200, "binary fixture"],
		['W/"fixture-etag"', 200, "binary fixture"],
	]) {
		const { request } = fixture();
		const response = await request("/releases/1.2.3/tx9_linux_amd64", {
			headers: { Range: "bytes=7-", "If-Range": validator },
		});
		assert.equal(response.status, status, validator);
		assert.equal(await response.text(), expected, validator);
	}
});

test("HEAD ignores Range and missing ranged assets remain 404", async () => {
	const { request, calls } = fixture();
	const response = await request("/releases/1.2.3/tx9_linux_amd64", {
		method: "HEAD",
		headers: { Range: "bytes=99-100" },
	});
	assert.equal(response.status, 200);
	assert.equal(response.body, null);
	assert.equal(response.headers.get("Content-Length"), "14");
	assert.equal(response.headers.get("Content-Range"), null);
	assert.equal(response.headers.get("Accept-Ranges"), "bytes");
	assert.deepEqual(calls, [["head", "1.2.3/tx9_linux_amd64"]]);
	const missing = await request("/releases/9.9.9/tx9_linux_amd64", {
		headers: { Range: "bytes=0-5" },
	});
	assert.equal(missing.status, 404);
});
