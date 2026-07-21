# ST-120.1 Tax-Exempt Certificate: Order → AcctSeed Purchase Order Pivot

**Linear:** HVAC-303, Option A
**Branch:** `hvac-303-po-pivot`
**Repo:** wo-summary/salesforce/sfdx
**Prior prod deploy (baseline, currently live):** `0AfPQ000001ZPiv0AG`, commit `fd5f074`
**Target object:** `AcctSeedERP__Purchase_Order__c` (replaces `Order`, which has 0 records in prod)
**Executor:** Hermes agent (sf CLI authenticated, org alias `mji-prod`, instance `michaeljamesindustries.my.salesforce.com`). Zac's Mac has no sf CLI — all `sf` commands below run in Hermes.

---

## 0. What's changing

| Area | From | To |
|---|---|---|
| SOQL root object | `Order` | `AcctSeedERP__Purchase_Order__c` |
| Vendor / billing address | n/a | `AcctSeedERP__Vendor__r` → Account Billing address |
| Job site / exempt org | WorkOrderLineItem chain | direct `Work_Order__c` lookup → `WorkOrder` |
| VF page `standardController` | `Order` | `AcctSeedERP__Purchase_Order__c` |
| Custom fields (5) | on `Order` | on `AcctSeedERP__Purchase_Order__c` |
| Permission set FLS | Order fields | new PO fields (same permset) |
| PageReference param | `orderId` (bug) | `id` (fixed) |
| EmailMessage logging | unguarded | wrapped in try/catch (needs activities enabled on PO) |
| Flow `Generate_Tax_Exempt_Certificate` | — | **unchanged**, no rebuild needed (invocable names/labels stable) |

---

## 1. Pre-deploy verification (5 min)

Run in Dev Console → Execute Anonymous (or `sf apex run --file scripts/verify_schema.apex -o mji-prod`) against **mji-prod**:

```
scripts/verify_schema.apex
```

Confirm before proceeding:

- [ ] `Work_Order__c` is the correct API name of the lookup field on `AcctSeedERP__Purchase_Order__c` pointing to `WorkOrder` (check for namespace prefix or a different field name — if it differs, fix the tokens documented in the comment block at the top of `ST120Generator` and in the test classes before deploying).
- [ ] Whether PO `Name` is an auto-number field (affects any hardcoded name assumptions in tests/data setup).
- [ ] Any non-nillable (required) custom fields on `AcctSeedERP__Purchase_Order__c` that test data inserts must populate — list them, they'll be needed in step 2 if validation fails.
- [ ] Activities enabled on Purchase Order object: Setup → Object Manager → Purchase Order → Activity Settings (or Feature Settings) → confirm "Allow Activities" is checked. If not enabled, EmailMessage logging will be silently skipped (by design — see Known Gaps).
- [ ] None of the 5 target field API names already exist on `AcctSeedERP__Purchase_Order__c`: `Tax_Exempt_Purchase__c`, `Cert_Delivery_Mode__c`, `Tax_Exempt_Contact_Email__c`, `Tax_Exempt_Contact_Name__c`, `Prime_Contract_Date__c`.

If `Work_Order__c` token needs to change: edit `ST120Generator`, `ST120GeneratorTest`, `ST120GeneratorExtensionTest` per the comment block, commit, then proceed.

---

## 2. Deploy (validate-first)

Validate:

```bash
sf project deploy validate \
  --manifest manifest/package-po-pivot.xml \
  -o mji-prod \
  --test-level RunSpecifiedTests \
  --tests ST120GeneratorTest ST120GeneratorExtensionTest
```

- [ ] Validation passes with 0 failures and required code coverage met.
- If test PO inserts fail on managed required fields (e.g., AcctSeed-required fields on `AcctSeedERP__Purchase_Order__c`), add them to test setup per the verify script's output, commit, and re-run validate.

Quick-deploy on pass (uses the validated deploy ID from above):

```bash
sf project deploy quick-deploy --job-id <VALIDATED_DEPLOY_ID> -o mji-prod
```

(Metadata API deploy is required — Tooling API deploy of Apex/VF on this production org fails with `ENTITY_IS_LOCKED`, same as the original deploy.)

- [ ] Confirm deploy status = Succeeded in Setup → Deployment Status, note the new deploy ID for the rollback record.

---

## 3. Post-deploy Setup UI steps (~10 min, Zac)

a. **Add the Flow action to PO:**
   Object Manager → Purchase Order (`AcctSeedERP__Purchase_Order__c`) → Buttons, Links, and Actions → New Action → Action Type: Flow → Flow: `Generate_Tax_Exempt_Certificate` → Label: "Generate Tax Exempt Certificate" → Save.

