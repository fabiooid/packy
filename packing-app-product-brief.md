# Manisante packing-check product brief

Use this as a self-contained prompt for the agent building the product. It replaces the earlier interaction-led prompt. Historical survey recommendations do not override this brief.

## Your task

Design and build an internal iPhone packing-check product for Manisante, an Italian fragrance and body-care brand at manisante.it. Solve the jobs and problems below. Choose the UX, screens, controls, flow, stack, and distribution approach yourself. Explain how your choices achieve the outcomes rather than treating these scenarios as a prescribed interface.

Distinguish hard requirements, proposed scope, and unresolved business policies. Build resolved parts without inventing bypasses for blocked cases.

## Goal and context

Help the person packing a parcel know that its physical contents match the current order before recording packing completion. Prevent missed units, accidental substitutions, and unintended extras.

The operator works on an iPhone near physical stock. Products can look alike, quantities can exceed one, work can be interrupted, and orders come from several systems. Fatture in Cloud, abbreviated FIC, supplies authoritative product names and codes. Order sources may use different titles.

The intended main verification method is reading product barcodes with the iPhone camera. The operator must know whether a scan was recognized, accepted as eligible, or rejected, and whether a packing action was recorded. A deliberate tap action must confirm the packing action. Barcode detection alone must not record a packed unit. These are needs for clear feedback and deliberate intent, not prescribed labels, layouts, or a multi-step flow.

## Jobs to be done

- When I start packing, I need the right current order across connected sources so that I do not pack an obsolete or ineligible order.
- When I pick an item, I need its exact FIC identity and required quantity so that similar names, sizes, and packaging do not cause substitutions.
- When I scan and pack, I need to distinguish product recognition from a recorded packing action so that camera activity does not become silent progress.
- When something does not match, I need to understand and resolve the physical discrepancy so that a correct digital count does not conceal a wrong parcel.
- When I return after an interruption, I need to know what is verified and what is uncertain so that I neither omit nor double-count units.
- When I finish, I need confidence that every ordered physical unit is verified and every discrepancy resolved. Packing completion must not imply shipment or source fulfillment.

## Concrete problem scenarios

Each scenario defines a job, a situation, and a desired outcome. Decide how the product achieves the outcome.

### Wrong product or lookalike

Job: Pack the exact product ordered.

Situation: The operator scans another product, including a similar fragrance, format, or size. Verified distinct examples are `MS001`, Cardamomo Sapone Mani 250ml, and `MS002`, Cardamomo Sapone Mani 500ml.

Desired outcome: The operator understands the mismatch. The wrong product earns no packing credit. The discrepancy remains unresolved until the operator accounts for the physical item and verifies the required product. Rejecting a scan does not establish that a wrong item was removed from the parcel.

### Excess quantity

Job: Pack exactly the required quantity without silent extras.

Situation: A product is scanned after its required quantity is satisfied. This could be another unit or a repeat read of a previous unit.

Desired outcome: Verified quantity never exceeds ordered quantity. The operator understands why the scan cannot add progress and resolves whether an extra physical item is present before completion. Rejection alone is not evidence that the extra item was set aside.

### Missing item

Job: Finish without leaving a required unit behind.

Situation: Most of an order is packed, but one product or one unit remains unverified.

Desired outcome: The operator can identify exactly what remains. Completion stays blocked even when every other line is satisfied.

### Quantity greater than one

Job: Verify every unit, not merely each product type.

Situation: An order requires several units with the same barcode. One valid read establishes the type but does not satisfy the whole quantity.

Desired outcome: Each required unit has its own deliberately confirmed packing action supported by verification. Partial quantities remain distinguishable from complete quantities.

### Repeated reads and the same bottle twice

Job: Avoid confusing camera activity with additional physical units.

Situation: A code remains visible, re-enters view, or the operator presents the same bottle again while more units are required.

Desired outcome: Repeated detection does not create automatic progress. The design reduces accidental repeat confirmations, and real packing trials evaluate that risk.

Ordinary SKU and EAN codes identify a product type, not an individual bottle. Two accepted reads of the same code cannot prove that two distinct bottles were packed. State this limit explicitly. Do not claim unique-unit proof without a separate source of individual-unit identity.

