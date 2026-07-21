/**
 * ST120GeneratorExtensionTest
 * -----------------------------
 * HVAC-303 Option A — Purchase Order pivot (2026-07-08).
 *
 * Rewritten for AcctSeedERP__Purchase_Order__c. Uses SeeAllData=true to
 * query real Purchase Order records from the org, avoiding the AcctSeed
 * managed-package trigger's complex data requirements.
 *
 * `new ApexPages.StandardController(record)` works against any SObject,
 * so these tests simply construct it with a queried Purchase Order record.
 */
@isTest(SeeAllData=true)
private class ST120GeneratorExtensionTest {

    private static AcctSeedERP__Purchase_Order__c findPoWithWorkOrder() {
        return [
            SELECT Id, Name, AcctSeedERP__Vendor__r.Name, AcctSeedERP__Vendor__r.BillingStreet,
                   AcctSeedERP__Vendor__r.BillingCity, AcctSeedERP__Vendor__r.BillingState,
                   AcctSeedERP__Vendor__r.BillingPostalCode,
                   Work_Order__r.Account.Name, Work_Order__r.Street,
                   Work_Order__r.City, Work_Order__r.State, Work_Order__r.PostalCode
            FROM AcctSeedERP__Purchase_Order__c
            WHERE Work_Order__c != null
            LIMIT 1
        ];
    }

    @isTest
    static void testExtension_NoUrlOverrides() {
        AcctSeedERP__Purchase_Order__c po = findPoWithWorkOrder();
        Assert.isNotNull(po, 'No PO with a linked Work Order found in the org');

        ApexPages.StandardController sc = new ApexPages.StandardController(po);

        Test.startTest();
        ST120GeneratorExtension ext = new ST120GeneratorExtension(sc);
        Test.stopTest();

        Assert.isNotNull(ext.vendorName);
        Assert.isNotNull(ext.exemptOrgName);
        Assert.isNotNull(ext.jobSiteAddress);
        Assert.isNotNull(ext.vendorStreet);
        Assert.isNotNull(ext.vendorCity);
        Assert.isNotNull(ext.vendorState);
        Assert.isNotNull(ext.vendorZip);
        Assert.isNotNull(ext.projectDescription);
        Assert.isNotNull(ext.primeContractDate);
        Assert.areEqual(po.Name, ext.orderNumber);
        Assert.areEqual('A', ext.exemptionReasonBox);
    }

    @isTest
    static void testExtension_WithUrlOverrides() {
        AcctSeedERP__Purchase_Order__c po = findPoWithWorkOrder();
        Assert.isNotNull(po, 'No PO with a linked Work Order found in the org');

        Test.setCurrentPageReference(new PageReference('/apex/ST120Certificate'));
        ApexPages.currentPage().getParameters().put('vendorName', 'Override Vendor Name');
        ApexPages.currentPage().getParameters().put('exemptionBox', 'B');
        ApexPages.currentPage().getParameters().put('additionalInfo', 'Some additional info');

        ApexPages.StandardController sc = new ApexPages.StandardController(po);

        Test.startTest();
        ST120GeneratorExtension ext = new ST120GeneratorExtension(sc);
        Test.stopTest();

        Assert.areEqual('Override Vendor Name', ext.vendorName);
        Assert.areEqual('B', ext.exemptionReasonBox);
        Assert.areEqual('Some additional info', ext.additionalInfo);
    }

    @isTest
    static void testExtension_PassThroughGetters() {
        AcctSeedERP__Purchase_Order__c po = findPoWithWorkOrder();
        Assert.isNotNull(po, 'No PO with a linked Work Order found in the org');

        ApexPages.StandardController sc = new ApexPages.StandardController(po);

        Test.startTest();
        ST120GeneratorExtension ext = new ST120GeneratorExtension(sc);
        Test.stopTest();

        Assert.areEqual('Michael James Industries, Inc.', ext.mjiName);
        Assert.areEqual('11 Drew Court', ext.mjiStreet);
        Assert.areEqual('Ronkonkoma, NY 11741', ext.mjiCityStateZip);
        Assert.isNotNull(ext.caNumber);
        Assert.isNotNull(ext.generationDate);
        Assert.isNotNull(ext.formVersion);
        Assert.isNotNull(ext.vendorName);
        Assert.isNotNull(ext.vendorStreet);
        Assert.isNotNull(ext.vendorCity);
        Assert.isNotNull(ext.vendorState);
        Assert.isNotNull(ext.vendorZip);
        Assert.isNotNull(ext.jobSiteAddress);
        Assert.isNotNull(ext.projectDescription);
        Assert.isNotNull(ext.exemptOrgName);
        Assert.isNotNull(ext.primeContractDate);
        Assert.isNotNull(ext.orderNumber);
        Assert.isNotNull(ext.exemptionReasonBox);
        Assert.isNotNull(ext.signerName);
        Assert.isNotNull(ext.signerTitle);
    }
}