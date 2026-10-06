// tx9.col-agents.com — homepage, `curl | sh` installer, and release downloads.
//
// URL surface (shared contract with scripts/install.sh and
// internal/selfupdate — change all of them together):
//   GET /                                homepage (static asset)
//   GET /install                         scripts/install.sh, as text
//   GET /releases/latest                 current version string, text/plain
//   GET /releases/latest/<asset>         302 -> /releases/<version>/<asset>
//   GET /releases/<version>/<asset>      binary/checksums from R2
//
// R2 layout in the tx9-releases bucket (written by the release workflow):
//   latest.txt                           e.g. "0.1.0\n"
//   <version>/tx9_<os>_<arch>            release binaries
//   <version>/checksums.txt              sha256sum-format digests

// Text-module import (wrangler.jsonc "rules"): the repo's installer is the
// deployed artifact, so /install can never drift from scripts/install.sh.
// install.txt is a symlink to ../../scripts/install.sh — Cloudflare's API
// WAF 403s any worker upload containing a module named *.sh whose content
// is a shell script (the same bytes upload fine under a .txt name), so
// the import has to go through the .txt alias.
import installScript from "./install.txt";

interface Env {
	ASSETS: Fetcher;
	RELEASES: R2Bucket;
}

// Exactly the assets `make dist` produces — anything else in a request
// path is a 404, so the bucket can't be probed for stray objects.
const ASSET_RE = /^tx9_(?:linux|darwin)_(?:amd64|arm64)$/u;
const VERSION_RE = /^\d+\.\d+\.\d+$/u;
const CHECKSUMS = "checksums.txt";

function isAsset(asset: string) {
	return asset === CHECKSUMS || ASSET_RE.test(asset);
}

function text(body: string, status = 200, extra: Record<string, string> = {}): Response {
	return new Response(body, {
		status,
		headers: {
			"Content-Type": "text/plain; charset=utf-8",
			"X-Content-Type-Options": "nosniff",
			...extra,
		},
	});
}

async function latestVersion(env: Env): Promise<string | null> {
	const object = await env.RELEASES.get("latest.txt");
	if (!object) return null;
	const version = (await object.text()).trim();
	return VERSION_RE.test(version) ? version : null;
}

function matchesEtag(condition: string | null, etag: string) {
	return (
		condition !== null &&
		(condition.trim() === "*" ||
			condition.split(",").some((tag) => tag.trim().replace(/^W\//u, "") === etag))
	);
}

// Support a single byte range for resumable downloads. Ignore malformed
// or multipart requests as HTTP permits, rather than buffering binaries
// to assemble multipart bodies in the Worker.
function releaseRange(header: string | null, size: number) {
	const match = header?.match(/^bytes=(\d*)-(\d*)$/iu);
	if (!match || (!match[1] && !match[2])) return null;
	const offset = match[1] ? Number(match[1]) : Math.max(0, size - Number(match[2]));
	const end = match[1] && match[2] ? Math.min(Number(match[2]), size - 1) : size - 1;
	if (size === 0 || offset > end) return "unsatisfiable";
	return { offset, length: end - offset + 1 };
}

async function serveReleaseObject(
	env: Env,
	version: string,
	asset: string,
	request: Request,
): Promise<Response> {
	if (!VERSION_RE.test(version)) return text("not found\n", 404);
	if (!isAsset(asset)) return text("not found\n", 404);

	const key = `${version}/${asset}`;
	const condition = request.headers.get("If-None-Match");
	// Range applies only to GET. Ordinary GET keeps its single conditional
	// R2 read; HEAD never requests the binary body.
	const rangeHeader = request.method === "GET" ? request.headers.get("Range") : null;
	let range: { offset: number; length: number } | null = null;
	let object: R2Object | null = null;
	let body: ReadableStream | null = null;
	let unchanged = false;
	if (request.method === "HEAD" || rangeHeader !== null) {
		object = await env.RELEASES.head(key);
		if (!object) return text("not found\n", 404);
		unchanged = matchesEtag(condition, object.httpEtag);
		const ifRange = request.headers.get("If-Range");
		if (!unchanged && (ifRange === null || ifRange.trim() === object.httpEtag)) {
			const parsed = releaseRange(rangeHeader, object.size);
			if (parsed === "unsatisfiable") {
				return text("range not satisfiable\n", 416, {
					"Content-Range": `bytes */${object.size}`,
					"Accept-Ranges": "bytes",
					"Cache-Control": "no-store",
				});
			}
			range = parsed;
		}
	}
	if (request.method !== "HEAD" && !unchanged) {
		// Pass only the supported validator. R2 omits the body when it
		// matches, avoiding a binary download for a cache revalidation.
		const onlyIf = new Headers();
		if (condition !== null) onlyIf.set("If-None-Match", condition);
		const got = await env.RELEASES.get(key, { onlyIf, ...(range ? { range } : {}) });
		object = got;
		unchanged = got !== null && !("body" in got);
		body = got && "body" in got ? got.body : null;
	}
	if (!object) return text("not found\n", 404);
	if (unchanged) {
		return new Response(null, {
			status: 304,
			headers: {
				ETag: object.httpEtag,
				"Cache-Control": "public, max-age=31536000, immutable",
			},
		});
	}

	return new Response(body, {
		status: range ? 206 : 200,
		headers: {
			"Content-Type":
				asset === CHECKSUMS ? "text/plain; charset=utf-8" : "application/octet-stream",
			"Content-Length": String(range ? range.length : object.size),
			...(range
				? {
						"Content-Range": `bytes ${range.offset}-${range.offset + range.length - 1}/${object.size}`,
					}
				: {}),
			"Accept-Ranges": "bytes",
			ETag: object.httpEtag,
			// Versioned paths are immutable by construction; the mutable
			// pointer is latest.txt, which is served no-store below.
			"Cache-Control": "public, max-age=31536000, immutable",
			"Content-Disposition": `attachment; filename="${asset}"`,
			"X-Content-Type-Options": "nosniff",
		},
	});
}

export default {
	async fetch(request, env): Promise<Response> {
		const url = new URL(request.url);
		const path = url.pathname;

		if (request.method !== "GET" && request.method !== "HEAD") {
			return text("method not allowed\n", 405, { Allow: "GET, HEAD" });
		}

		if (path === "/install" || path === "/install.sh") {
			return text(installScript, 200, { "Cache-Control": "no-store" });
		}

		if (path === "/releases/latest") {
			const version = await latestVersion(env);
			if (!version)
				return text("no releases published yet\n", 404, { "Cache-Control": "no-store" });
			return text(`${version}\n`, 200, { "Cache-Control": "no-store" });
		}

		const latestAsset = path.match(/^\/releases\/latest\/([^/]+)$/u);
		if (latestAsset) {
			if (!isAsset(latestAsset[1])) return text("not found\n", 404);
			const version = await latestVersion(env);
			if (!version)
				return text("no releases published yet\n", 404, { "Cache-Control": "no-store" });
			// Redirect rather than proxy so the download URL in error
			// messages / logs always names the concrete version.
			return new Response(null, {
				status: 302,
				headers: {
					Location: `/releases/${version}/${latestAsset[1]}`,
					"Cache-Control": "no-store",
				},
			});
		}

		const versioned = path.match(/^\/releases\/([^/]+)\/([^/]+)$/u);
		if (versioned) {
			return serveReleaseObject(env, versioned[1], versioned[2], request);
		}

		// Everything else (/, /favicon.ico, ...) falls through to static
		// assets; ASSETS 404s anything it doesn't have.
		return env.ASSETS.fetch(request);
	},
} satisfies ExportedHandler<Env>;