### Interruption, resume, and corrections

Job: Resume safely and correct mistakes without losing the relationship to the physical parcel.

Situation: The operator leaves, reloads, changes devices, removes a damaged unit, or discovers that recorded progress differs from the parcel. Another operator might also open the order.

Desired outcome: Progress is durable and attributable to the correct order. Uncertain, stale, or conflicting work is not treated as complete. A removed unit does not retain packing credit. Define supported ownership and concurrent-work policy rather than allowing silent conflicts.

### Order changes during packing

Job: Pack against the current obligation rather than an earlier snapshot.

Situation: Quantities, lines, cancellation, refund, or fulfillment status change after packing begins.

Desired outcome: Earlier progress cannot silently certify a changed order. The operator knows what needs reconciliation. Completion stays blocked until eligibility, quantities, and retained verification are reconciled. Establish freshness within the allowed pull model.

### Unknown barcode or uncertain mapping

Job: Establish which FIC product a physical code and source order line actually represent.

Situation: A code is unknown, a source SKU is blank, mappings conflict, or a title resembles an FIC name without an established identity link.

Desired outcome: Uncertainty remains visible and unresolved. No identity or barcode is invented. Name similarity never automatically establishes identity. Unmatched source titles may appear only as unresolved diagnostic text, never as claimed FIC names. Affected units receive no completion credit until identity and verification are established.

### Camera permission, unreadable label, or scan failure

Job: Verify the physical item despite a device or label problem.

Situation: Camera access is denied, a label is damaged, or detection fails.

Desired outcome: The operator knows that verification did not occur and understands what prevents progress. Failure does not become acceptance. An alternate physical-verification method requires an explicitly approved policy. Manual code entry or acknowledgement is not an automatic bypass.

### Network or source unavailable

Job: Distinguish unavailable information from an empty or completed workload.

Situation: The network, an order source, authentication, or a product lookup is unavailable.

Desired outcome: The operator can distinguish current, cached, and unavailable data. Failed reads do not appear as no orders or an all-clear result. Preserve work without fabricating freshness. Offline policy is a design decision, but unresolved freshness or identity must block completion.

### Physical kits and sets

Job: Verify the ordered kit as the correct complete physical item.

Situation: `MS010` Travel Kit has no GTIN in the surveyed register. Discovery Set has unresolved source identity coverage. Whole-kit and component-level verification are not interchangeable without a policy.

Desired outcome: Lack of a barcode does not exempt a physical kit. Propose and obtain approval for the verification policy, including any authoritative component definition. Until resolved, affected orders remain incomplete. Do not invent manual kit acknowledgement or assume components can substitute for the ordered kit.

### Free physical samples and nonphysical rows

Job: Account for required physical contents without demanding scans of accounting text.

Situation: Orders may include free physical samples, testers, shipping charges, notes, and accounting rows. Price, missing SKU, and labels such as `SAMPLE` do not establish whether a row represents physical contents.

Desired outcome: Required physical samples and testers follow the same unit-verification rules as paid products. Truly nonphysical shipping, note, and accounting rows need no physical scan. Uncertain classification remains unresolved rather than silently excluding a possible physical item.

## Success outcomes

The operator can explain what is verified, what remains, and why something was rejected. Valid work survives interruption without silent double counting. No physical product disappears from the obligation because it lacks a barcode or costs zero.

Completion is blocked whenever a physical unit lacks verification, identity is uncertain, an order change is unresolved, or any packing discrepancy remains unresolved. Zero remaining quantity alone is insufficient. Completion records an operator-supported packing assertion, not proof of unique bottles or shipment.

## Hard business, data, and security constraints

