import { spawnSync } from "node:child_process";
import { existsSync, renameSync, rmSync } from "node:fs";
const RESET = "\x1b[0m";
const COLORS = {
    red: "\x1b[31m",
    yellow: "\x1b[33m",
    blue: "\x1b[34m",
    green: "\x1b[32m",
    dim: "\x1b[2m",
    bold: "\x1b[1m",
};
const useColor = process.stdout.isTTY && !process.env.NO_COLOR;
export function color(c, s) {
    return useColor ? `${COLORS[c]}${s}${RESET}` : s;
}
/** Run a command, capturing output. Never throws on non-zero exit. */
export function run(cmd, args, opts = {}) {
    const res = spawnSync(cmd, args, {
        encoding: "utf-8",
        maxBuffer: 64 * 1024 * 1024,
        ...opts,
    });
    if (res.error && res.error.code === "ENOENT") {
        return { code: 127, stdout: "", stderr: `command not found: ${cmd}` };
    }
    return {
        code: res.status ?? 1,
        stdout: res.stdout ?? "",
        stderr: res.stderr ?? "",
    };
}
export function commandExists(cmd) {
    return run("/usr/bin/which", [cmd]).code === 0;
}
export function info(msg) {
    console.log(`${color("blue", "›")} ${msg}`);
}
export function ok(msg) {
    console.log(`${color("green", "✓")} ${msg}`);
}
export function warn(msg) {
    console.log(`${color("yellow", "!")} ${msg}`);
}
export function fail(msg) {
    console.error(`${color("red", "✗")} ${msg}`);
}
/**
 * Move a bundle/dir to `dest`, leaving NO copy behind. A same-volume rename is
 * instant and preserves the code signature untouched; across volumes (EXDEV) we
 * ditto-copy then delete the source, so the end state is still a single moved app.
 */
export function moveBundle(src, dest) {
    if (existsSync(dest))
        rmSync(dest, { recursive: true, force: true });
    try {
        renameSync(src, dest);
    }
    catch (e) {
        if (e.code !== "EXDEV")
            throw e;
        if (run("/usr/bin/ditto", [src, dest]).code !== 0)
            return false;
        rmSync(src, { recursive: true, force: true });
    }
    return existsSync(dest);
}
