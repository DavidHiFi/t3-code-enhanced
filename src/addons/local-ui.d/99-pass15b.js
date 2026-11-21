// Brand corner: the app icon alone (2026-11-22, was the "T3 Code" words plus an "Enhanced" pill).
// Puts <img class="t3l-brand-icon"> inside a[aria-label="T3 Code home"]; the words stay in the
// markup for screen readers but are hidden by 99-mocha-pass56-brand-icon.css. The picture is
// self.T3ICON, set by local-app-icon.cjs from the App icon choice (riced or original), which
// calls window.__t3BrandIcon.refresh() when the choice changes. Re-runs when React remounts
// the header.
(() => {
	if (window.__t3BrandIcon) { window.__t3BrandIcon.refresh(); return; }
	const LINK = 'a[aria-label="T3 Code home"]';
	const MARK = 'data-t3l-enh';
	function once(link) {
		const src = self.T3ICON;
		if (!src) return;
		let img = link.querySelector('img.t3l-brand-icon');
		if (!img) {
			img = document.createElement('img');
			img.className = 't3l-brand-icon';
			img.alt = '';
			img.draggable = false;
			link.prepend(img);
		}
		if (img.getAttribute('src') !== src) img.src = src;
		link.querySelector('.t3l-enh')?.remove();
		link.setAttribute(MARK, 'on');
	}
	function scan(force) {
		document.querySelectorAll(LINK).forEach((a) => { if (force || a.getAttribute(MARK) !== 'on') once(a); });
	}
	const touches = (recs) => {
		for (const r of recs) for (const n of r.addedNodes)
			if (n.nodeType === 1 && (n.matches(LINK) || n.querySelector(LINK))) return true;
		return false;
	};
	let queued = false;
	new MutationObserver((recs) => {
		if (queued || !touches(recs)) return;
		queued = true;
		requestAnimationFrame(() => { queued = false; scan(); });
	}).observe(document.body, { childList: true, subtree: true });
	window.__t3BrandIcon = { refresh: () => scan(true) };
	scan(true);
})();
