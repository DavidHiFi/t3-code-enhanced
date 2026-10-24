// T3 Code local UI add-on: version number on the sidebar header badge.
//
// Loaded by ~/.t3/local-main.cjs on every window load (config key "versionBadge", default on).
// The hook lives outside the install folder, so T3 updates never remove this file.
// The version placeholder below is replaced by the main process with app.getVersion().
//
// 1. The "Nightly" badge next to "T3 Code" gets "<version>" appended via a CSS ::after,
//    driven by one data attribute (React never sees a changed node).
// 2. The on/off switch lives in Settings > Appearance > Local add-ons (local-settings-ui.js).
//    The choice lives in localStorage "t3local.showVersion" ("0" = off, anything else = on).
(() => {
try {
	if (window.__t3LocalVersionBadge) window.__t3LocalVersionBadge.stop();
	const VERSION = __T3_VERSION__;
	const KEY = "t3local.showVersion";
	const ROW_ATTR = "data-t3local-version-row";
	const state = { badge: false, row: false, error: null };
	const enabled = () => localStorage.getItem(KEY) !== "0";

	const style = document.createElement("style");
	style.textContent =
		"[data-t3local-version]::after{content:' ' attr(data-t3local-version);opacity:.8;font-variant-numeric:tabular-nums}" +
		"[data-t3local-version]{max-width:100%;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}";
	document.documentElement.appendChild(style);

	const leaves = (text) =>
		[...document.querySelectorAll("span,div,p,h1,h2,h3,label")].filter((el) => el.children.length === 0 && el.textContent.trim() === text);

	function findBadge() {
		// the header badge sits in the top strip of the sidebar; the Update track select
		// and other "Nightly" words live lower on the page or inside controls
		return (
			leaves("Nightly").find(
				(el) => !el.closest("[role=combobox],[role=listbox],[role=option],[data-slot=select-trigger],[data-slot=select-item],button,[aria-label='Update track']") && el.getBoundingClientRect().top < 90,
			) || null
		);
	}

	function updateBadge() {
		const badge = findBadge();
		state.badge = !!badge;
		for (const old of document.querySelectorAll("[data-t3local-version]")) if (old !== badge || !enabled()) old.removeAttribute("data-t3local-version");
		if (badge && enabled()) badge.setAttribute("data-t3local-version", VERSION);
	}

	// React does not own the cloned row: the click handler flips the data-checked /
	// data-unchecked attributes itself.
	function ensureRow() {
		const existing = document.querySelector("[" + ROW_ATTR + "]");
		const anchor = leaves("Update track")[0];
		if (!anchor) {
			state.row = !!existing;
			return;
		}
		if (existing && existing.isConnected) {
			state.row = true;
			return;
		}
		// the row is the ancestor of the title that is a direct child of the card holding every row
		const probe = leaves("Version")[0] || leaves("t3 command")[0];
		let anchorRow = anchor;
		while (anchorRow.parentElement && !(probe ? anchorRow.parentElement.contains(probe) : false)) anchorRow = anchorRow.parentElement;
		if (!probe || !anchorRow.parentElement || anchorRow === document.body) return;
		// a stock toggle row: climb from its switch until the parent also holds another switch
		const switches = [...document.querySelectorAll("[role=switch]")].filter((el) => !el.closest("[" + ROW_ATTR + "]"));
		if (switches.length < 2) return;
		let source = switches[0];
		while (source.parentElement && !switches.some((el) => el !== switches[0] && source.parentElement.contains(el))) source = source.parentElement;
		const clone = source.cloneNode(true);
		clone.setAttribute(ROW_ATTR, "1");
		for (const el of clone.querySelectorAll("[id]")) el.removeAttribute("id");
		const sw = clone.querySelector("[role=switch]");
		if (!sw) return;
		const texts = [...clone.querySelectorAll("*")].filter((el) => el.children.length === 0 && el.textContent.trim() && !sw.contains(el));
		if (!texts.length) return;
		texts[0].textContent = "Show version in header badge";
		if (texts[1]) texts[1].textContent = "Adds the version number next to the Nightly label in the sidebar header.";
		for (const extra of texts.slice(2)) extra.remove();
		sw.setAttribute("aria-label", "Show version in header badge");
		const parts = [sw, ...sw.querySelectorAll("[data-slot=switch-thumb]")];
		const input = clone.querySelector("input");
		const sync = () => {
			const on = enabled();
			sw.setAttribute("aria-checked", on ? "true" : "false");
			for (const el of parts) {
				el.toggleAttribute("data-checked", on);
				el.toggleAttribute("data-unchecked", !on);
			}
			if (input) input.checked = on;
		};
		sync();
		clone.addEventListener("click", (event) => {
			if (!sw.contains(event.target) && !event.target.closest("label")) return;
			event.preventDefault();
			localStorage.setItem(KEY, enabled() ? "0" : "1");
			sync();
			updateBadge();
		});
		anchorRow.after(clone);
		state.row = true;
	}

	let queued = false;
	function run() {
		queued = false;
		try {
			updateBadge();
		} catch (error) {
			state.error = String(error && error.message ? error.message : error);
		}
	}
	const observer = new MutationObserver(() => {
		if (!queued) {
			queued = true;
			requestAnimationFrame(run);
		}
	});
	observer.observe(document.documentElement, { childList: true, subtree: true });
	run();

	window.__t3LocalVersionBadge = {
		state,
		version: VERSION,
		refresh: updateBadge,
		stop() {
			observer.disconnect();
			style.remove();
			for (const el of document.querySelectorAll("[data-t3local-version],[" + ROW_ATTR + "]")) el.hasAttribute(ROW_ATTR) ? el.remove() : el.removeAttribute("data-t3local-version");
		},
	};
} catch (error) {
	window.__t3LocalVersionBadgeError = String((error && error.stack) || error);
}
})();
