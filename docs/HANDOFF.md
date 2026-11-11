# Packy handoff

Status on 7 November 2026. Packy works end to end against fixture data in the iPhone Simulator. It has not run on a real iPhone or against live credentials, and it is not ready for real packing until the items under "What is needed to go live" are done.

## Why it is built this way

| Choice | Reason |
| --- | --- |
| Native SwiftUI app, not a phone web app | Apple's `DataScanner` gives steady on-device barcode tracking, and it reports when a code leaves view, which the repeat-read guard depends on. Haptics separate outcomes without looking at the screen. Cost: TestFlight and a developer membership, instead of a link. |
| Thin server that owns all rules | Tokens must stay off the phone and sign in must be enforced server-side. It also means a buggy or stale app cannot award credit. |
| One SQLite file on a Railway volume | One small team and one process. Writes are transactional, with no database service to run. Moving to Postgres later would be a contained change. |
| No offline packing | A confirmation needs a server answer. If there is none, the app says the unit may not be recorded, and retrying cannot double count. Offline queues would create exactly the silent conflicts the brief warns about. |

## How the design answers each job

- **Recognition versus recording:** a read only creates a single-use offer that expires after 90 seconds. Credit needs the tap on "It is in the box". The screen says "Right product. Not counted yet." until then.
- **Lookalikes:** the FIC Codice is the largest text on the screen, with the exact FIC name below it. A wrong scan names the scanned product and what is still needed.
- **Physical discrepancies:** a rejected scan opens a discrepancy that blocks completion until the operator states where the item is. Rejecting the read alone proves nothing, so it never closes itself.
- **Repeat reads:** a code held in view fires once. It must leave view for 1.2 seconds to fire again. Reads are limited to the aim box to reduce stray reads from nearby stock.
- **Honest limit:** ordinary barcodes identify a product type, not a bottle. Two reads of one code cannot prove two bottles. Each confirmation is the operator's statement, and the app says so. How often someone rescans the same bottle by accident must be measured in real packing trials.
- **Interruption:** all progress is on the server per order and operator. Retried taps replay their stored result. A stale second screen is refused with the latest progress.
- **Order changes:** packing runs against an accepted copy of the order. Any difference hides the camera until the operator accepts the update. Credit above a reduced quantity is withdrawn and the unit must be taken out.
- **Unavailable data:** source status is reported per source. "No orders" only appears when every connected source answered.

## Status

### Implemented and tested

Sign in, workload, scan and confirm, wrong product, excess, missing units, quantities over one, free samples, corrections, takeover, order changes, cancellation, freshness, unknown and conflicting codes, blocked kits, source outage, and completion with no source writes.

### Written but not yet run against the real service

- **Shopify adapter:** both queries were checked against the live store schema through a read-only connector. The service has not run with its own credentials, and the client credentials path is unproven.
- **FIC adapter:** never run. No FIC credential was available to this build, and none was looked for. Its field names are from the API as I know it, so check the first pull carefully.
- **Camera scanning:** compiles for device. Never run, because the Simulator has no camera.
- **Docker image and Railway deploy:** not built.

### Blocked until a decision or access exists

- **MS010 Travel Kit:** no barcode, and no kit policy. Orders containing it cannot complete.
- **Discovery Set and Vetiver room spray:** blank Shopify SKU, so identity is unresolved. Orders containing them cannot complete.
- **20 products with no barcode on hand:** see below. Orders containing them cannot complete.
- **Faire, Ankorstore, OrderChamp, FIC orders:** no authorized access. Shown as not connected. FIC `order` and `delivery_note` reads returned 403 at survey time.

## Barcode coverage

Rechecked read-only against live Shopify on 7 November 2026: 33 active variants, 8 with barcodes, 2 with blank SKUs. All 8 match the brief exactly, and there are no conflicts in the map today.

| Coverage | Variants | Codes |
| --- | --- | --- |
| Mapped | 10 | MS001, MS002, MS024 to MS030, MS040 |
| In the register, but the file is not on this machine | 20 | Listed in `data/barcode-map.json` |
| No barcode known | 1 | MS010 |
| Blank Shopify SKU | 2 | Vetiver room spray, Discovery Set |

