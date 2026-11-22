// T3 Code local main-process hook.
//
// The app.asar "localcss" patch (lib\patch-app-asar.ps1 in T3 Code Enhanced) calls
// this file with the main BrowserWindow on every page load of the main window. It lives outside the install folder, so T3 updates keep it;
// the patch guard puts the one-line call back after each update.
//
// What it does, driven by ~/.t3/local-patches.json:
//   localUiCss: true        inject ~/.t3/local-ui.css, then ~/.t3/local-ui.d/*.css (name order)
//   windowMaterial: "windhawk" | "acrylic" | "mica" | "tabbed" | "none"
//                           Windows 11 backdrop behind the whole window. "windhawk" leaves
//                           the backdrop to the Translucent Windows Plus rule for this exe
//                           (the house Mocha acrylic, also kept when the window is unfocused). The window
//                           background becomes transparent (T3 re-applies its own color
//                           on every theme change, so that call is pinned too) and
//                           <html data-window-material="..."> tells the CSS to let it through.
//   versionBadge: true      (default; false turns it off) inject local-version-badge.js: the
//                           app version after "Nightly" in the sidebar header, plus a switch
//                           in Settings > General to hide it again (localStorage t3local.showVersion)
//   glassMenus: true        (default) right-click menus drawn as glass panels in the page
//                           (local-glass-menu.js) instead of native Windows menus
//   settingsUi: true        (default) Settings > Appearance > Local add-ons card (local-settings-ui.js)
//   browserAppearance: "dark" | "light" | "system"
//                           default theme for pages in the built-in browser, see installBrowserAppearance();
//                           with "dark", pages that have no dark theme of their own are darkened by Chromium
//   sharedSignIns: ["tailscale.com"]
//                           (default none) sign-in cookies of these sites are shared by every built-in browser
//                           store, so one sign-in works in every thread, see installSharedSignIns()
//   evalBridge: true       (off by default) agent debug channel, see startEvalBridge()
//   appIcon: "riced" | "original"
//                           (default riced) the app icon everywhere: window, taskbar, shortcuts, the sidebar logo,
//                           and the program file after T3 closes, see local-app-icon.cjs
// Edits here load at the next window reload. Errors are written to ~/.t3/local-main.log.

const fs = require("fs");
const os = require("os");
const path = require("path");

const dir = path.join(os.homedir(), ".t3");
const MATERIALS = new Set(["windhawk", "acrylic", "mica", "tabbed"]);
const APP_ICONS = new Set(["riced", "original"]);

function appIconModule() {
	const file = path.join(dir, "local-app-icon.cjs");
	delete require.cache[file];
	return require(file);
}

function log(text) {
	try {
		fs.appendFileSync(path.join(dir, "local-main.log"), `${new Date().toISOString()} ${text}\n`);
	} catch {}
}

function readConfig() {
	try {
		// Windows PowerShell 5.1 saves UTF-8 with a byte-order mark, which JSON.parse rejects.
		const raw = fs.readFileSync(path.join(dir, "local-patches.json"), "utf8");
		return JSON.parse(raw.charCodeAt(0) === 0xfeff ? raw.slice(1) : raw);
	} catch (error) {
		log(`config unreadable: ${error.message}`);
		return {};
	}
}

function cssFiles() {
	return [path.join(dir, "local-ui.css"), ...layerFiles(".css")].filter((file) => fs.existsSync(file));
}

function layerFiles(ext) {
	try {
		const extra = path.join(dir, "local-ui.d");
		return fs.readdirSync(extra).sort().filter((name) => name.endsWith(ext)).map((name) => path.join(extra, name));
	} catch {
		return [];
	}
}

