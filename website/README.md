# Notifdex Website (`notifdex.com`)

Static public website for Notifdex, deployed on **Cloudflare Pages** via Git integration.

## Build & output contract

| Setting | Value |
| --- | --- |
| Root directory | `website` |
| Build command | `npm run build` |
| Build output directory | `dist` |
| Production branch | `main` |
| Watch paths (Pages Git integration) | `website/*` |

The build uses Node's built-in modules with zero third-party runtime dependencies so Pages builds stay fast, deterministic, and offline-capable.

## Local commands

```bash
cd website
npm run build      # builds website/src/ -> website/dist/
npm run check      # verifies HTML, links, CSP hygiene, branding, and Pages headers
npm run preview    # serves website/dist/ on http://127.0.0.1:4173
```

## Privacy & content boundaries

- All screenshots, inbox alerts, people profiles, and recovery logs shown on this site are **synthetic sample data**.
- Never include real notifications, personal contacts, local SQLite paths with usernames, or credentials.
- Public copy follows [issue #38](https://github.com/notifdex/notifdex/issues/38): refer to the product as **Notifdex** and its views as **Inbox**, **People**, **Today**, **Notes**, and **Recovery**.

## Preview indexing & rollbacks

- Cloudflare Pages automatically sends `X-Robots-Tag: noindex` on preview deployments (`*.notifdex.pages.dev`).
- `src/_headers` also sends `X-Robots-Tag: noindex, nofollow` on both `https://notifdex.pages.dev/*` and `https://*.notifdex.pages.dev/*` so only `https://notifdex.com` is indexed.
- Production content rollbacks are available in one click from **Workers & Pages → notifdex → Deployments → Rollback to this deployment** (see [infra/cloudflare/README.md](../infra/cloudflare/README.md)).
