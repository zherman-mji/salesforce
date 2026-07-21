# ST-120.1 Tax-Exempt Certificate — Order → Purchase Order Pivot (HVAC-303 Option A)

Date: 2026-07-08

This package migrates the ST-120.1 tax-exempt-certificate automation from the
standard `Order` object to `AcctSeedERP__Purchase_Order__c`. Everything not
listed below is unchanged from prod commit `fd5f074`.

## force-app/main/default/classes/ST120Generator.cls

- All SOQL against `Order` (with the `WorkOrderLineItems` child query) replaced
  with a single query against `AcctSeedERP__Purchase_Order__c`, joining:
  - `AcctSeedERP__Vendor__c` / `AcctSeedERP__Vendor__r` (Account) for
    vendor name/address/policy fields (replaces `Order.Account`).
  - `Work_Order__c` / `Work_Order__r` (WorkOrder) as a single direct lookup
    (replaces the `WorkOrderLineItems` child relationship and "firstWoli"
    list-handling logic entirely — no list iteration needed anymore).
- Added `WO_LOOKUP_FIELD` / `WO_LOOKUP_RELATIONSHIP` private static final
  String constants at the top of the class, documented as the single
  reference point if the Work Order lookup API name differs from
  `Work_Order__c` / `Work_Order__r` (confirmed against prod 2026-07-07). The
  SOQL itself is static (not dynamic) for compile-time safety, with a
  prominent "VERIFY BLOCK" comment directly above the query listing exactly
  which literal tokens to change if the schema differs.
- `data.orderNumber` now comes from PO `Name` (was `Order.OrderNumber`).
- `data.fileName` changed to `'ST120_' + cleanFileName(vendorName) + '_' + Name + '_' + date + '.pdf'`
  (dropped the extra literal `'PO'` prefix since `Name` already reads like
  `PO-00033`).
- Email subject in `sendSeparateEmail` changed from
  `'... – PO #' + data.orderNumber` to `'... – ' + data.orderNumber`.
- `data.exemptOrgName` now falls back to `Work_Order__r.Account.Name` when the
  WO lookup is populated (and its `AccountId` is set), else to the vendor
  account name (`AcctSeedERP__Vendor__r.Name`) — same fallback semantics as
  before, just sourced from the PO/WO fields instead of Order/WOLI.
- `projectDescriptionSource` fallback text for "no work order" changed from
  `'Standard service description (no Work Orders on PO)'` to
  `'Standard service description (no Work Order linked to PO)'`.
- `data.primeContractDate` now falls back to `po.CreatedDate.date().format()`
  when `Prime_Contract_Date__c` is blank (PO has no `EffectiveDate` field to
  fall back to, unlike Order).
- **Bug fix**: in `generateSinglePdf`, `pdfPage.getParameters().put(...)` now
  uses the key `'id'` (the standard-controller record-id parameter) instead
  of the previously-incorrect `'orderId'`. The `vendorName` /
  `exemptionBox` / `additionalInfo` override params are unchanged.
- `sendSeparateEmail`'s `EmailMessage` insert (used only for after-the-fact
  logging, not for actually sending the email) is now wrapped in
  `try/catch (Exception e) { System.debug(LoggingLevel.WARN, ...); }`, with a
  comment noting that custom objects (including Purchase Order) only accept
  `EmailMessage.RelatedToId` when Activities are enabled on that object — so a
  disabled-activities org no longer breaks the actual `Messaging.sendEmail`
  call that already succeeded.
- `checkVendorPolicy` now queries the PO with
  `AcctSeedERP__Vendor__r.Tax_Exempt_Policy__c` / `...Tax_Exempt_Notes__c`
  instead of `Order.Account.Tax_Exempt_Policy__c` / `...Tax_Exempt_Notes__c`.
  All 5 branch behaviors (Do Not Send / Short Pay Only / After Invoice Only /
  Manual Process Required / no policy → null) are unchanged.
- `resendCertificate`'s exception message changed from
  `'No ST-120.1 certificate found for this Order.'` to
  `'...this Purchase Order.'`.
- Class-level doc comment rewritten to describe the PO pivot, reference
  HVAC-303 Option A, and note the date (2026-07-08).
- **Unchanged for Screen Flow compatibility**: `GenerateRequest.orderId`
  member name and its `@InvocableVariable(label='Order ID' ...)` label,
  all other `GenerateRequest`/`CertificateData` member names, the
  `@InvocableMethod` label/description text pattern, and the
  `buildCertificateData(Id orderId)` public signature. A comment was added
  next to `GenerateRequest.orderId` clarifying it now carries a Purchase
  Order Id despite the legacy name/label.

## force-app/main/default/classes/ST120DataProvider.cls

- No functional change beyond following `ST120Generator`'s new return
  values (still calls `ST120Generator.buildCertificateData(orderId)` and
  maps every field 1:1 into `CertificateDataOutput`, same as before).