// 2026-11-21: T3 draws its own top bar 52px tall but asks Windows for 40px caption buttons, so the
// minimize/maximize/close glyphs sat higher than the panel toggles beside them (the top bar is inset ~8px, so
// its middle is at y=34). Ask for 68px so the glyphs are centred there; kept when T3 re-sends the overlay on a theme change.
const TITLEBAR_FIT_HEIGHT = 68;
function installTitleBarFit(window) {
	if (process.platform !== "win32" || typeof window.setTitleBarOverlay !== "function") return;
	if (!window.__t3LocalFitOverlay) {
		const original = window.setTitleBarOverlay.bind(window);
		window.__t3LocalFitOverlay = original;
		window.setTitleBarOverlay = (options) => {
			if (options && typeof options === "object") original({ ...options, height: TITLEBAR_FIT_HEIGHT });
			else original(options);
		};
	}
	try {
		const colors = window.__t3LocalOverlayColors || {};
		window.__t3LocalFitOverlay({ color: colors.color || "#01000000", symbolColor: colors.symbolColor || "#f8fafc", height: TITLEBAR_FIT_HEIGHT });
	} catch (error) {
		log("titleBarFit: " + error.message);
	}
}
function applyMaterial(window, material) {
	if (process.platform !== "win32" || typeof window.setBackgroundMaterial !== "function") return null;
	if (!MATERIALS.has(material)) material = "none";
	if (material !== "none" && !window.__t3LocalClearBackground) {
		// syncWindowAppearance() sets an opaque color on every theme change; keep it clear
		const setBackgroundColor = window.setBackgroundColor.bind(window);
		window.setBackgroundColor = () => setBackgroundColor("#00000000");
		window.__t3LocalClearBackground = setBackgroundColor;
	}
	if (material !== "none") window.setBackgroundColor("#00000000");
	// "windhawk" still asks Electron for acrylic: with "none" Chromium paints the page
	// on an opaque surface and the Windhawk blur only reached the title bar (2026-10-24 cold start)
	window.setBackgroundMaterial(material === "windhawk" ? "acrylic" : material);
	keepMaterial(window, material === "none" ? null : material === "windhawk" ? "acrylic" : material);
	return material === "none" ? null : material;
}

// 2026-11-14: the glass behind the window went see-through (no blur) until a reload. The wobble
// mod hides the window (DWM cloak) for every drag and shows it again without re-setting the
// backdrop, which DWM can leave stale (the window manager mod notes the same and re-sets it).
// So after a move, resize, focus, show or restore, ask for the same material again: that makes
// DWM rebuild it. Twice, because the wobble shows the window only after its landing (~0.3 s).
function keepMaterial(window, value) {
	if (window.__t3LocalKeepMaterial) {
		for (const [name, fn] of window.__t3LocalKeepMaterial) window.removeListener(name, fn);
		window.__t3LocalKeepMaterial = null;
	}
	if (!value) return;
	let timers = [];
	const reassert = () => {
		for (const t of timers) clearTimeout(t);
		timers = [450, 1400].map((ms) => setTimeout(() => {
			try {
				if (!window.isDestroyed()) window.setBackgroundMaterial(value);
			} catch (error) {
				log(`keepMaterial: ${error.message}`);
			}
		}, ms));
	};
	const events = ["moved", "resized", "focus", "show", "restore"].map((name) => [name, reassert]);
	for (const [name, fn] of events) window.on(name, fn);
	window.__t3LocalKeepMaterial = events;
	log(`keepMaterial: on (${value})`);
}

// Native context menus cannot be themed or blurred, so popups on the main window are drawn by
// local-glass-menu.js in the page instead. Menu.prototype.popup is patched once per app run; the
// hook it calls is replaced on every load, so edits here still apply at the next window reload.
function serializeMenu(items) {
	const out = [];
	items.forEach((item, i) => {
		if (item.visible === false) return;
		if (item.type === "separator") return out.push({ sep: true });
		out.push({
			i,
			label: String(item.label || ""),
			enabled: item.enabled !== false,
			checked: item.type === "checkbox" || item.type === "radio" ? !!item.checked : undefined,
			destructive: !!item.icon, // T3 marks Delete-style items with an icon and nothing else
			hint: item.accelerator ? String(item.accelerator).replace(/CommandOrControl|CmdOrCtrl/g, "Ctrl") : undefined,
			children: item.submenu ? serializeMenu(item.submenu.items) : undefined,
		});
	});
	return out;
}

