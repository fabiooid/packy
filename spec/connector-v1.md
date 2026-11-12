# Packy connector spec, version 1

Packy knows no platform. It reads orders, the product list and barcodes from **connectors**: small HTTP services that translate one platform (a shop, a marketplace, an ERP) into the shapes below. To add a platform, write a connector. Packy's code does not change.

The types and the validator Packy uses are in [`connector-v1.ts`](connector-v1.ts). It has no dependencies, so a connector can import or copy it and check its own output before sending it.

## Endpoints

Every request carries `Authorization: Bearer <token>`. Answer `401` without it. All responses are JSON, and every body names the spec: `"spec": "packy-connector/1"`.

| Request | Answer |
|---|---|
| `GET {base}/` | Manifest: `{ "spec", "name", "provides": ["orders", "products", "barcodes"] }`. List only what you serve. |
| `GET {base}/orders` | `{ "spec", "orders": [Order] }`: the orders that are open now. |
| `GET {base}/products` | `{ "spec", "products": [Product] }`: the whole product list. |
| `GET {base}/barcodes` | `{ "spec", "barcodes": [Barcode] }`: every barcode you know. |

`name` must match the name Packy is configured with, in lowercase letters, digits, `-` or `_`. Packy stores each order under that name.

Each list is complete every time. Packy has no paging or "changes since" in v1. An order missing from `/orders` has left the open set: Packy drops it, or blocks it if someone is packing it.

## Shapes

**Order**

| Field | Type | Meaning |
|---|---|---|
| `orderId` | string | Stable id on the platform. |
| `reference` | string | What people see, for example `#1042`. |
| `recipient` | string or null | Name on the parcel. |
| `createdAt`, `sourceUpdatedAt` | ISO 8601 | `sourceUpdatedAt` changes whenever the order changes. |
| `eligible` | boolean | `false` when it must not be packed now: unpaid, cancelled, on hold. |
| `ineligibleReason` | string or null | Why, in Italian, shown to the packer. |
| `lines` | Line[] | What goes in the box. |
| `nonPhysical` | `{ title, reason }[]` | Rows never packed, such as fees or gift cards. |

**Line**

| Field | Type | Meaning |
|---|---|---|
| `lineId` | string | Unique within the order. |
| `sku` | string or null | Exact text. Keep leading zeroes. |
| `title`, `variantTitle` | string, string or null | As on the platform. Shown only for custom items. |
| `required` | whole number, at least 1 | Pieces still to pack, after refunds and earlier shipments. |
| `kind` | `physical` or `uncertain` | `uncertain` when the platform cannot say whether it is a physical item. |
| `kindReason` | string or null | Why it is uncertain. |
| `shipping` | boolean, optional | A shipping-method row. Confirmed by hand, never counted as a piece. |
| `keys` | `{ type, value }[]`, optional | The platform's own ids for the product. `type` is `sku`, `product_id` or `variant_id`. Packy matches them through its product links. |

**Product**: `{ code, name, externalId }`. `code` is your product code, exact text. `name` is the full name, size included. `externalId` is the id in your product system, or null.

**Barcode**: `{ barcode, code, sourceRef }`. `barcode` is exact text (EAN, UPC) with leading zeroes. Never send spreadsheet notation such as `8.05E+12`. `code` is the product code it belongs to.

## How Packy matches a line to a product

In this order, never by guessing from the title:

1. a saved product link for one of the line's `keys`,
2. a saved product link for its `sku`,
3. the `sku` equal to a product `code`.

Anything else is shown as **Custom** and confirmed by hand. Product links are loaded from `data/product-links.json` (see `npm run links:import`).

## Rules for connectors

- **Read only.** Never write to the platform.
- **Errors are codes.** Answer a failure with a non-2xx status and `{ "error": { "code": "short_code" } }`. Never put tokens, customer names or order data in an error or a log.
- **All or nothing.** Packy rejects a whole response if any field breaks the spec, keeps its last good data and shows the source as unavailable. Check your output with the validator before sending it.
- **Be quick.** Packy waits 20 seconds per request.

## Configuring Packy

```bash
PACKY_CONNECTORS="shopify=https://connectors.example/shopify,fattureincloud=https://connectors.example/fattureincloud"
PACKY_CONNECTOR_TOKEN_SHOPIFY=...
PACKY_CONNECTOR_TOKEN_FATTUREINCLOUD=...
PACKY_PRODUCTS_FROM=fattureincloud
```

The token variable is the connector name in capitals, with `-` written as `_`. `PACKY_PRODUCTS_FROM` is needed only when more than one connector offers products. Addresses must use https, except localhost and private `.internal` hosts.

Packy reads every manifest at the start of each refresh, so a connector can start offering something new without restarting Packy.

## The bundled connectors service

[`connectors/`](../connectors) is a reference service with Shopify (orders, barcodes), Faire (orders) and Fatture in Cloud (products). It mounts each platform at `/<name>` only when that platform's keys are set, and checks every response against this spec before sending it. Fatture in Cloud orders are next.

Faire: `PROCESSING` and `PRE_TRANSIT` orders are packable; `NEW` (not yet accepted) and `BACKORDERED` are listed but not packable. Faire product and variant ids are sent as `keys`. A tester is a separate line confirmed by hand. The mapping has not yet been checked against a live Faire account.
