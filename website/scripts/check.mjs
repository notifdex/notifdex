import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const rootDir = path.resolve(__dirname, "..");
const distDir = path.join(rootDir, "dist");

const failures = [];

function assert(condition, message) {
  if (!condition) {
    failures.push(message);
  }
}

const requiredFiles = [
  "index.html",
  "updates.html",
  "faq.html",
  "privacy.html",
  "404.html",
  "styles.css",
  "app.js",
  "app-icon.png",
  "apple-touch-icon.png",
  "favicon.png",
  "og-card.svg",
  "_headers",
  "robots.txt",
  "sitemap.xml",
];

for (const rel of requiredFiles) {
  assert(existsSync(path.join(distDir, rel)), `Missing built file: dist/${rel}`);
}

if (failures.length === 0) {
  const indexHtml = readFileSync(path.join(distDir, "index.html"), "utf8");
  const updatesHtml = readFileSync(path.join(distDir, "updates.html"), "utf8");
  const faqHtml = readFileSync(path.join(distDir, "faq.html"), "utf8");
  const privacyHtml = readFileSync(path.join(distDir, "privacy.html"), "utf8");
  const notFoundHtml = readFileSync(path.join(distDir, "404.html"), "utf8");
  const headers = readFileSync(path.join(distDir, "_headers"), "utf8");
  const robots = readFileSync(path.join(distDir, "robots.txt"), "utf8");
  const sitemap = readFileSync(path.join(distDir, "sitemap.xml"), "utf8");
  const appJs = readFileSync(path.join(distDir, "app.js"), "utf8");
  const stylesCss = readFileSync(path.join(distDir, "styles.css"), "utf8");

  // Branding compliance (#38): avoid "Rolodex" in public website assets.
  const publicBundle = `${indexHtml}\n${updatesHtml}\n${faqHtml}\n${privacyHtml}\n${notFoundHtml}\n${appJs}`;
  assert(!/\brolodex\b/i.test(publicBundle), "Public website must not use the term 'Rolodex' (see issue #38)");

  // Canonical host, bundled icon, and required links (#57)
  assert(indexHtml.includes('rel="canonical" href="https://notifdex.com/"'), "index.html missing canonical link for https://notifdex.com/");
  assert(updatesHtml.includes('rel="canonical" href="https://notifdex.com/updates.html"'), "updates.html missing canonical link");
  assert(faqHtml.includes('rel="canonical" href="https://notifdex.com/faq.html"'), "faq.html missing canonical link");
  assert(privacyHtml.includes('rel="canonical" href="https://notifdex.com/privacy.html"'), "privacy.html missing canonical link");
  assert(indexHtml.includes("/app-icon.png"), "index.html should reference the bundled app icon (/app-icon.png)");
  assert(indexHtml.includes("/favicon.png"), "index.html should reference /favicon.png");
  assert(indexHtml.includes("https://github.com/notifdex/notifdex"), "index.html missing GitHub repository link");
  assert(indexHtml.includes("https://github.com/notifdex/notifdex#run-the-menu-bar-app"), "index.html missing install guide link");
  assert(indexHtml.includes("https://github.com/notifdex/notifdex/issues"), "index.html missing support link");
  assert(indexHtml.includes('href="/updates.html"'), "index.html missing link to /updates.html");
  assert(indexHtml.includes('href="/faq.html"'), "index.html missing link to /faq.html");
  assert(indexHtml.includes('href="/privacy.html"'), "index.html missing link to /privacy.html");

  // Sticky header scroll offset protection & dark mode toggle
  assert(/scroll-margin-top\s*:/.test(stylesCss), "styles.css should set scroll-margin-top so anchored sections clear the sticky header");
  assert(indexHtml.includes('id="theme-toggle"'), "index.html missing visible #theme-toggle button for dark/light mode");
  assert(updatesHtml.includes('id="theme-toggle"'), "updates.html missing visible #theme-toggle button");
  assert(faqHtml.includes('id="theme-toggle"'), "faq.html missing visible #theme-toggle button");
  assert(privacyHtml.includes('id="theme-toggle"'), "privacy.html missing visible #theme-toggle button");
  assert(stylesCss.includes('html[data-theme="dark"]'), "styles.css missing dark theme styling");

  const allHtmlPages = [
    ["index.html", indexHtml],
    ["updates.html", updatesHtml],
    ["faq.html", faqHtml],
    ["privacy.html", privacyHtml],
    ["404.html", notFoundHtml],
  ];

  // CSP hygiene: no inline event handlers, inline styles, or inline scripts in HTML pages
  for (const [name, html] of allHtmlPages) {
    assert(!/\son[a-z]+\s*=/i.test(html), `${name} contains an inline event handler that violates CSP`);
    assert(!/\sstyle\s*=/i.test(html), `${name} contains an inline style attribute that violates strict style-src 'self' CSP`);
    assert(!/<script(?![^>]*\bsrc=)[^>]*>/i.test(html), `${name} contains an inline <script> tag that violates CSP`);
  }

  // Local static asset links referenced from index.html exist in dist/
  const assetRefs = [...indexHtml.matchAll(/(?:href|src)="\/([^"#?]+)(?:[?#][^"]*)?"/g)].map((m) => m[1]);
  for (const ref of assetRefs) {
    assert(existsSync(path.join(distDir, ref)), `Broken local asset/link in index.html: /${ref}`);
  }

  // Content-hash cache-busting so returning visitors never hit stale 4h-cached JS/CSS after deploys
  const stylesHash = createHash("sha256").update(stylesCss).digest("hex").slice(0, 10);
  const appHash = createHash("sha256").update(appJs).digest("hex").slice(0, 10);
  for (const [name, html] of allHtmlPages) {
    assert(
      html.includes(`href="/styles.css?v=${stylesHash}"`),
      `${name} must reference versioned /styles.css?v=${stylesHash} to bust browser/CDN caches`
    );
    assert(
      html.includes(`src="/app.js?v=${appHash}"`),
      `${name} must reference versioned /app.js?v=${appHash} to bust browser/CDN caches`
    );
  }

  // Security headers and preview/pages.dev noindex
  assert(headers.includes("X-Content-Type-Options: nosniff"), "_headers missing X-Content-Type-Options");
  assert(headers.includes("Content-Security-Policy:"), "_headers missing Content-Security-Policy");
  assert(headers.includes("https://notifdex.pages.dev/*"), "_headers missing production pages.dev noindex rule");
  assert(headers.includes("https://*.notifdex.pages.dev/*"), "_headers missing preview pages.dev noindex rule");
  assert(headers.includes("X-Robots-Tag: noindex, nofollow"), "_headers missing X-Robots-Tag noindex rule");

  // robots.txt and sitemap.xml
  assert(robots.includes("Sitemap: https://notifdex.com/sitemap.xml"), "robots.txt missing sitemap URL");
  assert(sitemap.includes("<loc>https://notifdex.com/</loc>"), "sitemap.xml missing apex URL");
  assert(sitemap.includes("<loc>https://notifdex.com/updates.html</loc>"), "sitemap.xml missing updates URL");
  assert(sitemap.includes("<loc>https://notifdex.com/faq.html</loc>"), "sitemap.xml missing faq URL");
  assert(sitemap.includes("<loc>https://notifdex.com/privacy.html</loc>"), "sitemap.xml missing privacy URL");
}

if (failures.length > 0) {
  console.error("Website verification failed:");
  for (const failure of failures) {
    console.error(`  - ${failure}`);
  }
  process.exit(1);
}

console.log("Website verification passed (all files, links, CSP hygiene, headers, scroll offsets, and branding checks OK).");