function installGlassMenus(mainWindow) {
	const { Menu } = require("electron");
	mainWindow.__t3GlassMenus = true;
	if (!Menu.prototype.__t3GlassOriginalPopup) {
		const original = Menu.prototype.popup;
		Menu.prototype.__t3GlassOriginalPopup = original;
		Menu.prototype.popup = function (options) {
			const hook = globalThis.__t3GlassMenuHook;
			try {
				if (hook && hook(this, options || {})) return;
			} catch (error) {
				log(`glassMenus hook: ${error.message}`);
			}
			return original.call(this, options);
		};
	}
	globalThis.__t3GlassMenuHook = (menu, options) => {
		const win = options.window;
		if (!win || win.isDestroyed() || !win.__t3GlassMenus) return false;
		const items = serializeMenu(menu.items);
		if (!items.some((item) => !item.sep)) return false;
		const zoom = win.webContents.getZoomFactor() || 1;
		const pos = typeof options.x === "number" && typeof options.y === "number" ? { x: options.x / zoom, y: options.y / zoom } : null;
		const call = `window.__t3GlassMenu ? window.__t3GlassMenu.show(${JSON.stringify(items)}, ${JSON.stringify(pos)}) : "missing"`;
		win.webContents
			.executeJavaScript(call, true)
			.then((result) => {
				if (result === "missing") return Menu.prototype.__t3GlassOriginalPopup.call(menu, options);
				if (Array.isArray(result)) {
					let item = null;
					let list = menu.items;
					for (const index of result) {
						item = list[index];
						list = item && item.submenu ? item.submenu.items : [];
					}
					if (item && typeof item.click === "function") item.click({}, win, win.webContents);
				}
				if (typeof options.callback === "function") options.callback();
			})
			.catch((error) => {
				log(`glassMenus show: ${error.message}`);
				if (typeof options.callback === "function") options.callback();
			});
		return true;
	};
}

// The Enhanced update button and Settings card (local-enhanced-update.js) talk to the updater with
// console.log("T3ENH:{...}"). Like the settings listener below, each load replaces the old listener.
function installUpdater(window) {
	const file = path.join(dir, "local-enhanced-update.cjs");
	if (!fs.existsSync(file)) return;
	delete require.cache[file];
	const updater = require(file);
	const contents = window.webContents;
	for (const old of contents.listeners("console-message")) {
		if (String(old).includes("T3ENH:")) contents.removeListener("console-message", old);
	}
	contents.on("console-message", (...args) => {
		const message = args[0] && typeof args[0] === "object" && "message" in args[0] ? args[0].message : args[2];
		if (typeof message !== "string" || !message.startsWith("T3ENH:")) return;
		try {
			updater.handle(JSON.parse(message.slice(6)), window);
		} catch (error) {
			log(`updater: ${error.message}`);
		}
	});
	updater.attach(window);
	const ui = path.join(dir, "local-enhanced-update.js");
	if (fs.existsSync(ui)) contents.executeJavaScript(fs.readFileSync(ui, "utf8")).catch((error) => log(`update ui: ${error.message}`));
}

// Debug channel for agents (off unless "evalBridge": true): a script dropped at
// ~/.t3/local-eval/request.js runs in the page and its JSON result lands in result.json.
function startEvalBridge(mainWindow) {
	const folder = path.join(dir, "local-eval");
	clearInterval(mainWindow.__t3EvalTimer);
	mainWindow.__t3EvalTimer = setInterval(() => {
		const request = path.join(folder, "request.js");
		if (mainWindow.isDestroyed()) return clearInterval(mainWindow.__t3EvalTimer);
		// cmd.json: main-process commands for the t3ui CLI (hidden copy of the app, captures).
		// The handler lives in local-ghost.cjs and is re-read per command, so it changes without a reload.
		const cmdFile = path.join(folder, "cmd.json");
		if (fs.existsSync(cmdFile)) {
			const done = (value) => fs.writeFileSync(path.join(folder, "cmd-result.json"), JSON.stringify(value, null, 1));
			let req = null;
			try {
				req = JSON.parse(fs.readFileSync(cmdFile, "utf8"));
			} catch (error) {
				done({ ok: false, error: `bad cmd.json: ${error.message}` });
			}
			try { fs.unlinkSync(cmdFile); } catch {}
			if (req) {
				try {
					const ghost = path.join(dir, "local-ghost.cjs");
					delete require.cache[ghost];
					Promise.resolve(require(ghost)(mainWindow, req, { dir, cssFiles, layerFiles, readConfig, log }))
						.then((value) => done({ ok: true, id: req.id, at: new Date().toISOString(), value }))
						.catch((error) => done({ ok: false, id: req.id, at: new Date().toISOString(), error: String((error && error.message) || error) }));
				} catch (error) {
					done({ ok: false, id: req.id, error: String(error && error.message) });
				}
			}
		}
		if (!fs.existsSync(request)) return;
		let code = "";
		try {
			code = fs.readFileSync(request, "utf8");
			fs.unlinkSync(request);
		} catch {
			return;
		}
		const write = (value) => fs.writeFileSync(path.join(folder, "result.json"), JSON.stringify(value, null, 1));
		mainWindow.webContents
			.executeJavaScript(code, true)
			.then((value) => write({ ok: true, at: new Date().toISOString(), value }))
			.catch((error) => write({ ok: false, at: new Date().toISOString(), error: String(error && error.message) }));
	}, 1000);
}