- Class-level doc comment updated for the PO pivot.
- `@InvocableVariable` member **names** on `CertificateDataOutput` and the
  `orderIds` parameter of `prepareData` are unchanged.
- **Assumption/flag**: the original `ST120DataProvider.cls` could not be read
  during this migration (path outside connected folders — see "Assumptions"
  below), so this file was reconstructed from the spec's member list. Member
  *names* are taken directly from the spec and should match prod exactly.
  Member **label** strings (the `label='...'` text in each
  `@InvocableVariable`) are best-effort reconstructions and were not
  verified against the original source. This is flagged in a code comment.
  Labels are cosmetic in Flow Builder (Flow binds to variables by member
  name, not label), so this does not affect Flow functionality, but should
  be diffed against prod before assuming full label parity.
- Added a `null` guard in `prepareData` (`if (orderIds == null) return outputs;`)
  so the "prepareData with null input" test scenario passes deterministically;
  flagged as a reconstruction assumption since the original implementation
  couldn't be read.

## force-app/main/default/classes/ST120GeneratorExtension.cls

- No functional change: still a `with sharing` extension on
  `ApexPages.StandardController`, still calls
  `ST120Generator.buildCertificateData(stdController.getId())`, still applies
  the same three URL-parameter overrides (`vendorName`, `exemptionBox`,
  `additionalInfo`), still exposes the same 20 pass-through getters with the
  same names.
- Class-level doc comment updated to note the page's standard controller now
  runs against `AcctSeedERP__Purchase_Order__c` (handled at the VF page /
  layout level, outside this class — the page file itself was explicitly
  out of scope for this package).
- **Assumption/flag**: the original file could also not be read (same path
  restriction); reconstructed from the spec's getter list, which fully
  enumerates all 20 getters — no ambiguity here since getter names map 1:1
  to `CertificateData` members that are already fully specified in
  `ST120Generator.cls`.

## force-app/main/default/classes/ST120GeneratorTest.cls (+ .cls-meta.xml)

- Rewritten against `AcctSeedERP__Purchase_Order__c`. Since PO `Name` is
  assumed auto-number, records created in `@TestSetup` are re-queried in each
  test method by a `Tax_Exempt_Contact_Name__c` marker string (e.g.
  `INSTALL-NOPROJ-TEST`, `INSTALL-PROJ-TEST`, `SERVICE-TEST`, `NOWO-TEST`)
  rather than by `Name`.
- PO records are inserted with only `AcctSeedERP__Vendor__c`, `Work_Order__c`
  (where applicable), and the 5 new custom fields — per the instruction that
  managed-package required fields beyond the vendor lookup are unverified.
  A comment header on the class flags this and points at
  `scripts/verify_schema.apex` for follow-up if a validate-only deploy fails
  on `REQUIRED_FIELD_MISSING`.
- Preserved scenarios/assertions: install-WO-no-project warning branch,
  install-WO-with-project branch, service-WO branch, no-WO fallback (exempt
  org = vendor name, updated source text), exempt-org-from-WO-account,
  prime-contract-date CreatedDate fallback, `prepareData` null/empty/single,
  `generatePdf` Separate/default-Email/Hold modes, `resendCertificate`
  success + no-certificate exception, and all 5 `checkVendorPolicy` branches
  (now driven off the vendor Account of a PO).
- Site/Vendor Account record-type helper methods and WorkOrder setup
  (WorkTypes `Installation Work` / `Service Call`, addresses set on the
  WorkOrder) preserved in spirit from the original Order-based tests.
- Assumptions (flagged in the class header): `WorkOrder.Status = 'New'` is a
  valid picklist value; `Project__c.Name` is a settable Text field (not
  auto-number); Account has `Vendor` and `Site` record types by that exact
  `DeveloperName`.
- Because `sendSeparateEmail`'s `EmailMessage` logging is now best-effort
  (try/catch), the Separate-mode test only asserts that PDF generation and
  send complete without throwing, rather than asserting an `EmailMessage`
  row was created.

## force-app/main/default/classes/ST120GeneratorExtensionTest.cls (+ .cls-meta.xml)

- Rewritten to construct `new ApexPages.StandardController(po)` with a
  queried `AcctSeedERP__Purchase_Order__c` record (works against any
  SObject). Covers: no-URL-override baseline (vendor name, exempt org from
  WO account, job site address, order number, default exemption box),
  URL-param overrides (`vendorName`, `exemptionBox`, `additionalInfo`), and
  pass-through getters for the static MJI fields / generation date / form
  version.
- Same Site/Vendor record-type + WorkOrder setup pattern as
  `ST120GeneratorTest`, scoped to a single WorkOrder/PO pair marked with
  `Tax_Exempt_Contact_Name__c = 'EXT-BASE-TEST'`.

## force-app/main/default/permissionsets/ST120_Tax_Exempt_Certificate.permissionset-meta.xml

