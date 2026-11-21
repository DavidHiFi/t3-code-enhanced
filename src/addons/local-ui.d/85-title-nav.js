// Back/forward arrows inside the chat title dock (2026-11-02). Run by ~/.t3/local-main.cjs on each page load.
// T3 renders the pair next to "T3 Code" in the sidebar header. This adds two proxy buttons as the first
// crumb of the title breadcrumb; a click forwards to the stock button, so T3's own history logic runs.
// The stock pair is hidden by 85-mocha-docks.css while html[data-t3local-titlenav-on] is set.
// Rollback: delete this file and reload the window.
(() => {
  if (window.__t3localTitleNav) return;
  window.__t3localTitleNav = true;

  const NAV = 'nav[aria-label$="breadcrumb"] > ol';
  const stock = (label) => document.querySelector(`button[aria-label="${label}"]:not([data-t3local-proxy])`);

  function proxy(label) {
    const b = document.createElement("button");
    b.type = "button";
    b.setAttribute("aria-label", label);
    b.setAttribute("title", label);
    b.dataset.t3localProxy = "";
    b.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      stock(label)?.click();
    });
    return b;
  }

  function sync(li) {
    for (const b of li.querySelectorAll("button")) {
      const s = stock(b.getAttribute("aria-label"));
      const off = !s || s.disabled || s.getAttribute("aria-disabled") === "true";
      if (b.disabled !== off) b.disabled = off;
      if (s && !b.firstChild) {
        const svg = s.querySelector("svg");
        if (svg) b.append(svg.cloneNode(true));
      }
    }
  }

  function tick() {
    const ol = document.querySelector(NAV);
    const haveStock = !!stock("Go back");
    document.documentElement.toggleAttribute("data-t3local-titlenav-on", !!ol && haveStock);
    if (!ol || !haveStock) return;
    let li = ol.querySelector(":scope > [data-t3local-titlenav]");
    if (!li) {
      document.querySelectorAll("[data-t3local-titlenav]").forEach((n) => n.remove());
      li = document.createElement("li");
      li.dataset.t3localTitlenav = "";
      li.append(proxy("Go back"), proxy("Go forward"));
      ol.prepend(li);
    } else if (ol.firstElementChild !== li) {
      ol.prepend(li);
    }
    sync(li);
  }

  // 2026-11-21 (speed): skip batches that cannot touch the arrows (streamed reply text)
  const NAVISH = "button, nav, ol, li, svg";
  const touches = (recs) => {
    for (const r of recs) {
      if (r.type === "attributes") return true;
      for (const list of [r.addedNodes, r.removedNodes]) for (const n of list)
        if (n.nodeType === 1 && (n.matches(NAVISH) || n.querySelector(NAVISH))) return true;
    }
    return false;
  };
  let queued = false;
  new MutationObserver((recs) => {
    if (queued || !touches(recs)) return;
    queued = true;
    requestAnimationFrame(() => {
      queued = false;
      tick();
    });
  }).observe(document.documentElement, {
    subtree: true,
    childList: true,
    attributes: true,
    attributeFilter: ["disabled", "aria-disabled"],
  });
  tick();
})();
