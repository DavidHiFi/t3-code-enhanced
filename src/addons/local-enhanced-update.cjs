// T3 Code Enhanced: update checker and installer (main process).
//
// local-main.cjs requires this file on every window load. It checks the GitHub releases of
// DavidHiFi/t3-code-enhanced, tells the page (local-enhanced-update.js) what it found, and on
// request (or by itself, when "Install updates automatically" is on) runs lib\update.ps1 hidden.
// update.ps1 downloads the release zip, checks its SHA-256, and runs that release's install.ps1.
//
// Settings live in ~/.t3/local-patches.json under "enhancedUpdates":
//   check           true   look for a new release on start and every intervalHours
//   install         true   install a new release as soon as it is found
//   intervalHours   6      1, 6 or 24
// State (last check, latest release, last result) lives in
// %LOCALAPPDATA%\T3CodeEnhanced\update-state.json.
//
// The timer and the last result are kept on `global`, because this module is loaded again on
// every window reload.

const fs = require("fs");
const os = require("os");
const path = require("path");
const https = require("https");

const REPO = "DavidHiFi/t3-code-enhanced";
const t3Dir = path.join(os.homedir(), ".t3");
const installDir = path.join(process.env.LOCALAPPDATA || path.join(os.homedir(), "AppData", "Local"), "T3CodeEnhanced");
const statePath = path.join(installDir, "update-state.json");
const INTERVALS = new Set([1, 6, 24]);

function log(text) {
	try {
		fs.appendFileSync(path.join(t3Dir, "local-main.log"), `${new Date().toISOString()} update: ${text}\n`);
	} catch {}
}

function readJson(file, fallback) {
	try {
		return JSON.parse(fs.readFileSync(file, "utf8").replace(/^\uFEFF/, ""));
	} catch {
		return fallback;
	}
}

function settings() {
	const all = readJson(path.join(t3Dir, "local-patches.json"), {});
	const s = all.enhancedUpdates && typeof all.enhancedUpdates === "object" ? all.enhancedUpdates : {};
	return {
		check: s.check !== false,
		install: s.install !== false,
		intervalHours: INTERVALS.has(s.intervalHours) ? s.intervalHours : 6,
	};
}

function saveSettings(patch) {
	const file = path.join(t3Dir, "local-patches.json");
	const all = readJson(file, null);
	if (!all) return false;
	all.enhancedUpdates = { ...settings(), ...patch };
	fs.writeFileSync(file, JSON.stringify(all, null, "\t") + "\n");
	return true;
}

// "2.0.1" from "v2.0.1"; null for anything that is not a plain version
function parse(v) {
	const m = /^v?(\d+)\.(\d+)\.(\d+)$/.exec(String(v || "").trim());
	return m ? m.slice(1).map(Number) : null;
}
function newer(a, b) {
	const x = parse(a), y = parse(b);
	if (!x || !y) return false;
	for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return x[i] > y[i];
	return false;
}

function installed() {
	let version = null;
	try {
		version = fs.readFileSync(path.join(installDir, "version.txt"), "utf8").trim() || null;
	} catch {}
	// only a copy set up by install.ps1 can update itself; a hand-copied one can still check
	const canInstall = !!version && fs.existsSync(path.join(installDir, "lib", "update.ps1"));
	return { version, canInstall };
}

function getJson(url) {
	return new Promise((resolve, reject) => {
		const req = https.get(url, { headers: { "User-Agent": "t3-code-enhanced-updater", Accept: "application/vnd.github+json" }, timeout: 15000 }, (res) => {
			if (res.statusCode === 301 || res.statusCode === 302) {
				res.resume();
				return getJson(res.headers.location).then(resolve, reject);
			}
			let body = "";
			res.setEncoding("utf8");
			res.on("data", (chunk) => (body += chunk));
			res.on("end", () => {
				if (res.statusCode === 404) return reject(new Error("no releases yet"));
				if (res.statusCode === 403) return reject(new Error("GitHub asked us to slow down; trying again later"));
				if (res.statusCode !== 200) return reject(new Error(`GitHub answered ${res.statusCode}`));
				try {
					resolve(JSON.parse(body));
				} catch {
					reject(new Error("GitHub sent something unreadable"));
				}
			});
		});
		req.on("timeout", () => req.destroy(new Error("GitHub did not answer in time")));
		req.on("error", reject);
	});
}

const g = (global.__t3EnhancedUpdate ||= { state: readJson(statePath, {}), busy: null, timer: null, window: null });

function saveState(patch) {
	Object.assign(g.state, patch);
	try {
		fs.mkdirSync(installDir, { recursive: true });
		fs.writeFileSync(statePath, JSON.stringify(g.state, null, 1));
	} catch {}
	push();
}

// what the page sees
function snapshot() {
	const inst = installed();
	const s = g.state;
	return {
		installed: inst.version,
		canInstall: inst.canInstall,
		latest: s.latest || null,
		notes: s.notes || "",
		page: s.page || `https://github.com/${REPO}/releases`,
		available: !!(s.latest && inst.version && newer(s.latest, inst.version)),
		lastCheck: s.lastCheck || null,
		error: s.error || null,
		busy: g.busy,
		finish: s.finish && s.finishFor === inst.version ? s.finish : null, // "reload" | "restart" after an install
		settings: settings(),
	};
}

