// Brand dock (2026-11-02): T3 pins the sidebar collapse button fixed at the window's top-left, outside
// the brand row. This measures both and writes the offset that centres the button in the left end of
// the brand row into --t3l-tog-x / --t3l-tog-y; 86-mocha-glass.css applies it while
// html[data-t3l-brand-dock] is set.
// v2 (2026-11-09, speed): the attribute is now set only while the left sidebar is expanded (the CSS
// used a document-wide :has() for that, which made every DOM change restyle the whole page), the
// observer ignores changes outside the sidebar, and elements are cached instead of re-queried.
(() => {
	if (window.__t3localBrandDock) return;
	window.__t3localBrandDock = true;
	const root = document.documentElement;
	const ATTR = 'data-t3l-brand-dock';
	let dx = 0, dy = 0, measured = false, queued = false, sidebar = null, row = null, tog = null;
	const live = (el) => el && el.isConnected;
	const find = () => {
		if (!live(sidebar)) sidebar = document.querySelector('[data-slot="sidebar"][data-side="left"]');
		if (!live(row)) row = sidebar && sidebar.querySelector('div:has(> div > div > a[aria-label="T3 Code home"])');
		if (!live(tog)) tog = document.querySelector('div.pointer-events-none.fixed[class*="left-[var(--workspace-controls-left)]"]');
	};
	const expanded = () => live(sidebar) && sidebar.getAttribute('data-state') === 'expanded';
	const setOn = (on) => { if (on !== root.hasAttribute(ATTR)) on ? root.setAttribute(ATTR, '') : root.removeAttribute(ATTR); };
	const measure = () => {
		queued = false;
		find();
		if (!expanded()) return setOn(false);
		const btn = tog && (tog.querySelector('button') || tog);
		if (!live(row) || !btn) return;
		// the offset already applied, if the CSS is applying it now
		const ax = root.hasAttribute(ATTR) ? dx : 0, ay = root.hasAttribute(ATTR) ? dy : 0;
		const r = row.getBoundingClientRect(), b = btn.getBoundingClientRect();
		if (r.width < 60 || b.width === 0) return;
		const nx = Math.round(r.left + 24 - (b.left - ax + b.width / 2));
		const ny = Math.round(r.top + r.height / 2 - (b.top - ay + b.height / 2));
		if (nx !== dx || ny !== dy) {
			dx = nx; dy = ny;
			root.style.setProperty('--t3l-tog-x', dx + 'px');
			root.style.setProperty('--t3l-tog-y', dy + 'px');
		}
		measured = true;
		setOn(true);
	};
	// settle: once now-ish, once after the sidebar's open/close animation
	const schedule = (settle) => {
		if (!queued) { queued = true; requestAnimationFrame(measure); }
		if (settle) setTimeout(measure, 380);
	};
	new MutationObserver((records) => {
		let hit = false, settle = false;
		for (const rec of records) {
			if (rec.type === 'attributes') {
				if (rec.target !== sidebar) continue;
				// follow the open/closed state in the same frame, the way the old :has() rule did
				setOn(expanded() && measured);
				hit = settle = true;
			} else if (!live(sidebar) || !live(row) || !live(tog) || sidebar.contains(rec.target)) hit = true;
		}
		if (hit) schedule(settle);
	}).observe(document.body, { childList: true, subtree: true, attributes: true, attributeFilter: ['data-state'] });
	window.addEventListener('resize', () => schedule(true));
	find();
	schedule(true);
})();
