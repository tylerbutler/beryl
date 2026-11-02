import { DurableObject } from "cloudflare:workers";
import * as bridge from "./build/dev/javascript/portable_channels/portable_channels.mjs";
import { BitArray } from "./build/dev/javascript/gleam_stdlib/gleam.mjs";

const heartbeatTimeout = 60_000;
const maximumFrameBytes = 16_384;
const maximumCommands = 256;
const encoder = new TextEncoder();

function unwrap(result) {
	if (!result.isOk()) throw new Error("Protocol transition failed");
	return result[0];
}

function matchCode(request) {
	return new URL(request.url).pathname.match(
		/^\/matches\/([a-zA-Z0-9_-]{1,32})\/socket\/websocket$/,
	)?.[1];
}

export default {
	fetch(request, env) {
		const url = new URL(request.url);
		const code = matchCode(request);
		if (!code) return new Response("Not found", { status: 404 });
		if ([...url.searchParams.keys()].some((key) => key !== "vsn")) {
			return new Response("Put credentials in the join payload", { status: 400 });
		}
		return env.MATCHES.getByName(code).fetch(request);
	},
};

export class Match extends DurableObject {
	constructor(ctx, env) {
		super(ctx, env);
		this.sessions = new Map();
		ctx.blockConcurrencyWhile(async () => {
			this.code = await ctx.storage.get("code");
			for (const socket of ctx.getWebSockets()) {
				try {
					const attachment = socket.deserializeAttachment();
					const now = Date.now();
					if (
						attachment?.version !== 1 ||
						attachment.code !== this.code ||
						!Number.isSafeInteger(attachment.savedAt) ||
						attachment.savedAt > now ||
						![null, "demo"].includes(attachment.principal)
					) {
						throw new Error("Invalid connection attachment");
					}
					const session = { principal: attachment.principal };
					this.sessions.set(socket, session);
					await this.apply(
						socket,
						bridge.restore(
							attachment.protocol,
							now,
							now - attachment.savedAt,
						),
					);
				} catch {
					this.sessions.delete(socket);
					socket.close(1011, "Reconnect required");
				}
			}
			await this.schedule();
		});
	}

