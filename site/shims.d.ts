// wrangler.jsonc's rules import *.sh files as text modules.
declare module "*.sh" {
	const content: string;
	export default content;
}
