// T3 Code Enhanced: the Enhanced update button and the "T3 Code Enhanced updates" Settings card.
//
// Loaded by ~/.t3/local-main.cjs on every window load. The checking and installing happen in the
// main process (local-enhanced-update.cjs); this page side only shows what it reports and sends
// clicks back as console.log("T3ENH:{action,...}").
//
// Button: a round button right after T3's own update button in the sidebar footer (or in that
// spot when T3 has no update). It shows only when there is something to do: a new Enhanced
// release, an install in progress, or a reload/restart to finish one.
// Card: Settings > General, under T3's own update settings. Switches for checking and installing
// automatically, how often to check, a Check now button and the current status.
(() => {
try {
	if (window.__t3Enhanced) window.__t3Enhanced.stop();
	const BTN_ATTR = "data-t3enh-update";
	const CARD_ATTR = "data-t3enh-settings";
	let info = null;
	const send = (msg) => console.log("T3ENH:" + JSON.stringify(msg));

	const style = document.createElement("style");
	style.setAttribute("data-t3enh-style", "");
	style.textContent = `
[${BTN_ATTR}] button{position:relative;color:#cba6f7}
[${BTN_ATTR}] button:hover{color:#f5c2e7}
[${BTN_ATTR}] svg{width:16px;height:16px}
[${BTN_ATTR}][data-state="installing"] svg{animation:t3enh-spin 1s linear infinite}
[${BTN_ATTR}][data-state="available"] button::after{content:"";position:absolute;top:5px;right:5px;width:6px;height:6px;border-radius:50%;background:#cba6f7;box-shadow:0 0 0 2px var(--sidebar, #1e1e2e)}
[${BTN_ATTR}][data-state="reload"] button,[${BTN_ATTR}][data-state="restart"] button{color:#a6e3a1}
@keyframes t3enh-spin{to{transform:rotate(360deg)}}
@media (prefers-reduced-motion: reduce){[${BTN_ATTR}] svg{animation:none!important}}
[${CARD_ATTR}] .t3enh-actions{display:flex;align-items:center;gap:.5rem;flex-shrink:0}
[${CARD_ATTR}] .t3enh-btn{height:2rem;padding:0 .75rem;border-radius:.5rem;border:1px solid var(--border, rgba(255,255,255,.15));background:var(--background, transparent);color:inherit;font:inherit;font-size:.875rem;cursor:pointer;white-space:nowrap}
[${CARD_ATTR}] .t3enh-btn:disabled{opacity:.55;cursor:default}
[${CARD_ATTR}] .t3enh-btn[data-primary]{border-color:#cba6f7;color:#cba6f7}
[${CARD_ATTR}] select{min-width:9rem;height:2rem;padding:0 .6rem;border-radius:.5rem;border:1px solid var(--border, rgba(255,255,255,.15));background:var(--background, transparent);color:inherit;font:inherit;font-size:.875rem;cursor:pointer}
[${CARD_ATTR}] select option{background-color:var(--popover);color:var(--popover-foreground)}`;
	document.documentElement.appendChild(style);

	const svg = (paths) => `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${paths}</svg>`;
	const ICONS = {
		available: svg('<path d="M9.94 15.5A2 2 0 0 0 8.5 14.06l-6.14-1.58a.5.5 0 0 1 0-.96L8.5 9.94A2 2 0 0 0 9.94 8.5l1.58-6.14a.5.5 0 0 1 .96 0l1.58 6.14a2 2 0 0 0 1.44 1.44l6.14 1.58a.5.5 0 0 1 0 .96l-6.14 1.58a2 2 0 0 0-1.44 1.44l-1.58 6.14a.5.5 0 0 1-.96 0z"/><path d="M20 3v4"/><path d="M22 5h-4"/>'),
		installing: svg('<path d="M21 12a9 9 0 1 1-6.22-8.56"/>'),
		reload: svg('<path d="M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8"/><path d="M21 3v5h-5"/><path d="M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16"/><path d="M8 16H3v5"/>'),
	};
	ICONS.restart = ICONS.reload;
	ICONS.check = ICONS.reload;

	function buttonState() {
		if (!info) return null;
		if (info.busy === "installing") return "installing";
		if (info.finish === "restart") return "restart";
		if (info.finish === "reload") return "reload";
		if (info.available && info.canInstall) return "available";
		return "check";
	}
	function label(state) {
		if (state === "check") return "Check for T3 Code patch updates";
		if (state === "installing") return `Installing T3 Code Enhanced ${info.latest || ""}...`;
		if (state === "restart") return "T3 Code Enhanced is updated. Click to restart T3 Code and finish.";
		if (state === "reload") return "T3 Code Enhanced is updated. Click to reload and finish.";
		return `T3 Code Enhanced ${info.latest} is out (you have ${info.installed}). Click to install.`;
	}

	// T3's own update button lives in the sidebar footer menu; ours goes right after it
	function footerSpot() {
		const stock = document.querySelector('[data-slot="sidebar-footer"] button:is([aria-label^="Update"],[aria-label="Check for updates"]):not([' + BTN_ATTR + "] *)") ||
			document.querySelector('[data-sidebar="sidebar"] button[aria-label^="Update this app"]');
		if (stock) {
			const li = stock.closest("li") || stock.parentElement;
			return { after: li, template: stock };
		}
		const menu = document.querySelector('[data-slot="sidebar-footer"] ul[data-sidebar="menu"]');
		return menu ? { append: menu, template: null } : null;
	}

	let btnLi = null;
	function syncButton() {
		const state = buttonState();
		if (!state) {
			if (btnLi) btnLi.remove();
			btnLi = null;
			return;
		}
		const spot = footerSpot();
		if (!spot) return;
		if (!btnLi) {
			btnLi = document.createElement("li");
			btnLi.setAttribute(BTN_ATTR, "");
			const b = document.createElement("button");
			b.type = "button";
			b.addEventListener("click", () => {
				const s = buttonState();
				if (s === "check") send({ action: "check" });
				else if (s === "available") send({ action: "install" });
				else if (s === "reload") send({ action: "reload" });
				else if (s === "restart") send({ action: "restart" });
			});
			btnLi.appendChild(b);
		}
		const b = btnLi.firstChild;
		btnLi.className = spot.after ? spot.after.className.replace(/\bml-auto\b/, "") : "relative ml-auto shrink-0";
		b.className = spot.template ? spot.template.className : "inline-flex size-8 items-center justify-center rounded-full";
		if (btnLi.getAttribute("data-state") !== state) {
			btnLi.setAttribute("data-state", state);
			b.innerHTML = ICONS[state];
		}
		const text = label(state);
		if (b.title !== text) {
			b.title = text;
			b.setAttribute("aria-label", text);
		}
		b.disabled = state === "installing";
		if (spot.after && spot.after.nextElementSibling !== btnLi) spot.after.after(btnLi);
		else if (spot.append && btnLi.parentElement !== spot.append) spot.append.appendChild(btnLi);
	}

	// ---- Settings card -------------------------------------------------------------------------
	const timeText = (iso) => {
		if (!iso) return "never";
		const d = new Date(iso);
		const today = new Date().toDateString() === d.toDateString();
		const t = d.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" }).toLowerCase();
		return today ? `today at ${t}` : `${d.toLocaleDateString([], { month: "short", day: "numeric" })} at ${t}`;
	};
	function statusText() {
		if (!info) return "Looking...";
		const parts = [];
		parts.push(info.installed ? `You have ${info.installed}.` : "This copy was not set up with the installer, so it cannot update itself.");
		if (info.busy === "checking") parts.push("Checking now...");
		else if (info.busy === "installing") parts.push(`Installing ${info.latest}...`);
		else if (info.finish === "restart") parts.push("Updated. Restart T3 Code to finish.");
		else if (info.finish === "reload") parts.push("Updated. Reload to finish.");
		else if (info.available) parts.push(`${info.latest} is available.`);
		else if (info.latest) parts.push(`${info.latest} is the newest release.`);
		if (info.error) parts.push(`Last try: ${info.error}.`);
		parts.push(`Last checked ${timeText(info.lastCheck)}.`);
		return parts.join(" ");
	}

	function findGeneral() {
		// the section that holds T3's own "Update track" row; any settings section as a fallback shape
		const rows = [...document.querySelectorAll("[data-slot=settings-row]")];
		const track = rows.find((r) => /^Update track/.test((r.querySelector("h3") || {}).textContent || ""));
		const section = (track && track.closest("section"));
		const template = rows.find((r) => r.querySelector("[role=switch]") && r.querySelector("h3") && r.querySelector("p")) || (() => {
            const original = rows.find(r => r.querySelector("h3") && r.querySelector("p"));
            if (!original) return null;
            const row = original.cloneNode(true);
            const controls = row.firstElementChild?.lastElementChild;
            if (!controls || controls.contains(row.querySelector("h3"))) return null;
            const sw = document.createElement("button");
            sw.type = "button";
            sw.setAttribute("role", "switch");
            sw.setAttribute("data-slot", "switch");
            // T3's own Switch classes (the compiled CSS only has the classes T3 itself uses);
            // a live stock switch elsewhere on the page wins if there is one.
            const live = document.querySelector('[data-slot=switch]:not([data-t3enh-switch]) > [data-slot=switch-thumb]');
            sw.setAttribute("data-t3enh-switch", "");
            sw.className = live ? live.parentElement.className : "[--thumb-size:--spacing(5)] sm:[--thumb-size:--spacing(4)] inline-flex h-[calc(var(--thumb-size)+2px)] w-[calc(var(--thumb-size)*2-2px)] shrink-0 cursor-pointer items-center rounded-full p-[2px] outline-none transition-[background-color,box-shadow] duration-200 focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-ring focus-visible:ring-offset-1 focus-visible:ring-offset-background data-checked:bg-primary data-unchecked:bg-input data-disabled:cursor-not-allowed data-disabled:opacity-64 data-[mixed]:bg-input";
            const thumb = document.createElement("span");
            thumb.setAttribute("data-slot", "switch-thumb");
            thumb.className = live ? live.className : "pointer-events-none block size-[calc(var(--thumb-size)-2px)] shrink-0 origin-left in-[[role=switch]:active,[data-slot=label]:active,[data-slot=field-label]:active]:not-data-disabled:scale-x-110 in-[[role=switch]:active,[data-slot=label]:active,[data-slot=field-label]:active]:rounded-[var(--thumb-size)/calc(var(--thumb-size)*1.1)] rounded-(--thumb-size) bg-background shadow-sm/5 dark:data-unchecked:bg-muted-foreground [transition:translate_.15s,border-radius_.15s,scale_.1s_.1s,transform-origin_.15s] data-checked:origin-right data-checked:translate-x-[calc(var(--thumb-size)-4px)]";
            sw.append(thumb);
            controls.replaceChildren(sw);
            return row;
        })();
		return section && template ? { section, template } : null;
	}

	function blankRow(template, title, desc) {
		const el = template.cloneNode(true);
		for (const n of el.querySelectorAll("[id]")) n.removeAttribute("id");
		for (const n of el.querySelectorAll("[data-t3local-glassrow]")) n.removeAttribute("data-t3local-glassrow");
		el.removeAttribute("data-t3local-glassrow");
		const h = el.querySelector("h3"), p = el.querySelector("p"), sw = el.querySelector("[role=switch]");
		h.textContent = title;
		p.textContent = desc;
		for (const extra of [...h.parentElement.children].slice(1)) extra.remove();
		return { el, h, p, sw };
	}

	function switchRow(template, title, desc, key) {
		const { el, sw } = blankRow(template, title, desc);
		sw.setAttribute("aria-label", title);
		const parts = [sw, ...sw.querySelectorAll("[data-slot=switch-thumb]")];
		const input = el.querySelector("input");
		el.t3sync = () => {
			const on = !!(info && info.settings[key]);
			sw.setAttribute("aria-checked", on ? "true" : "false");
			for (const n of parts) {
				n.toggleAttribute("data-checked", on);
				n.toggleAttribute("data-unchecked", !on);
			}
			if (input) input.checked = on;
		};
		el.addEventListener("click", (event) => {
			if (!sw.contains(event.target) || !info) return;
			event.preventDefault();
			info.settings[key] = !info.settings[key];
			el.t3sync();
			send({ action: "settings", [key]: info.settings[key] });
		});
		return el;
	}

	function buildCard() {
		const g = findGeneral();
		if (!g) return null;
		const section = g.section.cloneNode(true);
		section.setAttribute(CARD_ATTR, "");
		for (const n of section.querySelectorAll("[id]")) n.removeAttribute("id");
		const head = section.children[0];
		const h2 = head && head.querySelector("h2");
		if (!h2) return null;
		h2.textContent = "T3 Code Enhanced updates";
		head.removeAttribute("data-settings-scroll-target");
		while (head.children.length > 1) head.lastElementChild.remove();
		const card = section.querySelector("div[class*='rounded-xl border']");
		if (!card) return null;
		while (card.firstChild) card.firstChild.remove();
		// leftovers from the cloned section (footnotes, extra cards)
		for (const n of [...section.children].slice(1)) if (!n.contains(card)) n.remove();

		const rows = [];
		const status = blankRow(g.template, "Status", "");
		const actions = document.createElement("div");
		actions.className = "t3enh-actions";
		const checkBtn = document.createElement("button");
		checkBtn.type = "button";
		checkBtn.className = "t3enh-btn";
		checkBtn.textContent = "Check now";
		checkBtn.addEventListener("click", () => send({ action: "check" }));
		const installBtn = document.createElement("button");
		installBtn.type = "button";
		installBtn.className = "t3enh-btn";
		installBtn.setAttribute("data-primary", "");
		installBtn.addEventListener("click", () => {
			const s = buttonState();
			send({ action: s === "reload" ? "reload" : s === "restart" ? "restart" : s === "check" ? "check" : "install" });
		});
		const notesLink = document.createElement("button");
		notesLink.type = "button";
		notesLink.className = "t3enh-btn";
		notesLink.textContent = "What's new";
		notesLink.addEventListener("click", () => info && window.open(info.page, "_blank"));
		actions.append(notesLink, checkBtn, installBtn);
		status.sw.replaceWith(actions);
		status.el.t3sync = () => {
			status.p.textContent = statusText();
			checkBtn.disabled = !!(info && info.busy);
			const s = buttonState();
			installBtn.hidden = s === "installing";
			installBtn.disabled = s === "check" || !(info && info.canInstall);
			installBtn.textContent = s === "restart" ? "Restart T3 Code" : s === "reload" ? "Reload" : s === "check" ? "Install update" : `Install ${info ? info.latest : ""}`;
		};
		rows.push(status.el);
		rows.push(switchRow(g.template, "Check for updates automatically", "Looks for a new T3 Code Enhanced release when T3 Code starts and then on the schedule below.", "check"));
		rows.push(switchRow(g.template, "Install updates automatically", "Downloads and installs a new release as soon as it is found. The update button in the sidebar shows when it is ready.", "install"));

		const often = blankRow(g.template, "How often to check", "Only while T3 Code is open. Checking takes a second and uses GitHub's public release list.");
		const select = document.createElement("select");
		select.setAttribute("aria-label", "How often to check");
		select.style.colorScheme = document.documentElement.classList.contains("dark") ? "dark" : "light";
		for (const [v, t] of [[1, "Every hour"], [6, "Every 6 hours"], [24, "Once a day"]]) select.add(new Option(t, String(v)));
		select.addEventListener("change", () => send({ action: "settings", intervalHours: Number(select.value) }));
		often.sw.replaceWith(select);
		often.el.t3sync = () => {
			if (info && document.activeElement !== select) select.value = String(info.settings.intervalHours);
		};
		rows.push(often.el);

		for (const r of rows) card.appendChild(r);
		section.t3sync = () => rows.forEach((r) => r.t3sync());
		section.t3sync();
		g.section.after(section);
		return section;
	}

	let cardEl = null;
	function syncCard() {
		if (!/\/settings/.test(location.hash + location.pathname)) {
			cardEl = null;
			return;
		}
		if (!cardEl || !cardEl.isConnected) cardEl = document.querySelector("[" + CARD_ATTR + "]") || buildCard();
		if (cardEl && cardEl.t3sync) cardEl.t3sync();
	}

	// ---- wiring ----------------------------------------------------------------------------------
	// Cheap on purpose: a DOM change only costs an isConnected check unless our button or card
	// went missing.
	let queued = false, stopped = false;
	function run() {
		queued = false;
		if (stopped) return;
		try {
			syncButton();
			syncCard();
		} catch (error) {
			window.__t3EnhancedError = String((error && error.message) || error);
		}
	}
	const schedule = () => {
		if (!stopped && !queued) {
			queued = true;
			requestAnimationFrame(run);
		}
	};
	const observer = new MutationObserver(() => {
		const wantBtn = !!buttonState();
		const onSettings = /\/settings/.test(location.hash + location.pathname);
		if ((wantBtn && !(btnLi && btnLi.isConnected)) || (onSettings && !(cardEl && cardEl.isConnected)) || (!onSettings && cardEl)) schedule();
	});
	observer.observe(document.body, { childList: true, subtree: true });

	window.__t3Enhanced = {
		set(next) {
			info = next;
			schedule();
		},
		get info() {
			return info;
		},
		stop() {
			stopped = true;
			observer.disconnect();
			style.remove();
			for (const el of document.querySelectorAll("[" + BTN_ATTR + "],[" + CARD_ATTR + "]")) el.remove();
		},
	};
	send({ action: "hello" });
} catch (error) {
	window.__t3EnhancedError = String((error && error.stack) || error);
}
})();
