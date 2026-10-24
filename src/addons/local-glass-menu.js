// Glass right-click menus for T3 Code. Loaded by ~/.t3/local-main.cjs on every window load.
// T3 shows its context menus (thread, project, message) as native Windows menus, which CSS cannot
// theme or blur. local-main.cjs hands each native popup to window.__t3GlassMenu.show(items, pos)
// instead; this draws it as a .dropdown-glass panel and resolves with the chosen item's index path
// (or null when dismissed), so main can run the original click handler.
(() => {
	if (window.__t3GlassMenu) window.__t3GlassMenu.close();

	const css = `
.t3gm{position:fixed;z-index:10050;min-width:12rem;max-width:22rem;padding:4px;border-radius:10px;
 color:var(--popover-foreground);font:13px/18px var(--font-sans,system-ui,sans-serif);outline:none;
 box-shadow:0 18px 44px -16px rgb(0 0 0/.6),0 0 0 1px rgb(255 255 255/.06) inset;user-select:none;
 max-height:calc(100vh - 8px);overflow-y:auto;overflow-x:hidden;
 opacity:0;transform:scale(.97);transition:opacity .12s ease-out,transform .12s cubic-bezier(.2,.9,.3,1)}
.t3gm[data-open]{opacity:1;transform:none}
.t3gm-item{display:flex;align-items:center;gap:8px;min-height:28px;padding:4px 10px;border-radius:6px;cursor:default;white-space:nowrap}
.t3gm-item[data-active]{background:color-mix(in srgb,var(--accent) 85%,transparent);color:var(--accent-foreground)}
.t3gm-item[aria-disabled=true]{opacity:.45}
.t3gm-item[data-destructive]{color:var(--destructive-foreground,#f38ba8)}
.t3gm-item[data-destructive][data-active]{background:color-mix(in srgb,var(--destructive,#f38ba8) 18%,transparent);color:var(--destructive-foreground,#f38ba8)}
.t3gm-label{flex:1;overflow:hidden;text-overflow:ellipsis}
.t3gm-check{width:14px;display:flex;justify-content:center;flex:none}
.t3gm-hint{color:var(--muted-foreground);font-size:12px;margin-left:16px}
.t3gm-item[data-active] .t3gm-hint{color:inherit;opacity:.75}
.t3gm-chev{width:14px;height:14px;flex:none;opacity:.7;margin-right:-4px}
.t3gm-sep{height:1px;margin:4px 8px;background:var(--border)}
@media (prefers-reduced-motion:reduce){.t3gm{transition:none;transform:none}}`;
	let style = document.getElementById("t3gm-style");
	if (!style) {
		style = document.createElement("style");
		style.id = "t3gm-style";
		document.head.appendChild(style);
	}
	style.textContent = css;

	const svg = (d) => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">${d}</svg>`;
	const CHECK = svg('<path d="M20 6 9 17l-5-5"/>');
	const CHEV = svg('<path d="m9 18 6-6-6-6"/>');

	// where the last right-click happened, for popups that do not pass a position
	let last = { x: 80, y: 80 };
	const track = (e) => (last = { x: e.clientX, y: e.clientY });
	window.removeEventListener("contextmenu", window.__t3GlassMenuTrack, true);
	window.addEventListener("contextmenu", track, true);
	window.__t3GlassMenuTrack = track;

	let session = null;

	function show(items, pos) {
		if (session) session.finish(null);
		return new Promise((resolve) => {
			const levels = []; // { el, items, rows, active, parentRow }
			const returnFocus = document.activeElement;
			let hoverTimer = 0;
			let done = false;

			const finish = (result) => {
				if (done) return;
				done = true;
				clearTimeout(hoverTimer);
				document.removeEventListener("keydown", onKey, true);
				document.removeEventListener("pointerdown", onDown, true);
				window.removeEventListener("blur", onBlur);
				window.removeEventListener("resize", onBlur);
				const hadFocus = levels.some((level) => level.el.contains(document.activeElement));
				for (const level of levels) level.el.remove();
				if (session && session.finish === finish) session = null;
				if (hadFocus && returnFocus && returnFocus.isConnected && typeof returnFocus.focus === "function") returnFocus.focus({ preventScroll: true });
				resolve(result);
			};
			session = { finish };

			const closeFrom = (depth) => {
				while (levels.length > depth) {
					const level = levels.pop();
					level.el.remove();
					if (level.parentRow) level.parentRow.removeAttribute("aria-expanded");
				}
			};

			const setActive = (depth, index) => {
				const level = levels[depth];
				if (!level) return;
				level.rows.forEach((row, i) => (i === index ? row.setAttribute("data-active", "") : row.removeAttribute("data-active")));
				level.active = index;
				if (index >= 0 && level.rows[index]) level.rows[index].scrollIntoView({ block: "nearest" });
			};

			const pathTo = (depth, index) => {
				const path = [];
				for (let d = 0; d < depth; d++) path.push(levels[d].items[levels[d].active].i);
				path.push(levels[depth].items[index].i);
				return path;
			};

			const place = (el, x, y, anchor) => {
				const r = el.getBoundingClientRect();
				const vw = window.innerWidth;
				const vh = window.innerHeight;
				let left = x;
				let top = y;
				if (anchor) {
					left = anchor.right - 2;
					top = anchor.top - 4;
					if (left + r.width > vw - 4) left = Math.max(4, anchor.left - r.width + 2);
				} else if (left + r.width > vw - 4) left = Math.max(4, x - r.width);
				if (top + r.height > vh - 4) top = anchor ? Math.max(4, vh - r.height - 4) : Math.max(4, y - r.height);
				el.style.left = `${Math.round(left)}px`;
				el.style.top = `${Math.round(top)}px`;
				el.style.transformOrigin = `${left < x ? "right" : "left"} ${top < y ? "bottom" : "top"}`;
			};

			const openLevel = (list, x, y, parentRow) => {
				const depth = levels.length;
				const el = document.createElement("div");
				el.className = "t3gm dropdown-glass";
				el.setAttribute("role", "menu");
				el.tabIndex = -1;
				const hasChecks = list.some((item) => typeof item.checked === "boolean");
				const rows = [];
				const usable = [];
				for (const item of list) {
					if (item.sep) {
						if (el.lastElementChild && !el.lastElementChild.classList.contains("t3gm-sep")) {
							const sep = document.createElement("div");
							sep.className = "t3gm-sep";
							sep.setAttribute("role", "separator");
							el.appendChild(sep);
						}
						continue;
					}
					const row = document.createElement("div");
					row.className = "t3gm-item";
					row.setAttribute("role", typeof item.checked === "boolean" ? "menuitemcheckbox" : "menuitem");
					if (typeof item.checked === "boolean") row.setAttribute("aria-checked", String(item.checked));
					if (!item.enabled) row.setAttribute("aria-disabled", "true");
					if (item.destructive) row.setAttribute("data-destructive", "");
					if (item.children) row.setAttribute("aria-haspopup", "menu");
					if (hasChecks) row.insertAdjacentHTML("beforeend", `<span class="t3gm-check">${item.checked ? CHECK.replace("<svg", '<svg width="14" height="14"') : ""}</span>`);
					const label = document.createElement("span");
					label.className = "t3gm-label";
					label.textContent = item.label;
					row.appendChild(label);
					if (item.hint) {
						const hint = document.createElement("span");
						hint.className = "t3gm-hint";
						hint.textContent = item.hint;
						row.appendChild(hint);
					}
					if (item.children) row.insertAdjacentHTML("beforeend", CHEV.replace("<svg", '<svg class="t3gm-chev"'));
					const index = rows.length;
					row.addEventListener("pointerenter", () => {
						if (done) return;
						closeFrom(depth + 1);
						setActive(depth, item.enabled ? index : -1);
						clearTimeout(hoverTimer);
						if (item.children && item.enabled) hoverTimer = setTimeout(() => openChild(depth, index), 110);
					});
					row.addEventListener("click", (e) => {
						e.preventDefault();
						activate(depth, index);
					});
					rows.push(row);
					usable.push(item);
					el.appendChild(row);
				}
				if (el.lastElementChild && el.lastElementChild.classList.contains("t3gm-sep")) el.lastElementChild.remove();
				el.addEventListener("contextmenu", (e) => e.preventDefault());
				document.body.appendChild(el);
				levels.push({ el, items: usable, rows, active: -1, parentRow });
				place(el, x, y, parentRow ? parentRow.getBoundingClientRect() : null);
				requestAnimationFrame(() => el.setAttribute("data-open", ""));
				if (depth === 0) el.focus({ preventScroll: true });
				return depth;
			};

			const openChild = (depth, index) => {
				const level = levels[depth];
				const item = level && level.items[index];
				if (!item || !item.children || done) return;
				closeFrom(depth + 1);
				level.rows[index].setAttribute("aria-expanded", "true");
				openLevel(item.children, 0, 0, level.rows[index]);
			};

			const activate = (depth, index) => {
				const item = levels[depth] && levels[depth].items[index];
				if (!item || !item.enabled) return;
				if (item.children) {
					openChild(depth, index);
					setActive(depth + 1, firstEnabled(depth + 1, 1, -1));
					return;
				}
				finish(pathTo(depth, index));
			};

			const firstEnabled = (depth, step, from) => {
				const level = levels[depth];
				if (!level) return -1;
				const n = level.items.length;
				for (let k = 1; k <= n; k++) {
					const i = (((from + step * k) % n) + n) % n;
					if (level.items[i].enabled) return i;
				}
				return -1;
			};

			const onKey = (e) => {
				const depth = levels.length - 1;
				const level = levels[depth];
				const stop = () => {
					e.preventDefault();
					e.stopPropagation();
				};
				if (e.key === "Escape") {
					stop();
					if (depth > 0) closeFrom(depth);
					else finish(null);
				} else if (e.key === "ArrowDown" || e.key === "ArrowUp") {
					stop();
					setActive(depth, firstEnabled(depth, e.key === "ArrowDown" ? 1 : -1, level.active < 0 && e.key === "ArrowUp" ? 0 : level.active));
				} else if (e.key === "Home" || e.key === "End") {
					stop();
					setActive(depth, firstEnabled(depth, e.key === "Home" ? 1 : -1, e.key === "Home" ? -1 : 0));
				} else if (e.key === "ArrowRight") {
					stop();
					if (level.active >= 0 && level.items[level.active].children) activate(depth, level.active);
				} else if (e.key === "ArrowLeft") {
					stop();
					if (depth > 0) closeFrom(depth);
				} else if (e.key === "Enter" || e.key === " ") {
					stop();
					if (level.active >= 0) activate(depth, level.active);
				} else if (e.key === "Tab") {
					stop();
				}
			};
			const onDown = (e) => {
				if (!levels.some((level) => level.el.contains(e.target))) finish(null);
			};
			const onBlur = () => finish(null);

			const at = pos && typeof pos.x === "number" ? pos : last;
			openLevel(items, at.x, at.y, null);
			document.addEventListener("keydown", onKey, true);
			document.addEventListener("pointerdown", onDown, true);
			window.addEventListener("blur", onBlur);
			window.addEventListener("resize", onBlur);
		});
	}

	window.__t3GlassMenu = { show, close: () => session && session.finish(null) };
})();
