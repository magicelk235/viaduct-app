import { color } from "./util.js";
const ORDER = ["error", "warning", "info"];
const LABEL = { error: "ERROR", warning: "WARN", info: "INFO" };
const HUE = { error: "red", warning: "yellow", info: "blue" };
export function printIssues(issues) {
    if (issues.length === 0) {
        console.log(color("green", "No compatibility issues found."));
        return;
    }
    for (const sev of ORDER) {
        const group = issues.filter((i) => i.severity === sev);
        if (group.length === 0)
            continue;
        console.log(`\n${color(HUE[sev], `${LABEL[sev]} (${group.length})`)}`);
        for (const i of group) {
            const loc = i.file ? color("dim", ` ${i.file}${i.line ? `:${i.line}` : ""}`) : "";
            const fixed = i.autoFixed ? color("green", " [auto-fixed]") : "";
            console.log(`  • [${i.category}]${loc}${fixed}`);
            console.log(`    ${i.message}`);
            if (i.fix && !i.autoFixed)
                console.log(color("dim", `    fix: ${i.fix}`));
            else if (i.fix && i.autoFixed)
                console.log(color("dim", `    ${i.fix}`));
        }
    }
}
export function countBlocking(issues) {
    return issues.filter((i) => i.severity === "error" && !i.autoFixed).length;
}
