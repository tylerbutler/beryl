import * as crdt from "./collab_docs_client.mjs";

const replicaId = `client-${crypto.randomUUID()}`;
const PUSH_DEBOUNCE_MS = 400;

let doc = crdt.new_document(replicaId);
let channel;

const statusEl = document.querySelector("#status") || createFallbackStatus();
const blocksEl = document.querySelector("#blocks");
const addTodoButton = document.querySelector("#add-todo");
const addNoteButton = document.querySelector("#add-note");
const pendingPushes = new Map();

const params = new URLSearchParams(window.location.search);
const docId = params.get("doc") || "welcome";
const tenant =
  document.querySelector('meta[name="beryl-tenant"]')?.content || "demo";
const tenantToken =
  document.querySelector('meta[name="beryl-tenant-token"]')?.content || "";
const topic = `document:${tenant}:${docId}`;

function createFallbackStatus() {
  const fallback = document.createElement("div");
  fallback.id = "status";
  fallback.setAttribute("role", "status");
  fallback.textContent = "Starting…";
  document.body?.prepend(fallback);
  return fallback;
}

function setStatus(message) {
  if (statusEl) {
    statusEl.textContent = message;
  }
}

function failStartup(message) {
  setStatus(message);
  console.error(message);
}

function requireElement(element, selector) {
  if (!element) {
    failStartup(`Startup error: missing ${selector}`);
    return false;
  }

  return true;
}

function checkRequiredElements() {
  return [
    requireElement(blocksEl, "#blocks"),
    requireElement(addTodoButton, "#add-todo"),
    requireElement(addNoteButton, "#add-note"),
  ].every(Boolean);
}

function blockId() {
  return `${Date.now().toString(36)}-${crypto.randomUUID()}`;
}

function newBlock(type) {
  const id = blockId();
  return {
    id,
    type,
    text: type === "todo" ? "New todo" : "New note",
    done: false,
    position: Date.now(),
  };
}

function parseBlock(value, fallbackId) {
  try {
    const parsed = JSON.parse(value);
    if (parsed && typeof parsed === "object") {
      return {
        id: typeof parsed.id === "string" ? parsed.id : fallbackId,
        type: parsed.type === "todo" ? "todo" : "note",
        text: typeof parsed.text === "string" ? parsed.text : "",
        done: parsed.done === true,
        position: Number.isFinite(parsed.position) ? parsed.position : 0,
      };
    }
  } catch {
    // Invalid block values are rendered as plain note text so the UI stays usable.
  }

  return {
    id: fallbackId,
    type: "note",
    text: String(value),
    done: false,
    position: 0,
  };
}

function getBlocks() {
  try {
    return JSON.parse(crdt.blocks_json(doc))
      .map((block) => {
        const values = Array.isArray(block.values)
          ? block.values.map((value) => parseBlock(value, block.id))
          : [];
        const position = values.reduce(
          (lowest, value) => Math.min(lowest, value.position),
          Number.POSITIVE_INFINITY,
        );

        return {
          id: block.id,
          values,
          position: Number.isFinite(position) ? position : 0,
        };
      })
      .filter((block) => block.values.length > 0)
      .sort((a, b) => a.position - b.position || a.id.localeCompare(b.id));
  } catch {
    setStatus("State error: invalid_blocks");
    return [];
  }
}

function serialize(block) {
  return JSON.stringify(block);
}

function mergeState(remoteState) {
  if (typeof remoteState !== "string" || remoteState.length === 0) {
    return;
  }

  const result = crdt.merge_json(doc, remoteState);
  if (result && typeof result.isOk === "function" && result.isOk()) {
    doc = result[0];
  } else {
    const reason = result?.[0]
      ? crdt.document_error_to_string(result[0])
      : "merge_failed";
    setStatus(`State error: ${reason}`);
  }
}

function pushState() {
  if (!channel) {
    return;
  }

  channel
    .push("sync_state", { state: crdt.document_to_json(doc) })
    .receive("error", (reply) => {
      setStatus(`State error: ${reply?.code || "sync_failed"}`);
    })
    .receive("timeout", () => {
      setStatus("State error: sync_timeout");
    });
}

function clearPendingPush(id) {
  const pending = pendingPushes.get(id);
  if (pending) {
    clearTimeout(pending);
    pendingPushes.delete(id);
  }
}

function schedulePush(id) {
  clearPendingPush(id);
  pendingPushes.set(
    id,
    setTimeout(() => {
      pendingPushes.delete(id);
      pushState();
    }, PUSH_DEBOUNCE_MS),
  );
}

function pushBlockState(id, mode) {
  if (mode === "debounced") {
    schedulePush(id);
    return;
  }

  clearPendingPush(id);
  pushState();
}

function currentBlockValue(id, fallback) {
  const block = getBlocks().find((block) => block.id === id);
  if (block?.values.length === 1) {
    return block.values[0];
  }

  return fallback;
}

