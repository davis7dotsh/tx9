import { readFileSync } from "node:fs";
import { registerHooks } from "node:module";

// Match Wrangler's text-module import without bundling or running a dev server.
registerHooks({
	resolve(specifier, context, nextResolve) {
		if (specifier.endsWith(".txt")) {
			return { url: new URL(specifier, context.parentURL).href, shortCircuit: true };
		}
		return nextResolve(specifier, context);
	},
	load(url, context, nextLoad) {
		if (url.endsWith(".txt")) {
			return {
				format: "module",
				source: `export default ${JSON.stringify(readFileSync(new URL(url), "utf8"))};`,
				shortCircuit: true,
			};
		}
		return nextLoad(url, context);
	},
});