- Replaced the 5 `Order.*` `fieldPermissions` entries with their
  `AcctSeedERP__Purchase_Order__c.*` equivalents (`Tax_Exempt_Purchase__c`,
  `Cert_Delivery_Mode__c`, `Tax_Exempt_Contact_Email__c`,
  `Tax_Exempt_Contact_Name__c`, `Prime_Contract_Date__c`).
- Left the 2 `Account.*` field permissions, all 3 `classAccesses`, and the
  `pageAccesses` entry unchanged.
- Updated `<description>` to mention the PO pivot and HVAC-303 Option A date.
- Per instructions, the old `Order.*` field grants are simply omitted going
  forward from this permission set — they are **not** removed from prod as
  part of this deploy (no destructive changes included).

## New custom fields on AcctSeedERP__Purchase_Order__c

All created at API version 62.0 with `required=false` (except Checkbox,
which cannot be required):

- `Tax_Exempt_Purchase__c` — Checkbox, `defaultValue=false`, label "Tax Exempt Purchase".
- `Cert_Delivery_Mode__c` — restricted Picklist, label "Cert Delivery Mode",
  values: `Email` ("Attach to PO Email", default), `Separate` ("Send Separately"),
  `Hold` ("Hold"). Apex switches on these fullName strings.
- `Tax_Exempt_Contact_Email__c` — Email, label "Tax Exempt Contact Email".
- `Tax_Exempt_Contact_Name__c` — Text(120), label "Tax Exempt Contact Name".
  Also doubles as the test-marker field described above.
- `Prime_Contract_Date__c` — Date, label "Prime Contract Date".

## manifest/package.xml

- New package.xml (API version 62.0) listing: the 5 Apex classes
  (`ST120Generator`, `ST120DataProvider`, `ST120GeneratorExtension`,
  `ST120GeneratorTest`, `ST120GeneratorExtensionTest`); the `ST120Certificate`
  Apex page; the 5 new `AcctSeedERP__Purchase_Order__c` custom fields; and
  the `ST120_Tax_Exempt_Certificate` permission set.

## scripts/verify_schema.apex

- New anonymous Apex script. Describes `AcctSeedERP__Purchase_Order__c` and
  prints, via `System.debug`: (a) whether `Name` is auto-number; (b) API
  name + relationship name of every lookup field whose `referenceTo`
  includes `WorkOrder`; (c) the vendor lookup's API name/relationship/
  referenceTo; (d) every custom, createable, non-nillable field (candidates
  for "required" fields the test classes may need to add); (e) whether each
  of the 5 new ST-120 fields already exists. Intended to be run before
  deploying this package to confirm/refute the `Work_Order__c` /
  `Work_Order__r` VERIFY assumption and to pre-empt required-field surprises
  in the test classes.

## Assumptions made (Read access to /Users/zac/wo-summary was denied)

The task allowed reading original sources from
`/Users/zac/wo-summary/salesforce/sfdx/force-app/main/default/` if accessible,
falling back to the embedded spec otherwise. The Read tool reported that path
as outside this session's connected folders (permission denied), for
`ST120DataProvider.cls`, `ST120GeneratorExtension.cls`,
`ST120GeneratorTest.cls`, and `ST120GeneratorExtensionTest.cls`. Per the task
instructions, all four were reconstructed solely from the embedded
spec/source-of-truth in the prompt:

1. `ST120DataProvider.CertificateDataOutput` and `ST120GeneratorExtension`
   getter **names** are taken verbatim from the spec's explicit member/getter
   lists, so these should match prod exactly. `CertificateDataOutput`
   `@InvocableVariable` **label** strings are best-effort (Title Case of the
   field's purpose) and not verified against prod — flagged in-code. Labels
   are Flow-cosmetic only, not functionally binding.
2. Added a defensive `null` check at the top of
   `ST120DataProvider.prepareData` so `prepareData(null)` returns an empty
   list rather than throwing — needed for the "prepareData null" test
   scenario; flagged as a reconstruction assumption.
3. Test classes assume: `WorkOrder.Status = 'New'` is insertable;
   `Project__c.Name` is a plain settable Text field; Account record types
   `Vendor` and `Site` exist by those exact `DeveloperName` values; and that
   Activities are enabled somewhere for `EmailMessage` inserts to succeed in
   at least one org (the Separate-mode test does not hard-assert this,
   consistent with the try/catch fix in item 5 of the required changes).
4. `AcctSeedERP__Purchase_Order__c` managed-package required fields beyond
   `AcctSeedERP__Vendor__c` are unverified; test `@TestSetup` inserts are
   intentionally minimal (vendor + work order + the 5 new fields) per the
   task's explicit instruction, with `scripts/verify_schema.apex` provided
   to identify any additional required fields if a validate-only deploy
   fails.
5. The VF page (`ST120Certificate.page`) itself is out of scope for this
   package per the task instructions and was not produced or modified.