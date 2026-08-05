# livepeer.bot — site

`index.html` is the entire site: one file, inline CSS, inline SVG, a few lines of inline JS
(copy buttons only — the page is fully readable with JavaScript disabled). No external requests
of any kind, so it works unmodified on IPFS, eth.limo gateways, and any static host.

Before publishing, replace the placeholders (search for `data-todo`):

| `data-todo` value | Replace with |
|---|---|
| ~~`contract-address`~~ | DONE — `0x2F5901C6D8EB0181FA4f2b75EAAd0344a916fdDE` |
| ~~`repo-url`~~ | DONE — https://github.com/Titan-Node/livepeer-bot |
| ~~`explorer-contract-url`~~ | DONE — Arbiscan + Blockscout verified-source pages |
| ~~`write-contract-url`~~ | DONE — BondingManager write-proxy on Blockscout |
| ~~`keeper-script-url` / `keeper-docs-url`~~ | DONE — repo `/keeper` links |
| ~~`chainlink-upkeep-id`~~ | OBSOLETE — Chainlink Automation sunset (July 2026) before launch; row replaced with backstop-status text |
| `keeper-donation-address` | keeper gas-wallet EOA |

The `cast` command address tokens are filled. Remaining `soon` badge: the donation row.

## Option A — ENS + IPFS (`livepeerbot.eth` → `livepeerbot.eth.limo`)

Censorship-resistant and unkillable; fits the trust story of the contract itself.

1. **Pin the file to IPFS.** Any pinning service works; you only need to pin one small file:
   - [Pinata](https://pinata.cloud) — web UI: upload `index.html` (upload it as a *folder*
     named e.g. `site/` containing `index.html` so the CID resolves `/` to the page), copy the
     folder CID. Free tier is far more than enough.
   - [web3.storage](https://web3.storage) or [Fleek](https://fleek.xyz) — same idea; Fleek can
     also auto-pin from a GitHub repo on every push.
   - Self-hosted: `ipfs add -r site/` on any machine running Kubo, then keep that node online
     or pin the CID with a service as backup.
2. **Set the ENS contenthash.** In the [ENS manager](https://app.ens.domains), open your name
   → Records → Content Hash → set `ipfs://<CID>` and confirm the transaction (mainnet L1).
   - Cost: one L1 transaction, typically **$1–10** depending on gas, plus the ENS name's yearly
     registration (~**$5/yr** for names of 5+ characters). Registering the name itself is one
     more L1 transaction.
3. **Reach it.** `https://<name>.eth.limo` (and `.eth.link`, and any IPFS gateway via the CID).
   Browsers with native ENS/IPFS support resolve `<name>.eth` directly.

**Updating:** re-pin the new `index.html` (new CID), then send one more L1 transaction updating
the contenthash. That per-update L1 fee is the real cost of this option — batch your edits.

## Option B — free static hosting behind the `livepeer.bot` domain

Fast, free, instant updates; depends on a hosting company.

- **Cloudflare Pages:** create a Pages project → connect the GitHub repo (build command: none,
  output directory: `site/`) or drag-and-drop the folder. Then add `livepeer.bot` as a custom
  domain — if the domain's DNS is already on Cloudflare this is two clicks and a free
  certificate. Every `git push` (or re-upload) deploys in seconds. Cost: **$0** + the domain's
  yearly registration.
- **GitHub Pages:** repo → Settings → Pages → serve from a branch, folder `/site` (or a
  `gh-pages` branch; simplest is copying `index.html` to the branch root). Add `livepeer.bot`
  as the custom domain (GitHub writes a `CNAME` file) and point DNS: `A` records to GitHub's
  Pages IPs or a `CNAME` to `<user>.github.io`. Enforce HTTPS. Cost: **$0** + domain.

**Updating:** `git push` — that's it.

## Option C — both (recommended)

Serve `livepeer.bot` from Cloudflare Pages / GitHub Pages for speed and instant updates, **and**
keep an IPFS pin + ENS contenthash as the canonical, censorship-resistant mirror. Because the
page is a single self-contained file with zero external requests, the two copies are always
byte-identical — publish the same commit to both. Link each from the other's footer if you want
the mirror discoverable.

Suggested cadence: update the web host on every change; refresh the ENS contenthash only for
meaningful releases (address changes, new upkeep ID), since each refresh costs an L1 transaction.
