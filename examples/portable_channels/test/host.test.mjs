import { env, exports } from "cloudflare:workers";
import {
	evictDurableObject,
	reset,
	runDurableObjectAlarm,
	runInDurableObject,
} from "cloudflare:test";
import { Socket } from "phoenix";
import { afterEach, expect, test } from "vitest";
import * as bridge from "../build/dev/javascript/portable_channels/portable_channels.mjs";
import { WorkerTransport } from "./transport.mjs";

const clients = [];

afterEach(async () => {
	for (const socket of clients.splice(0)) socket.disconnect();
	await reset();
});

function pushResult(push, status = "ok") {
	return new Promise((resolve, reject) => {
		for (const response of ["ok", "error", "timeout"]) {
			push.receive(response, (payload) => {
				if (response === status) resolve(payload);
				else reject(new Error(`${response}: ${JSON.stringify(payload)}`));
			});
		}
	});
}

function connect(code, token = "test-only-credential") {
	const socket = new Socket(`ws://example.test/matches/${code}/socket`, {
		transport: WorkerTransport,
		timeout: 1000,
		heartbeatIntervalMs: 3_600_000,
		rejoinAfterMs: () => 10,
		reconnectAfterMs: () => 10,
	});
	clients.push(socket);
	const channel = socket.channel(`match:${code}`, { token });
	socket.connect();
	return { socket, channel, stub: env.MATCHES.getByName(code) };
}

test("requires upgrades and rejects credentials in the URL", async () => {
	const ordinary = await exports.default.fetch(
		new Request("https://example.test/matches/routing/socket/websocket"),
	);
	expect(ordinary.status).toBe(426);
	const credentials = await exports.default.fetch(
		new Request("https://example.test/matches/routing/socket/websocket?token=secret"),
	);
	expect(credentials.status).toBe(400);
});

test("accepts a hibernatable WebSocket upgrade", async () => {
	const response = await exports.default.fetch(
		new Request("https://example.test/matches/upgrade/socket/websocket", {
			headers: { Upgrade: "websocket" },
		}),
	);
	expect(response.status).toBe(101);
	response.webSocket.accept();
	response.webSocket.close(1000);
});

test("rejects unauthorized joins without creating application state", async () => {
	const { channel, stub } = connect("authorization", "wrong-token");
	expect(await pushResult(channel.join(), "error")).toEqual({
		reason: "unauthorized",
	});
	await runInDurableObject(stub, async (_instance, state) => {
		expect(await state.storage.get("game")).toBeUndefined();
	});
});

test("orders the join reply before the snapshot and deduplicates commands", async () => {
	const { socket, channel, stub } = connect("ordering");
	const snapshot = new Promise((resolve) => channel.on("snapshot", resolve));
	expect(await pushResult(channel.join())).toEqual({
		snapshot: { value: 0, revision: 0, roster: ["demo"] },
	});
	expect(await snapshot).toEqual({ value: 0, revision: 0, roster: ["demo"] });
	const frames = socket.connection.transport.received.map((text) => JSON.parse(text));
	expect(frames.slice(0, 2).map((frame) => frame[3])).toEqual([
		"phx_reply",
		"snapshot",
	]);
	const command = { command_id: "one-mutation" };
	const first = await pushResult(channel.push("increment", command));
	const retry = await pushResult(channel.push("increment", command));
	expect(first).toEqual({ value: 1, revision: 1, roster: ["demo"] });
	expect(retry).toEqual(first);
	await pushResult(channel.leave());
	await runInDurableObject(stub, async (_instance, state) => {
		expect((await state.storage.get("game")).roster).toEqual(["demo"]);
	});
	const rejoined = socket.channel("match:ordering", {
		token: "test-only-credential",
	});
	expect(await pushResult(rejoined.join())).toEqual({ snapshot: first });
	expect(await pushResult(rejoined.push("increment", command))).toEqual(first);
});

test("preserves established membership and excludes credentials across hibernation", async () => {
	const { socket, channel, stub } = connect("hibernation");
	await pushResult(channel.join());
	await runInDurableObject(stub, (_instance, state) => {
		const attachment = state.getWebSockets()[0].deserializeAttachment();
		expect(JSON.stringify(attachment)).not.toContain("test-only-credential");
		expect(attachment.version).toBe(1);
	});
	await evictDurableObject(stub);
	expect(
		await pushResult(channel.push("increment", { command_id: "after-wake" })),
	).toMatchObject({ value: 1, revision: 1 });
	const joins = socket.connection.transport.sent
		.map((text) => JSON.parse(text))
		.filter((frame) => frame[3] === "phx_join");
	expect(joins).toHaveLength(1);
});

