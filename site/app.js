(() => {
    'use strict';

    const els = {
        search:       document.getElementById('search'),
        expandAll:    document.getElementById('expand-all'),
        collapseAll:  document.getElementById('collapse-all'),
        tree:         document.getElementById('tree'),
        empty:        document.getElementById('empty'),
        count:        document.getElementById('result-count'),
        meta:         document.getElementById('meta'),
    };

    let data = null;
    let mini = null;
    let tree = null;                  // Root tree node
    const expandedNodes  = new Set(); // Category paths currently expanded
    const expandedEntries = new Set();// Entry IDs currently expanded inline

    // ---------- utils ----------

    function escapeHtml(s) {
        return String(s).replace(/[&<>"']/g, c => ({
            '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
        })[c]);
    }

    function highlight(text, terms) {
        if (!terms || !terms.length) return escapeHtml(text);
        const escaped = escapeHtml(text);
        const pattern = terms
            .filter(t => t && t.length > 1)
            .map(t => t.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'))
            .sort((a, b) => b.length - a.length)  // longer phrases first
            .join('|');
        if (!pattern) return escaped;
        return escaped.replace(new RegExp(`(${pattern})`, 'gi'), '<mark>$1</mark>');
    }

    // Splits a raw query into quoted phrases (exact substring) and bare words
    // (fuzzy AND-matched). E.g. `"sync biobed" angel` -> phrases: ["sync
    // biobed"], words: ["angel"].
    function parseQuery(raw) {
        const phrases = [];
        const cleaned = raw.replace(/"([^"]+)"/g, (_, p) => {
            phrases.push(p);
            return ' ';
        });
        const words = cleaned.split(/\s+/).filter(Boolean);
        return { phrases, words };
    }

    function activeTerms() {
        const { phrases, words } = parseQuery(els.search.value.trim());
        return phrases.concat(words);
    }

    // ---------- tree construction ----------

    // Build a tree from entries. Each entry's `categories` is an ordered path
    // from root to leaf. Some entries are "header entries" whose title matches
    // the last category in their path — they describe their parent node.
    function buildTree(entries) {
        const root = makeNode('');
        for (const entry of entries) {
            const cats = entry.categories || [];
            let node = root;
            for (const cat of cats) {
                let child = node.children.get(cat);
                if (!child) {
                    child = makeNode(cat, node.path);
                    node.children.set(cat, child);
                }
                node = child;
            }
            const last = cats.length ? cats[cats.length - 1] : null;
            if (last && entry.title === last && !node.header) {
                node.header = entry;
            } else {
                node.entries.push(entry);
            }
        }
        sortTree(root);
        return root;
    }

    function makeNode(name, parentPath) {
        const path = name
            ? (parentPath ? parentPath + ' / ' + name : name)
            : '';
        return {
            name,
            path,
            children: new Map(),
            entries: [],
            header: null,    // optional describing entry for this category
        };
    }

    function sortTree(node) {
        node.children = new Map(
            Array.from(node.children.entries())
                .sort((a, b) => a[0].localeCompare(b[0], undefined, { sensitivity: 'base' }))
        );
        node.entries.sort((a, b) =>
            a.title.localeCompare(b.title, undefined, { sensitivity: 'base' })
        );
        for (const child of node.children.values()) sortTree(child);
    }

    // Count how many entries (including header entries) live at or under a node.
    function countEntries(node) {
        let n = node.entries.length + (node.header ? 1 : 0);
        for (const child of node.children.values()) n += countEntries(child);
        return n;
    }

    // ---------- search / visibility ----------

    function visibleEntryIds(query) {
        // Returns a Set of entry IDs matching the current search. When query
        // is empty, returns null meaning "no filter — show everything".
        //
        // Quoted phrases match as case-insensitive substrings across title,
        // body, and categories. Unquoted words go through MiniSearch with
        // OR combination + fuzzy + prefix, so each word independently widens
        // the result set. When both are present, phrase matches narrow the
        // word results.
        if (!query) return null;
        const { phrases, words } = parseQuery(query);
        if (!phrases.length && !words.length) return null;

        let candidates;
        if (words.length) {
            const hits = mini.search(words.join(' '), {
                prefix: true,
                fuzzy: 0.2,
            });
            candidates = new Set(hits.map(h => h.id));
        } else {
            // Phrase-only query — start with everything and filter below.
            candidates = new Set(data.entries.map(e => e.id));
        }

        if (phrases.length) {
            const lowerPhrases = phrases.map(p => p.toLowerCase());
            const filtered = new Set();
            for (const id of candidates) {
                const e = data.entriesById.get(id);
                if (!e) continue;
                const haystack = (
                    e.title + ' ' +
                    (e.body || '') + ' ' +
                    (e.categories || []).join(' ')
                ).toLowerCase();
                if (lowerPhrases.every(p => haystack.includes(p))) {
                    filtered.add(id);
                }
            }
            candidates = filtered;
        }

        return candidates;
    }

    // Walk the tree and mark which nodes have at least one visible entry
    // (including header entries) so we can hide empty branches.
    function computeVisibleNodes(node, visibleIds) {
        let visibleCount = 0;
        if (node.header && (!visibleIds || visibleIds.has(node.header.id))) {
            visibleCount++;
        }
        for (const entry of node.entries) {
            if (!visibleIds || visibleIds.has(entry.id)) visibleCount++;
        }
        for (const child of node.children.values()) {
            visibleCount += computeVisibleNodes(child, visibleIds);
        }
        node._visibleCount = visibleCount;
        return visibleCount;
    }

    // ---------- rendering ----------

    function chevron(open) {
        const span = document.createElement('span');
        span.className = 'chevron';
        span.textContent = open ? '▾' : '▸';
        return span;
    }

    function renderEntryDetail(entry, terms) {
        // The collapsible body of an entry leaf — image, body, metadata.
        const wrap = document.createElement('div');
        wrap.className = 'entry-detail';

        if (entry.image_url) {
            const img = document.createElement('img');
            img.className = 'entry-image';
            img.src = entry.image_url;
            img.alt = entry.title;
            img.loading = 'lazy';
            img.addEventListener('error', () => img.remove());
            wrap.appendChild(img);
        }

        const body = document.createElement('div');
        body.className = 'entry-body';
        body.innerHTML = highlight(entry.body || '(no body)', terms);
        wrap.appendChild(body);

        const meta = document.createElement('div');
        meta.className = 'entry-meta';
        const breadcrumb = (entry.categories || []).join(' › ') || '(uncategorized)';
        meta.innerHTML =
            `<span class="entry-breadcrumb">${escapeHtml(breadcrumb)}</span>` +
            `<span class="entry-id">${escapeHtml(entry.id)}</span>`;
        wrap.appendChild(meta);

        return wrap;
    }

    function renderEntryLeaf(entry, terms, visibleIds) {
        if (visibleIds && !visibleIds.has(entry.id)) return null;
        const li = document.createElement('li');
        li.className = 'tree-leaf';
        li.id = `entry-${entry.id}`;

        const header = document.createElement('button');
        header.type = 'button';
        header.className = 'leaf-header';
        header.appendChild(chevron(expandedEntries.has(entry.id)));

        const titleSpan = document.createElement('span');
        titleSpan.className = 'leaf-title';
        titleSpan.innerHTML = highlight(entry.title, terms);
        header.appendChild(titleSpan);

        header.addEventListener('click', () => {
            if (expandedEntries.has(entry.id)) {
                expandedEntries.delete(entry.id);
            } else {
                expandedEntries.add(entry.id);
            }
            render();
        });
        li.appendChild(header);

        if (expandedEntries.has(entry.id)) {
            li.appendChild(renderEntryDetail(entry, terms));
        }
        return li;
    }

    function renderCategoryNode(node, terms, visibleIds, autoExpand) {
        if (visibleIds && node._visibleCount === 0) return null;

        const li = document.createElement('li');
        li.className = 'tree-category';

        const isOpen = autoExpand || expandedNodes.has(node.path);
        if (isOpen) li.classList.add('open');

        const header = document.createElement('button');
        header.type = 'button';
        header.className = 'category-header';
        header.appendChild(chevron(isOpen));

        const nameSpan = document.createElement('span');
        nameSpan.className = 'category-name';
        nameSpan.innerHTML = highlight(node.name, terms);
        header.appendChild(nameSpan);

        const count = document.createElement('span');
        count.className = 'category-count';
        count.textContent = visibleIds
            ? `${node._visibleCount}`
            : `${countEntries(node)}`;
        header.appendChild(count);

        header.addEventListener('click', () => {
            if (expandedNodes.has(node.path)) {
                expandedNodes.delete(node.path);
            } else {
                expandedNodes.add(node.path);
            }
            render();
        });
        li.appendChild(header);

        if (isOpen) {
            const ul = document.createElement('ul');
            ul.className = 'tree-children';

            if (node.header && (!visibleIds || visibleIds.has(node.header.id))) {
                // The category's own descriptive entry, shown first.
                const headerLeaf = renderEntryLeaf(node.header, terms, visibleIds);
                if (headerLeaf) {
                    headerLeaf.classList.add('is-category-header');
                    ul.appendChild(headerLeaf);
                }
            }
            for (const child of node.children.values()) {
                const childEl = renderCategoryNode(child, terms, visibleIds, autoExpand);
                if (childEl) ul.appendChild(childEl);
            }
            for (const entry of node.entries) {
                const leaf = renderEntryLeaf(entry, terms, visibleIds);
                if (leaf) ul.appendChild(leaf);
            }
            li.appendChild(ul);
        }
        return li;
    }

    function render() {
        const query = els.search.value.trim();
        const terms = activeTerms();
        const visibleIds = visibleEntryIds(query);
        const autoExpand = query.length > 0;  // Search auto-expands matched branches.

        computeVisibleNodes(tree, visibleIds);

        els.tree.innerHTML = '';
        const frag = document.createDocumentFragment();
        for (const child of tree.children.values()) {
            const el = renderCategoryNode(child, terms, visibleIds, autoExpand);
            if (el) frag.appendChild(el);
        }
        // Top-level uncategorized entries (no categories array).
        for (const entry of tree.entries) {
            const leaf = renderEntryLeaf(entry, terms, visibleIds);
            if (leaf) frag.appendChild(leaf);
        }
        els.tree.appendChild(frag);

        const totalEntries = data.entries.length;
        const shownCount = visibleIds ? visibleIds.size : totalEntries;
        els.empty.hidden = shownCount > 0;
        els.count.textContent = visibleIds
            ? `${shownCount} of ${totalEntries} entries`
            : `${shownCount} entries`;
    }

    // ---------- expand/collapse all + deep linking ----------

    function allCategoryPaths(node, acc) {
        if (node.name) acc.add(node.path);
        for (const child of node.children.values()) allCategoryPaths(child, acc);
        return acc;
    }

    function expandAll() {
        allCategoryPaths(tree, expandedNodes);
        render();
    }
    function collapseAll() {
        expandedNodes.clear();
        expandedEntries.clear();
        render();
    }

    function applyHash() {
        const hash = decodeURIComponent(window.location.hash.replace(/^#/, ''));
        if (!hash) return;
        const entry = data.entriesById.get(hash);
        if (!entry) return;
        // Expand all ancestor categories so the target becomes visible.
        const cats = entry.categories || [];
        let path = '';
        for (const c of cats) {
            path = path ? path + ' / ' + c : c;
            expandedNodes.add(path);
        }
        expandedEntries.add(entry.id);
        render();
        requestAnimationFrame(() => {
            const target = document.getElementById(`entry-${entry.id}`);
            if (target) target.scrollIntoView({ behavior: 'smooth', block: 'center' });
        });
    }

    // ---------- init ----------

    function init(payload) {
        data = payload;
        data.entriesById = new Map(data.entries.map(e => [e.id, e]));

        const meta = [
            `${data.total} entries`,
            data.game_build ? `Build ${data.game_build}` : null,
            data.generated_at ? `Generated ${data.generated_at.slice(0, 10)}` : null,
        ].filter(Boolean).join(' · ');
        els.meta.textContent = meta;

        mini = new MiniSearch({
            fields: ['title', 'body', 'categories'],
            storeFields: ['id'],
            searchOptions: {
                boost: { title: 4, categories: 2 },
                prefix: true,
                fuzzy: 0.2,
            },
            extractField: (doc, field) => {
                const v = doc[field];
                if (Array.isArray(v)) return v.join(' ');
                return v == null ? '' : String(v);
            },
        });
        mini.addAll(data.entries);

        tree = buildTree(data.entries);

        els.search.addEventListener('input', render);
        els.expandAll.addEventListener('click', expandAll);
        els.collapseAll.addEventListener('click', collapseAll);
        window.addEventListener('hashchange', applyHash);

        render();
        applyHash();
    }

    let fetchSucceeded = false;
    fetch('databank.json')
        .then(r => {
            if (!r.ok) throw new Error(`HTTP ${r.status}`);
            fetchSucceeded = true;
            return r.json();
        })
        .then(init)
        .catch(err => {
            if (!fetchSucceeded) {
                els.meta.textContent =
                    `Failed to load databank.json: ${err.message}. ` +
                    `If you're opening index.html directly via file://, ` +
                    `run a local server instead (e.g. \`python -m http.server 8000 --directory site\`).`;
            } else {
                console.error(err);
                els.meta.textContent =
                    `Error initialising site after loading databank.json: ${err.message}. ` +
                    `See browser console for details.`;
            }
        });
})();