- FIC Prodotti e servizi is authoritative for product display names and `Codice`. Preserve distinct codes and sizes.
- FIC had no separate barcode field in surveyed product objects. Manisante uses `Codice` as the product code. Never overwrite it with an EAN.
- Maintain a separate barcode-to-FIC-product map. Existing Shopify variant barcodes may contribute. Ambiguous or conflicting mappings remain unresolved.
- Treat barcode values as exact strings and preserve leading zeroes. Do not silently coerce numbers or assume alternate representations are equivalent.
- Use a thin adapter layer to standardize source orders and centralize source-line and barcode matching. A heavy API framework is unnecessary. Choose the actual schema and stack.
- Preserve source order identity, line identity, quantities, mapping provenance, freshness, and packing progress conceptually. Do not merge separate orders because references or customer names resemble each other.
- Present connected sources as one coherent workload. Distinguish unavailable sources from sources with no orders.
- Pull on login, app open, or manual refresh only. No cron jobs or scheduled sync. Establish safe reconciliation within that constraint.
- Require authenticated internal access to customer orders, enforced server-side. Optional login or a public order interface is unacceptable.
- Keep integration tokens server-side, outside browser code and mobile bundles. Use least-privilege access. Never put credentials in chat, commits, logs, screenshots, or deliverables.
- Credentials on the survey machine are not automatically available to another agent, machine, or deployment. Request approved secure provisioning by credential name, never secret values in chat.
- Source access is read-only by default. Do not change products, barcodes, orders, inventory, fulfillment, shipping, or source statuses. App packed status is separate from shipped or fulfilled status. Future source writes require explicit authorization.
- Do not generate marketplace credentials, broaden permissions, send email, or conduct outreach. Document missing access instead.
- Minimize stored and logged customer data. Document access control, retention, and recovery.
- Internal iPhone distribution only. Public App Store submission is out of scope. The Italian invoicing entity remains unchanged. Do not use em dashes in copy or documentation for Fabio.

## Verified starting state

These findings are dated November 6, 2026, Asia/Hong_Kong. They are historical snapshots, not claims about current live data or guarantees of access on the builder's machine. Revalidate through authorized read-only access before operational use.

### Catalog and barcode coverage

- Shopify store `manisante.myshopify.com`, primary domain `manisante.it`, Basic plan, EUR.
- Of 33 active Shopify variants, 8 had barcode values and 25 did not. The 8 were oil perfumes and candles.
- 31 of 33 active variants had SKUs exactly matching FIC `Codice`. Two had blank SKUs, for the Vetiver room spray and Discovery Set. Titles alone do not establish their identity.
- FIC company `763305` had 68 product records. Surveyed product objects had no separate barcode field.
- The separate marketplace EAN register had 33 SKU rows, 32 with an EAN. It covered 22 of the 25 active Shopify variants whose Shopify barcode fields were empty.
- `MS010` Travel Kit had no GTIN in that register. The other two coverage gaps were the blank-SKU variants. Their identities and physical verification policies are not resolved by these counts.
- Verified name examples are `MS001`, Cardamomo Sapone Mani 250ml, and `MS002`, Cardamomo Sapone Mani 500ml. Their register EAN strings were `8050038450997` and `8050038450980`, respectively.

These eight Shopify barcode strings matched the separate register at survey time. Revalidate mappings before operational use.

| FIC Codice | Barcode string |
| --- | --- |
| MS024 | `0806812399109` |
| MS025 | `0806812399116` |
| MS026 | `0806812399123` |
| MS027 | `0806812399147` |
| MS028 | `0806812399130` |
| MS029 | `0806812399154` |
| MS030 | `0806812399161` |
| MS040 | `0806812399192` |

### Source access at survey time

- Shopify was connected and order reads worked. An open order was observed then. No historical order example is a promise of a packable order now. Eligibility must consider refunds, cancellations, and remaining physical fulfillment obligations, not merely an unfulfilled label.
- FIC product and issued-invoice reads worked. Document types `order` and `delivery_note` returned 403. FIC was usable as catalog authority, not a verified open-order feed. Invoice access alone does not establish packing obligations.
- FIC access used environment variable name `FATTURE_IN_CLOUD_API_KEY` on the survey machine. No value is included or requested here.
- Faire, Ankorstore, and OrderChamp had no usable tokens on the surveyed box. This is a dated local access finding, not evidence that their APIs do not exist.

For later authorized access, Faire's Brand Portal has Settings > Integrations. Ankorstore has Integrations > private apps. OrderChamp's supplier back office has Apps & Integrations > API. Portal details can change. Public documentation starts at https://developers.faire.com/, https://ankorstore.github.io/api-docs/, and https://developers.orderchamp.com/. Document required read access for Fabio or the coordinating agent. Do not create credentials yourself.