function push() {
	const w = g.window;
	if (!w || w.isDestroyed()) return;
	const json = JSON.stringify(snapshot());
	w.webContents.executeJavaScript(`window.__t3Enhanced && window.__t3Enhanced.set(${json})`).catch(() => {});
}

async function check(manual) {
	if (g.busy) return;
	g.busy = "checking";
	push();
	try {
		const rel = await getJson(`https://api.github.com/repos/${REPO}/releases/latest`);
		const zip = (rel.assets || []).find((a) => /^T3-Code-Enhanced-v[\d.]+\.zip$/i.test(a.name));
		const sum = (rel.assets || []).find((a) => /\.zip\.sha256$/i.test(a.name));
		g.busy = null;
		saveState({
			lastCheck: new Date().toISOString(),
			latest: String(rel.tag_name || "").replace(/^v/, "") || null,
			notes: String(rel.body || "").slice(0, 600),
			page: rel.html_url || null,
			zipUrl: zip ? zip.browser_download_url : null,
			sumUrl: sum ? sum.browser_download_url : null,
			error: null,
		});
		log(`checked: latest ${g.state.latest}, installed ${installed().version || "none"}${manual ? " (manual)" : ""}`);
		const snap = snapshot();
		if (snap.available && snap.canInstall && settings().install && !manual) install("auto");
	} catch (error) {
		g.busy = null;
		saveState({ lastCheck: new Date().toISOString(), error: error.message });
		log(`check failed: ${error.message}`);
	}
}

function pwsh() {
	// PowerShell 7 from PATH; the Store copy is reachable through its WindowsApps alias
	const candidates = [
		path.join(process.env.ProgramFiles || "C:\\Program Files", "PowerShell", "7", "pwsh.exe"),
		path.join(process.env.LOCALAPPDATA || "", "Microsoft", "WindowsApps", "pwsh.exe"),
	];
	return candidates.find((p) => fs.existsSync(p)) || "pwsh.exe";
}

function install(reason) {
	const snap = snapshot();
	if (g.busy || !snap.canInstall || !g.state.zipUrl || !g.state.sumUrl) return;
	g.busy = "installing";
	push();
	log(`installing ${g.state.latest} (${reason})`);
	const resultFile = path.join(installDir, "update-result.json");
	try {
		fs.rmSync(resultFile, { force: true });
	} catch {}
	const child = require("child_process").spawn(
		pwsh(),
		["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", path.join(installDir, "lib", "update.ps1"), "-ZipUrl", g.state.zipUrl, "-SumUrl", g.state.sumUrl, "-Version", g.state.latest, "-ResultPath", resultFile],
		{ stdio: "ignore", windowsHide: true },
	);
	child.on("error", (error) => {
		g.busy = null;
		saveState({ error: `could not start PowerShell 7: ${error.message}` });
	});
	child.on("exit", (code) => {
		g.busy = null;
		const result = readJson(resultFile, null);
		if (code === 0 && result && result.ok) {
			log(`installed ${result.version}${result.restart ? ", restart needed" : ""}`);
			saveState({ error: null, finish: result.restart ? "restart" : "reload", finishFor: result.version, installedAt: new Date().toISOString(), reason });
		} else {
			const why = (result && result.error) || `the installer stopped (exit code ${code})`;
			log(`install failed: ${why}`);
			saveState({ error: why });
		}
	});
}

function schedule() {
	clearTimeout(g.timer);
	const s = settings();
	if (!s.check) return;
	const last = Date.parse(g.state.lastCheck || "") || 0;
	const due = last + s.intervalHours * 3600e3 - Date.now();
	// at least 20 s after a window load, so start-up stays quick
	g.timer = setTimeout(() => {
		check(false).finally(schedule);
	}, Math.max(20e3, due));
	g.timer.unref && g.timer.unref();
}

// messages from the page: { action, ... }
function handle(msg, window) {
	if (!msg || typeof msg !== "object") return;
	switch (msg.action) {
		case "hello":
			push();
			break;
		case "check":
			check(true).finally(() => {
				const snap = snapshot();
				// a manual check that finds an update installs it when auto-install is on
				if (snap.available && snap.canInstall && settings().install) install("auto");
				schedule();
			});
			break;
		case "install":
			install("button");
			break;
		case "reload":
			saveState({ finish: null });
			window.webContents.reloadIgnoringCache();
			break;
		case "restart": {
			saveState({ finish: null });
			const { app } = require("electron");
			app.relaunch();
			app.quit();
			break;
		}
		case "settings": {
			const patch = {};
			if (typeof msg.check === "boolean") patch.check = msg.check;
			if (typeof msg.install === "boolean") patch.install = msg.install;
			if (INTERVALS.has(msg.intervalHours)) patch.intervalHours = msg.intervalHours;
			if (Object.keys(patch).length && saveSettings(patch)) log(`settings ${JSON.stringify(patch)}`);
			schedule();
			push();
			break;
		}
	}
}

module.exports = {
	attach(window) {
		g.window = window;
		// a stale "busy" from a window that reloaded mid-check is cleared by the check itself
		schedule();
	},
	handle,
	snapshot,
};
