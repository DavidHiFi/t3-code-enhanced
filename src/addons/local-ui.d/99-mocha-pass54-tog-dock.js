// Pass 54 (2026-11-20): the sidebar toggle keeps T3's stock spot (fixed top-left) when the
// Threads sidebar is hidden, which leaves it floating above the header row with nothing to
// anchor to. 86-brand-dock.js only docks it while the sidebar is expanded; this measures the
// chat header row and writes the offset that centres the button on that row into
// --t3l-tog-dy; 99-mocha-pass54-status-pill.css applies it while html[data-t3l-tog-dock] is
// set, and gives the button the same chip look as the header buttons while undocked.
// Cheap on purpose: cached elements, one rAF-scheduled measure, an early exit while the
// sidebar is expanded (one getAttribute), no per-thread-list work.
(() => {
	if (window.__t3lTogDock) return;
	window.__t3lTogDock = true;
	const root = document.documentElement;
	const ATTR = 'data-t3l-tog-dock';
	const TOG_SEL = 'div.pointer-events-none.fixed[class*="left-[var(--workspace-controls-left)]"]';
	let dy = 0, queued = false, tog = null, hdr = null, sb = null;
	const live = (el) => el && el.isConnected;
	// touch the root only when the mark really changes: a root write restyles the whole page
	const off = () => { if (root.hasAttribute(ATTR)) root.removeAttribute(ATTR); };
	const on = () => { if (!root.hasAttribute(ATTR)) root.setAttribute(ATTR, ''); };
	const find = () => {
		if (!live(tog)) tog = document.querySelector(TOG_SEL);
		if (!live(hdr)) hdr = document.querySelector('header[data-chat-header]');
		if (!live(sb)) sb = document.querySelector('[data-slot="sidebar"][data-side="left"]');
	};
	const collapsed = () => live(sb) && sb.getAttribute('data-state') === 'collapsed';
	const measure = () => {
		queued = false;
		find();
		if (!collapsed()) { off(); return; }
		const btn = tog && (tog.querySelector('button') || tog);
		if (!live(hdr) || !btn || !btn.getBoundingClientRect().width) { off(); return; }
		const h = hdr.getBoundingClientRect(), b = btn.getBoundingClientRect();
		if (!h.height || !b.height) { off(); return; }
		const ny = Math.round(h.top + h.height / 2 - (b.top + b.height / 2));
		if (ny !== dy) { dy = ny; root.style.setProperty('--t3l-tog-dy', dy + 'px'); }
		on();
	};
	// settle twice like brand-dock: now-ish and after the sidebar's open/close animation
	const schedule = (settle) => {
		if (!queued) { queued = true; requestAnimationFrame(measure); }
		if (settle) setTimeout(measure, 380);
	};
	new MutationObserver(() => schedule(false)).observe(document.body, {
		attributes: true, attributeFilter: ['data-state'], childList: true, subtree: true,
	});
	window.addEventListener('resize', () => schedule(true));
	find();
	schedule(true);
})();
