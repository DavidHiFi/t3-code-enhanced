// T3 Code Enhanced: one update button for T3 Code and T3 Code Enhanced, and the
// "T3 Code Enhanced updates" Settings card.
//
// Loaded by ~/.t3/local-main.cjs on every window load. The checking and installing happen in the
// main process (local-enhanced-update.cjs); this page side only shows what it reports and sends
// clicks back as console.log("T3ENH:{action,...}").
//
// Button: T3's own update button stays the one button in the sidebar footer. A click on it while
// T3 is idle also checks for an Enhanced release. When Enhanced has something to do (a new
// release, an install running, a reload or restart to finish one) and T3 itself does not, our
// button takes the same spot and T3's is hidden, so there is never more than one.
// Card: Settings > General, under T3's own update settings. One status row with one action and
// one switch that keeps Enhanced up to date by itself.
(() => {
try {
	if (window.__t3Enhanced) window.__t3Enhanced.stop();
	const BTN_ATTR = "data-t3enh-update";
	const CARD_ATTR = "data-t3enh-settings";
	const STOCK_ATTR = "data-t3enh-stock";
	const HIDE_ATTR = "data-t3enh-hide";
	let info = null;
	const send = (msg) => console.log("T3ENH:" + JSON.stringify(msg));

	const style = document.createElement("style");
	style.setAttribute("data-t3enh-style", "");
	style.textContent = `
[${HIDE_ATTR}]{display:none!important}
[${BTN_ATTR}] button{position:relative;color:#cba6f7}
[${BTN_ATTR}] button:hover{color:#f5c2e7}
[${BTN_ATTR}] svg{width:16px;height:16px}
[${BTN_ATTR}][data-state="installing"] svg,[${BTN_ATTR}][data-spin] svg{animation:t3enh-spin 1s linear infinite}
[${BTN_ATTR}] button[aria-disabled="true"],[${BTN_ATTR}] button[aria-disabled="true"]:hover{cursor:not-allowed;color:#cba6f7}
[${BTN_ATTR}][data-state="available"] button::after{content:"";position:absolute;top:5px;right:5px;width:6px;height:6px;border-radius:50%;background:#cba6f7;box-shadow:0 0 0 2px var(--sidebar, #1e1e2e)}
[${BTN_ATTR}][data-state="reload"] button,[${BTN_ATTR}][data-state="restart"] button{color:#a6e3a1}
@keyframes t3enh-spin{to{transform:rotate(360deg)}}
@media (prefers-reduced-motion: reduce){[${BTN_ATTR}] svg{animation:none!important}}
[${CARD_ATTR}] .t3enh-actions{display:flex;align-items:center;gap:.5rem;flex-shrink:0}
[${CARD_ATTR}] .t3enh-btn{height:2rem;padding:0 .75rem;border-radius:.5rem;border:1px solid var(--border, rgba(255,255,255,.15));background:var(--background, transparent);color:inherit;font:inherit;font-size:.875rem;cursor:pointer;white-space:nowrap}
[${CARD_ATTR}] .t3enh-btn:disabled{opacity:.55;cursor:default}
[${CARD_ATTR}] .t3enh-btn[data-primary]{border-color:#cba6f7;color:#cba6f7}`;
	document.documentElement.appendChild(style);

	const svg = (paths) => `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${paths}</svg>`;
	const ICONS = {
		available: svg('<path d="M9.94 15.5A2 2 0 0 0 8.5 14.06l-6.14-1.58a.5.5 0 0 1 0-.96L8.5 9.94A2 2 0 0 0 9.94 8.5l1.58-6.14a.5.5 0 0 1 .96 0l1.58 6.14a2 2 0 0 0 1.44 1.44l6.14 1.58a.5.5 0 0 1 0 .96l-6.14 1.58a2 2 0 0 0-1.44 1.44l-1.58 6.14a.5.5 0 0 1-.96 0z"/><path d="M20 3v4"/><path d="M22 5h-4"/>'),
		installing: svg('<path d="M21 12a9 9 0 1 1-6.22-8.56"/>'),
		reload: svg('<path d="M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8"/><path d="M21 3v5h-5"/><path d="M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16"/><path d="M8 16H3v5"/>'),
	};
	ICONS.restart = ICONS.reload;
	ICONS.check = ICONS.reload;
	ICONS.checking = ICONS.reload;

	// ---- T3's own button -------------------------------------------------------------------------
	// Found once by its label and marked, because the label changes ("Checking for updates…").
	const STOCK_LABEL = /update|up to date/i;
	const STOCK_IDLE = /^(Check for updates|Checking for updates|Up to date|Updates unavailable)/i;
	function findStock() {
		const marked = document.querySelector("[" + STOCK_ATTR + "]");
		if (marked && marked.isConnected) return marked;
		const footer = document.querySelector('[data-slot="sidebar-footer"]');
		if (!footer) return null;
		const stock = [...footer.querySelectorAll("button[aria-label]")].find((b) => !b.closest("[" + BTN_ATTR + "]") && STOCK_LABEL.test(b.getAttribute("aria-label")));
		if (!stock) return null;
		stock.setAttribute(STOCK_ATTR, "");
		// a click on T3's idle button checks both
		stock.addEventListener("click", () => {
			if (!STOCK_IDLE.test(stock.getAttribute("aria-label") || "") || !info || (info.busy)) return;
			pending = { quiet: true, last: info.lastCheck, timer: setTimeout(() => { pending = null; schedule(); }, 20000) };
			send({ action: "check" });
		}, true);
		return stock;
	}
	const stockLi = (stock) => stock.closest("li") || stock.parentElement;
	// T3 has something to say (an update to download or install, a failure): its button wins
	const t3HasAction = (stock) => !!stock && !STOCK_IDLE.test(stock.getAttribute("aria-label") || "");

	// a click asks for a check; this holds the spin until the main process reports the result
	let pending = null;
	function enhancedState() {
		if (!info) return null;
		if (info.busy === "installing") return "installing";
		if (info.finish === "restart") return "restart";
		if (info.finish === "reload") return "reload";
		if (info.available && info.canInstall) return "available";
		return null;
	}
	// what our button shows; null means T3's own button is the one on screen
	function buttonState() {
		const stock = findStock();
		const e = enhancedState();
		if (e === "installing") return e;
		if (t3HasAction(stock)) return null;
		if (e) return e;
		if (stock || !info) return null;
		// no T3 button at all (a web build): ours does the checking
		return info.busy === "checking" || (pending && !pending.quiet) ? "checking" : "check";
	}
	function label(state) {
		if (state === "check") return "Check for updates";
		if (state === "checking") return "Checking for updates…";
		if (state === "installing") return `Installing T3 Code Enhanced ${info.latest || ""}…`;
		if (state === "restart") return "T3 Code Enhanced is updated. Click to restart and finish.";
		if (state === "reload") return "T3 Code Enhanced is updated. Click to reload and finish.";
		return `T3 Code Enhanced ${info.latest} is ready (you have ${info.installed}). Click to install.`;
	}

	// our button sits where T3's is, with T3's own classes
	function footerSpot() {
		const stock = findStock();
		if (stock) return { after: stockLi(stock), template: stock };
		const menu = document.querySelector('[data-slot="sidebar-footer"] ul[data-sidebar="menu"]');
		return menu ? { append: menu, template: null } : null;
	}

	// ---- tooltip: the same markup, classes, side, offset, delay and fade as T3's own Tooltip ------
	// (Base UI Tooltip in T3's ui/tooltip: side top, align center, sideOffset 4, open delay 600 ms,
	// close delay 0, instant when another tooltip was open in the last 400 ms)
	const TIP_POSITIONER = "pointer-events-none z-[140] max-w-(--available-width) transition-[top,left,right,bottom,transform] data-instant:transition-none";
	const TIP_POPUP = "relative flex origin-(--transform-origin) text-balance rounded-md text-popover-foreground text-xs transition-[scale,opacity] before:pointer-events-none before:absolute before:inset-0 before:rounded-[calc(var(--radius-md)-1px)] before:shadow-[0_1px_--theme(--color-black/4%)] data-ending-style:scale-98 data-starting-style:scale-98 data-ending-style:opacity-0 data-starting-style:opacity-0 data-instant:duration-0 dark:before:shadow-[0_-1px_--theme(--color-white/6%)] border bg-popover not-dark:bg-clip-padding shadow-md/5 max-w-80 wrap-anywhere whitespace-normal leading-snug";
	const TIP_DELAY = 600, TIP_GROUP_MS = 400, TIP_OFFSET = 4, TIP_PAD = 5;
	const tip = { root: null, popup: null, text: null, anchor: null, timer: 0, hideTimer: 0, closedAt: 0, hover: false, note: null };
	function tipText() {
		if (tip.note) return tip.note;
		const state = buttonState();
		return state ? label(state) : "";
	}
	function placeTip() {
		if (!tip.root || !tip.anchor || !tip.anchor.isConnected) return;
		const a = tip.anchor.getBoundingClientRect();
		const vw = document.documentElement.clientWidth, vh = document.documentElement.clientHeight;
		tip.root.style.setProperty("--available-width", `${vw - TIP_PAD * 2}px`);
		const w = tip.popup.offsetWidth, h = tip.popup.offsetHeight;
		let side = "top", top = a.top - TIP_OFFSET - h;
		if (top < TIP_PAD) { side = "bottom"; top = a.bottom + TIP_OFFSET; }
		const centre = a.left + a.width / 2;
		const left = Math.round(Math.min(Math.max(centre - w / 2, TIP_PAD), vw - TIP_PAD - w));
		tip.root.style.left = `${left}px`;
		tip.root.style.top = `${Math.round(Math.min(top, vh - TIP_PAD - h))}px`;
		tip.popup.style.setProperty("--transform-origin", `${Math.round(centre - left)}px ${side === "top" ? h : 0}px`);
		for (const n of [tip.root, tip.popup]) n.setAttribute("data-side", side);
	}
	function showTip(instant) {
		clearTimeout(tip.timer);
		clearTimeout(tip.hideTimer);
		const anchor = btnLi && btnLi.firstChild;
		if (!anchor || !anchor.isConnected) return;
		tip.anchor = anchor;
		if (!tip.root) {
			const portal = document.createElement("div");
			portal.setAttribute("data-base-ui-portal", "");
			portal.setAttribute("data-t3enh-tip", "");
			const pos = document.createElement("div");
			pos.className = TIP_POSITIONER;
			pos.setAttribute("data-slot", "tooltip-positioner");
			pos.setAttribute("data-align", "center");
			pos.setAttribute("role", "presentation");
			pos.style.cssText = "position:fixed;left:0;top:0";
			const popup = document.createElement("div");
			popup.className = TIP_POPUP;
			popup.setAttribute("data-slot", "tooltip-popup");
			popup.setAttribute("data-align", "center");
			popup.setAttribute("role", "tooltip");
			popup.id = "t3enh-tip";
			const view = document.createElement("div");
			view.className = "min-w-0 px-2 py-1";
			view.setAttribute("data-slot", "tooltip-viewport");
			const span = document.createElement("span");
			span.className = "whitespace-pre-line";
			view.appendChild(span);
			popup.appendChild(view);
			pos.appendChild(popup);
			portal.appendChild(pos);
			tip.root = pos;
			tip.popup = popup;
			tip.text = span;
			tip.portal = portal;
		}
		tip.text.textContent = tipText();
		const fresh = !tip.portal.isConnected;
		for (const n of [tip.root, tip.popup]) {
			n.toggleAttribute("data-instant", !!instant);
			n.setAttribute("data-open", "");
			n.removeAttribute("data-ending-style");
		}
		if (fresh) {
			if (!instant) tip.popup.setAttribute("data-starting-style", "");
			// placed before its first paint with the position transition off, so it doesn't slide in
			// from the corner (that transition is only for moving between buttons)
			tip.root.style.transition = "none";
			document.body.appendChild(tip.portal);
			placeTip();
			void tip.root.offsetWidth;
			tip.root.style.transition = "";
			requestAnimationFrame(() => requestAnimationFrame(() => tip.popup && tip.popup.removeAttribute("data-starting-style")));
		} else placeTip();
		anchor.setAttribute("aria-describedby", "t3enh-tip");
	}
	function hideTip(instant) {
		clearTimeout(tip.timer);
		clearTimeout(tip.hideTimer);
		if (!tip.portal || !tip.portal.isConnected) return;
		tip.closedAt = Date.now();
		if (tip.anchor) tip.anchor.removeAttribute("aria-describedby");
		for (const n of [tip.root, tip.popup]) n.removeAttribute("data-open");
		if (instant) return tip.portal.remove();
		tip.popup.setAttribute("data-ending-style", "");
		tip.hideTimer = setTimeout(() => {
			if (tip.popup.hasAttribute("data-ending-style")) tip.portal.remove();
		}, 160);
	}
	const anotherTipOpen = () => !!document.querySelector('[data-slot="tooltip-popup"][data-open]:not(#t3enh-tip)');
	function refreshTip() {
		if (tip.portal && tip.portal.isConnected && tip.popup.hasAttribute("data-open")) {
			tip.text.textContent = tipText();
			placeTip();
		}
	}
	// after a check the button says what it found, in the same tooltip, for a few seconds
	function noteResult(text) {
		tip.note = text;
		showTip(true);
		clearTimeout(tip.noteTimer);
		tip.noteTimer = setTimeout(() => {
			tip.note = null;
			if (tip.hover) refreshTip();
			else hideTip(false);
		}, 3500);
	}
	function resultText() {
		if (info.error) return `Could not check for T3 Code Enhanced updates: ${info.error}`;
		if (info.available) return `T3 Code Enhanced ${info.latest} is ready${info.installed ? ` (you have ${info.installed})` : ""}.`;
		return "T3 Code Enhanced is up to date.";
	}
	function wireTip(b) {
		b.addEventListener("pointerenter", (event) => {
			if (event.pointerType === "touch") return;
			tip.hover = true;
			clearTimeout(tip.timer);
			if (tip.portal && tip.portal.isConnected && tip.popup.hasAttribute("data-open")) return refreshTip();
			const instant = anotherTipOpen() || Date.now() - tip.closedAt < TIP_GROUP_MS;
			if (instant) showTip(true);
			else tip.timer = setTimeout(() => tip.hover && showTip(false), TIP_DELAY);
		});
		b.addEventListener("pointerleave", () => {
			tip.hover = false;
			if (!tip.note) hideTip(false);
			else clearTimeout(tip.timer);
		});
		b.addEventListener("focus", () => b.matches(":focus-visible") && showTip(false));
		b.addEventListener("blur", () => !tip.hover && !tip.note && hideTip(false));
	}
	const onWindowBlur = () => { tip.hover = false; tip.note = null; hideTip(true); };
	window.addEventListener("blur", onWindowBlur);


	// the icon keeps turning until the check is over and the current turn has finished, like T3's own
	const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
	function syncSpin(state) {
		if (!btnLi) return;
		if (state === "checking") return btnLi.setAttribute("data-spin", "");
		if (!btnLi.hasAttribute("data-spin")) return;
		if (reducedMotion.matches) btnLi.removeAttribute("data-spin");
		else btnLi.setAttribute("data-spin", "ending");
	}

	const BTN_BASE = "inline-flex size-8 items-center justify-center rounded-full outline-hidden ring-ring transition-colors focus-visible:ring-2 focus-visible:ring-inset text-(--sidebar-icon-color)";
	let btnLi = null;
	function showStock(on) {
		const stock = findStock();
		if (stock) stockLi(stock).toggleAttribute(HIDE_ATTR, !on);
	}
	function syncButton() {
		const state = buttonState();
		if (!state) {
			if (btnLi) btnLi.remove();
			btnLi = null;
			showStock(true);
			if (!tip.note) hideTip(true);
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
				if (s === "check") {
					pending = { last: info.lastCheck, timer: setTimeout(() => { pending = null; schedule(); }, 20000) };
					send({ action: "check" });
					schedule();
				} else if (s === "available") send({ action: "install" });
				else if (s === "reload") send({ action: "reload" });
				else if (s === "restart") send({ action: "restart" });
			});
			b.addEventListener("animationiteration", () => {
				if (btnLi && btnLi.getAttribute("data-spin") === "ending") btnLi.removeAttribute("data-spin");
			});
			wireTip(b);
			btnLi.appendChild(b);
		}
		const b = btnLi.firstChild;
		const liClass = spot.after ? spot.after.className : "relative ml-auto shrink-0";
		if (btnLi.className !== liClass) btnLi.className = liClass;
		const blocked = state === "checking" || state === "installing";
		const cls = BTN_BASE + (blocked ? " cursor-not-allowed opacity-60" : " cursor-pointer hover:bg-sidebar-row-hover hover:text-sidebar-foreground");
		if (b.className !== cls) b.className = cls;
		if (btnLi.getAttribute("data-state") !== state) {
			btnLi.setAttribute("data-state", state);
			// same icon while checking, so the turning svg is not replaced mid-turn
			if (b.getAttribute("data-icon") !== ICONS[state]) {
				b.innerHTML = ICONS[state];
				b.setAttribute("data-icon", ICONS[state]);
			}
		}
		syncSpin(state);
		const text = label(state);
		b.removeAttribute("title");
		if (b.getAttribute("aria-label") !== text) b.setAttribute("aria-label", text);
		if (blocked) b.setAttribute("aria-disabled", "true");
		else b.removeAttribute("aria-disabled");
		b.disabled = state === "installing";
		refreshTip();
		if (spot.after && spot.after.nextElementSibling !== btnLi) spot.after.after(btnLi);
		else if (spot.append && btnLi.parentElement !== spot.append) spot.append.appendChild(btnLi);
		showStock(false);
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
		if (!info) return "Looking…";
		const parts = [];
		if (info.busy === "checking") parts.push("Checking now…");
		else if (info.busy === "installing") parts.push(`Installing ${info.latest}…`);
		else if (info.finish === "restart") parts.push("Updated. Restart T3 Code to finish.");
		else if (info.finish === "reload") parts.push("Updated. Reload to finish.");
		else if (info.available && info.canInstall) parts.push(`${info.latest} is ready to install (you have ${info.installed}).`);
		else if (info.installed) parts.push(info.latest && info.latest !== info.installed ? `You have ${info.installed}.` : `You have ${info.installed}, the newest.`);
		else parts.push("This copy runs from your own files, so it is not updated from GitHub.");
		if (info.error) parts.push(`Last check failed: ${info.error}.`);
		else parts.push(`Checked ${timeText(info.lastCheck)}.`);
		if (info.t3Staged) parts.push(`T3 Code ${info.t3Staged} is downloaded and already patched, so it installs in seconds.`);
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

	// one switch for both "check" and "install"
	const autoOn = () => !!(info && info.settings.check && info.settings.install);
	function autoRow(template) {
		const title = "Keep T3 Code Enhanced up to date";
		const { el, sw } = blankRow(template, title, "Checks for a new release while T3 Code is open and installs it by itself. T3 Code's own updates are patched ahead of time, so they install in seconds.");
		sw.setAttribute("aria-label", title);
		const parts = [sw, ...sw.querySelectorAll("[data-slot=switch-thumb]")];
		const input = el.querySelector("input");
		el.t3sync = () => {
			const on = autoOn();
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
			const on = !autoOn();
			info.settings.check = on;
			info.settings.install = on;
			el.t3sync();
			send({ action: "settings", check: on, install: on });
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

		const status = blankRow(g.template, "Status", "");
		const actions = document.createElement("div");
		actions.className = "t3enh-actions";
		const notesBtn = document.createElement("button");
		notesBtn.type = "button";
		notesBtn.className = "t3enh-btn";
		notesBtn.textContent = "What's new";
		notesBtn.addEventListener("click", () => info && window.open(info.page, "_blank"));
		const mainBtn = document.createElement("button");
		mainBtn.type = "button";
		mainBtn.className = "t3enh-btn";
		mainBtn.addEventListener("click", () => {
			const s = enhancedState();
			send({ action: s === "reload" ? "reload" : s === "restart" ? "restart" : s === "available" ? "install" : "check" });
		});
		actions.append(notesBtn, mainBtn);
		status.sw.replaceWith(actions);
		status.el.t3sync = () => {
			status.p.textContent = statusText();
			const s = enhancedState();
			notesBtn.hidden = s !== "available";
			mainBtn.toggleAttribute("data-primary", !!s);
			mainBtn.disabled = !!(info && info.busy);
			mainBtn.textContent = s === "restart" ? "Restart T3 Code" : s === "reload" ? "Reload" : s === "available" ? `Install ${info.latest}` : s === "installing" ? "Installing…" : info && info.busy === "checking" ? "Checking…" : "Check now";
		};
		const rows = [status.el, autoRow(g.template)];
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
	// Cheap on purpose: a DOM change only costs a few checks unless our button, T3's button or the
	// card changed.
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
	let lastStockLabel = null;
	const observer = new MutationObserver(() => {
		const stock = document.querySelector("[" + STOCK_ATTR + "]");
		const stockLabel = stock && stock.isConnected ? stock.getAttribute("aria-label") : null;
		const onSettings = /\/settings/.test(location.hash + location.pathname);
		if (stockLabel !== lastStockLabel || (btnLi && !btnLi.isConnected) || (onSettings && !(cardEl && cardEl.isConnected)) || (!onSettings && cardEl)) {
			lastStockLabel = stockLabel;
			schedule();
		}
	});
	observer.observe(document.body, { childList: true, subtree: true, attributes: true, attributeFilter: ["aria-label"] });

	window.__t3Enhanced = {
		set(next) {
			info = next;
			// a click-started check is over once main reports a new lastCheck with nothing running
			if (pending && info && !info.busy && info.lastCheck && info.lastCheck !== pending.last) {
				clearTimeout(pending.timer);
				const quiet = pending.quiet;
				pending = null;
				run();
				// after a click on T3's own button, speak up only when Enhanced has news
				if (btnLi && btnLi.isConnected && (!quiet || enhancedState())) noteResult(resultText());
			}
			schedule();
		},
		get info() {
			return info;
		},
		stop() {
			stopped = true;
			observer.disconnect();
			style.remove();
			if (pending) clearTimeout(pending.timer);
			window.removeEventListener("blur", onWindowBlur);
			clearTimeout(tip.noteTimer);
			hideTip(true);
			for (const el of document.querySelectorAll("[" + HIDE_ATTR + "]")) el.removeAttribute(HIDE_ATTR);
			for (const el of document.querySelectorAll("[" + BTN_ATTR + "],[" + CARD_ATTR + "],[data-t3enh-tip]")) el.remove();
		},
	};
	send({ action: "hello" });
} catch (error) {
	window.__t3EnhancedError = String((error && error.stack) || error);
}
})();
