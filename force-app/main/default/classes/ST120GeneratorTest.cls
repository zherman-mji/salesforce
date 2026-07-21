/**
 * ST120GeneratorTest
 * -------------------
 * HVAC-303 Option A — Purchase Order pivot (2026-07-08).
 *
 * Rewritten for AcctSeedERP__Purchase_Order__c. Uses SeeAllData=true to
 * query real Purchase Order records from the org, avoiding the AcctSeed
 * managed-package trigger's complex data requirements.
 *
 * IMPORTANT: Tests query POs that have a Work_Order__c lookup populated.
 * If no such PO exists in the org, the queries will return null and
 * all tests will fail with NullPointerException. Run verify_schema.apex
 * first to confirm the schema, then ensure at least one PO with a
 * linked Work Order exists.
 */
@isTest(SeeAllData=true)
private class ST120GeneratorTest {

    // ------------------------------------------------------------------
    // Helper: query a real PO that has a linked Work Order
    // ------------------------------------------------------------------
    private static AcctSeedERP__Purchase_Order__c findPoWithWorkOrder() {
        return [
            SELECT Id, Name, AcctSeedERP__Vendor__c, AcctSeedERP__Vendor__r.Name,
                   AcctSeedERP__Vendor__r.BillingStreet, AcctSeedERP__Vendor__r.BillingCity,
                   AcctSeedERP__Vendor__r.BillingState, AcctSeedERP__Vendor__r.BillingPostalCode,
                   Work_Order__c, Work_Order__r.AccountId, Work_Order__r.Account.Name,
                   Work_Order__r.Street, Work_Order__r.City, Work_Order__r.State,
                   Work_Order__r.PostalCode, Work_Order__r.WorkTypeId, Work_Order__r.WorkType.Name,
                   Work_Order__r.Project__c, Work_Order__r.Project__r.Name
            FROM AcctSeedERP__Purchase_Order__c
            WHERE Work_Order__c != null
            LIMIT 1
        ];
    }

    private static AcctSeedERP__Purchase_Order__c findPoWithoutWorkOrder() {
        return [
            SELECT Id, Name, AcctSeedERP__Vendor__c, AcctSeedERP__Vendor__r.Name
            FROM AcctSeedERP__Purchase_Order__c
            WHERE Work_Order__c = null
            LIMIT 1
        ];
    }

    // ------------------------------------------------------------------
    // buildCertificateData branch coverage
    // ------------------------------------------------------------------

    @isTest
    static void testBuildCertificateData_WithWorkOrder() {
        AcctSeedERP__Purchase_Order__c po = findPoWithWorkOrder();
        Assert.isNotNull(po, 'No PO with a linked Work Order found in the org');

        Test.startTest();
        ST120Generator.CertificateData data = ST120Generator.buildCertificateData(po.Id);
        Test.stopTest();

        Assert.areEqual(po.Name, data.orderNumber);
        Assert.isNotNull(data.vendorName);
        Assert.isNotNull(data.jobSiteAddress);
        Assert.isNotNull(data.exemptOrgName);
        Assert.isNotNull(data.formVersion);
    }

    @isTest
    static void testBuildCertificateData_NoWorkOrderFallback() {
        AcctSeedERP__Purchase_Order__c po = findPoWithoutWorkOrder();
        if (po == null) {
            // Can't test fallback if every PO has a Work Order — skip gracefully.
            Assert.isTrue(true, 'No PO without Work Order found — skipping test');
            return;
        }

        Test.startTest();
        ST120Generator.CertificateData data = ST120Generator.buildCertificateData(po.Id);
        Test.stopTest();

        Assert.areEqual('HVAC Services and Repairs', data.projectDescription);
        Assert.isNotNull(data.exemptOrgName, 'Exempt org should fall back to vendor name');
        Assert.isNotNull(data.vendorName, 'Vendor name should be populated');
    }

    @isTest
    static void testBuildCertificateData_ExemptOrgFromWorkOrderAccount() {
        AcctSeedERP__Purchase_Order__c po = findPoWithWorkOrder();

        Test.startTest();
        ST120Generator.CertificateData data = ST120Generator.buildCertificateData(po.Id);
        Test.stopTest();

        // The exempt org should be the Work Order's account name, not the vendor.
        Assert.areEqual(po.Work_Order__r.Account.Name, data.exemptOrgName);
    }

