import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

// Only the test's temporary VM contains this counter. Production source,
// exports, artifacts and payload budgets contain no instrumentation.
export function computedFixtureVM(methods: string[] = []): { directory: string; cleanup: () => void } {
  if (methods.some(name => !/^[a-z_][a-z0-9_]*$/.test(name))) throw new Error("invalid fixture method name");
  const original = process.env.MOCHI_GVM_DIR
    ? path.resolve(process.env.MOCHI_GVM_DIR)
    : path.resolve(__dirname, "../../../mochi-gvm");
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "mochi-computed-vm-"));
  try {
    for (const name of ["src", "scripts"]) fs.cpSync(path.join(original, name), path.join(directory, name), { recursive: true });
    fs.mkdirSync(path.join(directory, "dist"));
    const computed = path.join(directory, "src/gvm/computed.goose");
    let source = fs.readFileSync(computed, "utf8");
    const marker = "machine.pool.computed[index].evaluating = true;";
    if (source.split(marker).length !== 2) throw new Error("computed evaluation instrumentation seam changed");
    const counters = methods.map((name, index) => `if symbol_name(method_symbol) == "${name}" { g_fixture_method_${index} += 1; }`).join("\n");
    source = source.replace(marker, `${marker}\n        g_fixture_computed_calls += 1;\n${counters}`);
    source += `\nvar g_fixture_computed_calls: i32 = 0;\nexport fn goose_fixture_computed_calls() -> i32 {\n    return g_fixture_computed_calls;\n}\n`;
    source += methods.map((_, index) => `var g_fixture_method_${index}: i32 = 0;\n`).join("");
    source += `export fn goose_fixture_computed_count(index: i32) -> i32 {\n${methods.map((_, index) => `    if index == ${index} { return g_fixture_method_${index}; }`).join("\n")}\n    return -1;\n}\n`;
    fs.writeFileSync(computed, source);
    const build = path.join(directory, "scripts/build_wasm.goose");
    let script = fs.readFileSync(build, "utf8");
    const exportList = "-sEXPORTED_FUNCTIONS='[";
    if (script.split(exportList).length !== 2) throw new Error("expected one WASM export list in the build script");
    script = script.replace(exportList, `${exportList}\\"_goose_fixture_computed_calls\\",\\"_goose_fixture_computed_count\\",`);
    fs.writeFileSync(build, script);
    execFileSync("goose", ["run", "scripts/build_wasm.goose"], { cwd: directory, stdio: "pipe", timeout: 120_000 });
    return { directory: path.join(directory, "dist"), cleanup: () => fs.rmSync(directory, { recursive: true, force: true }) };
  } catch (error) {
    fs.rmSync(directory, { recursive: true, force: true });
    throw error;
  }
}
