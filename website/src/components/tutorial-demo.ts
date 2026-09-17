export function element<T extends Element>(
	root: ParentNode,
	selector: string,
	type: { new(): T },
): T {
	const found = root.querySelector(selector);
	if (!(found instanceof type)) {
		throw new Error(`Tutorial demo is missing ${selector}.`);
	}
	return found;
}

export function animate(
	target: Element,
	frames: Keyframe[],
	duration: number,
	deliver: () => void = () => {},
): void {
	if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
		deliver();
		return;
	}
	const flight = target.animate(frames, { duration, easing: "ease-in-out" });
	flight.onfinish = () => {
		flight.onfinish = null;
		flight.cancel();
		if (target.isConnected) deliver();
	};
}

export function cancelMotion(root: Element): void {
	for (const flight of root.getAnimations({ subtree: true })) {
		flight.onfinish = null;
		flight.cancel();
	}
}
