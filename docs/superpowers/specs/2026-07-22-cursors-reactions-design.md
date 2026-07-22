# Cursors Reactions Design

## Goal

Add collaborative reactions to the cursors example. A user selects a reaction, clicks the canvas, and sees the reaction rise and fade from the click point. Every other user in the room sees the same reaction at the corresponding position.

## Interaction

The canvas contains a compact reaction toolbar centered near its bottom edge. The toolbar offers:

- 👍
- ❤️
- 😂
- 🎉
- 🔥

👍 starts selected. Selecting another button changes the active reaction. Clicking the active button again clears the selection. Canvas clicks create reactions only while a reaction is active, and toolbar clicks never create reactions.

Each reaction begins at the click point, drifts upward with a small randomized horizontal offset and scale, and fades out in about 1.2 seconds. Rapid clicks create independent animations. The client removes each animation node when the animation ends.

## Client Architecture

`priv/static/app.js` owns toolbar selection and reaction rendering. A shared rendering helper creates both local and remote reactions.

On a valid canvas click, the client:

1. Renders the selected reaction immediately.
2. Converts the click point to normalized `x` and `y` coordinates from 0 through 1.
3. Pushes a `reaction` channel event with `{ reaction, x, y }`.

On a remote `reaction` event, the client converts the normalized coordinates to its current canvas dimensions and calls the same rendering helper. Normalized coordinates keep reactions aligned across different viewport sizes.

The client stores no reaction history. Reactions exist only as short-lived DOM nodes.

## Server Architecture

`src/cursors/app.gleam` handles `reaction` as a separate domain event beside `cursor_move`. This explicit event matches Gleam's preference for small, concrete data flows over speculative generic abstractions.

The handler accepts only the five toolbar reactions and numeric coordinates within the normalized range. Valid events produce a `BroadcastFrom` effect, which sends the reaction to every other socket in the topic without echoing it to the sender. Invalid payloads produce no broadcast.

The server stores no reaction state. Existing presence and cursor state remain unchanged.

## Markup and Styling

`src/cursors/router.gleam` adds the toolbar markup inside `#canvas`. Each reaction is a button with an accessible label and `aria-pressed` state.

`priv/static/style.css` styles the toolbar, selected state, reaction nodes, and animation. The toolbar remains above the canvas content and clear of the Online sidebar. A `prefers-reduced-motion` rule preserves the fade while removing most movement.

## Edge Cases

- A click with no selected reaction does nothing.
- A toolbar click changes selection without spawning a reaction.
- Unsupported emoji and malformed coordinates never reach other clients.
- Multiple reactions animate independently.
- Animation nodes are removed after completion.
- A client can render remote reactions before it has moved its own cursor.

## Testing

Gleam tests cover:

- Broadcasting each supported reaction.
- Preserving normalized coordinates.
- Rejecting unsupported reactions.
- Rejecting malformed or out-of-range coordinates.
- Leaving cursor movement behavior unchanged.

Playwright tests cover:

- Toolbar structure and accessible labels.
- 👍 as the initial selection.
- Switching and clearing the selection.
- Local reaction creation and cleanup.
- Toolbar clicks not creating reactions.
- No reaction when the selection is clear.
- Two-browser reaction broadcasting.
- Remote placement at the corresponding canvas position.

## Out of Scope

- Reaction history or persistence.
- Counts, summaries, or analytics.
- User-defined reaction sets.
- Sound effects.
- Server-assigned animation timing.
