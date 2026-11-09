/* T3 Mocha rice, pass 15 worker C (2026-11-04); rewritten pass 17 (2026-11-06).
   Gives every dock with the standard 1px inset-edge signature a real
   backdrop-filter so the window acrylic shows through the Mocha tint.
   Pass 17 changes (global cleanup item 6):
   - no nested blur: an element inside an ancestor that already carries any
     backdrop-filter (stylesheet or injected) is skipped, so blur is applied
     once per dock, not to every nested descendant;
   - no perpetual polling: the old every-2.5s full-document scan is gone.
     Work happens on a debounced (800ms) mutation callback and on resize;
     after 12 consecutive no-op batches the hook idles until new elements
     actually appear (which resets it).
   Rollback: restore this file from .bak-20261106-2210 and reload.
   Notes: notes\2026-11-02-t3-mocha-docks.md pass 15. */
(() => {
  if (window.__t3lMaterialOn) return;
  window.__t3lMaterialOn = true;
  const BLUR = 'blur(20px) saturate(1.25)';
  const done = new WeakSet();
  const blurred = new WeakSet();
  let timer = null, quiet = 0;
  const apply = () => {
    let added = 0;
    const els = document.querySelectorAll('div, section, aside, header, footer, nav, span');
    for (const e of els) {
      if (done.has(e)) continue;
      const s = getComputedStyle(e);
      if ((s.backdropFilter || 'none') !== 'none') { blurred.add(e); done.add(e); continue; }
      const bs = s.boxShadow || '';
      // Chromium serializes the inset keyword last: "rgb(...) 0px 0px 0px 1px inset"
      const edge = /0px 0px 0px 1px/.test(bs) && /inset/.test(bs);
      // pass 22: the old workspace-topbar-height class-substring clause is gone -
      // it matched the fixed collapse wrapper (28x52 square blur box) and the
      // 1280x52 thread-top band (blurred the first message line). Only real
      // docks with the inset-edge signature get the material now, and never a
      // broad strip: skip anything wider than 70% of the viewport or very tall.
      const r = e.getBoundingClientRect();
      if (r.width > innerWidth * 0.7 || r.height > 220) { done.add(e); continue; }
      if (edge) {
        // never blur inside an already-blurred ancestor: document order processes
        // ancestors first, so the WeakSet is populated before descendants arrive
        let a = e.parentElement, nested = false;
        while (a) { if (blurred.has(a)) { nested = true; break; } a = a.parentElement; }
        if (!nested) {
          e.style.setProperty('backdrop-filter', BLUR, 'important');
          e.style.setProperty('-webkit-backdrop-filter', BLUR, 'important');
          blurred.add(e);
          added++;
        }
      }
      done.add(e);
    }
    return added;
  };
  const kick = () => {
    if (timer || quiet >= 12) return;
    timer = setTimeout(() => {
      timer = null;
      try { const n = apply(); quiet = n > 0 ? 0 : Math.min(quiet + 1, 12); } catch (_) {}
    }, 800);
  };
  new MutationObserver(kick).observe(document.documentElement, { childList: true, subtree: true });
  addEventListener('resize', () => { quiet = 0; kick(); }, { passive: true });
  kick();
})();
