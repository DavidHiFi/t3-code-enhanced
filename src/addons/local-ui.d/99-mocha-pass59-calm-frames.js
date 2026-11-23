// Pass 59 (2026-11-23): every working spinner and breathing label steps on the same screen refresh.
// Each one starts when its row appears, so without this their steps fall on different refreshes
// and T3 still draws on most of them. Giving them one shared start time lines the steps up.
// The cursor keeps its own timing: it goes solid again on every move.
// Rollback: delete this file and 99-mocha-pass59-calm-frames.css, then reload T3.
(() => {
	if (window.__t3p59) return;
	window.__t3p59 = true;
	const SYNC = new Set(['p31h-spin', 't25-breathe']);
	// A new animation has no start time until its first frame (it is still pending when the
	// animationstart event fires), so wait for that, then move it.
	const line = (a) => {
		if (!SYNC.has(a.animationName) || a.startTime === 0) return;
		if (a.startTime === null) return void a.ready.then(() => line(a), () => {});
		a.startTime = 0;
	};
	document.addEventListener('animationstart', (e) => {
		if (!SYNC.has(e.animationName) || !e.target.getAnimations) return;
		for (const a of e.target.getAnimations()) line(a);
	}, true);
	// The first rows can start before this file runs, or while the page is still loading and drawing
	// nothing (no start event then), so catch those up a few times after load.
	const all = () => { for (const a of document.getAnimations()) line(a); };
	all();
	for (const ms of [3000, 10000, 30000]) setTimeout(all, ms);
})();
