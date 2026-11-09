/* T3 Mocha rice, pass 13: shadow-root docks + alert fill enforcer (2026-11-04).
   T3 renders the diff code view in a shadow root under <diffs-container> and the Changes file
   list under <file-tree-container>; light CSS cannot reach them. The t5 tokens on :root inherit
   through the boundary, so this add-on injects one small style per shadow root. It re-runs on a
   debounced MutationObserver because React remounts both elements on tab switches and virtualizer
   updates. It also pins the pinned API-error alert's fill inline: every stylesheet rule up to
   (0,4,1) important loses to an unknown T3 rule that keeps the alert at a 75% canvas glass, while
   an inline important background-color demonstrably wins (probed 2026-11-04, q125).
   Rollback: delete this file and reload.
   Notes: notes\2026-11-02-t3-mocha-docks.md */
(() => {
	if (window.__t3lDiffDocks) return;
	window.__t3lDiffDocks = true;
	const DIFF_CSS = `
		/* file header inside the code view (AGENTS.md  +9 -0): sticky over lines, so a 95% fill */
		[data-diffs-header] {
			background: var(--t5-solid) !important;
			box-shadow: inset 0 0 0 1px var(--t5-edge) !important;
			border-radius: 10px !important;
			transition: var(--t5-ease) !important;
		}
		[data-diffs-header]:hover {
			box-shadow: var(--t5-ring), var(--t5-glow) !important;
		}
		[data-diffs-header] [data-expand-button] {
			border-radius: 7px !important;
			transition: var(--t5-ease) !important;
		}
		[data-diffs-header] [data-expand-button]:hover {
			background-color: var(--t5-pill-hi) !important;
		}
		/* hunk separators ("47 unmodified lines" with the expand control) */
		:is([data-separator="line-info"], [data-separator="line-info-basic"]) {
			background: var(--t5-pill) !important;
			border-radius: 8px !important;
			box-shadow: inset 0 0 0 1px var(--t5-edge) !important;
			transition: var(--t5-ease) !important;
		}
		:is([data-separator="line-info"], [data-separator="line-info-basic"]):hover {
			box-shadow: var(--t5-ring), var(--t5-glow) !important;
		}
		:is([data-separator="line-info"], [data-separator="line-info-basic"]) [data-separator-content],
		:is([data-separator="line-info"], [data-separator="line-info-basic"]) [data-expand-button] {
			border-radius: 7px !important;
			transition: var(--t5-ease) !important;
		}
		:is([data-separator="line-info"], [data-separator="line-info-basic"]) [data-expand-button]:hover {
			background-color: var(--t5-pill-hi) !important;
			box-shadow: var(--t5-ring) !important;
		}
	`;
	const TREE_CSS = `
		/* Changes file rows: resting transparent, hover pill with blue edge; selected row keeps glow */
		button[data-type="item"] {
			border-radius: 8px !important;
			transition: var(--t5-ease) !important;
		}
		button[data-type="item"]:hover {
			background: var(--t5-pill-hi) !important;
			box-shadow: inset 0 0 0 1px var(--t5-edge) !important;
		}
		button[data-type="item"]:has([data-truncate-group-container]) [data-truncate-group-container] {
			border-radius: 5px !important;
		}
	`;
	const mark = (sr) => sr.querySelector('style[data-t3l-docks]');
	const inject = (sr, css) => {
		if (!sr || mark(sr)) return;
		const s = document.createElement('style');
		s.dataset.t3lDocks = '1';
		s.textContent = css;
		sr.appendChild(s);
	};
	const patch = (el) => {
		if (el.tagName === 'DIFFS-CONTAINER') inject(el.shadowRoot, DIFF_CSS);
		else if (el.tagName === 'FILE-TREE-CONTAINER') inject(el.shadowRoot, TREE_CSS);
	};
	const ALERT_SEL = 'div[data-slot="alert"][data-variant="error"]';
	const enforceAlerts = () => {
		document.querySelectorAll(ALERT_SEL).forEach((a) => {
			if (a.style.getPropertyValue('background-color') !== 'var(--t5-solid)') {
				a.style.setProperty('background-color', 'var(--t5-solid)', 'important');
			}
		});
	};
	/* Pass 14: "Background activity updated" rows are classless virtualized elements with no data
	   attributes (the label's own ancestors are not all DIVs), so no stylesheet selector can reach
	   them. Mark the row element so 98-mocha-pass14.css can dock it; re-marked after every remount.
	   Pass 17: the XPath runs against the timeline root only (it was a full-document scan on every
	   mutation batch), and the belt-and-braces 2.5s interval is gone - the debounced observer
	   covers remounts. */
	const BA_TEXT = 'Background activity updated';
	const frameLike = (el) => !el ? true : el.classList.contains('legend-list-content-container')
		|| el.classList.contains('messages-timeline-row-frame')
		|| el.hasAttribute('data-timeline-row-id');
	const markBaRows = () => {
		const root = document.querySelector('[data-timeline-root="true"]');
		if (!root) return;
		const snap = document.evaluate(
			`//text()[starts-with(normalize-space(.), "${BA_TEXT}")]`,
			root, null, XPathResult.UNORDERED_NODE_SNAPSHOT_TYPE, null
		);
		for (let i = 0; i < snap.snapshotLength; i++) {
			let el = snap.snapshotItem(i).parentElement;
			if (!el || !el.textContent.startsWith(BA_TEXT)) continue;
			let row = el;
			while (!frameLike(row.parentElement)) row = row.parentElement;
			row.setAttribute('data-t3l-ba-row', '1');
		}
	};
	const scan = () => {
		document.querySelectorAll('diffs-container,file-tree-container').forEach((el) => patch(el));
		enforceAlerts();
		markBaRows();
	};
	let queued = false, lastScan = 0;
	const schedule = () => {
		if (queued) return;
		queued = true;
		// v2 (2026-11-09, speed): next frame after a quiet spell (no flash on tab switches), at most
		// five scans a second while a reply streams
		const wait = Math.max(0, lastScan + 200 - performance.now());
		const run = () => { queued = false; lastScan = performance.now(); scan(); };
		wait ? setTimeout(() => requestAnimationFrame(run), wait) : requestAnimationFrame(run);
	};
	new MutationObserver(schedule).observe(document.documentElement, { childList: true, subtree: true });
	scan();
})();
