(() => {
    'use strict';

    const article = document.getElementById('timeline-content');

    // Citation IDs in the markdown look like `DA_Foo` or `DA_Foo_Bar_Baz`.
    // After marked.js renders inline backticks to <code>…</code>, we rewrite
    // every code span whose text matches a databank-entry ID into a deep-link
    // back to index.html#<id>. The hash handler in app.js then auto-expands
    // the ancestor categories and scrolls to the entry.
    //
    // We allow any [A-Za-z0-9_]+ tail after `DA_`, which covers both
    // single-segment IDs (`DA_Alterra`, `DA_Kharaa`) and multi-segment ones
    // (`DA_CoralGardens_BlackBox_Chap_02_DatabankEntry`). Patterns containing
    // other characters (`DA_*_AxumLogogram`) correctly fail to match because
    // the `*` is outside the allowed set.
    const ID_RE = /^DA_[A-Za-z0-9_]+$/;

    function linkifyCitations(root) {
        const codes = root.querySelectorAll('code');
        for (const code of codes) {
            const text = code.textContent;
            if (!ID_RE.test(text)) continue;
            const a = document.createElement('a');
            a.className = 'citation';
            a.href = 'index.html#' + encodeURIComponent(text);
            a.title = 'Open ' + text + ' in the lore search';
            // Wrap (not replace) so the <code> styling is preserved inside.
            code.parentNode.insertBefore(a, code);
            a.appendChild(code);
        }
    }

    function render(md) {
        marked.setOptions({
            gfm: true,
            breaks: false,
            headerIds: true,
            mangle: false,
        });
        const html = marked.parse(md);
        article.innerHTML = html;
        linkifyCitations(article);
    }

    fetch('timeline.md')
        .then(r => {
            if (!r.ok) throw new Error('HTTP ' + r.status);
            return r.text();
        })
        .then(render)
        .catch(err => {
            article.innerHTML =
                '<p class="loading">Failed to load timeline.md: ' +
                err.message + '. If you opened this file directly via file://, ' +
                'run a local server instead (e.g. <code>python -m http.server 8000 --directory docs</code>).</p>';
        });
})();
