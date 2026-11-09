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
  let pending = false;
  new MutationObserver(() => {
    if (pending) return;
    pending = true;
    requestAnimationFrame(() => { pending = false; run(); });
  }).observe(document.body, {childList:true, subtree:true});
  run();
})();
