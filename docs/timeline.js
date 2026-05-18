(() => {
    'use strict';

    const article = document.getElementById('timeline-content');

    // Citation IDs in the markdown look like `DA_Foo_Bar`. After marked.js
    // renders inline backticks to <code>…</code>, we rewrite every code span
    // whose text matches a databank-entry ID into a deep-link back to
    // index.html#<id>. The hash handler in app.js will then auto-expand the
    // ancestor categories and scroll to the entry.
    //
    // The pattern requires at least one underscore after the `DA_` prefix so
    // we don't link bare `DA_` fragments (e.g. inside `DA_*_AxumLogogram`
    // which marked leaves intact inside a code span — the asterisk breaks
    // the pattern and the whole token is correctly skipped).
    const ID_RE = /^DA_[A-Za-z0-9]+(?:_[A-Za-z0-9]+)+$/;

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