// Default theme for pages in T3's built-in browser. T3 attaches its own debugger to every <webview>
// tab but only sends prefers-color-scheme when the tab's Appearance menu is not "System", so new tabs
// follow nativeTheme and usually open light. With browserAppearance "light" or "dark", that value is
// sent whenever T3 would send or skip "System"; a tab set to Light or Dark in its own menu keeps it.
// Each webview tab's Debugger is wrapped once per process; state lives on global because this module is
// re-required on every window load.
// Dark pages: prefers-color-scheme only changes pages that ship a dark theme (Tailscale's admin does not),
// so when a tab's final scheme is "dark" Chromium's auto dark mode (CDP Emulation.setAutoDarkModeOverride)
// is switched on as well. Chromium leaves pages that declare a dark color-scheme alone; pages that are
// already dark without declaring it (AdGuard Home) are detected by their painted background and skipped.
const SCHEMES = new Set(["light", "dark"]);

// The theme is Mocha, a dark theme. T3 copies its Appearance choice onto nativeTheme.themeSource, and
// its default "System" follows Windows, so on a PC set to light mode T3 opened light over a light,
// see-through backdrop: grey with faint text (seen in the test PC 2026-11-22). "System" now means dark;
// an explicit Light choice in T3's settings is kept. Wrapped once per process.
function pinDarkTheme() {
	const { nativeTheme } = require("electron");
	if (global.__t3PinDark) return;
	let desc;
	for (let proto = nativeTheme; proto && !desc; proto = Object.getPrototypeOf(proto)) desc = Object.getOwnPropertyDescriptor(proto, "themeSource");
	if (!desc || !desc.get || !desc.set) return;
	Object.defineProperty(nativeTheme, "themeSource", {
		configurable: true,
		enumerable: desc.enumerable,
		get() {
			return desc.get.call(this);
		},
		set(value) {
			desc.set.call(this, value === "system" ? "dark" : value);
		},
	});
	global.__t3PinDark = true;
	if (desc.get.call(nativeTheme) !== "system") return false;
	const wasLight = !nativeTheme.shouldUseDarkColors;
	desc.set.call(nativeTheme, "dark");
	// T3's page picked light from Windows before this hook ran, and no listener re-reads it on every
	// screen (the first-run welcome page has none), so the caller reloads the page once.
	return wasLight;
}

