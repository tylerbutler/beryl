import { Ok, Error } from "./gleam.mjs";

// gleam_json represents Json as native JSON values on JavaScript.
export function parse(text) {
	try {
		return new Ok(JSON.parse(text));
	} catch {
		return new Error(undefined);
	}
}