b. **PO page layout:**
   - [ ] Add "Generate Tax Exempt Certificate" action to both Salesforce Mobile and Lightning Experience Actions section.
   - [ ] Add the 5 fields to the layout — new section suggested, e.g. "Tax Exempt": `Tax_Exempt_Purchase__c`, `Cert_Delivery_Mode__c`, `Tax_Exempt_Contact_Email__c`, `Tax_Exempt_Contact_Name__c`, `Prime_Contract_Date__c`.
   - [ ] Add Files related list to the layout.

c. **Account (Vendor record type) layout:**
   - [ ] Confirm `Tax_Exempt_Policy__c` and `Tax_Exempt_Notes__c` are present (carried over from the original plan — these were already correctly placed on Account, no change needed here).

d. **Flow:**
   - [ ] No changes needed. Only open `Generate_Tax_Exempt_Certificate`, re-save, and re-activate if the action picker in step (a) complains about the invocable actions — invocable method signatures are unchanged so this should not be necessary.

e. **Permission set:**
   - [ ] No re-assignment needed. "ST120 Tax Exempt Certificate" permission set already assigned to Zac Herman and Michele Champion; updated FLS for the 5 new PO fields rides along with this same permset via the deploy.

---

## 4. Test plan (re-targeted to PO)

Use a real PO with `Work_Order__c` populated, e.g. **PO-00033 → WO 00004202 → "PL Developments 200 Hicks Street"**.

1. **PDF sanity check** — browse to:
   `https://michaeljamesindustries.my.salesforce.com/apex/ST120Certificate?id=<PO_ID>`
   - [ ] PDF renders.
   - [ ] Exempt org on the certificate = customer/job site account (from Work Order), **not** the vendor.

2. **Data assembly check** — Execute Anonymous:
   ```apex
   System.debug(JSON.serializePretty(ST120Generator.buildCertificateData('<PO_ID>')));
   ```
   - [ ] Vendor name/address sourced from `AcctSeedERP__Vendor__r` → Account Billing address.
   - [ ] Job site / exempt org sourced from `Work_Order__c` → `WorkOrder`.

3. **Flow — Hold mode** from the PO record:
   - [ ] PDF lands in Files on the PO.
   - [ ] No email sent.

4. **Flow — Send Separately** to own email:
   - [ ] Email received.
   - [ ] `EmailMessage` logged on PO activity (only if activities enabled per step 1 check).

5. **Flow — Attach-to-PO-Email mode:**
   - [ ] Only attaches; does not send independently.

6. **Overrides:**
   - [ ] Vendor Name override applies.
   - [ ] Box C override applies.

7. **Fallback case** — run against a PO with no `Work_Order__c` populated:
   - [ ] Description falls back to "HVAC Services and Repairs".
   - [ ] Exempt org falls back to vendor name.
   - [ ] Manually review before sending in this fallback scenario.

---

## 5. Cleanup (after PO version verified)

- [ ] Delete the 5 orphaned fields from `Order`: `Tax_Exempt_Purchase__c`, `Cert_Delivery_Mode__c`, `Tax_Exempt_Contact_Email__c`, `Tax_Exempt_Contact_Name__c`, `Prime_Contract_Date__c`. Safe — `Order` has 0 records and the permission set no longer references these fields.
- [ ] Delete any quick action created on the `Order` object during the original rollout, if one exists.

---

## 6. Known gaps carried forward

- `checkVendorPolicy` is still not flow-callable — there is no "Do Not Send" blocking behavior in the flow. Needs an invocable Apex wrapper plus a Decision element in `Generate_Tax_Exempt_Certificate` to actually enforce it.
- MJI's own address is still hard-coded in the certificate rather than sourced from CMDT (`Tax_Exempt_Form_Config__mdt`).
- `EmailMessage` logging is silently skipped if activities are not enabled on `AcctSeedERP__Purchase_Order__c` — no error surfaced to the user.

---

## 7. Rollback

The old Order-based code paths are replaced in place (not additive), so rollback is a redeploy of the prior baseline:

```bash
# From the hvac-303-po-pivot branch (which has the manifest), restore the
# baseline source, then deploy classes + page + permset (the new PO
# CustomFields in the manifest can be omitted or left — they're inert):
git checkout fd5f074 -- force-app
sf project deploy start --manifest manifest/package-po-pivot.xml -o mji-prod \
  --test-level RunSpecifiedTests --tests ST120GeneratorTest ST120GeneratorExtensionTest
```

- New PO fields and PO permission set FLS added by this deploy can be left in place — they are inert once the Order-based code is restored and cause no harm.
- No need to remove the Flow's PO Quick Action or PO layout changes for rollback to succeed; they simply become unused if the pivot is reverted.