function saveBlock(block, { rerender = true, push = "immediate" } = {}) {
  const result = crdt.edit_block(doc, block.id, serialize(block));
  if (!result?.isOk?.()) {
    const reason = result?.[0]
      ? crdt.document_error_to_string(result[0])
      : "edit_rejected";
    setStatus(`Edit rejected: ${reason}`);
    return;
  }

  doc = result[0];
  if (rerender) {
    render();
  }
  pushBlockState(block.id, push);
}

function addBlock(type) {
  const block = newBlock(type);
  const result = crdt.add_block(doc, serialize(block));
  if (!result?.isOk?.()) {
    const reason = result?.[0]
      ? crdt.document_error_to_string(result[0])
      : "add_rejected";
    setStatus(`Add rejected: ${reason}`);
    return;
  }

  doc = result[0];
  render();
  pushState();
}

function removeBlock(id) {
  clearPendingPush(id);
  doc = crdt.remove_block(doc, id);
  render();
  pushState();
}

function renderBlock(block) {
  if (block.values.length > 1) {
    return renderConflict(block);
  }

  const value = block.values[0];
  const article = document.createElement("article");
  article.className = `block block-card ${value.done ? "is-done" : ""}`;

  const header = document.createElement("div");
  header.className = "block-header";

  const label = document.createElement("label");
  label.className = "check-row";

  const checkbox = document.createElement("input");
  checkbox.type = "checkbox";
  checkbox.checked = value.done;
  checkbox.addEventListener("change", (event) => {
    const current = currentBlockValue(value.id, value);
    saveBlock({
      ...current,
      done: event.currentTarget.checked,
    });
  });

  const type = document.createElement("span");
  type.className = "block-type";
  type.textContent = value.type === "todo" ? "Todo" : "Note";

  label.append(checkbox, type);

  const deleteButton = document.createElement("button");
  deleteButton.className = "delete-button";
  deleteButton.type = "button";
  deleteButton.textContent = "Delete";
  deleteButton.addEventListener("click", () => removeBlock(block.id));

  header.append(label, deleteButton);

  const textarea = document.createElement("textarea");
  textarea.value = value.text;
  textarea.rows = Math.max(2, Math.min(8, value.text.split("\n").length + 1));
  textarea.addEventListener("input", (event) => {
    const current = currentBlockValue(value.id, value);
    saveBlock(
      { ...current, text: event.currentTarget.value },
      { rerender: false, push: "debounced" },
    );
  });

  article.append(header, textarea);
  return article;
}

function renderConflict(block) {
  const article = document.createElement("article");
  article.className = "block block-card conflict conflict-card";

  const title = document.createElement("h2");
  title.textContent = "Edit conflict";
  article.append(title);

  const detail = document.createElement("p");
  detail.textContent = "Choose the version to keep.";
  article.append(detail);

  block.values.forEach((value, index) => {
    const option = document.createElement("section");
    option.className = "conflict-option";

    const heading = document.createElement("h3");
    heading.textContent = `Version ${index + 1}`;

    const text = document.createElement("p");
    text.textContent = value.text || "Empty block";

    const meta = document.createElement("span");
    meta.className = "conflict-meta";
    meta.textContent = `${value.type === "todo" ? "Todo" : "Note"}${
      value.done ? " · done" : ""
    }`;

    const useButton = document.createElement("button");
    useButton.type = "button";
    useButton.textContent = "Use this version";
    useButton.addEventListener("click", () => {
      clearPendingPush(block.id);
      saveBlock({ ...value, id: block.id });
    });

    option.append(heading, text, meta, useButton);
    article.append(option);
  });

  const deleteButton = document.createElement("button");
  deleteButton.className = "delete-button";
  deleteButton.type = "button";
  deleteButton.textContent = "Delete block";
  deleteButton.addEventListener("click", () => removeBlock(block.id));
  article.append(deleteButton);

  return article;
}

function render() {
  if (!blocksEl) {
    return;
  }

  blocksEl.replaceChildren();
  const blocks = getBlocks();

  if (blocks.length === 0) {
    const empty = document.createElement("p");
    empty.className = "empty-state";
    empty.textContent = "No blocks yet. Add a todo or note to get started.";
    blocksEl.append(empty);
    return;
  }

  blocks.forEach((block) => {
    blocksEl.append(renderBlock(block));
  });
}

function start() {
  if (!checkRequiredElements()) {
    return;
  }

  if (!window.Phoenix?.Socket) {
    failStartup("Startup error: Phoenix socket client unavailable");
    return;
  }

  const socket = new window.Phoenix.Socket("/socket");
  socket.connect();

  channel = socket.channel(topic, { token: tenantToken });
  channel
    .join()
    .receive("ok", (reply) => {
      setStatus("Connected");
      mergeState(reply?.state);
      render();
    })
    .receive("error", (reply) => {
      setStatus(`State error: ${reply?.code || "join_failed"}`);
    })
    .receive("timeout", () => {
      setStatus("State error: join_timeout");
    });

  channel.on("doc_state", (payload) => {
    mergeState(payload?.state);
    render();
  });

  channel.on("state_error", (payload) => {
    setStatus(`State error: ${payload?.code || "unknown"}`);
  });

  addTodoButton.addEventListener("click", () => addBlock("todo"));
  addNoteButton.addEventListener("click", () => addBlock("note"));

  render();
}

start();