The MS001 and MS002 rows come from the brief, not from a live read. This gap affects real orders today: the one open order on 7 November, #MS1668, needs MS019, which has no barcode on hand, so it would be blocked.

## What is needed to go live

1. The marketplace EAN register file, as text CSV.
2. Read-only Shopify and FIC credentials, provisioned straight into Railway.
3. An Apple Developer Program membership. This Mac has no signing identity yet.
4. The decisions below.
5. A real iPhone trial, using the checklist below.

## Decisions needed

Each default below is what the code does today. All of them fail closed.

| Topic | Today | Options and consequences |
| --- | --- | --- |
| Kits (MS010, Discovery Set) | Blocked | **A.** Print and register a barcode for each kit: simplest and keeps one rule. **B.** Scan components: needs an authoritative component list, and does not prove the kit itself. |
| Missing or unreadable labels | Blocked, no manual entry | **A.** Reprint the label: keeps the guarantee. **B.** A second person checks and signs off: slower but auditable. Typing a code proves nothing physical, so I advise against it. |
| Rows that may not be physical | Shopify rows with no shipping stay blocked | Approve a list of known nonphysical products. A wider rule risks hiding a real item. |
| Payment | Only PAID and PARTIALLY_REFUNDED are packable | Allow PENDING if you ship bank transfer orders before payment arrives. Those orders are currently listed as not packable. |
| Freshness | 5 minutes for orders, 24 hours for the FIC catalog, plus a pull on the completing tap | Shorter limits catch more, but fail more on a bad connection. |
| Offline | Not supported | Stock area wifi must be reliable. Check this before the trial. |
| Corrections | Packer can remove a unit, reopen, or empty the box | Decide if reopening a packed order needs a supervisor. Today any operator can, and units then need rescanning if it was someone else's. |
| Two people, one order | One owner. Takeover is explicit, and all counted units must be rescanned | Softer rules would be faster, but would trust a box the new person did not fill. |
| Retention | 90 days, run by hand | Confirm the period, and whether recipient names are wanted at all. |
| App language | English | Translate to Italian if operators prefer it. |

## Evidence

Everything below used fixture data unless stated.

| # | Acceptance outcome | Server tests | Simulator | Real iPhone |
| --- | --- | --- | --- | --- |
| 1 | Authenticated access only | Pass | Sign in | Not run |
| 2 | FIC names, unresolved stays unresolved | Pass | Names shown | Not run |
| 3 | Several units, detection adds nothing | Pass | Ran 2 of 3 | Not run |
| 4 | Wrong and excess earn nothing | Pass | Wrong product ran | Not run |
| 5 | Missing unit and free sample block | Pass | Not run by hand | Not run |
| 6 | Repeated reads add nothing | Pass, plus 4 `ScanGate` unit tests | Not testable without a camera | Not run. Needs trials |
| 7 | Resume without loss or double count | Pass | Survived 2 app relaunches | Not run |
| 8 | Changes and conflicts cannot inherit an all clear | Pass | Quantity reduction ran | Not run |
| 9 | Unknown, ambiguous, kits, leading zeroes | Pass | Kit listed as blocked | Not run |
| 10 | Failure is not an empty list | Pass | Outage ran | Not run |
| 11 | No source writes | Pass | Not applicable | Not applicable |
| 12 | Works on a real iPhone | Not applicable | Not applicable | **Not done** |

Counts: 37 server tests and 4 iOS unit tests pass. The device build compiles unsigned.

## First iPhone trial checklist

1. **Scan MS024 first.** Its barcode is `0806812399109`. If the printed code is really a 12 digit UPC-A, the camera may report a different string than the map holds. Packy would then say "Unknown code", which is safe but wrong. Never pad it automatically. Compare the real payload and decide deliberately.
2. Scan MS001 and MS002 side by side to judge the lookalike warning.
3. Test glossy, curved labels under stock area lighting.
4. Pack an order of three identical units at normal speed, and count accidental double confirmations.
5. Deny camera access, and check the message.
6. Turn wifi off during a confirmation, and check the retry.
7. Check that a neighbouring product on the shelf does not trigger reads.

## Future scope

More order sources fit behind `OrderSource` in `server/src/types.ts`. Individual unit proof would need serialized labels. Source writes, such as marking orders fulfilled, need explicit authorization.
