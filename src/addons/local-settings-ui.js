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

	// Read by the server.asar "usageaccounts" patch (thread popover usage limits). Gets the usage store's account
	// list, T3's "unavailable reason" function and the instance id; returns one limits object with a row per
	// readable account, each labelled with the name set for that email in accountNames (self.T3N) or the first 5
	// characters of the email. Returns T3's own pick when no account has readable limits.
	self.T3A = function (accs, reason, instanceId) {
		try {
			const list = Array.isArray(accs) ? accs : [];
			const ok = list.filter((a) => a && a.limits && Array.isArray(a.limits.windows) && !reason(a.limits));
			if (!ok.length) return (list.find((a) => a && a.instanceId === instanceId) || {}).limits;
			const names = self.T3N || {};
			const windows = [];
			for (const a of ok) {
				const who = names[a.email] !== undefined ? names[a.email] : String(a.email || a.id || "").slice(0, 5);
				for (const w of a.limits.windows) windows.push({ ...w, id: String(a.id || a.email) + ":" + w.id, label: who + " " + w.label });
			}
			return { ...ok[0].limits, windows, t3a: 1 };
		} catch (e) {
			return undefined;
		}
	};

	const ROWS = [
		{ id: "versionBadge", key: "t3local.showVersion", title: "Version in header badge", desc: "Shows the app version next to the Nightly label in the sidebar header." },
		{ id: "galaxyHeader", key: "t3local.galaxyHeader", title: "Galaxy in the sidebar header", desc: "The star-field artwork behind the T3 Code title at the top left." },
		{ id: "galaxySend", key: "t3local.galaxySend", title: "Galaxy on the send button", desc: "The star-field artwork inside the round send button of the message box." },
		{ id: "contrast", key: "t3local.contrast", title: "Stronger highlights", desc: "Clearer selected rows in lists and menus, and visible edges on panels, in Catppuccin Mocha tones." },
		{ id: "sidebarSeconds", key: "t3local.sidebarSeconds", title: "Seconds on sidebar timers", desc: "Shows how long a thread or helper agent has been working down to the second in the sidebar, like 23m 27s." },
		{ id: "extendedGlass", key: "t3local.extendedGlass", inline: true, title: "Extend glass across the whole window", desc: "Lets the blur show through the chat area and sidebar as well as menus. Off keeps glass to menus, dialogs, and the message box." },
		{ id: "glassMenus", config: "glassMenus", def: true, title: "Frosted glass right-click menus", desc: "Draws right-click menus as blurred glass panels. Applies after a reload (Ctrl+R)." },
		{ id: "nativeTitleBar", config: "nativeTitleBar", def: false, title: "Native Windows title bar", desc: "Uses the Windows title bar instead of T3's own drawn one. Applies after you restart T3 Code." },
	];

	const read = (row) => (row.config ? (CONFIG[row.config] === undefined ? row.def : CONFIG[row.config] !== false && CONFIG[row.config] !== 0) : localStorage.getItem(row.key) !== "0");
	function mirror() {
		for (const row of ROWS) if (!row.config) document.documentElement.toggleAttribute("data-t3local-" + row.id + "-off", !read(row));
		// read by the server.asar "sidebarsecs" patch on every timer tick
		self.T3S = read(ROWS.find((r) => r.id === "sidebarSeconds"));
		applyWorkingColor();
	}

	// Color of the "Working" status (spinner icon, label and timer) in the sidebar and the
	// thread-list status dot. localStorage t3local.workingColor: "#rrggbb", or "stock" for T3's own blue.
	const WORKING_KEY = "t3local.workingColor";
	const WORKING_DEFAULT = "#89b4fa"; // Catppuccin Mocha blue
	const STYLE_ATTR = "data-t3local-working-color";
	function normalizeHex(value) {
		const m = /^#?([0-9a-f]{3}|[0-9a-f]{6})$/i.exec(String(value || "").trim());
		if (!m) return null;
		const h = m[1].length === 3 ? m[1].replace(/./g, (c) => c + c) : m[1];
		return "#" + h.toLowerCase();
	}
	function workingColor() {
		const saved = localStorage.getItem(WORKING_KEY);
		if (saved === "stock") return null;
		return normalizeHex(saved) || WORKING_DEFAULT;
	}
	function applyWorkingColor() {
		let style = document.head && document.head.querySelector("style[" + STYLE_ATTR + "]");
		const color = workingColor();
		if (!color) return style && style.remove();
		if (!style) {
			if (!document.head) return;
			style = document.createElement("style");
			style.setAttribute(STYLE_ATTR, "");
			document.head.appendChild(style);
		}
		const css =
			`.text-info-foreground:has(> svg.lucide-circle-dashed){color:${color}!important}` +
			`[role="img"][aria-label="Working"]{color:${color}!important}` +
			`[role="img"][aria-label="Working"]>span.rounded-full{background-color:${color}!important}`;
		if (style.textContent !== css) style.textContent = css;
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
		const iconRow = makeIconRow(template);
		if (iconRow) newCard.appendChild(iconRow);
		const colorRow = makeColorRow(template);
		if (!colorRow) return null;
		newCard.appendChild(colorRow);
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
		select.style.cssText = "min-width:10rem;padding:0.35rem 0.6rem;border-radius:0.5rem;border:1px solid var(--border, rgba(255,255,255,.15));background:var(--background, transparent);color:inherit;font:inherit;font-size:0.875rem;cursor:pointer";
		// The open list is drawn by Chromium, not the page: "dark light" let it pick a white
		// list. Follow T3's own theme and paint the options like T3's popovers.
		const dark = document.documentElement.classList.contains("dark");
		select.style.colorScheme = dark ? "dark" : "light";
		for (const [value, label] of PAGE_THEMES) {
			const option = new Option(label, value);
			option.style.cssText = "background-color:var(--popover);color:var(--popover-foreground)";
			select.add(option);
		}
		select.value = PAGE_THEMES.some(([v]) => v === CONFIG.browserAppearance) ? CONFIG.browserAppearance : "system";
		select.addEventListener("change", () => {
			CONFIG.browserAppearance = select.value;
			console.log("T3LOCAL:" + JSON.stringify({ key: "browserAppearance", value: select.value }));
		});
		sw.replaceWith(select);
		return el;
	}

	// App icon: two tiles, Riced (the Mocha tile) and Original. Saved as appIcon in local-patches.json;
	// local-app-icon.cjs applies it at once to the window, taskbar, shortcuts and the sidebar corner,
	// and to the program file the next time T3 closes. Looks live in 99-mocha-pass56-brand-icon.css.
	const APP_ICONS = [
		["riced", "Riced"],
		["original", "Original"],
	];
	function makeIconRow(template) {
		const el = template.cloneNode(true);
		el.removeAttribute(INLINE_ATTR);
		for (const n of el.querySelectorAll("[id]")) n.removeAttribute("id");
		const sw = el.querySelector("[role=switch]");
		const title = el.querySelector("h3");
		const desc = el.querySelector("p");
		if (!sw || !title || !desc) return null;
		title.textContent = "App icon";
		desc.textContent = "The T3 Code icon on the taskbar, Start, the desktop, the window and the sidebar corner. The program file itself switches the next time T3 closes.";
		for (const extra of [...title.parentElement.children].slice(1)) extra.remove();
		const group = document.createElement("div");
		group.setAttribute("role", "group");
		group.setAttribute("aria-label", "App icon");
		group.setAttribute("data-t3local-iconpick", "");
		const current = () => (CONFIG.appIcon === "original" ? "original" : "riced");
		const tiles = APP_ICONS.map(([value, label]) => {
			const b = document.createElement("button");
			b.type = "button";
			b.dataset.icon = value;
			const img = document.createElement("img");
			img.alt = "";
			img.draggable = false;
			if (self.T3ICONS && self.T3ICONS[value]) img.src = self.T3ICONS[value];
			const span = document.createElement("span");
			span.textContent = label;
			b.append(img, span);
			b.addEventListener("click", () => {
				if (current() === value) return;
				CONFIG.appIcon = value;
				console.log("T3LOCAL:" + JSON.stringify({ key: "appIcon", value }));
				paint();
			});
			group.appendChild(b);
			return b;
		});
		function paint() {
			for (const b of tiles) b.setAttribute("aria-pressed", b.dataset.icon === current() ? "true" : "false");
		}
		paint();
		window.__t3IconPicker = (pick) => {
			CONFIG.appIcon = pick;
			for (const b of tiles) {
				const img = b.querySelector("img");
				if (!img.src && self.T3ICONS) img.src = self.T3ICONS[b.dataset.icon];
			}
			paint();
		};
		sw.replaceWith(group);
		return el;
	}

	// Working color: a swatch picker, a hex box, and a Reset button (back to Mocha blue). An empty
	// hex box means T3's stock blue. Changes apply at once to every open sidebar row.
	function makeColorRow(template) {
		const el = template.cloneNode(true);
		el.removeAttribute(INLINE_ATTR);
		for (const n of el.querySelectorAll("[id]")) n.removeAttribute("id");
		const sw = el.querySelector("[role=switch]");
		const title = el.querySelector("h3");
		const desc = el.querySelector("p");
		if (!sw || !title || !desc) return null;
		title.textContent = "Working color";
		desc.textContent = "Color of the Working spinner, label and timer in the sidebar. Type any hex code; leave it empty for T3's own blue.";
		for (const extra of [...title.parentElement.children].slice(1)) extra.remove();
		const box = document.createElement("div");
		box.setAttribute("data-t3local-workingcolor", "");
		box.style.cssText = "display:flex;align-items:center;gap:0.5rem;flex-shrink:0";
		const field = "height:2rem;border-radius:0.5rem;border:1px solid var(--border, rgba(255,255,255,.15));background:var(--background, transparent);color:inherit;font:inherit;font-size:0.875rem;color-scheme:" + (document.documentElement.classList.contains("dark") ? "dark" : "light");
		// Chromium's own <input type=color> popup can't be themed, so the swatch opens our picker
		const picker = makeColorPicker((value) => save(value));
		const hex = document.createElement("input");
		hex.type = "text";
		hex.maxLength = 7;
		hex.spellcheck = false;
		hex.placeholder = "T3 blue";
		hex.setAttribute("aria-label", "Working color hex code");
		hex.style.cssText = field + ";width:6.5rem;padding:0 0.6rem;font-family:ui-monospace,monospace";
		const reset = document.createElement("button");
		reset.type = "button";
		reset.textContent = "Reset";
		reset.title = "Back to Catppuccin Mocha blue " + WORKING_DEFAULT;
		reset.style.cssText = field + ";padding:0 0.75rem;cursor:pointer";
		const sync = () => {
			const color = workingColor();
			picker.value = color || "#3b82f6";
			if (document.activeElement !== hex) hex.value = color || "";
			hex.style.borderColor = "";
		};
		function save(value) {
			localStorage.setItem(WORKING_KEY, value);
			applyWorkingColor();
			sync();
		}
		hex.addEventListener("input", () => {
			const v = hex.value.trim();
			const color = normalizeHex(v);
			if (color) {
				localStorage.setItem(WORKING_KEY, color);
				applyWorkingColor();
				picker.value = color;
				hex.style.borderColor = "";
			} else if (v === "") {
				localStorage.setItem(WORKING_KEY, "stock");
				applyWorkingColor();
				hex.style.borderColor = "";
			} else hex.style.borderColor = "var(--destructive, #f38ba8)";
		});
		hex.addEventListener("blur", sync);
		hex.addEventListener("keydown", (event) => {
			if (event.key === "Enter") hex.blur();
		});
		reset.addEventListener("click", () => save(WORKING_DEFAULT));
		box.append(picker.button, hex, reset);
		sync();
		sw.replaceWith(box);
		return el;
	}

	// ---- Mocha colour picker: a swatch button that opens a small opaque panel with a
	// saturation/brightness area, a hue slider, a hex field and the Catppuccin accents.
	// Looks live in 99-mocha-pass31c-enhanced.css. Edits save straight away through onPick.
	const MOCHA_SWATCHES = [
		["Rosewater", "#f5e0dc"], ["Flamingo", "#f2cdcd"], ["Pink", "#f5c2e7"], ["Mauve", "#cba6f7"],
		["Red", "#f38ba8"], ["Maroon", "#eba0ac"], ["Peach", "#fab387"], ["Yellow", "#f9e2af"],
		["Green", "#a6e3a1"], ["Teal", "#94e2d5"], ["Sky", "#89dceb"], ["Sapphire", "#74c7ec"],
		["Blue", "#89b4fa"], ["Lavender", "#b4befe"],
	];
	const openPickers = new Set();
	function hexToHsv(hex) {
		const n = parseInt(hex.slice(1), 16);
		const r = (n >> 16) / 255, g = ((n >> 8) & 255) / 255, b = (n & 255) / 255;
		const max = Math.max(r, g, b), d = max - Math.min(r, g, b);
		let h = 0;
		if (d) h = max === r ? ((g - b) / d) % 6 : max === g ? (b - r) / d + 2 : (r - g) / d + 4;
		return { h: (h * 60 + 360) % 360, s: max ? d / max : 0, v: max };
	}
	function hsvToHex({ h, s, v }) {
		const f = (k) => {
			const x = (k + h / 60) % 6;
			return Math.round((v - v * s * Math.max(0, Math.min(x, 4 - x, 1))) * 255);
		};
		return "#" + [f(5), f(3), f(1)].map((c) => c.toString(16).padStart(2, "0")).join("");
	}
	function makeColorPicker(onPick) {
		const button = document.createElement("button");
		button.type = "button";
		button.setAttribute("data-t3local-cpick", "");
		button.setAttribute("aria-label", "Pick working color");
		button.setAttribute("aria-haspopup", "dialog");
		button.setAttribute("aria-expanded", "false");
		const chip = document.createElement("span");
		chip.setAttribute("data-chip", "");
		button.appendChild(chip);

		let value = "#3b82f6", hsv = hexToHsv(value), panel = null, parts = null;
		const api = {
			button,
			get value() { return value; },
			set value(next) {
				const v = normalizeHex(next);
				if (!v) return;
				// the hue is kept while the colour is grey or black, so dragging back to colour feels right
				if (v !== hsvToHex(hsv)) hsv = hexToHsv(v);
				value = v;
				chip.style.background = v;
				if (panel) paint();
			},
		};

		function build() {
			panel = document.createElement("div");
			panel.setAttribute("data-t3local-cpanel", "");
			panel.setAttribute("role", "dialog");
			panel.setAttribute("aria-label", "Working color picker");
			panel.tabIndex = -1;
			const sv = document.createElement("div");
			sv.setAttribute("data-sv", "");
			sv.setAttribute("role", "slider");
			sv.setAttribute("aria-label", "Saturation and brightness");
			sv.tabIndex = 0;
			const svThumb = document.createElement("span");
			svThumb.setAttribute("data-thumb", "");
			sv.appendChild(svThumb);
			const hue = document.createElement("div");
			hue.setAttribute("data-hue", "");
			hue.setAttribute("role", "slider");
			hue.setAttribute("aria-label", "Hue");
			hue.setAttribute("aria-valuemin", "0");
			hue.setAttribute("aria-valuemax", "360");
			hue.tabIndex = 0;
			const hueThumb = document.createElement("span");
			hueThumb.setAttribute("data-thumb", "");
			hue.appendChild(hueThumb);
			const row = document.createElement("div");
			row.setAttribute("data-row", "");
			const preview = document.createElement("span");
			preview.setAttribute("data-preview", "");
			const hexIn = document.createElement("input");
			hexIn.type = "text";
			hexIn.maxLength = 7;
			hexIn.spellcheck = false;
			hexIn.setAttribute("data-hex", "");
			hexIn.setAttribute("aria-label", "Hex code");
			row.append(preview, hexIn);
			const grid = document.createElement("div");
			grid.setAttribute("data-swatches", "");
			const swatches = MOCHA_SWATCHES.map(([name, color]) => {
				const s = document.createElement("button");
				s.type = "button";
				s.setAttribute("data-swatch", color);
				s.setAttribute("aria-label", name + " " + color);
				s.style.background = color;
				s.addEventListener("click", () => pick(color));
				grid.appendChild(s);
				return s;
			});
			panel.append(sv, hue, row, grid);
			parts = { sv, svThumb, hue, hueThumb, preview, hexIn, swatches };

			const drag = (area, apply) => {
				area.addEventListener("pointerdown", (event) => {
					if (event.button !== 0) return;
					event.preventDefault();
					area.focus({ preventScroll: true });
					try {
						area.setPointerCapture(event.pointerId);
					} catch {}
					const move = (e) => {
						const r = area.getBoundingClientRect();
						apply(Math.min(Math.max((e.clientX - r.left) / r.width, 0), 1), Math.min(Math.max((e.clientY - r.top) / r.height, 0), 1));
					};
					move(event);
					const up = () => {
						area.removeEventListener("pointermove", move);
						area.removeEventListener("pointerup", up);
						area.removeEventListener("pointercancel", up);
					};
					area.addEventListener("pointermove", move);
					area.addEventListener("pointerup", up);
					area.addEventListener("pointercancel", up);
				});
			};
			drag(sv, (x, y) => setHsv({ h: hsv.h, s: x, v: 1 - y }));
			drag(hue, (x) => setHsv({ h: Math.min(x * 360, 359.9), s: hsv.s, v: hsv.v }));
			const keys = (area, step) => area.addEventListener("keydown", (event) => {
				const k = event.shiftKey ? 10 : 1;
				const d = { ArrowLeft: [-k, 0], ArrowRight: [k, 0], ArrowUp: [0, k], ArrowDown: [0, -k] }[event.key];
				if (!d) return;
				event.preventDefault();
				step(d[0], d[1]);
			});
			const clamp01 = (n) => Math.min(Math.max(n, 0), 1);
			keys(sv, (dx, dy) => setHsv({ h: hsv.h, s: clamp01(hsv.s + dx / 100), v: clamp01(hsv.v + dy / 100) }));
			keys(hue, (dx, dy) => setHsv({ h: (hsv.h + dx + dy + 360) % 360, s: hsv.s, v: hsv.v }));
			hexIn.addEventListener("input", () => {
				const v = normalizeHex(hexIn.value);
				hexIn.toggleAttribute("data-invalid", !v && hexIn.value.trim() !== "");
				if (v) pick(v, true);
			});
			hexIn.addEventListener("keydown", (event) => {
				if (event.key === "Enter") close(true);
			});
			hexIn.addEventListener("blur", () => {
				hexIn.removeAttribute("data-invalid");
				hexIn.value = value;
			});
		}
		function setHsv(next) {
			hsv = next;
			pick(hsvToHex(next), false, true);
		}
		function pick(color, fromHexField, keepHsv) {
			const v = normalizeHex(color);
			if (!v) return;
			if (!keepHsv) hsv = hexToHsv(v);
			value = v;
			chip.style.background = v;
			paint(fromHexField);
			onPick(v);
		}
		function paint(fromHexField) {
			const { sv, svThumb, hue, hueThumb, preview, hexIn, swatches } = parts;
			sv.style.setProperty("--hue", `hsl(${Math.round(hsv.h)} 100% 50%)`);
			svThumb.style.left = `${hsv.s * 100}%`;
			svThumb.style.top = `${(1 - hsv.v) * 100}%`;
			svThumb.style.background = value;
			sv.setAttribute("aria-valuetext", `saturation ${Math.round(hsv.s * 100)}%, brightness ${Math.round(hsv.v * 100)}%`);
			hueThumb.style.left = `${(hsv.h / 360) * 100}%`;
			hueThumb.style.background = `hsl(${Math.round(hsv.h)} 100% 50%)`;
			hue.setAttribute("aria-valuenow", String(Math.round(hsv.h)));
			preview.style.background = value;
			if (!fromHexField && document.activeElement !== hexIn) hexIn.value = value;
			for (const s of swatches) s.setAttribute("aria-pressed", s.getAttribute("data-swatch") === value ? "true" : "false");
		}

		function place() {
			if (!panel) return;
			if (!button.isConnected) return close(false);
			const a = button.getBoundingClientRect();
			const host = panel.parentElement && panel.parentElement !== document.body ? panel.parentElement.getBoundingClientRect() : null;
			const vw = document.documentElement.clientWidth, vh = document.documentElement.clientHeight;
			const top0 = Math.max(host ? host.top : 0, 0), bottom0 = Math.min(host ? host.bottom : vh, vh);
			const left0 = Math.max(host ? host.left : 0, 0), right0 = Math.min(host ? host.right : vw, vw);
			const w = panel.offsetWidth, h = panel.offsetHeight, gap = 6, pad = 8;
			let top = a.bottom + gap;
			if (top + h > bottom0 - pad && a.top - gap - h >= top0 + pad) top = a.top - gap - h;
			top = Math.max(top0 + pad, Math.min(top, bottom0 - pad - h));
			const left = Math.max(left0 + pad, Math.min(a.right - w, right0 - pad - w));
			// a blurred or transformed ancestor makes position:fixed relative to it; measure and correct
			panel.style.left = `${left}px`;
			panel.style.top = `${top}px`;
			const r = panel.getBoundingClientRect();
			if (Math.abs(r.left - left) > 0.5 || Math.abs(r.top - top) > 0.5) {
				panel.style.left = `${left * 2 - r.left}px`;
				panel.style.top = `${top * 2 - r.top}px`;
			}
		}
		const onOutside = (event) => {
			if (panel && !panel.contains(event.target) && !button.contains(event.target)) close(false);
		};
		const onKey = (event) => {
			if (event.key !== "Escape" || !panel) return;
			// keep the Settings dialog open: Escape only closes the picker
			event.preventDefault();
			event.stopImmediatePropagation();
			close(true);
		};
		const onHash = () => close(false);
		function open() {
			if (!panel) build();
			paint();
			const host = button.closest("[data-app-modal]") || document.body;
			host.appendChild(panel);
			place();
			button.setAttribute("aria-expanded", "true");
			button.setAttribute("data-open", "");
			window.addEventListener("pointerdown", onOutside, true);
			window.addEventListener("keydown", onKey, true);
			window.addEventListener("scroll", place, true);
			window.addEventListener("resize", place);
			window.addEventListener("hashchange", onHash);
			window.addEventListener("blur", onHash);
			openPickers.add(close);
			parts.sv.focus({ preventScroll: true });
		}
		function close(refocus) {
			if (!panel || !panel.isConnected) return;
			panel.remove();
			button.setAttribute("aria-expanded", "false");
			button.removeAttribute("data-open");
			window.removeEventListener("pointerdown", onOutside, true);
			window.removeEventListener("keydown", onKey, true);
			window.removeEventListener("scroll", place, true);
			window.removeEventListener("resize", place);
			window.removeEventListener("hashchange", onHash);
			window.removeEventListener("blur", onHash);
			openPickers.delete(close);
			if (refocus && button.isConnected) button.focus({ preventScroll: true });
		}
		button.addEventListener("click", () => (panel && panel.isConnected ? close(false) : open()));
		api.open = open;
		api.close = close;
		return api;
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
			for (const close of [...openPickers]) close(false);
			for (const el of document.querySelectorAll("[" + SECTION_ATTR + "]")) el.remove();
		},
	};
} catch (error) {
	window.__t3LocalSettingsError = String((error && error.stack) || error);
}
})();
