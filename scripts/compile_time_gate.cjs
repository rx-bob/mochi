#!/usr/bin/env node

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { performance } = require("node:perf_hooks");
const { spawnSync } = require("node:child_process");

const repoRoot = path.resolve(__dirname, "..");
const referenceRoot = path.dirname(repoRoot);
const appRoot = fs.readdirSync(referenceRoot)
  .map((name) => path.join(referenceRoot, name, "frontend-mochi"))
  .find((candidate) => fs.existsSync(path.join(candidate, "lib/costs/CostsScreen.rb")));

const fixtures = {
  minimal: {
    input: path.join(repoRoot, "compiler/motestproj"),
    edit: "lib/MyCounter.rb",
  },
  costs: {
    input: appRoot,
    edit: "lib/costs/CostsScreen.rb",
  },
  logs: {
    input: appRoot,
    edit: "lib/logs/LogsScreen.rb",
  },
  cowboy: {
    input: appRoot,
    edit: "lib/shell/ZRoot.rb",
  },
};

const scenarios = ["cold", "warm", "edit"];
const limitMs = 1000;
const defaultRuns = 5;

function parseArgs(argv) {
  const options = { runs: defaultRuns, fixture: "all", scenario: "all", compiler: path.join(repoRoot, "compiler/mochi") };
  for (let index = 0; index < argv.length; index += 1) {
    const key = argv[index];
    if (!["--runs", "--fixture", "--scenario", "--compiler"].includes(key)) {
      throw new Error(`unknown argument: ${key}`);
    }
    const value = argv[index + 1];
    if (!value || value.startsWith("--")) throw new Error(`missing value for ${key}`);
    index += 1;
    if (key === "--runs") options.runs = Number(value);
    if (key === "--fixture") options.fixture = value;
    if (key === "--scenario") options.scenario = value;
    if (key === "--compiler") options.compiler = path.resolve(value);
  }
  if (!Number.isInteger(options.runs) || options.runs < 1 || options.runs > 100) {
    throw new Error("--runs must be an integer from 1 through 100");
  }
  if (options.fixture !== "all" && !Object.hasOwn(fixtures, options.fixture)) {
    throw new Error(`unknown fixture: ${options.fixture}`);
  }
  if (options.scenario !== "all" && !scenarios.includes(options.scenario)) {
    throw new Error(`unknown scenario: ${options.scenario}`);
  }
  if (!fs.existsSync(options.compiler)) throw new Error(`compiler not found: ${options.compiler}`);
  if (!appRoot) throw new Error("frontend-mochi app source was not found beside the Mochi repository");
  return options;
}

function runBuild(compiler, input, output) {
  const started = performance.now();
  const result = spawnSync(compiler, ["-i", input, "-o", output], {
    cwd: input,
    encoding: "utf8",
    maxBuffer: 16 * 1024 * 1024,
  });
  const elapsedMs = performance.now() - started;
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(`compiler exited ${result.status}:\n${result.stdout || ""}\n${result.stderr || ""}`);
  }
  return elapsedMs;
}

function removeGeneratedState(input, output) {
  fs.rmSync(path.join(input, "build"), { recursive: true, force: true });
  fs.rmSync(path.join(input, "mochi_build.pftrace"), { force: true });
  fs.rmSync(output, { recursive: true, force: true });
}

function stageFixture(source, destination) {
  fs.cpSync(source, destination, {
    recursive: true,
    dereference: true,
    filter: (entry) => !["build", "dist", "node_modules", "test-results", "playwright-report"].includes(path.basename(entry)),
  });
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const selectedFixtures = options.fixture === "all" ? Object.keys(fixtures) : [options.fixture];
  const selectedScenarios = options.scenario === "all" ? scenarios : [options.scenario];
  const workspace = fs.mkdtempSync(path.join(os.tmpdir(), "mochi-compile-gate-"));
  const failures = [];
  let measured = 0;

  try {
    for (const fixtureName of selectedFixtures) {
      const fixture = fixtures[fixtureName];
      if (!fixture.input || !fs.existsSync(fixture.input)) throw new Error(`${fixtureName} fixture source is missing`);
      const input = path.join(workspace, fixtureName, "project");
      const output = path.join(workspace, fixtureName, "dist");
      fs.mkdirSync(path.dirname(input), { recursive: true });
      stageFixture(fixture.input, input);

      for (const scenario of selectedScenarios) {
        for (let run = 1; run <= options.runs; run += 1) {
          if (scenario === "cold") removeGeneratedState(input, output);
          if (scenario === "edit") {
            const editPath = path.join(input, fixture.edit);
            fs.appendFileSync(editPath, `\n# compile gate edit ${run}\n`);
          }

          try {
            const elapsedMs = runBuild(options.compiler, input, output);
            measured += 1;
            const result = `${fixtureName}/${scenario} ${run}/${options.runs}: ${elapsedMs.toFixed(1)} ms`;
            if (elapsedMs >= limitMs) {
              failures.push(`${fixtureName}/${scenario}: ${elapsedMs.toFixed(1)} ms (limit < ${limitMs} ms)`);
              process.stderr.write(`FAIL ${result}\n`);
            } else {
              process.stdout.write(`PASS ${result}\n`);
            }
          } catch (error) {
            measured += 1;
            failures.push(`${fixtureName}/${scenario}: ${error.message}`);
            process.stderr.write(`FAIL ${fixtureName}/${scenario} ${run}/${options.runs}: ${error.message}\n`);
          }
        }
      }
    }
  } finally {
    fs.rmSync(workspace, { recursive: true, force: true });
  }

  process.stdout.write(`Measured ${measured} builds; strict limit is < ${limitMs} ms.\n`);
  if (failures.length > 0) {
    process.stderr.write(`Compile-time gate failed for ${failures.length} invocation(s):\n`);
    for (const failure of failures) process.stderr.write(`- ${failure}\n`);
    process.exitCode = 1;
  }
}

try {
  main();
} catch (error) {
  process.stderr.write(`Compile-time gate setup failed: ${error.message}\n`);
  process.exitCode = 2;
}