test("a lost reply and reconnect do not repeat an application command", async () => {
	const { socket, channel, stub } = connect("retry");
	await pushResult(channel.join());
	socket.connection.transport.dropReplies = true;
	const command = { command_id: "durable-command" };
	await pushResult(channel.push("increment", command, 50), "timeout");
	await runInDurableObject(stub, async (_instance, state) => {
		expect((await state.storage.get("game")).revision).toBe(1);
	});
	socket.disconnect();
	const replacement = connect("retry");
	const joined = await pushResult(replacement.channel.join());
	expect(joined.snapshot.revision).toBe(1);
	expect(
		await pushResult(replacement.channel.push("increment", command)),
	).toMatchObject({ value: 1, revision: 1 });
});

test("rejects invalid or excess command IDs without evicting retry records", async () => {
	const { channel, stub } = connect("command-capacity");
	await pushResult(channel.join());
	expect(await pushResult(channel.push("increment", {}), "error")).toEqual({
		reason: "invalid_command_id",
	});
	const command = { command_id: "retained-command" };
	const first = await pushResult(channel.push("increment", command));
	await runInDurableObject(stub, async (_instance, state) => {
		const records = Object.fromEntries(
			Array.from({ length: 255 }, (_, index) => [
				`command:demo:seed-${index}`,
				first,
			]),
		);
		await state.storage.put(records);
	});
	expect(
		await pushResult(
			channel.push("increment", { command_id: "over-capacity" }),
			"error",
		),
	).toEqual({ reason: "command_capacity" });
	expect(await pushResult(channel.push("increment", command))).toEqual(first);
	expect(await pushResult(channel.push("snapshot", {}))).toEqual(first);
});

test("unrecoverable pending work requires an authorized rejoin", async () => {
	const { socket, channel, stub } = connect("lost-work");
	await pushResult(channel.join());
	await runInDurableObject(stub, (instance, state) => {
		const server = state.getWebSockets()[0];
		const session = instance.sessions.get(server);
		const result = bridge.receive_text(
			session.state,
			JSON.stringify([
				channel.joinRef(),
				"lost-reply",
				"match:lost-work",
				"snapshot",
				{},
			]),
			Date.now(),
		);
		expect(result.isOk()).toBe(true);
		// Checkpoint the pending delivery without executing its application callback.
		session.state = result[0].state;
		instance.checkpoint(server);
	});
	await evictDurableObject(stub);
	// Wake the object; recovery must reject this old instance before dispatch.
	channel.push("snapshot", {}, 50);
	await expect
		.poll(() =>
			socket.connection.transport.sent
				.map((text) => JSON.parse(text))
				.filter((frame) => frame[3] === "phx_join").length,
		)
		.toBeGreaterThanOrEqual(2);
	await expect.poll(() => channel.isJoined()).toBe(true);
	expect(await pushResult(channel.push("snapshot", {}))).toMatchObject({
		revision: 0,
	});
});

test("expires heartbeats after time spent hibernating", async () => {
	const { socket, channel, stub } = connect("heartbeat");
	await pushResult(channel.join());
	const closed = new Promise((resolve) => socket.onClose(resolve));
	await runInDurableObject(stub, (_instance, state) => {
		const server = state.getWebSockets()[0];
		const attachment = server.deserializeAttachment();
		attachment.savedAt -= 61_000;
		server.serializeAttachment(attachment);
	});
	await evictDurableObject(stub);
	await runDurableObjectAlarm(stub);
	await closed;
	socket.disconnect();
});

test("finishes a checkpointed disconnect after hibernation", async () => {
	const { socket, stub } = connect("interrupted-close");
	await new Promise((resolve) => socket.onOpen(resolve));
	const closed = new Promise((resolve) => socket.onClose(resolve));
	await runInDurableObject(stub, (instance, state) => {
		const server = state.getWebSockets()[0];
		const session = instance.sessions.get(server);
		const result = bridge.disconnect(session.state, Date.now());
		expect(result.isOk()).toBe(true);
		// Interrupt between checkpointing the closed state and closing the socket.
		session.state = result[0].state;
		instance.checkpoint(server);
	});
	await evictDurableObject(stub);
	await runInDurableObject(stub, () => {});
	await closed;
	socket.disconnect();
});

test("answers heartbeats with their original Phoenix reference", async () => {
	const { socket, channel } = connect("heartbeat-reply");
	await pushResult(channel.join());
	const reply = new Promise((resolve) =>
		socket.onMessage((message) => {
			if (message.topic === "phoenix") resolve(message);
		}),
	);
	socket.connection.transport.send(
		JSON.stringify([null, "heartbeat-ref", "phoenix", "heartbeat", {}]),
	);
	expect(await reply).toMatchObject({
		ref: "heartbeat-ref",
		event: "phx_reply",
		payload: { status: "ok", response: {} },
	});
});
