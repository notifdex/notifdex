import { createHash } from "node:crypto";
import { cpSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const rootDir = path.resolve(__dirname, "..");
const srcDir = path.join(rootDir, "src");
const distDir = path.join(rootDir, "dist");

if (!existsSync(srcDir)) {
  console.error(`Source directory not found: ${srcDir}`);
  process.exit(1);
}

rmSync(distDir, { recursive: true, force: true });
mkdirSync(distDir, { recursive: true });
cpSync(srcDir, distDir, { recursive: true });

function contentHash(filePath) {
  return createHash("sha256").update(readFileSync(filePath)).digest("hex").slice(0, 10);
}

const stylesHash = contentHash(path.join(distDir, "styles.css"));
const appHash = contentHash(path.join(distDir, "app.js"));

for (const entry of readdirSync(distDir)) {
  if (!entry.endsWith(".html")) continue;
  const htmlPath = path.join(distDir, entry);
  const original = readFileSync(htmlPath, "utf8");
  const versioned = original
    .replaceAll('href="/styles.css"', `href="/styles.css?v=${stylesHash}"`)
    .replaceAll('src="/app.js"', `src="/app.js?v=${appHash}"`);
  writeFileSync(htmlPath, versioned, "utf8");
}

function listFiles(dir, prefix = "") {
  const results = [];
  for (const entry of readdirSync(dir).sort()) {
    const fullPath = path.join(dir, entry);
    const relPath = prefix ? `${prefix}/${entry}` : entry;
    if (statSync(fullPath).isDirectory()) {
      results.push(...listFiles(fullPath, relPath));
    } else {
      results.push(relPath);
    }
  }
  return results;
}

const builtFiles = listFiles(distDir);
console.log(`Built ${builtFiles.length} static files into website/dist:`);
for (const file of builtFiles) {
  console.log(`  - ${file}`);
}
