// verify_schema.apex
// ---------------------------------------------------------------------------
// Anonymous Apex — run before deploying the ST-120 Purchase Order pivot to
// confirm the AcctSeedERP__Purchase_Order__c schema assumptions baked into
// ST120Generator.cls (see the "VERIFY" comment block in buildCertificateData()).
//
// Usage:
//   sf apex run --file scripts/verify_schema.apex --target-org <alias>
//
// Prints, via System.debug:
//   (a) whether Name is an auto-number field
//   (b) every lookup field whose relationship targets WorkOrder (to confirm Work_Order__c)
//   (c) the vendor lookup field/relationship
//   (d) every custom, createable, non-nillable field (candidate "required" fields for tests)
//   (e) whether the 5 new ST-120 custom fields already exist
// ---------------------------------------------------------------------------

Schema.DescribeSObjectResult poDescribe = AcctSeedERP__Purchase_Order__c.SObjectType.getDescribe();
Map<String, Schema.SObjectField> fieldMap = poDescribe.fields.getMap();

System.debug('================================================================');
System.debug('=== (a) Name field — auto-number check =======================');
System.debug('================================================================');
Schema.DescribeFieldResult nameDescribe = fieldMap.get('name').getDescribe();
System.debug('Name API name        : ' + nameDescribe.getName());
System.debug('Name isAutoNumber     : ' + nameDescribe.isAutoNumber());
System.debug('Name isCreateable     : ' + nameDescribe.isCreateable() + ' (auto-number fields are typically NOT createable)');

System.debug('================================================================');
System.debug('=== (b) Lookup fields whose referenceTo includes WorkOrder ====');
System.debug('================================================================');
Boolean foundWorkOrderLookup = false;
for (String apiName : fieldMap.keySet()) {
    Schema.DescribeFieldResult dfr = fieldMap.get(apiName).getDescribe();
    if (dfr.getType() == Schema.DisplayType.REFERENCE) {
        for (Schema.SObjectType refType : dfr.getReferenceTo()) {
            if (refType.getDescribe().getName() == 'WorkOrder') {
                foundWorkOrderLookup = true;
                System.debug('WorkOrder lookup -> API Name: ' + dfr.getName() + ', RelationshipName: ' + dfr.getRelationshipName());
            }
        }
    }
}
if (!foundWorkOrderLookup) {
    System.debug('WARNING: no lookup field referencing WorkOrder was found on AcctSeedERP__Purchase_Order__c.');
}

System.debug('================================================================');
System.debug('=== (c) Vendor lookup =========================================');
System.debug('================================================================');
if (fieldMap.containsKey('acctseederp__vendor__c')) {
    Schema.DescribeFieldResult vendorDfr = fieldMap.get('acctseederp__vendor__c').getDescribe();
    System.debug('Vendor lookup API Name    : ' + vendorDfr.getName());
    System.debug('Vendor RelationshipName   : ' + vendorDfr.getRelationshipName());
    System.debug('Vendor ReferenceTo        : ' + vendorDfr.getReferenceTo());
} else {
    System.debug('WARNING: AcctSeedERP__Vendor__c was not found on AcctSeedERP__Purchase_Order__c.');
}

System.debug('================================================================');
System.debug('=== (d) Custom, createable, non-nillable fields (candidate ====');
System.debug('===     "required" fields to set on insert in tests) ==========');
System.debug('================================================================');
for (String apiName : fieldMap.keySet()) {
    Schema.DescribeFieldResult dfr = fieldMap.get(apiName).getDescribe();
    if (dfr.getName().endsWith('__c') && dfr.isCreateable() && !dfr.isNillable()) {
        System.debug('Required-ish custom field: ' + dfr.getName() + ' (type: ' + dfr.getType() + ')');
    }
}

System.debug('================================================================');
System.debug('=== (e) Do the 5 new ST-120 fields already exist? =============');
System.debug('================================================================');
List<String> newFields = new List<String>{
    'Tax_Exempt_Purchase__c',
    'Cert_Delivery_Mode__c',
    'Tax_Exempt_Contact_Email__c',
    'Tax_Exempt_Contact_Name__c',
    'Prime_Contract_Date__c'
};
for (String f : newFields) {
    System.debug(f + ' exists: ' + fieldMap.containsKey(f.toLowerCase()));
}

System.debug('================================================================');
System.debug('=== Verification complete. Compare output against the =========');
System.debug('=== WO_LOOKUP_FIELD / WO_LOOKUP_RELATIONSHIP constants in ======');
System.debug('=== ST120Generator.cls before deploying.                =======');
System.debug('================================================================');