const OWN_DARK_PROBE = `(() => {
	const cs = getComputedStyle(document.documentElement).colorScheme || "";
	const meta = (document.querySelector('meta[name="color-scheme"]') || {}).content || "";
	if (/dark/.test(cs) || /dark/.test(meta)) return true;
	const ctx = document.createElement("canvas").getContext("2d", { willReadFrequently: true });
	const light = (el) => {
		for (; el && el.nodeType === 1; el = el.parentElement) {
			ctx.clearRect(0, 0, 1, 1); ctx.fillStyle = "#000"; ctx.fillStyle = getComputedStyle(el).backgroundColor; ctx.fillRect(0, 0, 1, 1);
			const [r, g, b, a] = ctx.getImageData(0, 0, 1, 1).data;
			if (a > 128) return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255;
		}
		return null;
	};
	const l = light(document.elementFromPoint(innerWidth / 2, innerHeight / 2)) ?? light(document.body) ?? 1;
	return l < 0.35;
})()`;
function installBrowserAppearance(scheme) {
	const { app, webContents } = require("electron");
	const state = (global.__t3BrowserAppearance ||= {});
	state.orig ||= new WeakMap();
	state.attachedAt ||= new WeakMap();
	state.value ||= new WeakMap(); // debugger -> last prefers-color-scheme value sent ("", "light", "dark")
	state.dark ||= new WeakMap(); // debugger -> auto dark override currently on
	state.wcOf ||= new WeakMap();
	state.loadHooked ||= new WeakSet();
	state.scheme = SCHEMES.has(scheme) ? scheme : "system";
	state.applyDark = (wc) => {
		if (!wc || wc.isDestroyed() || !wc.debugger.isAttached()) return;
		const dbg = wc.debugger;
		const orig = state.orig.get(dbg);
		if (!orig) return;
		const set = (on) => {
			if (state.dark.get(dbg) === on) return;
			state.dark.set(dbg, on);
			orig.sendCommand.call(dbg, "Emulation.setAutoDarkModeOverride", on ? { enabled: true } : {}).catch((error) => {
				state.dark.delete(dbg);
				log(`autoDark: ${error.message}`);
			});
		};
		const value = state.value.has(dbg) ? state.value.get(dbg) : state.scheme === "system" ? "" : state.scheme;
		if (value !== "dark") return set(false);
		wc.executeJavaScriptInIsolatedWorld(1999, [{ code: OWN_DARK_PROBE }])
			.then((ownDark) => set(!ownDark))
			.catch(() => set(true));
	};
	// Electron gives every Debugger its own attach/detach/sendCommand properties, so patching the prototype
	// changes nothing. Each webview tab's debugger is wrapped once; the wrappers only call state.hooks, which
	// every window load replaces, so edits below apply at the next window reload, not the next T3 start.
	state.hooks = {
		attach(dbg, attach, args) {
			const result = attach.apply(dbg, args);
			state.attachedAt.set(dbg, Date.now());
			state.dark.delete(dbg); // a fresh attach starts with no overrides
			if (state.scheme !== "system") state.emulate(dbg);
			return result;
		},
		// T3 re-sends the tab's stored scheme right after it attaches; that value comes from its own
		// default, so it is replaced too. A later non-empty send is a choice made in the tab's menu.
		send(dbg, sendCommand, args) {
			let [method, params, ...rest] = args;
			if (method === "Emulation.setEmulatedMedia" && params && Array.isArray(params.features)) {
				const feature = params.features.find((f) => f && f.name === "prefers-color-scheme");
				if (feature) {
					const restoring = Date.now() - (state.attachedAt.get(dbg) || 0) < 2000;
					if ((restoring || feature.value === "") && state.scheme !== "system") params = { ...params, features: params.features.map((f) => (f === feature ? { ...f, value: state.scheme } : f)) };
					const value = params.features.find((f) => f && f.name === "prefers-color-scheme").value;
					state.value.set(dbg, value);
					const sent = sendCommand.call(dbg, method, params, ...rest);
					Promise.resolve(sent).then(() => state.applyDark(state.wcOf.get(dbg)), () => {});
					return sent;
				}
			}
			return sendCommand.call(dbg, method, params, ...rest);
		},
	};
	state.emulate = (dbg) => {
		const value = state.scheme === "system" ? "" : state.scheme;
		state.value.set(dbg, value);
		state.orig
			.get(dbg)
			.sendCommand.call(dbg, "Emulation.setEmulatedMedia", { features: [{ name: "prefers-color-scheme", value }] })
			.then(() => state.applyDark(state.wcOf.get(dbg)))
			.catch((error) => log(`browserAppearance emulate: ${error.message}`));
	};
	state.track = (wc) => {
		if (wc.getType() !== "webview" || wc.isDestroyed()) return;
		const dbg = wc.debugger;
		state.wcOf.set(dbg, wc);
		// re-check the page's own background on every page load (SPAs paint late, so twice more after load)
		if (!state.loadHooked.has(wc)) {
			state.loadHooked.add(wc);
			wc.on("dom-ready", () => state.applyDark && state.applyDark(wc));
			wc.on("did-finish-load", () => {
				for (const delay of [0, 1500, 4000]) setTimeout(() => state.applyDark && state.applyDark(wc), delay);
			});
		}
		if (state.orig.has(dbg)) return;
		const orig = { attach: dbg.attach, sendCommand: dbg.sendCommand };
		state.orig.set(dbg, orig);
		dbg.attach = (...args) => state.hooks.attach(dbg, orig.attach, args);
		dbg.sendCommand = (...args) => state.hooks.send(dbg, orig.sendCommand, args);
	};
	if (!state.listening) {
		app.on("web-contents-created", (_event, wc) => state.track(wc));
		state.listening = true;
	}
	for (const wc of webContents.getAllWebContents()) state.track(wc);
	// apply to open tabs now, so a change in Settings shows without reopening them
	for (const wc of webContents.getAllWebContents()) {
		if (wc.getType() === "webview" && !wc.isDestroyed() && wc.debugger.isAttached()) state.emulate(wc.debugger);
	}
}