	async fetch(request) {
		const code = matchCode(request);
		if (!code || (this.code && code !== this.code)) {
			return new Response("Wrong match", { status: 404 });
		}
		if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
			return new Response("WebSocket upgrade required", { status: 426 });
		}
		if (!this.code) {
			this.code = code;
			await this.ctx.storage.put("code", code);
		}
		const [client, server] = Object.values(new WebSocketPair());
		this.ctx.acceptWebSocket(server);
		this.sessions.set(server, {
			state: unwrap(
				bridge.new_connection(crypto.randomUUID(), heartbeatTimeout, Date.now()),
			),
			principal: null,
		});
		this.checkpoint(server);
		await this.schedule();
		return new Response(null, { status: 101, webSocket: client });
	}

	webSocketMessage(socket, message) {
		return this.ctx.blockConcurrencyWhile(async () => {
			const size =
				typeof message === "string"
					? encoder.encode(message).byteLength
					: message.byteLength;
			if (size > maximumFrameBytes) {
				await this.finish(socket, 1009, "Frame too large");
				return;
			}
			const session = this.sessions.get(socket);
			if (!session) return;
			try {
				const result =
					typeof message === "string"
						? bridge.receive_text(session.state, message, Date.now())
						: bridge.receive_binary(
								session.state,
								new BitArray(new Uint8Array(message)),
								Date.now(),
							);
				// Codec errors drop a frame without changing the protocol ledger.
				if (result.isOk()) await this.apply(socket, result);
			} catch {
				await this.finish(socket, 1011, "Reconnect required");
			}
			await this.schedule();
		});
	}

	webSocketClose(socket, code, reason) {
		return this.ctx.blockConcurrencyWhile(async () => {
			await this.finish(socket, code, reason);
			await this.schedule();
		});
	}

	webSocketError(socket) {
		return this.webSocketClose(socket, 1011, "Transport failed");
	}

	alarm() {
		return this.ctx.blockConcurrencyWhile(async () => {
			for (const [socket, session] of this.sessions) {
				await this.apply(socket, bridge.expire(session.state, Date.now()));
			}
			await this.schedule();
		});
	}

	checkpoint(socket) {
		const session = this.sessions.get(socket);
		if (!session) return;
		const now = Date.now();
		const attachment = {
			version: 1,
			code: this.code,
			principal: session.principal,
			savedAt: now,
			protocol: unwrap(bridge.snapshot(session.state, now)),
		};
		if (encoder.encode(JSON.stringify(attachment)).byteLength > 16_000) {
			throw new Error("Connection attachment exceeds its budget");
		}
		socket.serializeAttachment(attachment);
	}

	async apply(socket, result) {
		const transition = unwrap(result);
		const session = this.sessions.get(socket);
		if (!session) return;
		session.state = transition.state;
		// Commit protocol consumption before a send; command retries use durable IDs.
		this.checkpoint(socket);
		for (const action of transition.actions) {
			if (action instanceof bridge.SendText) {
				socket.send(action.data);
			} else if (action instanceof bridge.SendBinary) {
				socket.send(action.data.buffer);
			} else if (action instanceof bridge.Authorize) {
				await this.authorize(socket, action);
			} else if (action instanceof bridge.Deliver) {
				await this.deliver(socket, action);
			} else if (action instanceof bridge.Cleanup) {
				// Closing a channel does not remove its player from the match roster.
				await this.apply(
					socket,
					bridge.cleaned_up(session.state, action.operation, Date.now()),
				);
			} else if (action instanceof bridge.Disconnect) {
				this.sessions.delete(socket);
				socket.close(session.closeCode ?? 1000, session.closeReason ?? action.reason);
			} else if (!(action instanceof bridge.Schedule)) {
				throw new Error("Unknown host action");
			}
		}
	}

	async authorize(socket, action) {
		const session = this.sessions.get(socket);
		const payload = action.payload;
		if (
			action.topic !== `match:${this.code}` ||
			typeof this.env.JOIN_TOKEN !== "string" ||
			this.env.JOIN_TOKEN.length === 0 ||
			payload?.token !== this.env.JOIN_TOKEN
		) {
			await this.apply(
				socket,
				bridge.join_rejected(session.state, action.operation, Date.now()),
			);
			return;
		}
		// This example token represents one fixed principal, not a client-chosen ID.
		session.principal = "demo";
		const snapshot = await this.ctx.storage.transaction(async (storage) => {
			const game = (await storage.get("game")) ?? {
				value: 0,
				revision: 0,
				roster: [],
			};
			if (!game.roster.includes(session.principal)) {
				game.roster.push(session.principal);
				await storage.put("game", game);
			}
			return game;
		});
		await this.apply(
			socket,
			bridge.join_accepted(
				session.state,
				action.operation,
				JSON.stringify({ snapshot }),
				Date.now(),
			),
		);
		if (!this.sessions.has(socket)) return;
		await this.apply(
			socket,
			bridge.push(
				session.state,
				action.topic,
				"snapshot",
				JSON.stringify(snapshot),
				Date.now(),
			),
		);
	}

	async deliver(socket, action) {
		const session = this.sessions.get(socket);
		if (!session.principal) throw new Error("Unauthenticated application delivery");
		let response;
		let succeeded = true;
		if (action.event === "snapshot") {
			response = await this.ctx.storage.get("game");
		} else if (action.event === "increment") {
			const command = action.payload;
			if (
				typeof command?.command_id !== "string" ||
				!/^[a-zA-Z0-9_-]{1,128}$/.test(command.command_id)
			) {
				response = { reason: "invalid_command_id" };
				succeeded = false;
			} else {
				({ response, succeeded } = await this.increment(
					session.principal,
					command.command_id,
				));
			}
		} else {
			response = { reason: "unknown_event" };
			succeeded = false;
		}
		await this.apply(
			socket,
			bridge.reply(
				session.state,
				action.operation,
				JSON.stringify(response),
				succeeded,
				Date.now(),
			),
		);
	}

	increment(principal, commandId) {
		return this.ctx.storage.transaction(async (storage) => {
			const key = `command:${principal}:${commandId}`;
			const previous = await storage.get(key);
			if (previous) return { response: previous, succeeded: true };
			const commands = await storage.list({
				prefix: "command:",
				limit: maximumCommands,
			});
			if (commands.size >= maximumCommands) {
				return { response: { reason: "command_capacity" }, succeeded: false };
			}
			const game = await storage.get("game");
			if (!game || !Number.isSafeInteger(game.revision + 1)) {
				return { response: { reason: "match_unavailable" }, succeeded: false };
			}
			const next = { ...game, value: game.value + 1, revision: game.revision + 1 };
			await storage.put({ game: next, [key]: next });
			return { response: next, succeeded: true };
		});
	}

	async finish(socket, code, reason) {
		const session = this.sessions.get(socket);
		const closeCode =
			[1000, 1001, 1002, 1003, 1007, 1008, 1009, 1011, 1012, 1013].includes(code) ||
			(code >= 3000 && code <= 4999)
				? code
				: 1011;
		if (session) {
			session.closeCode = closeCode;
			session.closeReason = reason;
			await this.apply(socket, bridge.disconnect(session.state, Date.now()));
			this.sessions.delete(socket);
		}
		socket.close(closeCode, reason);
	}

	async schedule() {
		const deadlines = [...this.sessions.values()]
			.map((session) => bridge.next_deadline(session.state))
			.filter((deadline) => deadline >= 0);
		if (deadlines.length === 0) {
			await this.ctx.storage.deleteAlarm();
		} else {
			await this.ctx.storage.setAlarm(Math.max(Date.now() + 1, Math.min(...deadlines)));
		}
	}
}
