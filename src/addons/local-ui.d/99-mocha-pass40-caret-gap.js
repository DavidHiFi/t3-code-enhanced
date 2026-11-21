// Pass 40 (2026-11-14): the message box cursor gets a little room from the text.
// Chromium draws its caret right on the letter edge and offers no setting to move it, so in the
// message box only this hides the native caret and draws a Mocha blue one in its place:
//   at the start of a line it sits GAP px left of the first letter (in the box padding),
//   anywhere else it sits GAP px right of the letter before it.
// It keeps the pass 39 soft fade, goes solid again on every move like the real caret, and hides
// when the box loses focus, a selection is made, or something covers the spot.
// The native caret is only hidden while this caret is actually drawn, so a failure falls back.
(() => {
	// Pass 42: settings search boxes get the same caret. Pass 49 (2026-11-17): the sidebar thread
	// search and every other "Search ..." box (project picker) too. Set before the guard, so running
	// this file again in a live window updates the list without a reload.
	window.__t3gcInputs = 'input[aria-label="Search settings"], input[aria-label="Search threads"], input[placeholder^="Search"]';
	if (window.__t3localCaretGap) return;
	window.__t3localCaretGap = true;
	const GAP = 2, WIDTH = 2, EDITOR = '[data-composer-rich-text]', ON = 't3gc-on';
	// One-line search boxes get a wider gap (owner, 2026-11-17: "too close"). The thread search has
	// no padding of its own, so its text moves right by the same amount to keep the cursor off the icon.
	const IGAP = 3;

	const style = document.createElement('style');
	style.textContent = `
${EDITOR}.${ON}, input.${ON} { caret-color: transparent !important; animation: none !important; }
html input[aria-label="Search threads"][data-slot="input"] { padding-left: ${IGAP + WIDTH}px !important; }
html [data-slot="combobox-popup"] div.relative[class*="border-b"][class*="pb-1.5"] input[placeholder^="Search"] { padding-left: 26px !important; }
@keyframes t3gc-fade { 0%, 18% { opacity: 1 } 50%, 68% { opacity: 0 } 100% { opacity: 1 } }
#t3gc-caret { position: fixed; z-index: 2147483000; pointer-events: none; display: none;
	width: ${WIDTH}px; border-radius: ${WIDTH / 2}px; background: rgb(137 180 250);
	animation: t3gc-fade 1.15s ease-in-out infinite; }`;
	document.head.appendChild(style);
	const caret = document.createElement('div');
	caret.id = 't3gc-caret';
	document.body.appendChild(caret);

	let lastEd = null, lastKey = '', queued = false;
	const hide = () => {
		caret.style.display = 'none';
		if (lastEd) lastEd.classList.remove(ON);
		lastEd = null; lastKey = '';
	};

	const charRect = (node, i) => {
		const r = document.createRange();
		r.setStart(node, i); r.setEnd(node, i + 1);
		const rs = r.getClientRects();
		return rs.length ? rs[rs.length - 1] : null;
	};
	// The visible character just before the caret inside the same paragraph, as a rect.
	const prevCharRect = (node, offset, block) => {
		if (node.nodeType === 3 && offset > 0) return charRect(node, offset - 1);
		const walk = document.createTreeWalker(block, NodeFilter.SHOW_TEXT);
		let last = null, t;
		const stop = node.nodeType === 3 ? node : (node.childNodes[offset] || null);
		while ((t = walk.nextNode())) {
			if (stop && (t === stop || (stop.compareDocumentPosition(t) & Node.DOCUMENT_POSITION_FOLLOWING))) break;
			if (!stop && !node.contains(t) && (node.compareDocumentPosition(t) & Node.DOCUMENT_POSITION_FOLLOWING)) break;
			if (t.data.length) last = t;
		}
		return last ? charRect(last, last.data.length - 1) : null;
	};

	// Plain one-line boxes (settings search): the caret spot comes from measuring the text before it.
	const canvas = document.createElement('canvas').getContext('2d');
	function updateInput(el) {
		if (el.selectionStart === null || el.selectionStart !== el.selectionEnd) return hide();
		const cs = getComputedStyle(el), r = el.getBoundingClientRect();
		canvas.font = `${cs.fontStyle} ${cs.fontWeight} ${cs.fontSize} ${cs.fontFamily}`;
		const v = el.value, at = el.selectionStart;
		const ls = parseFloat(cs.letterSpacing) || 0;
		const textX = r.left + parseFloat(cs.borderLeftWidth) + parseFloat(cs.paddingLeft) - el.scrollLeft;
		const x = textX + canvas.measureText(v.slice(0, at)).width + ls * at;
		const prevCh = at > 0 ? v[at - 1] : null, nextCh = at < v.length ? v[at] : null;
		// In a proportional font a space can be narrower than gap + caret, so next to a space the
		// caret centres in it instead of touching the letter on the far side.
		const sp = (ch) => Math.max(0, Math.min(IGAP, (canvas.measureText(ch).width + ls - WIDTH) / 2));
		const left = !prevCh ? x - IGAP - WIDTH
			: /\s/.test(prevCh) ? x - sp(prevCh) - WIDTH
			: nextCh && !/\s/.test(nextCh) ? x - WIDTH / 2
			: nextCh ? x + sp(nextCh)
			: x + IGAP;
		const fs = parseFloat(cs.fontSize) || 14;
		const h = Math.round(fs * 1.3);
		// Centre on the capital letters, not the whole font box (whose descender space pushed it low):
		// the text's font box sits centred in the box, so the baseline and cap height follow from it.
		const innerTop = r.top + parseFloat(cs.borderTopWidth) + parseFloat(cs.paddingTop);
		const innerH = r.height - parseFloat(cs.borderTopWidth) - parseFloat(cs.borderBottomWidth) - parseFloat(cs.paddingTop) - parseFloat(cs.paddingBottom);
		const m = canvas.measureText('H');
		const fA = m.fontBoundingBoxAscent, fD = m.fontBoundingBoxDescent, capA = m.actualBoundingBoxAscent;
		const top = fA > 0 && capA > 0
			// the last 1px is measured: drawn text sat 1px above this estimate (thread search, 2026-11-17)
			? innerTop + (innerH - fA - fD) / 2 + fA - capA / 2 - h / 2 - 1
			: innerTop + (innerH - h) / 2;
		// The box has no padding of its own (the field around it does), so clip to the field.
		let box = r;
		for (let a = el.parentElement, i = 0; a && i < 3 && box.width <= r.width + 1; a = a.parentElement, i++) box = a.getBoundingClientRect();
		if (left < box.left || left + WIDTH > box.right) return hide();
		const hit = document.elementFromPoint(left + WIDTH / 2, top + h / 2);
		if (hit && hit !== caret && hit !== el && !hit.contains(el)) return hide();
		draw(el, left, top, h);
	}
	function draw(el, left, top, h) {
		const key = `${Math.round(left * 4)}:${Math.round(top * 4)}:${Math.round(h * 4)}`;
		if (key !== lastKey) {
			caret.style.left = `${left}px`; caret.style.top = `${top}px`; caret.style.height = `${h}px`;
			caret.style.animation = 'none'; void caret.offsetWidth; caret.style.animation = '';
			lastKey = key;
		}
		caret.style.display = 'block';
		if (lastEd && lastEd !== el) lastEd.classList.remove(ON);
		el.classList.add(ON); lastEd = el;
	}

	function update() {
		queued = false;
		const act = document.activeElement;
		if (act && act.matches && act.matches(window.__t3gcInputs) && document.hasFocus()) return updateInput(act);
		const sel = getSelection();
		const ed = act && act.closest && act.closest(EDITOR);
		if (!ed || !document.hasFocus() || !sel.rangeCount || !sel.isCollapsed || !ed.contains(sel.focusNode)) return hide();
		const node = sel.focusNode, offset = sel.focusOffset;
		const range = sel.getRangeAt(0);
		let rect = null;
		const rs = range.getClientRects();
		if (rs.length) rect = rs[rs.length - 1];
		if (!rect || !rect.height) {
			// Empty paragraph or element position: use the line box of the child or the element.
			const el = node.nodeType === 1 ? (node.childNodes[offset] || node.childNodes[offset - 1] || node) : node.parentElement;
			const er = (el.nodeType === 1 ? el : el.parentElement).getBoundingClientRect();
			const cs = getComputedStyle(el.nodeType === 1 ? el : el.parentElement);
			const lh = parseFloat(cs.lineHeight) || er.height;
			rect = { left: er.left + (el === node ? parseFloat(cs.paddingLeft) || 0 : 0), top: er.top, height: Math.min(lh, er.height || lh) };
		}
		const block = (node.nodeType === 1 ? node : node.parentElement).closest('p, li, h1, h2, h3, h4, h5, h6, pre, blockquote') || ed;
		const prev = prevCharRect(node, offset, block);
		const lineStart = !prev || Math.abs((prev.top + prev.height / 2) - (rect.top + rect.height / 2)) > rect.height / 2;
		const prevCh = node.nodeType === 3 && offset > 0 ? node.data[offset - 1] : null;
		const nextCh = node.nodeType === 3 && offset < node.data.length ? node.data[offset] : null;
		const fs = parseFloat(getComputedStyle(block).fontSize) || 14;
		const h = Math.min(rect.height, Math.round(fs * 1.3));
		const top = rect.top + (rect.height - h) / 2;
		// Line start or after a space: sit before the next letter. Inside a word: centre on the
		// boundary. After the last letter: sit after it.
		const left = lineStart || (prevCh && /\s/.test(prevCh)) ? rect.left - GAP - WIDTH
			: nextCh && !/\s/.test(nextCh) ? rect.left - WIDTH / 2
			: (prev ? Math.max(prev.right, rect.left) : rect.left) + GAP;
		// Hide when the spot is scrolled out of the box or covered by a menu.
		const er = ed.getBoundingClientRect();
		const cx = Math.min(Math.max(left + WIDTH / 2, er.left + 1), er.right - 1), cy = top + h / 2;
		if (cy < er.top || cy > er.bottom) return hide();
		const hit = document.elementFromPoint(cx, cy);
		if (hit && hit !== caret && !ed.contains(hit) && !hit.contains(ed)) return hide();
		draw(ed, left, top, h);
	}
	const queue = () => { if (!queued) { queued = true; requestAnimationFrame(update); } };
	for (const ev of ['selectionchange', 'selectstart', 'focusin', 'focusout', 'input', 'keydown', 'keyup', 'pointerup', 'transitionend'])
		document.addEventListener(ev, queue, true);
	window.addEventListener('scroll', queue, { capture: true, passive: true });
	window.addEventListener('resize', queue);
	window.addEventListener('blur', queue);
	window.addEventListener('focus', queue);
	queue();
})();