// Shared sign-ins for the built-in browser. T3 keeps one persistent cookie store per environment
// (persist:t3code-preview-<sha256(environmentId)[0..20]>), so a sign-in made in a laptop thread's browser
// was missing in a tower thread's browser and Tailscale sent it back to its login page. Cookies of the
// sites in local-patches.json "sharedSignIns" (default none) are copied into every
// default-profile store at each window load and mirrored live, sign-outs included. Stores are flushed so
// it survives a T3 restart. Cookie values are never logged. Session objects outlive window reloads, so
// each gets one listener that calls state.onChanged, which every load replaces.
function installSharedSignIns(list) {
	const { app, session } = require("electron");
	const state = (global.__t3SharedSignIns ||= { hooked: new WeakSet(), echo: new Map() });
	const domains = (Array.isArray(list) ? list : []).map((d) => String(d).toLowerCase().replace(/^\./, "")).filter(Boolean);
	if (!domains.length) {
		state.onChanged = () => {};
		return;
	}
	const STORE = /^t3code-preview-[0-9a-f]{20}$/;
	const matches = (domain) => {
		const host = String(domain || "").toLowerCase().replace(/^\./, "");
		return domains.some((d) => host === d || host.endsWith(`.${d}`));
	};
	const id = (c) => `${c.domain}|${c.path}|${c.name}`;
	const url = (c) => `https://${String(c.domain).replace(/^\./, "")}${c.path || "/"}`;
	const details = (c) => {
		const d = { url: url(c), name: c.name, value: c.value, path: c.path || "/", secure: c.secure, httpOnly: c.httpOnly, sameSite: c.sameSite };
		if (!c.hostOnly) d.domain = c.domain;
		if (!c.session && c.expirationDate) d.expirationDate = c.expirationDate;
		return d;
	};
	// a write we make fires "changed" in the target store; that echo must not be mirrored back
	const expect = (s, key) => state.echo.set(`${s.storagePath}|${key}`, Date.now());
	const isEcho = (s, key) => {
		const k = `${s.storagePath}|${key}`;
		const at = state.echo.get(k);
		state.echo.delete(k);
		return at !== undefined && Date.now() - at < 5000;
	};
	const stores = () => {
		let names = [];
		try {
			names = fs.readdirSync(path.join(app.getPath("userData"), "Partitions")).filter((n) => STORE.test(n));
		} catch {}
		return names.map((n) => session.fromPartition(`persist:${n}`));
	};
	const flush = (s) => s.cookies.flushStore().catch(() => {});
	state.onChanged = (s, cookie, cause, removed) => {
		if (!matches(cookie.domain)) return;
		// the removal half of an overwrite (ours or the site's) is never mirrored and must not use up the echo mark
		if (removed && cause !== "explicit" && cause !== "expired-overwrite") return;
		if (isEcho(s, id(cookie))) return;
		for (const other of stores()) {
			if (other === s) continue;
			expect(other, id(cookie));
			const done = removed ? other.cookies.remove(url(cookie), cookie.name) : other.cookies.set(details(cookie));
			done.then(() => flush(other)).catch((error) => log(`sharedSignIns mirror: ${error.message}`));
		}
	};
	const hook = (s) => {
		if (state.hooked.has(s)) return;
		state.hooked.add(s);
		s.cookies.on("changed", (_event, cookie, cause, removed) => state.onChanged(s, cookie, cause, removed));
	};
	if (!state.listening) {
		// a store created later (a new environment) is hooked and filled when T3 opens it
		app.on("session-created", (s) => {
			if (!STORE.test(path.basename(s.storagePath || ""))) return;
			hook(s);
			setTimeout(() => state.sync && state.sync(), 1000);
		});
		state.listening = true;
	}
	state.sync = async () => {
		const all = stores();
		all.forEach(hook);
		// get({ domain }) skips host-only cookies on subdomains (login.tailscale.com's sign-in), so read all and filter here
		const have = await Promise.all(all.map(async (s) => (await s.cookies.get({})).filter((c) => matches(c.domain))));
		const best = new Map(); // newest copy of each cookie, by expiry
		for (const cookies of have) for (const c of cookies) {
			const cur = best.get(id(c));
			if (!cur || (c.expirationDate || Infinity) > (cur.expirationDate || Infinity)) best.set(id(c), c);
		}
		let writes = 0;
		await Promise.all(
			all.map(async (s, i) => {
				const mine = new Map(have[i].map((c) => [id(c), c]));
				let changed = false;
				for (const [key, c] of best) {
					const own = mine.get(key);
					if (own && own.value === c.value && Math.abs((own.expirationDate || 0) - (c.expirationDate || 0)) < 60) continue;
					expect(s, key);
					try {
						await s.cookies.set(details(c));
						writes++;
						changed = true;
					} catch (error) {
						log(`sharedSignIns set ${c.name}@${c.domain}: ${error.message}`);
					}
				}
				if (changed) await flush(s);
			}),
		);
		log(`sharedSignIns: ${best.size} cookies for ${domains.join(",")} across ${all.length} stores, ${writes} copied`);
	};
	state.sync().catch((error) => log(`sharedSignIns: ${error.message}`));
}

