// zuko docs mermaid init (~30 lines, owned). Loads mermaid from the jsdelivr
// CDN, swaps mdBook's `<pre><code class="language-mermaid">` blocks into the
// `<pre class="mermaid">` shape mermaid expects, and renders them — no mdbook
// preprocessor needed. Theme-aware (reloads on theme switch — mermaid can't
// recolor in place).
(() => {
  const dark = ['ayu', 'navy', 'coal'];
  const light = ['light', 'rust'];
  const classList = document.documentElement.classList;
  let lastLight = ![...classList].some(c => dark.includes(c));

  function init() {
    mermaid.initialize({ startOnLoad: false, theme: lastLight ? 'default' : 'dark' });
    for (const code of document.querySelectorAll('code.language-mermaid')) {
      const pre = code.parentElement;
      if (!pre || pre.tagName !== 'PRE' || pre.classList.contains('mermaid')) continue;
      const div = document.createElement('pre');
      div.className = 'mermaid';
      div.textContent = code.textContent;
      pre.replaceWith(div);
    }
    mermaid.run({ querySelector: '.mermaid' });
  }

  window.addEventListener('DOMContentLoaded', init);
  window.addEventListener('popstate', init);

  for (const t of dark) {
    const el = document.getElementById(t);
    if (el) el.addEventListener('click', () => { if (lastLight) location.reload(); });
  }
  for (const t of light) {
    const el = document.getElementById(t);
    if (el) el.addEventListener('click', () => { if (!lastLight) location.reload(); });
  }
})();