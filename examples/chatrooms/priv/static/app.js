// Chat Rooms — beryl demo client
// Uses the Phoenix JS client to connect via WebSocket

(function () {
  "use strict";

  // --- Config ---
  const TYPING_TIMEOUT_MS = 2000;
  const AUTH_TOKEN = new URLSearchParams(window.location.search).get("token") || "beryl-demo";

  // --- State ---
  let currentRoom = null;
  let currentChannel = null;
  let mySocketId = null;
  let myUsername = null;
  let myColor = null;
  let typingTimer = null;
  let isTyping = false;
  let lobbyChannel = null;
  let lobbyJoined = false;

  // --- Username prompt ---
  const username = prompt("Choose a display name:", "User" + Math.floor(Math.random() * 1000)) || "Anonymous";
  myUsername = username;

  // --- Connect via Phoenix ---
  const { Socket } = window.Phoenix || window;
  const socket = new Socket("/socket", {
    params: { token: AUTH_TOKEN },
  });
  socket.connect();

  // --- DOM References ---
  const roomList = document.getElementById("room-list");
  const roomTitle = document.getElementById("room-title");
  const messagesEl = document.getElementById("messages");
  const typingEl = document.getElementById("typing-indicator");
  const msgForm = document.getElementById("msg-form");
  const msgInput = document.getElementById("msg-input");
  const sendBtn = document.getElementById("send-btn");
  const userList = document.getElementById("user-list");

  async function refreshRoomCounts() {
    try {
      const response = await fetch("/api/rooms");
      if (!response.ok) {
        throw new Error(`Room refresh failed with ${response.status}`);
      }
      updateRoomCounts(await response.json());
    } catch (error) {
      console.warn("Could not refresh room counts", error);
    }
  }

  function updateRoomCounts(rooms) {
    const counts = new Map(rooms.map((room) => [room.name, room.users]));

    document.querySelectorAll(".room-count").forEach((badge) => {
      const roomName = badge.dataset.roomCount;
      if (!counts.has(roomName)) return;
      const users = counts.get(roomName);
      badge.textContent = String(users);
      badge.setAttribute(
        "aria-label",
        `${users} ${users === 1 ? "user" : "users"} in ${roomName}`
      );
    });
  }

  // --- Room switching ---
  roomList.addEventListener("click", (e) => {
    const item = e.target.closest(".room-item");
    if (!item) return;
    const roomName = item.dataset.room;
    joinRoom(roomName);
  });

  function joinRoom(roomName) {
    if (currentRoom === roomName) return;

    // Leave current channel
    if (currentChannel) {
      currentChannel.leave();
    }

    // Clear state
    messagesEl.innerHTML = "";
    typingEl.textContent = "";
    userList.innerHTML = "";
    currentRoom = roomName;

    // Update UI
    roomTitle.textContent = roomName;
    document.querySelectorAll(".room-item").forEach((el) => {
      el.classList.toggle("active", el.dataset.room === roomName);
    });
    msgInput.disabled = false;
    sendBtn.disabled = false;
    msgInput.placeholder = "Message #" + roomName;
    msgInput.focus();

    // Join new channel
    const topic = "room:" + roomName;
    currentChannel = socket.channel(topic, { username: username });

    currentChannel.join()
      .receive("ok", (resp) => {
        mySocketId = resp.socket_id;
        myUsername = resp.username;
        myColor = resp.color;
        if (lobbyJoined) {
          refreshRoomCounts();
        }
      })
      .receive("error", (resp) => {
        const msg = resp.error || resp.message || "Failed to join room";
        addSystemMessage("Error: " + msg);
        msgInput.disabled = true;
        sendBtn.disabled = true;
      });

    // Listen for messages
    currentChannel.on("new_msg", (payload) => {
      if (payload.type === "system") {
        addSystemMessage(payload.text);
      } else {
        addUserMessage(payload);
      }
    });

    // Listen for presence updates
    currentChannel.on("presence_list", (payload) => {
      updateUserList(payload);
    });

    // Listen for typing indicators
    currentChannel.on("typing", (payload) => {
      if (payload.socket_id !== mySocketId) {
        showTypingIndicator(payload);
      }
    });
  }

  // --- Send messages ---
  msgForm.addEventListener("submit", (e) => {
    e.preventDefault();
    const text = msgInput.value.trim();
    if (!text || !currentChannel) return;

    currentChannel.push("new_msg", { text: text })
      .receive("ok", (_resp) => {
        // Message acknowledged
      })
      .receive("error", (resp) => {
        addErrorMessage(resp.error || "Failed to send message");
      });

    // Stop typing indicator
    if (isTyping) {
      currentChannel.push("stop_typing", {});
      isTyping = false;
      clearTimeout(typingTimer);
    }

    msgInput.value = "";
    msgInput.focus();
  });

  // --- Typing indicator (client → server) ---
  msgInput.addEventListener("input", () => {
    if (!currentChannel) return;

    if (!isTyping) {
      isTyping = true;
      currentChannel.push("typing", {});
    }

    clearTimeout(typingTimer);
    typingTimer = setTimeout(() => {
      isTyping = false;
      currentChannel.push("stop_typing", {});
    }, TYPING_TIMEOUT_MS);
  });

  // --- UI Rendering ---

  function addSystemMessage(text) {
    const div = document.createElement("div");
    div.className = "message system";
    div.textContent = text;
    messagesEl.appendChild(div);
    messagesEl.scrollTop = messagesEl.scrollHeight;
  }

  function addUserMessage(payload) {
    const div = document.createElement("div");
    div.className = "message user";
    const isMe = payload.socket_id === mySocketId;
    const time = new Date(payload.timestamp).toLocaleTimeString([], {
      hour: "2-digit",
      minute: "2-digit",
    });

    div.innerHTML = [
      '<div class="msg-header">',
        '<span class="msg-author" style="color: ' + escapeAttr(payload.color) + '">',
          escapeHtml(payload.username) + (isMe ? " (you)" : ""),
        "</span>",
        '<span class="msg-time">' + time + "</span>",
      "</div>",
      '<div class="msg-text">' + escapeHtml(payload.text) + "</div>",
    ].join("");

    messagesEl.appendChild(div);
    messagesEl.scrollTop = messagesEl.scrollHeight;
  }

  function addErrorMessage(text) {
    const div = document.createElement("div");
    div.className = "msg-error";
    div.textContent = "⚠ " + text;
    messagesEl.appendChild(div);
    messagesEl.scrollTop = messagesEl.scrollHeight;
  }

  function updateUserList(presences) {
    userList.innerHTML = "";
    for (const [pid, meta] of Object.entries(presences)) {
      const entry = (typeof meta === "object" && meta !== null) ? meta : {};
      const name = entry.username || "Unknown";
      const color = entry.color || "#999";
      const isMe = pid === mySocketId;
      const isUserTyping = entry.typing === true;

      const li = document.createElement("li");
      li.innerHTML = [
        '<span class="user-dot" style="background: ' + escapeAttr(color) + '"></span>',
        '<span class="user-name">' + escapeHtml(name) + (isMe ? " (you)" : "") + "</span>",
        isUserTyping ? '<span class="user-typing">typing...</span>' : "",
      ].join("");
      userList.appendChild(li);
    }
  }

  const typingUsers = new Map();

  function showTypingIndicator(payload) {
    if (payload.typing) {
      typingUsers.set(payload.username, Date.now());
    } else {
      typingUsers.delete(payload.username);
    }
    renderTypingIndicator();
  }

  function renderTypingIndicator() {
    const names = Array.from(typingUsers.keys());
    if (names.length === 0) {
      typingEl.textContent = "";
    } else if (names.length === 1) {
      typingEl.textContent = names[0] + " is typing...";
    } else {
      typingEl.textContent = names.join(", ") + " are typing...";
    }
  }

  // Clean up stale typing indicators
  setInterval(() => {
    const now = Date.now();
    for (const [name, timestamp] of typingUsers) {
      if (now - timestamp > 3000) {
        typingUsers.delete(name);
      }
    }
    renderTypingIndicator();
  }, 1000);

  // --- Lobby-first startup ---
  function joinFirstRoom() {
    const firstRoom = document.querySelector(".room-item");
    if (firstRoom) {
      joinRoom(firstRoom.dataset.room);
    }
  }

  lobbyChannel = socket.channel("lobby", {});
  lobbyChannel.on("rooms_changed", () => {
    refreshRoomCounts();
  });
  lobbyChannel.join()
    .receive("ok", () => {
      lobbyJoined = true;
      joinFirstRoom();
    })
    .receive("error", (response) => {
      console.warn("Failed to join lobby", response);
      joinFirstRoom();
    });

  // --- Utilities ---
  function escapeHtml(str) {
    const div = document.createElement("div");
    div.textContent = str;
    return div.innerHTML;
  }

  function escapeAttr(str) {
    return str.replace(/"/g, "&quot;").replace(/'/g, "&#39;");
  }
})();
