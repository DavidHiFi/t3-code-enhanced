// Section shelves (pass 16 rewrite for build 0.1.8-nightly.20261106.4262).
// Fixes the owner-reported Drafts bug: the old script trusted the draft divider
// alone. When T3 drops that one marker (it does on some re-renders), every
// plain row in the list was classified as a draft - collapsing Drafts then
// hid the Active/Working rows too, the count showed every row in the list
// (46), and stale display:none kept rows hidden after expanding.
// Now: the Drafts section ends at the FIRST present marker of a fallback
// chain, Active is scoped the same way, and every sync clears stale inline
// display styles before re-applying, so a row can never stay stuck hidden.
// Style: li.t3l-shelf / .t3l-shelf-* in 90-mocha-pass6.css + 99-mocha-pass15-b.css
// + 99-mocha-pass16-fixes.css.
// Rollback: restore 90-section-shelves.js.bak-20261106-<stamp>, reload.
(() => {
	if (window.__t3localShelves) return;
	window.__t3localShelves = true;
	const KEY = 't3local:shelves:collapsed';
	const readCollapsed = () => { try { return JSON.parse(localStorage.getItem(KEY) || '{}') || {}; } catch { return {}; } };
	const LIST_SEL = '[data-slot="sidebar-container"] ul.relative.flex.flex-col.gap-px.flex-1';
	const MARKERS = [
		'li[data-testid="sidebar-draft-divider"]',
		'li[data-testid="sidebar-pinned-header"]',
		'li[data-testid="sidebar-pinned-divider"]',
		'li[data-testid="sidebar-active-placeholder"]',
		'li[data-testid="sidebar-working-header"]',
		'li[data-testid="sidebar-settled-header"]',
		'li[data-testid="sidebar-settled-placeholder"]',
	];
	const SECTIONS = [
		{ name: 'drafts', label: 'Drafts', end: MARKERS },
		{ name: 'pinned', label: 'Pinned', start: 'li[data-testid="sidebar-pinned-header"]', end: ['li[data-testid="sidebar-pinned-divider"]', 'li[data-testid="sidebar-active-placeholder"]', 'li[data-testid="sidebar-working-header"]', 'li[data-testid="sidebar-settled-header"]'] },
		{ name: 'active', label: 'Active', start: 'li[data-testid="sidebar-active-placeholder"]', end: ['li[data-testid="sidebar-working-header"]', 'li[data-testid="sidebar-settled-header"]'] },
	];
	const firstPresent = (ul, sels) => { for (const s of sels) { const m = ul.querySelector(`:scope > ${s}`); if (m) return m; } return null; };
	function rowsBefore(ul, endSels) {
		const out = [];
		for (const li of ul.children) {
			if (endSels.some(s => li.matches(s))) break;
			// 0.1.8 rows are plain li.list-none.py-0.5 with no data attributes
			if (li.matches('li:not(.t3l-shelf):not([data-testid])')) out.push(li);
		}
		return out;
	}
	function rowsBetween(ul, startSels, endSels) {
		const out = [];
		let on = false;
		for (const li of ul.children) {
			if (!on && startSels.some(s => li.matches(s))) { on = true; continue; }
			if (!on) continue;
			if (endSels.some(s => li.matches(s))) break;
			if (li.matches('li[data-thread-item]')) out.push(li);
		}
		return out;
	}
	const chevron = '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="t3l-shelf-chev" aria-hidden="true"><path d="m6 9 6 6 6-6"></path></svg>';
	function make(sec) {
		const li = document.createElement('li');
		li.className = 't3l-shelf list-none relative';
		li.setAttribute('role', 'presentation');
		li.dataset.t3lShelf = sec.name;
		li.innerHTML = `<button type="button" tabindex="-1" class="t3l-shelf-btn"><span class="t3l-shelf-label">${sec.label}</span><span class="t3l-shelf-fill"></span><span class="t3l-shelf-count"></span>${chevron}</button>`;
		li.firstChild.addEventListener('click', e => {
			e.preventDefault();
			e.stopPropagation();
			const c = readCollapsed();
			c[sec.name] = !c[sec.name];
			try { localStorage.setItem(KEY, JSON.stringify(c)); } catch {}
			sync();
		});
		return li;
	}
	let queued = false;
	function sync() {
		queued = false;
		const ul = document.querySelector(LIST_SEL);
		if (!ul) return;
		const collapsed = readCollapsed();
		const sectionRows = {};
		for (const sec of SECTIONS) sectionRows[sec.name] = sec.start ? rowsBetween(ul, [sec.start], sec.end) : rowsBefore(ul, sec.end);
		for (const sec of SECTIONS) {
			const rows = sectionRows[sec.name];
			let head = ul.querySelector(`:scope > li.t3l-shelf[data-t3l-shelf="${sec.name}"]`);
			// pass 30: Active keeps its header with a 0 count when every thread is working,
			// so the group never vanishes; it sits right after T3's active marker.
			const keep = sec.name === 'active' ? ul.querySelector(':scope > li[data-testid="sidebar-active-placeholder"]') : null;
			if (!rows.length && !keep) { if (head) head.remove(); continue; }
			if (!head) head = make(sec);
			if (rows.length) { if (head.nextElementSibling !== rows[0]) ul.insertBefore(head, rows[0]); }
			else if (head.previousElementSibling !== keep) keep.after(head);
			head.toggleAttribute('data-t3l-empty', !rows.length);
			const n = String(rows.length);
			const count = head.querySelector('.t3l-shelf-count');
			if (count.textContent !== n) count.textContent = n;
			const btn = head.firstChild;
			if (btn.getAttribute('aria-expanded') !== String(!collapsed[sec.name])) btn.setAttribute('aria-expanded', String(!collapsed[sec.name]));
			for (const li of rows) {
				const hide = !!collapsed[sec.name];
				if (hide && li.style.display !== 'none') li.style.display = 'none';
				if (!hide && li.style.display === 'none') li.style.display = '';
			}
		}
		// stale-style cleanup: a row that changed sections while its old group was
		// collapsed must never keep a stale display:none from the old classification
		for (const li of ul.children) {
			if (li.matches && li.matches('li:not(.t3l-shelf):not([data-testid])') && li.style.display === 'none') {
				const owned = SECTIONS.some(sec => sectionRows[sec.name].includes(li));
				if (!owned) li.style.removeProperty('display');
			}
		}
		// tight stack: a pill whose next visible section start is another pill touches it
		const PILL = 'li.t3l-shelf, li[data-testid="sidebar-working-header"], li[data-testid="sidebar-settled-header"]';
		for (const li of ul.children) {
			if (!li.matches(PILL)) continue;
			let n = li.nextElementSibling;
			while (n && n.offsetHeight === 0) n = n.nextElementSibling;
			const tight = !!n && n.matches(PILL);
			if (tight !== li.hasAttribute('data-t3l-tight')) li.toggleAttribute('data-t3l-tight', tight);
			const cur = li.style.getPropertyValue('margin-bottom');
			if (tight && cur !== '0px') li.style.setProperty('margin-bottom', '0', 'important');
			if (!tight && cur === '0px') li.style.removeProperty('margin-bottom');
		}
	}
	const schedule = () => { if (!queued) { queued = true; requestAnimationFrame(sync); } };
	new MutationObserver(muts => {
		// ignore mutations made by sync itself
		if (muts.every(m => [...m.addedNodes, ...m.removedNodes].every(n => n.classList?.contains('t3l-shelf')) && m.type === 'childList')) return;
		// pass 17 bound: only run when the threads list actually exists - one cheap
		// query instead of a full sync() for every mutation anywhere in the app
		const ul = document.querySelector(LIST_SEL);
		if (!ul) return;
		// v2 (2026-11-09, speed): only changes inside the threads list (or a list that just
		// mounted) matter; a streaming reply no longer re-runs the sidebar layout pass
		if (!muts.some(m => ul.contains(m.target) || [...m.addedNodes].some(n => n.contains && n.contains(ul)))) return;
		schedule();
	}).observe(document.body, { childList: true, subtree: true });
	schedule();
})();
