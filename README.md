# Packy

Internal iPhone packing check for Manisante. It helps the person packing a parcel confirm the physical contents match the current order before recording it as packed. Packy never ships, fulfills, or writes to any source.

- `ios/`: native SwiftUI app. Reads barcodes with the camera and shows what is verified, what remains, and why.
- `server/`: thin Node service. Owns sign in, integration tokens, source adapters, and every packing rule.
- `data/barcode-map.json`: barcode to FIC Codice map with provenance and coverage gaps.
- `data/policies.json`: products that stay blocked until a policy is approved.
- `docs/HANDOFF.md`: rationale, status, decisions needed, and test evidence. Start there.

## Run locally with fixture data

Needs Node 24 or newer and Xcode 26. Fixture mode is clearly labelled in the app and refuses to start in production.

```bash
cd server && npm install
```

```bash
PACKY_DB=data/fixtures.db PACKY_OPERATOR_PASSWORD='choose-a-test-password' npm run operator -- ana "Ana Test"
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
cd ios && xcodebuild -project Packy.xcodeproj -scheme Packy -destination 'platform=iOS Simulator,name=iPhone 17' test
```

## Deploy

The repo includes a `Dockerfile` and `railway.json`. The image has not been built yet, because Docker is not installed on the build machine.

1. Create a Railway service from this folder and attach a volume at `/data`.
2. Set the variables below as Railway variables. Never commit them.
3. Add operators from a Railway shell with `npm run operator`.
4. Put the deployed HTTPS address in `PACKY_API_URL` for the Release config in `ios/project.yml`.
5. Distribute through TestFlight internal testing, which needs an Apple Developer Program membership.

| Variable | Purpose |
| --- | --- |
| `SHOPIFY_SHOP_DOMAIN` | `your-store.myshopify.com` |
| `SHOPIFY_ADMIN_ACCESS_TOKEN` | Read-only Admin token, or use the two below |
| `SHOPIFY_CLIENT_ID`, `SHOPIFY_CLIENT_SECRET` | Dev Dashboard app using the client credentials grant |
| `FATTURE_IN_CLOUD_API_KEY` | Read-only FIC token with products access |
| `FIC_COMPANY_ID` | `<company-id>` |
| `PACKY_DB` | Database path. The image defaults to `/data/packy.db` |

Least privilege for Shopify: `read_orders`, `read_products`, `read_merchant_managed_fulfillment_orders`, `read_assigned_fulfillment_orders`. Add customer data access only if the recipient name is wanted on screen. Without it the name may be blank, which Packy handles.

## Operations

- **Barcode register:** export the marketplace EAN register as CSV with `sku` and `ean` columns, formatted as text, then run `npm run barcodes:import -- register.csv`. Open the file in a spreadsheet with care: spreadsheets drop leading zeroes. The importer refuses values in scientific notation.
- **Sync:** data is pulled on sign in, app open, manual refresh, and the tap that completes an order. Nothing is scheduled.
- **Access:** every `/v1` route except login needs a server-side session. Sessions last 12 hours. Five failed logins lock an account for 15 minutes. To remove someone's access, set `active = 0` on their `users` row.
- **Stored customer data:** order reference, recipient name, and line items. Logs hold error codes only, never order data or tokens.
- **Retention:** `npm run purge -- 90` removes finished packing records older than 90 days and their recipient names. Run it by hand. The 90 day default is a proposal.
- **Backup and recovery:** all state is the one SQLite file on the volume. Back up the volume. If it is lost, orders come back on the next pull, but operators and packing progress do not, so any in-progress box must be recounted.