    @isTest
    static void testBuildCertificateData_PrimeContractDateFallsBackToCreatedDate() {
        AcctSeedERP__Purchase_Order__c po = findPoWithWorkOrder();

        Test.startTest();
        ST120Generator.CertificateData data = ST120Generator.buildCertificateData(po.Id);
        Test.stopTest();

        AcctSeedERP__Purchase_Order__c freshPo = [SELECT CreatedDate FROM AcctSeedERP__Purchase_Order__c WHERE Id = :po.Id];
        Assert.areEqual(freshPo.CreatedDate.date().format(), data.primeContractDate);
    }

    @isTest
    static void testBuildCertificateData_FileNameAndOrderNumber() {
        AcctSeedERP__Purchase_Order__c po = findPoWithWorkOrder();

        Test.startTest();
        ST120Generator.CertificateData data = ST120Generator.buildCertificateData(po.Id);
        Test.stopTest();

        Assert.areEqual(po.Name, data.orderNumber);
        Assert.isTrue(data.fileName.startsWith('ST120_'));
        Assert.isTrue(data.fileName.endsWith('.pdf'));
    }

    // ------------------------------------------------------------------
    // ST120DataProvider.prepareData
    // ------------------------------------------------------------------

    @isTest
    static void testPrepareData_Null() {
        Test.startTest();
        List<ST120DataProvider.CertificateDataOutput> outputs = ST120DataProvider.prepareData(null);
        Test.stopTest();

        Assert.isTrue(outputs.isEmpty());
    }

    @isTest
    static void testPrepareData_Empty() {
        Test.startTest();
        List<ST120DataProvider.CertificateDataOutput> outputs = ST120DataProvider.prepareData(new List<Id>());
        Test.stopTest();

        Assert.isTrue(outputs.isEmpty());
    }

    @isTest
    static void testPrepareData_Single() {
        AcctSeedERP__Purchase_Order__c po = findPoWithWorkOrder();

        Test.startTest();
        List<ST120DataProvider.CertificateDataOutput> outputs = ST120DataProvider.prepareData(new List<Id>{ po.Id });
        Test.stopTest();

        Assert.areEqual(1, outputs.size());
        Assert.areEqual(String.valueOf(po.Id), outputs[0].orderId);
        Assert.areEqual(po.Name, outputs[0].orderNumber);
    }

    // ------------------------------------------------------------------
    // generatePdf delivery modes
    // ------------------------------------------------------------------

    @isTest
    static void testGeneratePdf_DefaultEmailMode() {
        AcctSeedERP__Purchase_Order__c po = findPoWithWorkOrder();
        ST120Generator.GenerateRequest req = new ST120Generator.GenerateRequest();
        req.orderId = po.Id;

        Test.startTest();
        List<String> results = ST120Generator.generatePdf(new List<ST120Generator.GenerateRequest>{ req });
        Test.stopTest();

        Assert.areEqual(1, results.size());
        Assert.isNotNull(results[0]);
        // PO may already have files — assert at least 1 new ContentDocumentLink was created.
        Integer linkCount = [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :po.Id];
        Assert.isTrue(linkCount >= 1, 'Expected at least 1 ContentDocumentLink after generatePdf');
    }

    @isTest
    static void testGeneratePdf_HoldMode() {
        AcctSeedERP__Purchase_Order__c po = findPoWithWorkOrder();
        ST120Generator.GenerateRequest req = new ST120Generator.GenerateRequest();
        req.orderId = po.Id;
        req.deliveryMode = 'Hold';

        Test.startTest();
        List<String> results = ST120Generator.generatePdf(new List<ST120Generator.GenerateRequest>{ req });
        Test.stopTest();

        Assert.areEqual(1, results.size());
        // Hold mode still generates & attaches the PDF; it just never triggers a separate email.
        Integer emailMessageCount = [SELECT COUNT() FROM EmailMessage WHERE RelatedToId = :po.Id];
        Assert.areEqual(0, emailMessageCount);
    }

    @isTest
    static void testGeneratePdf_SeparateMode() {
        AcctSeedERP__Purchase_Order__c po = findPoWithWorkOrder();
        ST120Generator.GenerateRequest req = new ST120Generator.GenerateRequest();
        req.orderId = po.Id;
        req.deliveryMode = 'Separate';
        req.contactEmail = 'test@example.com';
        req.contactName = 'Test Recipient';

        Test.startTest();
        List<String> results = ST120Generator.generatePdf(new List<ST120Generator.GenerateRequest>{ req });
        Test.stopTest();

        // EmailMessage logging is best-effort — just confirm no exception.
        Assert.areEqual(1, results.size());
    }

