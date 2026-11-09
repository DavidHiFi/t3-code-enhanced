// Pass 15 worker B: brand button accent (2026-11-04).
// Adds a small "Enhanced" pill right after the "Code" word inside
// a[aria-label="T3 Code home"] (the "T3" is the logo svg, the word is a span).
// Idempotent via data-t3l-enh on the link; re-runs on mutations because React
// remounts the header. Style lives in 99-mocha-pass15-b.css (.t3l-enh).
(() => {
	if (window.__t3lEnh) return;
	window.__t3lEnh = true;
	const MARK = 'data-t3l-enh';
	function once(link) {
		if (link.querySelector('.t3l-enh')) { link.setAttribute(MARK, 'on'); return; }
		const code = [...link.querySelectorAll('span')].find(s => s.children.length === 0 && /^Code$/.test(s.textContent.trim()));
		const span = document.createElement('span');
		span.className = 't3l-enh';
		span.textContent = 'Enhanced';
		if (code) code.after(span); else link.appendChild(span);
		link.setAttribute(MARK, 'on');
	}
	function scan() {
		document.querySelectorAll('a[aria-label="T3 Code home"]').forEach(a => { if (a.getAttribute(MARK) !== 'on') once(a); });
	}
	let queued = false;
	new MutationObserver(() => {
		if (queued) return;
		queued = true;
		requestAnimationFrame(() => { queued = false; scan(); });
	}).observe(document.body, { childList: true, subtree: true });
	scan();
})();
