// T3 Code local UI add-on: a "Local add-ons" card in Settings > Appearance.
//
// Loaded by ~/.t3/local-main.cjs on every window load. A "Web page theme" dropdown, then one switch per local tweak:
//   - page-side tweaks (extended window glass, version badge, header galaxy, send-button galaxy, stronger highlights) live in
//     localStorage "t3local.<id>" ("0" = off) and mirror to <html data-t3local-<id>="off"> for the CSS
//   - main-process tweaks (glass menus, native title bar) are written to ~/.t3/local-patches.json by
//     local-main.cjs, which listens for console messages that start with "T3LOCAL:"
// The section is a clone of the stock "Interface" section, so rows match the app's own switches.
// The config placeholder below is replaced by the main process with the parsed local-patches.json.
(() => {
try {
	if (window.__t3LocalSettings) window.__t3LocalSettings.stop();
	const CONFIG = __T3_CONFIG__;
	const SECTION_ATTR = "data-t3local-settings";
	const INLINE_ATTR = "data-t3local-glassrow";
	const state = { section: false, error: null };

	const ROWS = [
		{ id: "versionBadge", key: "t3local.showVersion", title: "Version in header badge", desc: "Shows the app version next to the Nightly label in the sidebar header." },
		{ id: "galaxyHeader", key: "t3local.galaxyHeader", title: "Galaxy in the sidebar header", desc: "The star-field artwork behind the T3 Code title at the top left." },
		{ id: "galaxySend", key: "t3local.galaxySend", title: "Galaxy on the send button", desc: "The star-field artwork inside the round send button of the message box." },
		{ id: "contrast", key: "t3local.contrast", title: "Stronger highlights", desc: "Clearer selected rows in lists and menus, and visible edges on panels, in Catppuccin Mocha tones." },
		{ id: "extendedGlass", key: "t3local.extendedGlass", inline: true, title: "Extend glass across the whole window", desc: "Lets the blur show through the chat area and sidebar as well as menus. Off keeps glass to menus, dialogs, and the message box." },
		{ id: "glassMenus", config: "glassMenus", def: true, title: "Frosted glass right-click menus", desc: "Draws right-click menus as blurred glass panels. Applies after a reload (Ctrl+R)." },
		{ id: "nativeTitleBar", config: "nativeTitleBar", def: false, title: "Native Windows title bar", desc: "Uses the Windows title bar instead of T3's own drawn one. Applies after you restart T3 Code." },
	];

	const read = (row) => (row.config ? (CONFIG[row.config] === undefined ? row.def : CONFIG[row.config] !== false && CONFIG[row.config] !== 0) : localStorage.getItem(row.key) !== "0");
	function mirror() {
		for (const row of ROWS) if (!row.config) document.documentElement.toggleAttribute("data-t3local-" + row.id + "-off", !read(row));
	}
	function write(row, on) {
		if (row.config) {
			CONFIG[row.config] = on;
			console.log("T3LOCAL:" + JSON.stringify({ key: row.config, value: on }));
		} else {
			localStorage.setItem(row.key, on ? "1" : "0");
			mirror();
			if (row.id === "versionBadge" && window.__t3LocalVersionBadge && window.__t3LocalVersionBadge.refresh) window.__t3LocalVersionBadge.refresh();
		}
	}
	mirror();

	function build() {
		const interfaceSection = [...document.querySelectorAll("section")].find((s) => {
			const h = s.querySelector("h2");
			return h && h.textContent.trim() === "Interface";
		});
		if (!interfaceSection) return null;
		const card = interfaceSection.querySelector("[role=switch]") && interfaceSection.querySelector("[role=switch]").closest("div[class*='rounded-xl border']");
		if (!card) return null;
		const template = [...card.children].find((c) => c.querySelector("[role=switch]"));
		if (!template) return null;

		const section = interfaceSection.cloneNode(true);
		section.setAttribute(SECTION_ATTR, "1");
		for (const el of section.querySelectorAll("[id]")) el.removeAttribute("id");
		const head = section.children[0];
		head.querySelector("h2").textContent = "Local add-ons";
		head.removeAttribute("data-settings-scroll-target");
		while (head.children.length > 1) head.lastElementChild.remove();
		const newCard = section.querySelector("div[class*='rounded-xl border']");
		while (newCard.firstChild) newCard.firstChild.remove();

		const pageTheme = makeSelectRow(template);
		if (!pageTheme) return null;
		newCard.appendChild(pageTheme);
		for (const row of ROWS.filter((r) => !r.inline)) {
			const el = makeRow(template, row);
			if (!el) return null;
			newCard.appendChild(el);
		}
		interfaceSection.after(section);
		return section;
	}

	function makeRow(template, row) {
		const el = template.cloneNode(true);
		el.removeAttribute(INLINE_ATTR);
		for (const n of el.querySelectorAll("[id]")) n.removeAttribute("id");
		const sw = el.querySelector("[role=switch]");
		const title = el.querySelector("h3");
		const desc = el.querySelector("p");
		if (!sw || !title || !desc) return null;
		title.textContent = row.title;
		desc.textContent = row.desc;
		for (const extra of [...title.parentElement.children].slice(1)) extra.remove();
		sw.setAttribute("aria-label", row.title);
		const parts = [sw, ...sw.querySelectorAll("[data-slot=switch-thumb]")];
		const input = el.querySelector("input");
		const sync = () => {
			const on = read(row);
			sw.setAttribute("aria-checked", on ? "true" : "false");
			for (const p of parts) {
				p.toggleAttribute("data-checked", on);
				p.toggleAttribute("data-unchecked", !on);
			}
			if (input) input.checked = on;
		};
		sync();
		el.addEventListener("click", (event) => {
			if (!sw.contains(event.target)) return;
			event.preventDefault();
			write(row, !read(row));
			sync();
		});
		return el;
	}

	// Default theme for web pages in T3's browser. Saved as browserAppearance in local-patches.json;
	// local-main.cjs applies it to open and new tabs straight away.
	const PAGE_THEMES = [
		["dark", "Dark"],
		["light", "Light"],
		["system", "System (T3 default)"],
	];
	function makeSelectRow(template) {
		const el = template.cloneNode(true);
		el.removeAttribute(INLINE_ATTR);
		for (const n of el.querySelectorAll("[id]")) n.removeAttribute("id");
		const sw = el.querySelector("[role=switch]");
		const title = el.querySelector("h3");
		const desc = el.querySelector("p");
		if (!sw || !title || !desc) return null;
		title.textContent = "Web page theme";
		desc.textContent = "Light or dark for every website opened in T3's browser. A tab set in its own Appearance menu keeps that choice.";
		for (const extra of [...title.parentElement.children].slice(1)) extra.remove();
		const select = document.createElement("select");
		select.setAttribute("aria-label", "Web page theme");
		select.setAttribute("data-t3local-pagetheme", "");
		const trigger = document.querySelector("[data-slot=select-trigger]");
		if (trigger) select.className = trigger.className;
		select.style.cssText = "min-width:10rem;padding:0.35rem 0.6rem;border-radius:0.5rem;border:1px solid var(--border, rgba(255,255,255,.15));background:var(--background, transparent);color:inherit;font:inherit;font-size:0.875rem;color-scheme:dark light;cursor:pointer";
		for (const [value, label] of PAGE_THEMES) select.add(new Option(label, value));
		select.value = PAGE_THEMES.some(([v]) => v === CONFIG.browserAppearance) ? CONFIG.browserAppearance : "system";
		select.addEventListener("change", () => {
			CONFIG.browserAppearance = select.value;
			console.log("T3LOCAL:" + JSON.stringify({ key: "browserAppearance", value: select.value }));
		});
		sw.replaceWith(select);
		return el;
	}

	// The stock Glass opacity slider now drives every glass area, so its text says so, and the
	// "extend glass" switch sits right under it.
	const GLASS_DESC = "How see-through the glass is: window, sidebar, menus, dialogs, and the message box. Lower is clearer, 100% is solid.";
	function glassRows() {
		const stock = [...document.querySelectorAll("section")].find((x) => !x.hasAttribute(SECTION_ATTR) && x.querySelector("h2") && x.querySelector("h2").textContent.trim() === "Interface");
		if (!stock) return;
		const rows = [...stock.querySelectorAll("[data-slot=settings-row]")];
		const glass = rows.find((r) => r.querySelector("h3") && r.querySelector("h3").textContent.trim() === "Glass opacity");
		if (!glass) return;
		const p = glass.querySelector("p");
		if (p && p.textContent !== GLASS_DESC) p.textContent = GLASS_DESC;
		if (stock.querySelector("[" + INLINE_ATTR + "]")) return;
		const template = rows.find((r) => r.querySelector("[role=switch]"));
		const el = template && makeRow(template, ROWS.find((r) => r.inline));
		if (!el) return;
		el.setAttribute(INLINE_ATTR, "1");
		glass.after(el);
	}

	let queued = false;
	function run() {
		queued = false;
		try {
			const onPage = /\/settings\/appearance/.test(location.hash + location.pathname);
			const existing = document.querySelector("[" + SECTION_ATTR + "]");
			if (existing && !existing.isConnected) state.section = false;
			state.section = !!(existing && existing.isConnected);
			if (onPage) glassRows();
			if (!state.section && onPage) state.section = !!build();
		} catch (error) {
			state.error = String((error && error.message) || error);
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

	window.__t3LocalSettings = {
		state,
		stop() {
			observer.disconnect();
			for (const el of document.querySelectorAll("[" + SECTION_ATTR + "]")) el.remove();
		},
	};
} catch (error) {
	window.__t3LocalSettingsError = String((error && error.stack) || error);
}
})();
