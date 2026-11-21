const fs = require("node:fs/promises");
const path = require("node:path");
const { minify } = require("terser");

async function main() {
  const mode = process.argv[2];
  if (!["--write", "--check"].includes(mode) || process.argv.length !== 3) {
    throw new Error("Usage: node build_loader.cjs --write|--check");
  }
  const source = await fs.readFile(path.join(__dirname, "src", "mochi-loader.js"), "utf8");
  const { code } = await minify(source, {
    compress: false,
    mangle: false,
    format: { ascii_only: true, comments: "some" },
  });
  const generated = `// Generated from src/mochi-loader.js. Run npm run build:loader.\n${code}\n`;
  const destination = path.join(__dirname, "mochi-loader.js");
  if (mode === "--write") {
    await fs.writeFile(destination, generated);
  } else if (await fs.readFile(destination, "utf8") !== generated) {
    throw new Error("mochi-loader.js is stale. Run npm run build:loader in runtime.");
  }
}

main().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