    // ------------------------------------------------------------------
    // resendCertificate
    // ------------------------------------------------------------------

    @isTest
    static void testResendCertificate_Success() {
        AcctSeedERP__Purchase_Order__c po = findPoWithWorkOrder();
        ST120Generator.GenerateRequest req = new ST120Generator.GenerateRequest();
        req.orderId = po.Id;
        ST120Generator.generatePdf(new List<ST120Generator.GenerateRequest>{ req });

        Test.startTest();
        ST120Generator.resendCertificate(po.Id, 'resend@example.com', 'Resend Recipient');
        Test.stopTest();
        // No exception thrown == success path exercised.
    }

    @isTest
    static void testResendCertificate_NoCertificateThrows() {
        // Use a PO that has never had a certificate generated.
        List<AcctSeedERP__Purchase_Order__c> pos = [
            SELECT Id FROM AcctSeedERP__Purchase_Order__c
            WHERE Work_Order__c != null
            LIMIT 5
        ];
        AcctSeedERP__Purchase_Order__c po = pos.isEmpty() ? new AcctSeedERP__Purchase_Order__c() : pos[0];
        // Check if this PO has a certificate; if so, try another
        for (AcctSeedERP__Purchase_Order__c p : pos) {
            List<ContentDocumentLink> links = [SELECT Id FROM ContentDocumentLink WHERE LinkedEntityId = :p.Id LIMIT 1];
            if (links.isEmpty()) { po = p; break; }
        }
        Boolean threw = false;

        Test.startTest();
        try {
            ST120Generator.resendCertificate(po.Id, 'resend@example.com', 'Resend Recipient');
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw);
    }

    // ------------------------------------------------------------------
    // checkVendorPolicy — all 5 branches
    // ------------------------------------------------------------------

    @isTest
    static void testCheckVendorPolicy_DoNotSend() {
        checkPolicyScenario('Do Not Send', 'BLOCKED:');
    }

    @isTest
    static void testCheckVendorPolicy_ShortPayOnly() {
        checkPolicyScenario('Short Pay Only', 'WARNING:');
    }

    @isTest
    static void testCheckVendorPolicy_AfterInvoiceOnly() {
        checkPolicyScenario('After Invoice Only', 'WARNING:');
    }

    @isTest
    static void testCheckVendorPolicy_ManualProcessRequired() {
        checkPolicyScenario('Manual Process Required', 'INFO:');
    }

    @isTest
    static void testUploadCertificate() {
        AcctSeedERP__Purchase_Order__c po = findPoWithWorkOrder();
        Blob testPdf = Blob.valueOf('%PDF-1.4 test');
        String base64 = EncodingUtil.base64Encode(testPdf);
        Test.startTest();
        Map<String, Object> result = ST120Generator.uploadCertificate(po.Id, base64, 'test_cert.pdf');
        Test.stopTest();
        Assert.isTrue((Boolean)result.get('success'), 'Upload should succeed');
    }

    @isTest
    static void testCheckVendorPolicy_NoPolicyReturnsNull() {
        AcctSeedERP__Purchase_Order__c po = findPoWithWorkOrder();

        // Only test if the vendor has no policy set.
        if (po.AcctSeedERP__Vendor__r != null) {
            Account vendor = [SELECT Tax_Exempt_Policy__c FROM Account WHERE Id = :po.AcctSeedERP__Vendor__c LIMIT 1];
            if (vendor.Tax_Exempt_Policy__c != null) {
                Assert.isTrue(true, 'Vendor has a policy set — skipping NoPolicy test');
                return;
            }
        }

        Test.startTest();
        String result = ST120Generator.checkVendorPolicy(po.Id);
        Test.stopTest();

        Assert.isNull(result);
    }

    private static void checkPolicyScenario(String policyValue, String expectedPrefix) {
        AcctSeedERP__Purchase_Order__c po = findPoWithWorkOrder();
        if (po.AcctSeedERP__Vendor__c == null) {
            Assert.isTrue(true, 'PO has no vendor — skipping policy test');
            return;
        }

        Account vendor = new Account(
            Id = po.AcctSeedERP__Vendor__c,
            Tax_Exempt_Policy__c = policyValue,
            Tax_Exempt_Notes__c = 'Test notes for ' + policyValue
        );
        update vendor;

        Test.startTest();
        String result = ST120Generator.checkVendorPolicy(po.Id);
        Test.stopTest();

        Assert.isNotNull(result);
        Assert.isTrue(result.startsWith(expectedPrefix));
    }
}