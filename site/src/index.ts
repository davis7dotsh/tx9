// tx9.davis7.sh — homepage, `curl | sh` installer, and release downloads.
//
// URL surface (shared contract with scripts/install.sh — change both):
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

async function serveReleaseObject(
	env: Env,
	version: string,
	asset: string,
	method: string,
): Promise<Response> {
	if (!VERSION_RE.test(version)) return text("not found\n", 404);
	if (asset !== CHECKSUMS && !ASSET_RE.test(asset)) return text("not found\n", 404);

	// HEAD needs only metadata — head() skips pulling the (binary-sized)
	// body out of R2 entirely.
	const key = `${version}/${asset}`;
	let object: R2Object | null;
	let body: ReadableStream | null = null;
	if (method === "HEAD") {
		object = await env.RELEASES.head(key);
	} else {
		const got = await env.RELEASES.get(key);
		object = got;
		body = got?.body ?? null;
	}
	if (!object) return text("not found\n", 404);

	return new Response(body, {
		headers: {
			"Content-Type": asset === CHECKSUMS ? "text/plain; charset=utf-8" : "application/octet-stream",
			"Content-Length": String(object.size),
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
			if (!version) return text("no releases published yet\n", 404, { "Cache-Control": "no-store" });
			return text(`${version}\n`, 200, { "Cache-Control": "no-store" });
		}

		const latestAsset = path.match(/^\/releases\/latest\/([^/]+)$/u);
		if (latestAsset) {
			const version = await latestVersion(env);
			if (!version) return text("no releases published yet\n", 404, { "Cache-Control": "no-store" });
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
			return serveReleaseObject(env, versioned[1], versioned[2], request.method);
		}

		// Everything else (/, /favicon.ico, ...) falls through to static
		// assets; ASSETS 404s anything it doesn't have.
		return env.ASSETS.fetch(request);
	},
} satisfies ExportedHandler<Env>;
