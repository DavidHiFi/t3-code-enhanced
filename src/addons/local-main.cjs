// T3 Code Enhanced: main-process hook.
//
// The app.asar "localcss" patch (lib/patch-app-asar.ps1) calls this file with the main
// BrowserWindow on every page load of the main window. It lives outside the install folder,
// so T3 updates keep it; the guard task puts the one-line call back after each update.
//
// What it does, driven by ~/.t3/local-patches.json:
//   localUiCss: true        inject ~/.t3/local-ui.css, then ~/.t3/local-ui.d/*.css (name order)
//   windowMaterial: "acrylic" | "mica" | "tabbed" | "windhawk" | "none"
//                           Windows 11 backdrop behind the whole window. "windhawk" leaves the
//                           backdrop color to a Windhawk Translucent Windows rule for this exe.
//                           The window background becomes transparent (T3 re-applies its own
//                           color on every theme change, so that call is pinned too) and
//                           <html data-window-material="..."> tells the CSS to let it through.
//   versionBadge: true      (default; false turns it off) inject local-version-badge.js: the
//                           app version after the channel label (Nightly, Beta) in the sidebar
//                           header, plus a switch in Settings > General to hide it again
//                           (localStorage t3local.showVersion)
//   glassMenus: true        (default) right-click menus drawn as glass panels in the page
//                           (local-glass-menu.js) instead of native Windows menus
//   settingsUi: true        (default) Settings > Appearance > Local add-ons card (local-settings-ui.js)
//   browserAppearance: "dark" | "light" | "system"
//                           default theme for pages in the built-in browser, see installBrowserAppearance()
// Edits here load at the next window reload. Errors are written to ~/.t3/local-main.log.

const fs = require("fs");
const os = require("os");
const path = require("path");

const dir = path.join(os.homedir(), ".t3");
const MATERIALS = new Set(["windhawk", "acrylic", "mica", "tabbed"]);

function log(text) {
	try {
		fs.appendFileSync(path.join(dir, "local-main.log"), `${new Date().toISOString()} ${text}\n`);
	} catch {}
}

function readConfig() {
	try {
		return JSON.parse(fs.readFileSync(path.join(dir, "local-patches.json"), "utf8"));
	} catch (error) {
		log(`config unreadable: ${error.message}`);
		return {};
	}
}

function cssFiles() {
	const files = [path.join(dir, "local-ui.css")];
	try {
		const extra = path.join(dir, "local-ui.d");
		for (const name of fs.readdirSync(extra).sort()) if (name.endsWith(".css")) files.push(path.join(extra, name));
	} catch {}
	return files.filter((file) => fs.existsSync(file));
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
	return material === "none" ? null : material;
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

// Default theme for pages in T3's built-in browser. T3 attaches its own debugger to every <webview>
// tab but only sends prefers-color-scheme when the tab's Appearance menu is not "System", so new tabs
// follow nativeTheme and usually open light. With browserAppearance "light" or "dark", that value is
// sent whenever T3 would send or skip "System"; a tab set to Light or Dark in its own menu keeps it.
// Each webview tab's Debugger is wrapped once per process; state lives on global because this module is
// re-required on every window load.
const SCHEMES = new Set(["light", "dark"]);
function installBrowserAppearance(scheme) {
	const { app, webContents } = require("electron");
	const state = (global.__t3BrowserAppearance ||= {});
	state.orig ||= new WeakMap();
	state.attachedAt ||= new WeakMap();
	state.scheme = SCHEMES.has(scheme) ? scheme : "system";
	// Electron gives every Debugger its own attach/detach/sendCommand properties, so patching the prototype
	// changes nothing. Each webview tab's debugger is wrapped once; the wrappers only call state.hooks, which
	// every window load replaces, so edits below apply at the next window reload, not the next T3 start.
	state.hooks = {
		attach(dbg, attach, args) {
			const result = attach.apply(dbg, args);
			state.attachedAt.set(dbg, Date.now());
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
				}
			}
			return sendCommand.call(dbg, method, params, ...rest);
		},
	};
	state.emulate = (dbg) => {
		state.orig
			.get(dbg)
			.sendCommand.call(dbg, "Emulation.setEmulatedMedia", { features: [{ name: "prefers-color-scheme", value: state.scheme === "system" ? "" : state.scheme }] })
			.catch((error) => log(`browserAppearance emulate: ${error.message}`));
	};
	state.track = (wc) => {
		if (wc.getType() !== "webview" || wc.isDestroyed() || state.orig.has(wc.debugger)) return;
		const dbg = wc.debugger;
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

// The Local add-ons card in Settings > Appearance (local-settings-ui.js) reports a changed switch as
// console.log("T3LOCAL:{key,value}"). Only keys listed here are accepted. nativeTitleBar also needs the
// app.asar patch re-run, which happens in a detached pwsh so the app never waits on it.
const SETTING_KEYS = new Set(["glassMenus", "nativeTitleBar"]);
const PATCHER = path.join(process.env.LOCALAPPDATA || "", "T3CodeEnhanced", "lib", "patch-app-asar.ps1");
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
			const valid = key === "browserAppearance" ? SCHEMES.has(value) || value === "system" : SETTING_KEYS.has(key) && typeof value === "boolean";
			if (!valid) return;
			const config = readConfig();
			config[key] = value;
			fs.writeFileSync(path.join(dir, "local-patches.json"), JSON.stringify(config, null, "\t") + "\n");
			log(`setting ${key}=${value}`);
			if (key === "glassMenus") window.__t3GlassMenus = value;
			if (key === "browserAppearance") installBrowserAppearance(value);
			if (key === "nativeTitleBar") {
				if (fs.existsSync(PATCHER)) {
					require("child_process").spawn("pwsh.exe", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", PATCHER, "-Apply"], { detached: true, stdio: "ignore", windowsHide: true }).unref();
				} else log("nativeTitleBar: patch-app-asar.ps1 not installed; switch saved, run install.ps1 to apply it");
			}
		} catch (error) {
			log(`setting write: ${error.message}`);
		}
	});
}

module.exports = function onMainWindowLoad(window) {
	// the patch require()s this file on every load; dropping it from the cache makes
	// edits here apply at the next window reload instead of the next T3 start
	delete require.cache[__filename];
	const config = readConfig();
	const contents = window.webContents;
	if (config.localUiCss === true) {
		for (const file of cssFiles()) {
			try {
				contents.insertCSS(fs.readFileSync(file, "utf8")).catch((error) => log(`insertCSS ${file}: ${error.message}`));
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
		installBrowserAppearance(config.browserAppearance);
	} catch (error) {
		log(`browserAppearance: ${error.message}`);
	}
	let material = null;
	try {
		material = applyMaterial(window, config.windowMaterial);
	} catch (error) {
		log(`material: ${error.message}`);
	}
	const flag = material ? `document.documentElement.dataset.windowMaterial=${JSON.stringify(material)}` : "delete document.documentElement.dataset.windowMaterial";
	contents.executeJavaScript(`${flag};0`).catch((error) => log(`flag: ${error.message}`));
};