// The Local add-ons card in Settings > Appearance (local-settings-ui.js) reports a changed switch as
// console.log("T3LOCAL:{key,value}"). Only keys listed here are accepted. nativeTitleBar also needs the
// app.asar patch re-run, which happens in a detached pwsh so the app never waits on it.
const SETTING_KEYS = new Set(["glassMenus", "nativeTitleBar"]);
const PWSH = path.join(process.env.LOCALAPPDATA || "", "Microsoft/WindowsApps/Microsoft.PowerShell_8wekyb3d8bbwe/pwsh.exe");
function listenForSettings(window) {
	// The BrowserWindow outlives window reloads, and a listener closes over the module that added it. So each
	// load removes every earlier settings listener (ours or from an older copy of this file, found by its
	// "T3LOCAL:" marker) before adding its own; edits here then apply at the next window reload.
	const contents = window.webContents;
	for (const old of contents.listeners("console-message")) {
		if (String(old).includes("T3LOCAL:")) contents.removeListener("console-message", old);
	}
	contents.on("console-message", (...args) => {
		const message = args[0] && typeof args[0] === "object" && "message" in args[0] ? args[0].message : args[2];
		if (typeof message !== "string" || !message.startsWith("T3LOCAL:")) return;
		try {
			const { key, value } = JSON.parse(message.slice(8));
			const valid =
				key === "browserAppearance" ? SCHEMES.has(value) || value === "system" : key === "appIcon" ? APP_ICONS.has(value) : SETTING_KEYS.has(key) && typeof value === "boolean";
			if (!valid) return;
			const config = readConfig();
			config[key] = value;
			fs.writeFileSync(path.join(dir, "local-patches.json"), JSON.stringify(config, null, "\t") + "\n");
			log(`setting ${key}=${value}`);
			if (key === "glassMenus") window.__t3GlassMenus = value;
			if (key === "browserAppearance") installBrowserAppearance(value);
			if (key === "appIcon") appIconModule().apply(window, config, log);
			if (key === "nativeTitleBar") {
				const script = "H:/System Configuration/scripts/2026-10-24-t3-app-asar-patcher.ps1";
				require("child_process").spawn(PWSH, ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script, "-Apply"], { detached: true, stdio: "ignore", windowsHide: true }).unref();
			}
		} catch (error) {
			log(`setting write: ${error.message}`);
		}
	});
}

