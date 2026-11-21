// T3 Mocha rice, pass 15 worker A (2026-11-05); rewritten pass 20 (2026-11-07).
// Marks the frames of the latest run in each timeline with data-t15a-run
// (+ data-t15a-run-start / -end) so the CSS paints one outer dock around the
// whole run on the row's chat-content-lane.
//
// Pass 20 fix (build 0.1.8): data-timeline-root="true" moved onto each row's
// own .chat-content-lane, so the old per-lane grouping saw one frame per lane
// and gave every frame start+end. Frames are the paint unit; the timeline is
// .messages-timeline-scroll. Grouping now keys on that container (fallback:
// the frames' shared parent), never on the lanes.
//
// Pass 20 perf: no more 2.5 s full-DOM poll. One debounced MutationObserver
// on the document (childList only) drives re-marking; a 15 s backstop catches
// missed attribute-only changes. mark() itself is one bounded query.
//
// Rollback: delete this file (and 99-mocha-pass15a.css), reload.
(function () {
	if (window.__t15aRunMarker) return;
	window.__t15aRunMarker = true;

	// kinds that belong to a run's output; user messages, turn-folds and event
	// dividers are run boundaries (or their own docks)
	const RUN_KINDS = new Set([
		'work', 'work-live', 'work-toggle', 'thinking', 'working',
		'assistant-meta', 'proposed-plan', 'html-render', 'mcp-app',
		'worktree-setup',
		// 2026-11-14: images the agent viewed belong to its turn's dock
		'viewed-images',
		// pass 19, build .4275: assistant turns carry data-timeline-row-kind="message"
		// (role=assistant; kindOf maps user messages to 'user-message'), so the run
		// dock skipped every real assistant output row.
		'message',
		// 2026-11-10 (4:30 pm): a compaction line mid-run stays inside the run's one dock.
		'context-compaction',
	]);
	// 2026-11-10: making compaction a boundary split every run at the compaction line, so all
	// output above it lost the dock. It is now a status kind instead: a run of only the
	// "Compacting context" pill gets no dock, a run with real output keeps one dock through it.
	const BOUNDARY_KINDS = new Set(['turn-fold', 'attempt-fold', 'event']);
	// Pass 17 (owner steering): status-only rows ("Working for 4s", "Thinking",
	// a collapsed "Worked for" fold) are pure pills. A run made ONLY of them
	// gets NO outer dock - painting one produced the near-empty full-column
	// "ghost frames". When real content rows exist, every run frame is marked
	// so the container stays one continuous dock.
	const STATUS_KINDS = new Set(['working', 'thinking', 'work-toggle', 'context-compaction']);

	function kindOf(row) {
		const k = row.getAttribute && row.getAttribute('data-timeline-row-kind');
		if (!k) return null;
		if (k === 'message' && row.getAttribute('data-message-role') !== 'assistant') return 'user-message';
		return k;
	}

	function frameOf(row) {
		return row.closest('.messages-timeline-row-frame') || row.parentElement;
	}

	// the timeline a frame belongs to: the scroll container on every build seen
	// so far; the frame's parent as a fallback (old sibling shape)
	function timelineOf(frame) {
		return frame.closest('.messages-timeline-scroll') || frame.parentElement || document.body;
	}

	const ATTRS = ['data-t15a-run', 'data-t15a-run-start', 'data-t15a-run-end'];
	// v2 (2026-11-09, speed): attributes are written only when they change. The old code cleared and
	// re-set every mark on every pass, and each write restyled the timeline even when nothing moved.
	function setMarks(frame, want) {
		ATTRS.forEach((a, i) => {
			const on = !!want && want[i];
			if (on !== frame.hasAttribute(a)) on ? frame.setAttribute(a, '') : frame.removeAttribute(a);
		});
	}

	function mark() {
		// rows in document order; frames deduped per timeline, keeping order
		const rows = document.querySelectorAll('[data-timeline-row-kind]');
		const timelines = new Map(); // timeline el -> Map(frame -> kind)
		for (const row of rows) {
			const frame = frameOf(row);
			if (!frame) continue;
			const tl = timelineOf(frame);
			let g = timelines.get(tl);
			if (!g) { g = new Map(); timelines.set(tl, g); }
			if (!g.has(frame)) g.set(frame, kindOf(row));
		}
		const want = new Map(); // frame -> [run, start, end]
		segOf = new WeakMap();
		// 2026-11-14: every turn gets its own dock, not only the latest one. Finished turns used to lose
		// the marks, so each reply above the bottom fell back to its own separate box.
		for (const [, g] of timelines) {
			const frames = [...g.keys()];
			const segs = [[]];
			frames.forEach((frame, i) => {
				const k = g.get(frame);
				if (BOUNDARY_KINDS.has(k) || k === 'user-message') segs.push([]);
				else segs[segs.length - 1].push(i);
			});
			for (const seg of segs) {
				const idx = seg.filter((i) => RUN_KINDS.has(g.get(frames[i])));
				if (!idx.length || !idx.some((i) => !STATUS_KINDS.has(g.get(frames[i])))) continue;
				// pass34: a row of another kind between two run rows stays inside the dock
				const run = [];
				for (let i = idx[0]; i <= idx[idx.length - 1]; i++) run.push(frames[i]);
				run.forEach((f, i) => { want.set(f, [true, i === 0, i === run.length - 1]); segOf.set(f, run); });
			}
		}
		for (const frame of document.querySelectorAll('[data-t15a-run],[data-t15a-run-start],[data-t15a-run-end]')) {
			if (!want.has(frame)) setMarks(frame, null);
		}
		for (const [frame, w] of want) setMarks(frame, w);
		lit(lastOver);
	}

	// v2: while the pointer is over a frame of the latest run, the timeline carries data-t25-lit and
	// 99-mocha-pass25.css lights the whole run's frame. This was a :has(:hover) rule before, which
	// made Chromium restyle the page on every DOM change.
	let lastOver = null, litOn = null, segOf = new WeakMap();
	// 2026-11-14: lights only the hovered turn's frames (data-t25-lit on each frame), since every turn is a run now
	function lit(target) {
		const frame = target && target.isConnected && target.closest ? target.closest('.messages-timeline-row-frame[data-t15a-run]') : null;
		const run = frame ? segOf.get(frame) || null : null;
		if (run === litOn) return;
		if (litOn) litOn.forEach((f) => f.removeAttribute('data-t25-lit'));
		if (run) run.forEach((f) => f.setAttribute('data-t25-lit', ''));
		litOn = run;
	}
	document.addEventListener('pointerover', (e) => { lastOver = e.target; lit(lastOver); }, { passive: true });
	document.addEventListener('pointerout', (e) => { if (!e.relatedTarget) { lastOver = null; lit(null); } }, { passive: true });

	let scheduled = false;
	function schedule() {
		if (scheduled) return;
		scheduled = true;
		requestAnimationFrame(() => {
			scheduled = false;
			mark();
		});
	}

	// one document-level observer: new lanes/frames/remounts all land here.
	// childList only; attribute churn (spinners, streaming text) is covered by
	// the backstop, not per-keystroke work.
	// 2026-11-21 (speed): only batches that add or remove a timeline row, frame or timeline can move a
	// run, so words streaming into a reply no longer re-mark every frame on each chunk.
	const ROWISH = '[data-timeline-row-kind], .messages-timeline-row-frame, .messages-timeline-scroll';
	const touches = (recs) => {
		for (const r of recs) for (const list of [r.addedNodes, r.removedNodes]) for (const n of list)
			if (n.nodeType === 1 && (n.matches(ROWISH) || n.querySelector(ROWISH))) return true;
		return false;
	};
	const mo = new MutationObserver((recs) => { if (!scheduled && touches(recs)) schedule(); });
	function start() {
		mo.observe(document.body, { childList: true, subtree: true });
		setInterval(mark, 15000);
		mark();
	}
	if (document.body) start();
	else document.addEventListener('DOMContentLoaded', start, { once: true });
})();
