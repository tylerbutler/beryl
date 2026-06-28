export default ({ marp } = {}) => {
  const engine = marp;
  const fence = engine.markdown.renderer.rules.fence;
  engine.markdown.renderer.rules.fence = (tokens, idx, options, env, self) => {
    const token = tokens[idx];
    if ((token.info || "").trim() === "mermaid") {
      return `<pre class="mermaid">${token.content}</pre>`;
    }
    return fence(tokens, idx, options, env, self);
  };
  return engine;
};
