// Custom dock icons for project scripts (2026-11-10, pass 31e). Run by ~/.t3/local-main.cjs on each page load.
// What it fixes: the script Edit/Add dialog only offers T3's six icon names, and the script's own
// `icon` field must stay one of play|test|lint|configure|build|debug (any other value makes T3 drop
// every setting). This adds a "Dock icon" row under Name: glyph presets, Catppuccin colours, an SVG
// path box and "Use T3 icon". On save it writes localStorage['t3i'+scriptId] = 'path|fill'; the
// scripticons asar patch (v6, marker t3p13f) reads that key when it draws the dock icon. The script
// record itself is never touched. New scripts get their id the way T3 makes it (slug of the name,
// -2/-3 on a clash), computed from the dialog's own script list at save time.
// Rollback: delete this file and reload T3 (custom icons then fall back to T3's own).
(() => {
	if (window.__t3localP31eIcons) return;
	window.__t3localP31eIcons = true;

	const KEY = 't3i';
	const BUILTIN = ['halo', 'catp', 'clip', 'adgu', 'tail'];
	const GLYPHS = [
		['Sparkle', 'M12 2l2.4 7.6L22 12l-7.6 2.4L12 22l-2.4-7.6L2 12l7.6-2.4z'],
		['Cat', 'M4.5 2.5l5.2 2.9q2.3 1.6 4.6 0l5.2-2.9c.8 2.3.7 4.4-.2 6.3a7.8 7.8 0 1 1-14.6 0c-.9-1.9-.8-4-.2-6.3z'],
		['Server', 'M2 3h20v8H2zm3 3v2h2V6zM2 13h20v8H2zm3 3v2h2v-2z'],
		['Shield', 'M12 2 4 5v7c0 5 4 9 8 10 4-1 8-5 8-10V5z'],
		['Dots', 'M2 7.5h5v5H2zm7.5 0h5v5h-5zm7.5 0h5v5h-5zm-7.5 7.5h5v5h-5z'],
		['Star', 'M12 2l3 6.9 7.5.6-5.7 5 1.7 7.4L12 18l-6.5 3.9 1.7-7.4-5.7-5 7.5-.6z'],
		['Bolt', 'M13 2 4 14h7l-1 8 9-12h-7z'],
		['Heart', 'M12 21s-8-5.2-8-11a4.5 4.5 0 0 1 8-2.8A4.5 4.5 0 0 1 20 10c0 5.8-8 11-8 11z'],
		['Dot', 'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18z'],
	];
	const COLOURS = [
		['Blue', '#89b4fa'], ['Mauve', '#cba6f7'], ['Green', '#a6e3a1'], ['Yellow', '#f9e2af'], ['Peach', '#fab387'],
		['Red', '#f38ba8'], ['Teal', '#94e2d5'], ['Pink', '#f5c2e7'], ['Sky', '#89dceb'], ['Text', '#cdd6f4'],
	];
	const PATH_OK = /^[MmLlHhVvCcSsQqTtAaZz0-9.,\s-]{1,800}$/;
	const SVG = 'http://www.w3.org/2000/svg';

	const read = id => { try { return localStorage[KEY + id] || ''; } catch { return ''; } };
	const write = (id, v) => { try { if (v === null) localStorage.removeItem(KEY + id); else localStorage[KEY + id] = v; } catch {} };

	// T3's own id rule (keybindings chunk: slug of the name, max 24, then -2, -3 ... on a clash)
	const slug = name => {
		const t = name.trim().toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
		return t.length === 0 ? 'script' : t.length <= 24 ? t : t.slice(0, 24).replace(/-+$/g, '') || 'script';
	};
	const newId = (name, ids) => {
		const used = new Set(ids), r = slug(name);
		if (!used.has(r)) return r;
		for (let i = 2; i < 1e4; i++) {
			const e = `${r}-${i}`, t = e.length <= 24 ? e : `${r.slice(0, Math.max(1, 24 - String(i).length - 1))}-${i}`;
			if (!used.has(t)) return t;
		}
		return null;
	};

	// The dialog component's props (request + scripts), found by walking up from the Name input's fiber
	const dialogProps = el => {
		const k = Object.keys(el).find(x => x.startsWith('__reactFiber$'));
		for (let f = k && el[k], n = 0; f && n < 60; f = f.return, n++) {
			const p = f.memoizedProps;
			if (p && p.request && Array.isArray(p.scripts)) return p;
		}
		return null;
	};

	const icon = (d, fill, size) => {
		const s = document.createElementNS(SVG, 'svg');
		s.setAttribute('viewBox', '0 0 24 24');
		s.setAttribute('width', size); s.setAttribute('height', size);
		const p = document.createElementNS(SVG, 'path');
		p.setAttribute('d', d); p.setAttribute('fill', fill);
		s.appendChild(p);
		return s;
	};

	const style = document.createElement('style');
	style.id = 't3local-p31e-icons';
	style.textContent = `
[data-p31e-icon]{display:flex;flex-direction:column;gap:6px}
[data-p31e-icon] .p31e-label{font-size:.875rem;font-weight:500;display:flex;align-items:center;gap:8px}
[data-p31e-icon] .p31e-row{display:flex;flex-wrap:wrap;gap:4px}
[data-p31e-icon] button{display:inline-flex;align-items:center;justify-content:center;height:28px;min-width:28px;padding:0 6px;
 border-radius:6px;border:1px solid #45475a;background:#181825;color:#cdd6f4;font-size:.75rem;cursor:pointer}
[data-p31e-icon] button:hover{border-color:transparent;background:linear-gradient(#181825,#181825) padding-box,linear-gradient(135deg,#89b4fa,#cba6f7) border-box}
[data-p31e-icon] button[aria-pressed="true"]{border-color:#89b4fa;background:#1e1e2e}
[data-p31e-icon] .p31e-sw{width:20px;height:20px;border-radius:50%;display:block}
[data-p31e-icon] input{height:28px;flex:1;min-width:0;border-radius:6px;border:1px solid #45475a;background:#181825;color:#cdd6f4;padding:0 8px;font-size:.75rem}
[data-p31e-icon] input:focus{outline:none;border-color:#89b4fa}
[data-p31e-icon] input[aria-invalid="true"]{border-color:#f38ba8}
[data-p31e-icon] .p31e-preview{display:inline-flex;width:22px;height:22px;align-items:center;justify-content:center;border-radius:6px;border:1px solid #45475a;background:#11111b}
[data-p31e-icon] .p31e-hint{font-size:.75rem;color:#a6adc8}`;
	document.head.appendChild(style);

	function mount(nameInput) {
		const nameRow = nameInput.closest('.space-y-1\\.5');
		const form = nameInput.closest('form');
		if (!nameRow || !form || form.querySelector('[data-p31e-icon]')) return;
		const props = dialogProps(nameInput);
		if (!props) return;
		const editId = props.request.scriptId || null;
		const ids = props.scripts.map(s => s.id);
		const start = editId ? read(editId).split('|') : [];
		const st = { d: start[1] ? start[0] : '', fill: start[1] || COLOURS[0][1], t3: !start[1], touched: false };

		const box = document.createElement('div');
		box.dataset.p31eIcon = '';
		const label = document.createElement('div');
		label.className = 'p31e-label';
		const preview = document.createElement('span');
		preview.className = 'p31e-preview';
		label.append('Dock icon', preview);
		const glyphRow = document.createElement('div'); glyphRow.className = 'p31e-row';
		const colourRow = document.createElement('div'); colourRow.className = 'p31e-row';
		const pathRow = document.createElement('div'); pathRow.className = 'p31e-row';
		const pathIn = document.createElement('input');
		pathIn.type = 'text'; pathIn.placeholder = 'Custom SVG path (24 x 24), e.g. M4 4h16v16H4z';
		pathIn.spellcheck = false; pathIn.value = st.d;
		const t3Btn = document.createElement('button');
		t3Btn.type = 'button'; t3Btn.textContent = 'Use T3 icon';
		pathRow.append(pathIn, t3Btn);
		const hint = document.createElement('div');
		hint.className = 'p31e-hint';
		hint.textContent = 'Saved with the script. The T3 icon above stays as the fallback.';

		const sync = () => {
			preview.replaceChildren(st.t3 ? document.createTextNode('T3') : icon(st.d, st.fill, 16));
			if (st.t3) preview.style.fontSize = '9px';
			for (const b of glyphRow.children) b.setAttribute('aria-pressed', String(!st.t3 && b.dataset.d === st.d));
			for (const b of colourRow.children) b.setAttribute('aria-pressed', String(!st.t3 && b.dataset.fill === st.fill));
			t3Btn.setAttribute('aria-pressed', String(st.t3));
			pathIn.setAttribute('aria-invalid', String(!!pathIn.value && !PATH_OK.test(pathIn.value)));
		};
		for (const [name, d] of GLYPHS) {
			const b = document.createElement('button');
			b.type = 'button'; b.title = name; b.setAttribute('aria-label', name); b.dataset.d = d;
			b.appendChild(icon(d, '#cdd6f4', 14));
			b.addEventListener('click', () => { st.d = d; st.t3 = false; st.touched = true; pathIn.value = d; sync(); });
			glyphRow.appendChild(b);
		}
		for (const [name, fill] of COLOURS) {
			const b = document.createElement('button');
			b.type = 'button'; b.title = name; b.setAttribute('aria-label', name); b.dataset.fill = fill;
			const sw = document.createElement('span'); sw.className = 'p31e-sw'; sw.style.background = fill;
			b.appendChild(sw);
			b.addEventListener('click', () => { st.fill = fill; if (st.d) st.t3 = false; st.touched = true; sync(); });
			colourRow.appendChild(b);
		}
		pathIn.addEventListener('input', () => {
			const v = pathIn.value.trim();
			if (PATH_OK.test(v)) { st.d = v; st.t3 = false; st.touched = true; }
			sync();
		});
		t3Btn.addEventListener('click', () => { st.t3 = true; st.touched = true; sync(); });

		box.append(label, glyphRow, colourRow, pathRow, hint);
		nameRow.after(box);
		sync();

		let lastNewKey = null;
		form.addEventListener('submit', () => {
			if (!st.touched) return;
			const id = editId || newId(nameInput.value, ids);
			if (!id) return;
			if (lastNewKey && lastNewKey !== id) write(lastNewKey, null);
			if (!editId) lastNewKey = id;
			if (st.t3 || !st.d) write(id, BUILTIN.includes(id.slice(0, 4)) ? '|' : null);
			else write(id, `${st.d}|${st.fill}`);
		}, true);
	}

	let queued = false;
	const scan = () => {
		queued = false;
		for (const el of document.querySelectorAll('form input#script-name')) mount(el);
	};
	new MutationObserver(() => { if (!queued) { queued = true; requestAnimationFrame(scan); } })
		.observe(document.body, { childList: true, subtree: true });
	scan();
})();