// Rendered reply cards and HTML previews sit in sandboxed frames that the theme CSS cannot reach, so
// their selected text kept Chromium's default bright blue. Each such frame gets the same Mocha blue
// highlight as the app (rgb(137 180 250 / .32)) when it loads. Listener marker: "T3SEL".
const FRAME_SELECTION_CSS = "::selection{background-color:rgb(137 180 250 / 0.32) !important}";
function installFrameSelection(window) {
	const { webFrameMain } = require("electron");
	const contents = window.webContents;
	const paint = (frame) => {
		if (!frame || frame === contents.mainFrame || !/\/api\/assets\//.test(frame.url || "")) return;
		// a constructed sheet, so a strict style-src policy in the frame cannot block it
		const code = `(()=>{/*T3SEL*/if(window.__t3sel)return;window.__t3sel=1;const s=new CSSStyleSheet();s.replaceSync(${JSON.stringify(FRAME_SELECTION_CSS)});document.adoptedStyleSheets=[...document.adoptedStyleSheets,s]})()`;
		frame.executeJavaScript(code).then(() => log("frameSelection: card frame painted")).catch((error) => log(`frameSelection: ${error.message}`));
	};
	for (const old of contents.listeners("did-frame-finish-load")) {
		if (String(old).includes("T3SEL")) contents.removeListener("did-frame-finish-load", old);
	}
	contents.on("did-frame-finish-load", (_event, isMainFrame, processId, routingId) => {
		/* T3SEL */
		if (isMainFrame) return;
		try {
			paint(webFrameMain.fromId(processId, routingId));
		} catch {}
	});
	for (const frame of contents.mainFrame.framesInSubtree) paint(frame);
}

module.exports = function onMainWindowLoad(window) {
	// the patch require()s this file on every load; dropping it from the cache makes
	// edits here apply at the next window reload instead of the next T3 start
	delete require.cache[__filename];
	const config = readConfig();
	const contents = window.webContents;
	// before the layers, so the sidebar logo script finds self.T3ICON on its first pass
	try {
		appIconModule().apply(window, config, log);
	} catch (error) {
		log(`appIcon: ${error.message}`);
	}
	if (config.localUiCss === true) {
		for (const file of cssFiles()) {
			try {
				contents.insertCSS(fs.readFileSync(file, "utf8")).catch((error) => log(`insertCSS ${file}: ${error.message}`));
			} catch (error) {
				log(`read ${file}: ${error.message}`);
			}
		}
		// local-ui.d/*.js: small DOM add-ons that ride with the CSS layers (85-title-nav.js)
		for (const file of layerFiles(".js")) {
			try {
				contents.executeJavaScript(fs.readFileSync(file, "utf8")).catch((error) => log(`layer ${file}: ${error.message}`));
			} catch (error) {
				log(`read ${file}: ${error.message}`);
			}
		}
	}
	if (config.versionBadge !== false) {
		try {
			const script = fs.readFileSync(path.join(dir, "local-version-badge.js"), "utf8").replace("__T3_VERSION__", JSON.stringify(require("electron").app.getVersion()));
			contents.executeJavaScript(script).catch((error) => log(`versionBadge: ${error.message}`));
			setTimeout(() => {
				contents
					.executeJavaScript("JSON.stringify({state: window.__t3LocalVersionBadge && window.__t3LocalVersionBadge.state, error: window.__t3LocalVersionBadgeError})")
					.then((state) => log(`versionBadge state ${state}`))
					.catch(() => {});
			}, 6000);
		} catch (error) {
			log(`versionBadge: ${error.message}`);
		}
	}
	if (config.settingsUi !== false) {
		try {
			const script = fs.readFileSync(path.join(dir, "local-settings-ui.js"), "utf8").replace("__T3_CONFIG__", () => JSON.stringify(config));
			contents.executeJavaScript(script).catch((error) => log(`settingsUi: ${error.message}`));
			listenForSettings(window);
		} catch (error) {
			log(`settingsUi: ${error.message}`);
		}
	}
	if (config.glassMenus !== false) {
		try {
			contents.executeJavaScript(fs.readFileSync(path.join(dir, "local-glass-menu.js"), "utf8")).catch((error) => log(`glassMenus: ${error.message}`));
			installGlassMenus(window);
		} catch (error) {
			log(`glassMenus: ${error.message}`);
		}
	} else window.__t3GlassMenus = false;
	try {
		installUpdater(window);
	} catch (error) {
		log(`updater: ${error.message}`);
	}
	if (config.evalBridge === true) startEvalBridge(window);
	try {
		if (pinDarkTheme()) {
			log("pinDark: Windows is in light mode; reloading once in dark");
			contents.reload();
			return;
		}
	} catch (error) {
		log(`pinDark: ${error.message}`);
	}
	try {
		installBrowserAppearance(config.browserAppearance);
	} catch (error) {
		log(`browserAppearance: ${error.message}`);
	}
	try {
		installSharedSignIns(config.sharedSignIns);
	} catch (error) {
		log(`sharedSignIns: ${error.message}`);
	}
	try {
		installFrameSelection(window);
	} catch (error) {
		log(`frameSelection: ${error.message}`);
	}
	try {
		installTitleBarFit(window);
	} catch (error) {
		log(`titleBarFit: ${error.message}`);
	}
	let material = null;
	try {
		material = applyMaterial(window, config.windowMaterial);
	} catch (error) {
		log(`material: ${error.message}`);
	}
	const flag = material ? `document.documentElement.dataset.windowMaterial=${JSON.stringify(material)}` : "delete document.documentElement.dataset.windowMaterial";
	// accountNames: { email: name } labels the Limits popover rows (server.asar usageaccounts patch)
	const names = `self.T3N=${JSON.stringify(config.accountNames || {})}`;
	contents.executeJavaScript(`${flag};${names};0`).catch((error) => log(`flag: ${error.message}`));
};
