import { exports } from "cloudflare:workers";

// Keep Phoenix's serializer and channel implementation; replace only network dialing.
export class WorkerTransport {
	constructor(url) {
		this.readyState = 0;
		this.binaryType = "arraybuffer";
		this.sent = [];
		this.received = [];
		this.open(url).catch((error) => {
			this.readyState = 3;
			this.onerror?.(error);
		});
	}

	async open(url) {
		const endpoint = new URL(url);
		endpoint.protocol = endpoint.protocol === "wss:" ? "https:" : "http:";
		const response = await exports.default.fetch(
			new Request(endpoint, { headers: { Upgrade: "websocket" } }),
		);
		if (!response.webSocket) throw new Error(`Upgrade failed: ${response.status}`);
		this.webSocket = response.webSocket;
		this.webSocket.addEventListener("message", (event) => {
			this.received.push(event.data);
			if (!this.dropReplies) this.onmessage?.(event);
		});
		this.webSocket.addEventListener("close", (event) => {
			this.readyState = 3;
			this.onclose?.(event);
		});
		this.webSocket.addEventListener("error", (event) => this.onerror?.(event));
		this.webSocket.accept();
		this.readyState = 1;
		this.onopen?.();
	}

	send(data) {
		this.sent.push(data);
		this.webSocket.send(data);
	}

	close(code = 1000, reason = "") {
		this.readyState = 2;
		this.webSocket?.close(code, reason);
	}
}