### Optional supporting files

These paths may exist on the original machine. They are optional context, not prerequisites or permission to retrieve credentials:

- `/workspace/packing-app-survey.md`
- `/workspace/manisante-marketplace/raw/v4/master_rows.json`
- `/workspace/shopify_variants_barcodes.json`
- `/workspace/fic_products_snapshot.json`
- `/workspace/barcode_map_summary.json`
- `/workspace/master_ean_by_sku.json`

If unavailable, use this brief to start and document what must be obtained securely. Do not fabricate missing records or describe fixtures as live data.

## Proposed scope and non-goals

A feasible first slice is Shopify order reads, FIC names and codes, the separate barcode lookup, and app-owned packing progress. This is a recommendation based on surveyed access, not a mandate to exclude other order sources. Keep the thin adapter suitable for Faire, Ankorstore, OrderChamp, and potentially FIC orders when authorized access permits them.

A phone web app is a starting recommendation, not a fixed implementation mandate. Compare it with private TestFlight distribution based on camera reliability, secure access, operational recovery, and maintenance. Explain the chosen trade-off.

Non-goals are marketplace catalog copy or photos, Shopify theme work, invoicing changes, source barcode cleanup, inventory management, shipping automation, public App Store submission, and unsolicited notifications. Original interest in importing order PDFs is context, not a first-slice requirement. Any proposed PDF intake needs the same identity and quantity guarantees.

## Open policy choices

Identify the decisions needed for safe operation and propose options with consequences. At minimum, address kits, absent or unreadable barcodes, physical-row classification, order eligibility and freshness, offline completion, corrections, and concurrent packing ownership.

Do not silently introduce overrides, substitutions, or manual verification as defaults. Unresolved cases fail closed. Missing marketplace credentials need not block authorized sources. Missing policy for an affected product must block that order's completion rather than force an invented policy.

## Outcome-based acceptance scenarios

Demonstrate these outcomes without tying evidence to a particular interface:

1. An authenticated operator can work with eligible orders from available sources. Unauthenticated access exposes neither customer orders nor integration credentials.
2. Resolved lines use authoritative FIC names and codes. Unresolved lines are not presented as resolved FIC identities.
3. An order requiring several identical units remains incomplete after one verified, deliberately confirmed unit. Detection alone never adds a packed unit.
4. Wrong-product and excess scans earn no credit. The operator understands and resolves the physical discrepancy before completion is possible.
5. One missing physical unit, including a required free sample, prevents completion. Truly nonphysical shipping and notes require no physical verification.
6. Repeated reads do not silently add units. Evidence acknowledges that identical product-type codes cannot prove distinct bottles.
7. Interrupted work resumes without silent loss or duplicate credit. Removed physical units do not retain unjustified credit.
8. Changed quantities, cancellation, or conflicting work cannot inherit an earlier all-clear without reconciliation.
9. Unknown codes, ambiguous mappings, scan failures, and kits without approved policy remain unresolved. Leading zeroes survive matching and storage.
10. Source failure is distinguishable from an empty workload. Stale data cannot silently certify current-order correctness.
11. App-level packing completion performs no source fulfillment or shipping write. Read-only operation leaves FIC Codice and Shopify products unchanged.
12. The chosen implementation works on an actual iPhone in representative packing conditions. Report what was tested, simulated, or not verified.

## What the builder should deliver

- A product and implementation rationale connecting design choices to these jobs and problems. State unresolved policies and how each remains blocked.
- A working internal iPhone product for the agreed first slice, with authenticated access, thin read-only source adapters, and separate packing records. Choose the UX and stack.
- A validated barcode mapping artifact with provenance, conflicts, and coverage gaps. Do not manufacture missing codes or names.
- Outcome-based verification evidence, representative failure scenarios, and real-device results. Clearly label fixtures where live access is unavailable.
- Source code and operational documentation covering setup, deployment, credential variable names only, access, retention, recovery, supported sources, and known limits.
- A handoff distinguishing implemented behavior, proposed policy, blocked cases, and future scope. Never describe a blocked kit or unavailable source as supported.

Optimize for accurate physical packing and honest uncertainty, not a particular number of screens or a prescribed scan sequence.
