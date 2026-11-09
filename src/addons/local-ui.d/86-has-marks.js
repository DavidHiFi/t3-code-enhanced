// Marks (v2 speed fix, 2026-11-09): a few theme rules used to find their element with :has(),
// which makes Chromium re-check the whole page on every change and cost 60+ ms per streamed
// message. This marks those elements once instead, and the CSS keys on the marks:
//   data-t3l-pv    a div holding an image Preview button directly (image tiles, attachments)
//   data-t3l-pvz   the same, when that button is the zoomable kind (cursor-zoom-in)
//   data-t3l-live  the box holding T3's "live activity" label copy (.live-activity-focus)
// Only added nodes are looked at, and marks are dropped again once their child is gone.
(() => {
	if (window.__t3localHasMarks) return;
	window.__t3localHasMarks = true;
	const PREVIEW = 'button[aria-label^="Preview "]';
	const LIVE = '.live-activity-focus';
	const marked = new Set();
	const mark = (el, attr) => { if (!el.hasAttribute(attr)) el.setAttribute(attr, ''); marked.add(el); };
	function markButton(b) {
		const p = b.parentElement;
		if (!p || p.tagName !== 'DIV') return;
		mark(p, 'data-t3l-pv');
		if (b.classList.contains('cursor-zoom-in')) mark(p, 'data-t3l-pvz');
	}
	function markLive(el) {
		const p = el.parentElement;
		if (p && p.tagName === 'DIV') mark(p, 'data-t3l-live');
	}
	function scan(node) {
		if (node.nodeType !== 1) return;
		if (node.matches(PREVIEW)) markButton(node);
		else if (node.matches(LIVE)) markLive(node);
		if (!node.firstElementChild) return;
		for (const b of node.querySelectorAll(PREVIEW)) markButton(b);
		for (const l of node.getElementsByClassName('live-activity-focus')) markLive(l);
	}
	// a mark stays only while its element still has the child it was given for
	function prune() {
		for (const el of marked) {
			const kids = el.children;
			let pv = false, pvz = false, live = false;
			if (el.isConnected) for (const k of kids) {
				if (k.tagName === 'BUTTON' && k.matches(PREVIEW)) { pv = true; if (k.classList.contains('cursor-zoom-in')) pvz = true; }
				else if (k.classList.contains('live-activity-focus')) live = true;
			}
			if (!pv && el.hasAttribute('data-t3l-pv')) el.removeAttribute('data-t3l-pv');
			if (!pvz && el.hasAttribute('data-t3l-pvz')) el.removeAttribute('data-t3l-pvz');
			if (!live && el.hasAttribute('data-t3l-live')) el.removeAttribute('data-t3l-live');
			if (!pv && !live) marked.delete(el);
		}
	}
	let pending = [], removed = false, queued = false;
	function flush() {
		queued = false;
		const nodes = pending; pending = [];
		for (const n of nodes) if (n.isConnected) scan(n);
		if (removed) { removed = false; prune(); }
	}
	new MutationObserver((records) => {
		for (const r of records) {
			for (const n of r.addedNodes) if (n.nodeType === 1) pending.push(n);
			if (r.removedNodes.length && marked.size) removed = true;
		}
		if ((pending.length || removed) && !queued) { queued = true; requestAnimationFrame(flush); }
	}).observe(document.body, { childList: true, subtree: true });
	scan(document.body);
})();
