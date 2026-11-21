// T3 Code app icon switch (2026-11-22): Riced (Mocha tile) or Original.
//
// Called from local-main.cjs on every main-window load and when the Local add-ons
// card sends appIcon. config.appIcon: "riced" (default) | "original".
//   - window and taskbar button: BrowserWindow.setIcon
//   - Start, pinned taskbar and desktop shortcuts: their icon points at ~/.t3/icons/<pick>.ico
//   - sidebar logo: self.T3ICON (a data URL) plus <html data-t3-app-icon>, drawn by 99-pass15b.js
//   - the program file itself: rewritten by local-app-icon-swap.ps1 after T3 has fully closed,
//     never while it runs (Electron starts its helpers from the same file). An update replaces
//     the file, so the next close swaps it again. ~/.t3/icons/exe-state.json remembers which
//     icon the file carries, keyed by its size and time.
const fs = require("fs");
const os = require("os");
const path = require("path");

const dir = path.join(os.homedir(), ".t3");
const iconsDir = path.join(dir, "icons");
const FILES = { riced: "T3-Mocha", original: "T3-Original" };
// Shortcut names: the program file's own name plus the stable and Nightly names T3 installs.
const NAMES = [...new Set([path.basename(process.execPath, ".exe"), "T3 Code", "T3 Code (Nightly)"])];
const SHORTCUTS = NAMES.flatMap((name) => [
	path.join(process.env.APPDATA || "", `Microsoft/Windows/Start Menu/Programs/${name}.lnk`),
	path.join(process.env.APPDATA || "", `Microsoft/Internet Explorer/Quick Launch/User Pinned/TaskBar/${name}.lnk`),
	path.join(os.homedir(), `Desktop/${name}.lnk`),
]);

const pickOf = (config) => (config && config.appIcon === "original" ? "original" : "riced");
const icoOf = (pick) => path.join(iconsDir, FILES[pick] + ".ico");

// self.T3ICONS holds both pictures for the Settings picker; self.T3ICON is the picked one.
function pageScript(pick) {
	const icons = {};
	for (const [name, file] of Object.entries(FILES)) icons[name] = "data:image/png;base64," + fs.readFileSync(path.join(iconsDir, file + "-128.png")).toString("base64");
	return `(()=>{self.T3ICONS=${JSON.stringify(icons)};self.T3ICON=self.T3ICONS[${JSON.stringify(pick)}];document.documentElement.dataset.t3AppIcon=${JSON.stringify(pick)};window.__t3BrandIcon&&window.__t3BrandIcon.refresh();window.__t3IconPicker&&window.__t3IconPicker(${JSON.stringify(pick)});})();0`;
}

function refreshIconCache(log) {
	try {
		const exe = path.join(process.env.SystemRoot || "C:/Windows", "System32/ie4uinit.exe");
		require("child_process").spawn(exe, ["-show"], { detached: true, stdio: "ignore", windowsHide: true }).unref();
	} catch (error) {
		log(`appIcon cache: ${error.message}`);
	}
}

function updateShortcuts(pick, log) {
	const { shell } = require("electron");
	const ico = icoOf(pick);
	let changed = 0;
	for (const lnk of SHORTCUTS) {
		try {
			if (!fs.existsSync(lnk)) continue;
			const now = shell.readShortcutLink(lnk);
			if (now.icon && path.resolve(now.icon).toLowerCase() === ico.toLowerCase() && (now.iconIndex || 0) === 0) continue;
			if (shell.writeShortcutLink(lnk, "update", { icon: ico, iconIndex: 0 })) changed++;
			else log(`appIcon shortcut not written: ${lnk}`);
		} catch (error) {
			log(`appIcon shortcut ${lnk}: ${error.message}`);
		}
	}
	return changed;
}

// Which icon the program file carries now. A file that no longer matches the saved size and time
// was replaced by an update, which always ships the original icon.
function exeIcon(exe) {
	try {
		const st = fs.statSync(exe);
		const raw = fs.readFileSync(path.join(iconsDir, "exe-state.json"), "utf8");
		const saved = JSON.parse(raw.charCodeAt(0) === 0xfeff ? raw.slice(1) : raw);
		if (saved.size === st.size && Math.abs(saved.mtimeMs - st.mtimeMs) < 2) return saved.choice;
	} catch {}
	return "original";
}

// At quit: if the program file's icon differs from the pick, start the swap helper. It waits until
// every T3 process is gone. Listener marker "T3ICONQUIT" so a reload replaces the old listener.
function installQuitSwap(log) {
	const { app } = require("electron");
	for (const old of app.listeners("will-quit")) {
		if (String(old).includes("T3ICONQUIT")) app.removeListener("will-quit", old);
	}
	app.on("will-quit", () => {
		/* T3ICONQUIT */
		try {
			const config = JSON.parse(fs.readFileSync(path.join(dir, "local-patches.json"), "utf8").replace(/^\uFEFF/, ""));
			const pick = pickOf(config);
			const exe = process.execPath;
			if (exeIcon(exe) === pick) return;
			const st = fs.statSync(exe);
			const ps = path.join(process.env.SystemRoot || "C:/Windows", "System32/WindowsPowerShell/v1.0/powershell.exe");
			const args = ["-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", path.join(dir, "local-app-icon-swap.ps1"),
				"-Exe", exe, "-Ico", icoOf(pick), "-Choice", pick, "-Size", String(st.size), "-MtimeMs", String(st.mtimeMs)];
			require("child_process").spawn(ps, args, { detached: true, stdio: "ignore", windowsHide: true }).unref();
			log(`appIcon: program file swap to ${pick} queued for after quit`);
		} catch (error) {
			log(`appIcon quit: ${error.message}`);
		}
	});
}

function apply(window, config, log) {
	const pick = pickOf(config);
	try {
		window.setIcon(icoOf(pick));
	} catch (error) {
		log(`appIcon window: ${error.message}`);
	}
	window.webContents.executeJavaScript(pageScript(pick)).catch((error) => log(`appIcon page: ${error.message}`));
	const changed = updateShortcuts(pick, log);
	if (changed) {
		log(`appIcon: ${changed} shortcut(s) now ${pick}`);
		refreshIconCache(log);
	}
	installQuitSwap(log);
	return pick;
}

module.exports = { apply, pageScript, pickOf, exeIcon, SHORTCUTS };
