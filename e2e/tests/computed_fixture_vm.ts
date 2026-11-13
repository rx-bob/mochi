import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

// Only the test's temporary VM contains this counter. Production source,
// exports, artifacts and payload budgets contain no instrumentation.
export function computedFixtureVM(): { directory: string; cleanup: () => void } {
  const original = path.resolve(__dirname, "../../../mochi-gvm");
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "mochi-computed-vm-"));
  try {
    for (const name of ["src", "scripts"]) fs.cpSync(path.join(original, name), path.join(directory, name), { recursive: true });
    fs.mkdirSync(path.join(directory, "dist"));
    const computed = path.join(directory, "src/gvm/computed.goose");
    let source = fs.readFileSync(computed, "utf8");
    const marker = "machine.pool.computed[index].evaluating = true;";
    if (source.split(marker).length !== 2) throw new Error("computed evaluation instrumentation seam changed");
    source = source.replace(marker, `${marker}\n        g_fixture_computed_calls += 1;`);
    source += `\nvar g_fixture_computed_calls: i32 = 0;\nexport fn goose_fixture_computed_calls() -> i32 {\n    return g_fixture_computed_calls;\n}\n`;
    fs.writeFileSync(computed, source);
    const build = path.join(directory, "scripts/build_wasm.goose");
    let script = fs.readFileSync(build, "utf8");
    const exportMarker = '\\"_main\\"';
    if (!script.includes(exportMarker)) throw new Error("WASM export instrumentation seam changed");
    script = script.replace(exportMarker, `${exportMarker},\\"_goose_fixture_computed_calls\\"`);
    fs.writeFileSync(build, script);
    execFileSync("goose", ["run", "scripts/build_wasm.goose"], { cwd: directory, stdio: "pipe", timeout: 120_000 });
    return { directory: path.join(directory, "dist"), cleanup: () => fs.rmSync(directory, { recursive: true, force: true }) };
  } catch (error) {
    fs.rmSync(directory, { recursive: true, force: true });
    throw error;
  }
}
