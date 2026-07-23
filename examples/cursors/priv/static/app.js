// Collaborative Cursors — beryl demo client
// Uses the Phoenix JS client to connect via WebSocket

(function () {
  "use strict";

  // --- Config ---
  const THROTTLE_MS = 50; // 20fps cursor updates
  const CURSOR_TIMEOUT_MS = 5000; // Remove stale cursors after 5s
  const REACTION_DURATION_MS = 1200;

  // --- State ---
  let mySocketId = null;
  let myUsername = null;
  let myColor = null;
  const cursors = new Map(); // socket_id -> { el, x, y, username, color, lastSeen }

  // --- Username prompt ---
  const username = prompt("Choose a display name:", "User" + Math.floor(Math.random() * 1000)) || "Anonymous";

  // --- Connect via Phoenix ---
  const { Socket } = window.Phoenix || window;
  const socket = new Socket("/socket", {});
  socket.connect();

  const channel = socket.channel("cursor:lobby", { username: username });

  channel.join()
    .receive("ok", (resp) => {
      mySocketId = resp.socket_id;
      myUsername = resp.username;
      myColor = resp.color;
      console.log("Joined cursor:lobby as", myUsername, myColor);

      // Show own indicator in sidebar
      updateSidebar({});
    })
    .receive("error", (resp) => {
      console.error("Failed to join:", resp);
    });

  // --- Handle presence list updates ---
  channel.on("presence_list", (payload) => {
    updateSidebar(payload);
  });

  // --- Handle remote cursor moves ---
  channel.on("cursor_move", (payload) => {
    const { socket_id, x, y, username, color } = payload;
    if (socket_id === mySocketId) return;

    let cursor = cursors.get(socket_id);
    if (!cursor) {
      cursor = createCursorElement(socket_id, username, color);
      cursors.set(socket_id, cursor);
    }

    cursor.x = x;
    cursor.y = y;
    cursor.lastSeen = Date.now();
    cursor.el.style.transform = `translate(${x}px, ${y}px)`;
  });

  // --- DOM references and reaction state ---
  const canvas = document.getElementById("canvas");
  const reactionToolbar = document.getElementById("reaction-toolbar");
  const reactionButtons = Array.from(
    reactionToolbar.querySelectorAll(".reaction-option")
  );
  let selectedReaction = "👍";

  // --- Reaction toolbar ---

  function setSelectedReaction(reaction) {
    selectedReaction = selectedReaction === reaction ? null : reaction;
    for (const button of reactionButtons) {
      const selected = button.dataset.reaction === selectedReaction;
      button.classList.toggle("is-selected", selected);
      button.setAttribute("aria-pressed", String(selected));
    }
  }

  for (const button of reactionButtons) {
    button.addEventListener("click", (event) => {
      event.stopPropagation();
      setSelectedReaction(button.dataset.reaction);
    });
  }

  canvas.addEventListener("click", (event) => {
    if (!selectedReaction || event.target.closest("#reaction-toolbar")) return;

    const rect = canvas.getBoundingClientRect();
    spawnReaction(
      selectedReaction,
      event.clientX - rect.left,
      event.clientY - rect.top
    );
  });

  function spawnReaction(reaction, x, y) {
    const el = document.createElement("span");
    el.className = "reaction-burst";
    el.textContent = reaction;
    el.style.left = `${x}px`;
    el.style.top = `${y}px`;
    el.style.setProperty(
      "--reaction-drift",
      `${(Math.random() * 32 - 16).toFixed(1)}px`
    );
    el.style.setProperty(
      "--reaction-scale",
      (0.9 + Math.random() * 0.25).toFixed(2)
    );

    const cleanup = () => el.remove();
    el.addEventListener("animationend", cleanup, { once: true });
    setTimeout(cleanup, REACTION_DURATION_MS + 200);
    canvas.appendChild(el);
  }

  // --- Send own cursor position ---
  let localCursorEl = null;

  function ensureLocalCursor() {
    if (localCursorEl) return;
    const color = myColor || "#999";
    const name = myUsername || "You";
    localCursorEl = document.createElement("div");
    localCursorEl.className = "cursor cursor-local";

    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("width", "20");
    svg.setAttribute("height", "20");
    svg.setAttribute("viewBox", "0 0 20 20");
    svg.setAttribute("fill", "none");
    const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
    path.setAttribute("d", "M3 3L10 17L12 10L19 8L3 3Z");
    path.setAttribute("fill", color);
    path.setAttribute("stroke", "#333");
    path.setAttribute("stroke-width", "1");
    svg.appendChild(path);

    const label = document.createElement("span");
    label.className = "cursor-label";
    label.style.background = color;
    label.textContent = name;

    localCursorEl.appendChild(svg);
    localCursorEl.appendChild(label);
    localCursorEl.style.transform = "translate(-100px, -100px)";
    canvas.appendChild(localCursorEl);
  }

  canvas.addEventListener("mousemove", (e) => {
    const rect = canvas.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const y = e.clientY - rect.top;

    // Update local cursor immediately (no throttle for responsiveness)
    ensureLocalCursor();
    localCursorEl.style.transform = `translate(${x}px, ${y}px)`;
  });

  canvas.addEventListener("mousemove", throttle((e) => {
    const rect = canvas.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const y = e.clientY - rect.top;
    channel.push("cursor_move", { x: x, y: y });
  }, THROTTLE_MS));

  canvas.addEventListener("mouseleave", () => {
    if (localCursorEl) {
      localCursorEl.style.transform = "translate(-100px, -100px)";
    }
  });

  // Touch support
  canvas.addEventListener("touchmove", throttle((e) => {
    e.preventDefault();
    const touch = e.touches[0];
    const rect = canvas.getBoundingClientRect();
    const x = touch.clientX - rect.left;
    const y = touch.clientY - rect.top;
    channel.push("cursor_move", { x: x, y: y });
  }, THROTTLE_MS), { passive: false });

  // --- Create a cursor element for a remote user ---
  function createCursorElement(socketId, name, color) {
    const el = document.createElement("div");
    el.className = "cursor";
    el.innerHTML = `
      <svg width="20" height="20" viewBox="0 0 20 20" fill="none">
        <path d="M3 3L10 17L12 10L19 8L3 3Z" fill="${color}" stroke="#333" stroke-width="1"/>
      </svg>
      <span class="cursor-label" style="background: ${color}">${escapeHtml(name)}</span>
    `;
    el.style.transform = "translate(-100px, -100px)";
    canvas.appendChild(el);

    return { el, x: 0, y: 0, username: name, color, lastSeen: Date.now() };
  }

  // --- Update sidebar user list ---
  function updateSidebar(presences) {
    const list = document.getElementById("user-list");
    list.innerHTML = "";

    // Add entries from presence payload
    for (const [pid, meta] of Object.entries(presences)) {
      const entry = (typeof meta === "object" && meta !== null) ? meta : {};
      const name = entry.username || "Unknown";
      const color = entry.color || "#999";
      const isMe = pid === mySocketId;

      const li = document.createElement("li");
      li.innerHTML = `
        <span class="user-dot" style="background: ${color}"></span>
        <span class="user-name">${escapeHtml(name)}${isMe ? " (you)" : ""}</span>
      `;
      list.appendChild(li);
    }

    // If no presences yet but we're connected, show self
    if (Object.keys(presences).length === 0 && myUsername) {
      const li = document.createElement("li");
      li.innerHTML = `
        <span class="user-dot" style="background: ${myColor}"></span>
        <span class="user-name">${escapeHtml(myUsername)} (you)</span>
      `;
      list.appendChild(li);
    }
  }

  // --- Clean up stale cursors ---
  setInterval(() => {
    const now = Date.now();
    for (const [id, cursor] of cursors) {
      if (now - cursor.lastSeen > CURSOR_TIMEOUT_MS) {
        cursor.el.remove();
        cursors.delete(id);
      }
    }
  }, 1000);

  // --- Utilities ---
  function throttle(fn, ms) {
    let last = 0;
    return function (...args) {
      const now = Date.now();
      if (now - last >= ms) {
        last = now;
        fn.apply(this, args);
      }
    };
  }

  function escapeHtml(str) {
    const div = document.createElement("div");
    div.textContent = str;
    return div.innerHTML;
  }
})();
