<img src="ios/Packy/Assets.xcassets/LoginMark.imageset/LoginMark.png" alt="Packy" width="96">

# Packy

Open-source iPhone packing check. It helps the person packing a parcel confirm the physical contents match the current order before recording it as packed. Packy is order-source agnostic: connect your own order sources and product catalog, and use it with your own orders. It never ships, fulfills, or writes to any source. It is released under the MIT license.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Node.js >= 24](https://img.shields.io/badge/node-%3E%3D24-339933)
![TypeScript](https://img.shields.io/badge/TypeScript-strict-3178C6)
![Swift](https://img.shields.io/badge/Swift-5-F05138)
![Status: local prototype](https://img.shields.io/badge/status-local%20prototype-orange)

- `ios/`: native SwiftUI app. Reads barcodes with the camera and shows what is verified, what remains, and why.
- `server/`: thin Node service. Owns sign in and every packing rule. It knows no platform: orders, products and barcodes arrive through connectors.
- `spec/`: the connector spec ([connector-v1.md](spec/connector-v1.md)) and its validator. Add a platform by writing a connector, not by changing Packy.
- `connectors/`: reference connectors service (Shopify, Faire, Fatture in Cloud). It holds the platform keys.
- `data/barcode-map.json`: barcode to product-code map with provenance and coverage gaps.
- `data/policies.json`: products that stay blocked until a policy is approved.
- `docs/HANDOFF.md`: implementation notes, status, and test evidence.

## Run locally with fixture data

Needs Node 24 or newer and Xcode 26. Fixture mode is clearly labelled in the app and refuses to start in production.

```bash
cd server && npm install
```

```bash
PACKY_DB=data/fixtures.db PACKY_OPERATOR_PASSWORD='<pick-a-test-password>' npm run operator -- ana "Ana Test"
```

```bash
npm run dev:fixtures
```

Then build the app. The project file is generated, so run this first:

```bash
cd ios && xcodegen generate && open Packy.xcodeproj
```

Run on an iPhone Simulator. The Simulator has no camera, so a labelled panel stands in for reads. That panel is not compiled into device builds.

## Tests

```bash
cd server && npm test && npm run typecheck
```

```bash
cd connectors && npm test && npm run typecheck
```

```bash
cd ios && xcodebuild -project Packy.xcodeproj -scheme Packy -destination 'platform=iOS Simulator,name=iPhone 17' test
```

## Deploy

The repo includes a `Dockerfile` and `railway.json`. The image has not been built yet, because Docker is not installed on the build machine.

1. Create a Railway service from this folder and attach a volume at `/data`.
2. Create a second service from this folder for the connectors, with config file `railway.connectors.json`. Set its platform keys and a `CONNECTOR_TOKEN` (`openssl rand -hex 32`) as variables. Names are in `connectors/.env.example`.
3. On the Packy service set `PACKY_CONNECTORS`, one `PACKY_CONNECTOR_TOKEN_<NAME>` per connector (the connectors service's token), and `PACKY_PRODUCTS_FROM` if needed. Names are in `server/.env.example`. Prefer the private Railway address between the two services. Never commit real values.
4. Add operators from a Railway shell with `npm run operator`.
5. Put the deployed HTTPS address in `PACKY_API_URL` for the Release config in `ios/project.yml`.
6. Distribute through TestFlight internal testing, which needs an Apple Developer Program membership.

The database path defaults to `/data/packy.db` in the image (`PACKY_DB`). Use read-only access for order and catalog sources. Add customer data access only if you want the recipient name on screen. Without it the name may be blank, which Packy handles.

## Security

- **Keys live only in deployment variables.** Platform keys (Shopify, Faire, Fatture in Cloud) are set only on the connectors service. Packy holds one token per connector. The iPhone app holds no keys at all: only the operator's session, kept in the Keychain on that device.
- **Nothing secret in git.** `scripts/check-secrets.sh` refuses env files, databases, private keys and anything shaped like a token. It runs before every commit (turn it on once per clone with `git config core.hooksPath .githooks`) and on every push in GitHub Actions. GitHub secret scanning and push protection are also on.
- **Keys never travel further than their platform.** Every outbound call refuses redirects, so a key can't be carried to another host. Errors and logs carry short codes only, never tokens, order data or customer names.
- **If a key leaks, rotate it first.** Deleting it from git is not enough. Issue a new key on the platform, update the Railway variable, then revoke the old key.

## Operations

- **Barcode register:** export the marketplace EAN register as CSV with `sku` and `ean` columns, formatted as text, then run `npm run barcodes:import -- register.csv`. Open the file in a spreadsheet with care: spreadsheets drop leading zeroes. The importer refuses values in scientific notation.
- **Product links:** every order line is matched to a product in the product list, in this order: a saved link for the source's own product id, a saved link for the source's SKU, then the SKU equal to the product code. Set links up once, before going live: make a CSV with `source,key,codice` (and optionally `key_type`: `sku`, `product_id` or `variant_id`), run `npm run links:import -- links.csv` and restart the server. Lines that still match nothing are shown as **Custom**, with the title from the order, and are confirmed by hand. They never block the order.
- **Sync:** data is pulled on sign in, app open, manual refresh, and the tap that completes an order. Nothing is scheduled.
- **Dashboard:** open `/admin` on the server address, for example `https://your-packy-server/admin`, and sign in with the same operator account as the app. It is read-only and shows orders packed in the last 30 days: when, the customer, the reference, the number of pieces, and who packed it. The page itself holds no data until you sign in.
- **Access:** every `/v1` route except login needs a server-side session. Sessions last 12 hours. Five failed logins lock an account for 15 minutes. To remove someone's access, set `active = 0` on their `users` row.
- **Stored customer data:** order reference, recipient name, and line items. Logs hold error codes only, never order data or tokens.
- **Retention:** `npm run purge -- 90` removes finished packing records older than 90 days and their recipient names. Run it by hand. The 90 day default is a proposal.
- **Backup and recovery:** all state is the one SQLite file on the volume. Back up the volume. If it is lost, orders come back on the next pull, but operators and packing progress do not, so any in-progress box must be recounted.
