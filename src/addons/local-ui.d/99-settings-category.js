(() => {
  const run = () => {
    const group = document.querySelector('[data-settings-section="/settings/labs"]')?.closest('[role="group"]');
    if (!group || group.querySelector('h3')) return;
    const reference = document.querySelector('[role="group"][aria-label="Connections"] > h3');
    if (!reference) return;
    const heading = reference.cloneNode(true);
    heading.textContent = 'System & Labs';
    group.setAttribute('aria-label', 'System & Labs');
    group.prepend(heading);
  };
  // 2026-11-21 (speed): only batches that add or remove a settings group or heading matter
  const SEL = '[data-settings-section], [role="group"], h3';
  const touches = (recs) => {
    for (const r of recs) for (const list of [r.addedNodes, r.removedNodes]) for (const n of list)
      if (n.nodeType === 1 && (n.matches(SEL) || n.querySelector(SEL))) return true;
    return false;
  };
  let pending = false;
  new MutationObserver((recs) => {
    if (pending || !touches(recs)) return;
    pending = true;
    requestAnimationFrame(() => { pending = false; run(); });
  }).observe(document.body, {childList:true, subtree:true});
  run();
})();
