// Adapted from Phoenix v1.8.17's Channels guide, "Tying it all together".
// Copyright (c) 2014 Chris McCord. MIT license: phoenix_tutorial.LICENSE.txt.
import { Socket } from "https://unpkg.com/phoenix@1.8.17/priv/static/phoenix.mjs";

const socket = new Socket("/phoenix/socket");
socket.connect();

const channel = socket.channel("room:lobby", {});
const chatInput = document.querySelector("#chat-input");
const messagesContainer = document.querySelector("#messages");

chatInput.addEventListener("keypress", (event) => {
  if (event.key === "Enter") {
    channel.push("new_msg", { body: chatInput.value });
    chatInput.value = "";
  }
});

channel.on("new_msg", (payload) => {
  const messageItem = document.createElement("p");
  messageItem.innerText = `[${Date()}] ${payload.body}`;
  messagesContainer.appendChild(messageItem);
});

channel.join()
  .receive("ok", (response) => { console.log("Joined successfully", response); })
  .receive("error", (response) => { console.error("Unable to join", response); });

export default socket;
