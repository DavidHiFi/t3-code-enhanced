// Picker fit (2026-11-02, pass 10): model/agent picker names truncate with "..." because the
// panes are fixed width. 94-mocha-pass10.css widens the panes; this shrinks any label that
// still does not fit until it does (dynamic size-to-fit, owner ask). Re-runs when the
// virtualized list re-renders rows. Rollback: delete this file and reload.
(() => {
	if (window.__t3localPickerFit) return;
	window.__t3localPickerFit = true;
	const MIN_PX = 10;
	const fit = el => {
		el.style.fontSize = '';
		let size = parseFloat(getComputedStyle(el).fontSize) || 13;
		let guard = 24;
		while (el.scrollWidth > el.clientWidth + 0.5 && size > MIN_PX && guard-- > 0) {
			size = Math.round((size - 0.5) * 2) / 2;
			el.style.fontSize = size + 'px';
		}
	};
	const fitPopups = () => {
		for (const pop of document.querySelectorAll('[data-slot="popover-popup"]')) {
			if (!pop.querySelector('[data-model-picker-content]')) continue;
			for (const el of pop.querySelectorAll('[class*="truncate"], [class*="line-clamp"]')) fit(el);
		}
	};
	let t = 0;
	const schedule = () => { clearTimeout(t); t = setTimeout(fitPopups, 150); };
	new MutationObserver(schedule).observe(document.body, { childList: true, subtree: true });
	schedule();
})();
