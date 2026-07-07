// wrangler.jsonc's rules import *.txt files as text modules.
declare module "*.txt" {
	const content: string;
	export default content;
}
