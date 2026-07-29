/**
 * @description Test class for DurationOverageService and DurationOverageInvocable.
 * Covers all scenarios: within estimate, over estimate, approved suppression,
 * 24h dedup, null/zero DurationInMinutes, and bulk 200 SAs.
 */
@isTest(SeeAllData=false)
private class DurationOverageServiceTest {

    /**
     * @description Creates test data: a manager user, a WO owner user,
     * a WorkOrder, and ServiceAppointments.
     * @param numSAs Number of SAs to create
     * @param parentOverageMinutes Total SA minutes relative to WO estimate
     * @return Map with references to created records
     */
    private static Map<String, Id> setupTestData(
        Integer numSAs, Decimal parentOverageMinutes
    ) {
        return setupTestData(numSAs, parentOverageMinutes, false);
    }

    /**
     * @description Creates test data with optional approved flag.
     */
    private static Map<String, Id> setupTestData(
        Integer numSAs, Decimal parentOverageMinutes, Boolean approved
    ) {
        // Create manager user
        Profile p = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];

        User manager = new User(
            Alias = 'mgrusr',
            Email = 'manager@test.example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'Manager',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'America/New_York',
            UserName = 'manager.test.' + System.currentTimeMillis() + '@example.com'
        );
        insert manager;

        // Create WO owner
        User owner = new User(
            Alias = 'woownr',
            Email = 'owner@test.example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'Owner',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'America/New_York',
            UserName = 'owner.test.' + System.currentTimeMillis() + '@example.com',
            ManagerId = manager.Id
        );
        insert owner;

        // Create WorkOrder
        WorkOrder wo = new WorkOrder(
            DurationInMinutes = 100,
            Duration_Overage_Approved__c = approved,
            OwnerId = owner.Id
        );
        insert wo;

        // Create ServiceAppointments
        List<ServiceAppointment> sas = new List<ServiceAppointment>();
        Decimal minutesPerSa = parentOverageMinutes / numSAs;
        for (Integer i = 0; i < numSAs; i++) {
            sas.add(new ServiceAppointment(
                FSSK__FSK_Work_Order__c = wo.Id,
                DurationInMinutes = minutesPerSa,
                Status = 'Scheduled',
                SchedStartTime = System.now().addHours(i),
                SchedEndTime = System.now().addHours(i + 1)
            ));
        }
        insert sas;

        Map<String, Id> result = new Map<String, Id>();
        result.put('workOrderId', wo.Id);
        result.put('ownerId', owner.Id);
        result.put('managerId', manager.Id);
        result.put('saId', sas[0].Id);
        return result;
    }

    // ========================================================================
    // SA sum within estimate -> no alert
    // ========================================================================

    @isTest
    static void testWithinEstimateNoAlert() {
        // 1 SA with 50 min, WO estimate 100 min -> within estimate
        Map<String, Id> data = setupTestData(1, 50);

        Test.startTest();
        DurationOverageService.evaluateScheduledDuration(
            new Set<Id>{ data.get('saId') }
        );
        Test.stopTest();

        // Verify no approval record was created
        List<Duration_Overage_Approval__c> approvals = [
            SELECT Id FROM Duration_Overage_Approval__c
            WHERE Work_Order__c = :data.get('workOrderId')
        ];
        System.assertEquals(
            0, approvals.size(),
            'No approval record should be created when SA sum is within estimate'
        );
    }

    // ========================================================================
    // SA sum exceeding estimate -> alert created
    // ========================================================================

    @isTest
    static void testExceedingEstimateCreatesAlert() {
        // SA sum 150 min, WO estimate 100 min -> exceeds estimate
        Map<String, Id> data = setupTestData(1, 150);

        Test.startTest();
        DurationOverageService.evaluateScheduledDuration(
            new Set<Id>{ data.get('saId') }
        );
        Test.stopTest();

        // Verify approval record was created
        List<Duration_Overage_Approval__c> approvals = [
            SELECT Id, Status__c, Total_Scheduled_Minutes__c,
                   Estimated_Duration_Minutes__c, Notification_Sent_At__c
            FROM Duration_Overage_Approval__c
            WHERE Work_Order__c = :data.get('workOrderId')
        ];
        System.assertEquals(
            1, approvals.size(),
            'One approval record should be created when SA sum exceeds estimate'
        );
        System.assertEquals(
            'Pending', approvals[0].Status__c,
            'Approval status should be Pending'
        );
        System.assertEquals(
            150, approvals[0].Total_Scheduled_Minutes__c,
            'Total scheduled minutes should be 150'
        );
        System.assertEquals(
            100, approvals[0].Estimated_Duration_Minutes__c,
            'Estimated duration minutes should be 100'
        );
        System.assertNotEquals(
            null, approvals[0].Notification_Sent_At__c,
            'Notification sent timestamp should be set'
        );
    }

    // ========================================================================
    // Already approved -> suppressed
    // ========================================================================

    @isTest
    static void testAlreadyApprovedSuppressed() {
        // WO is already approved, SA sum 150 min > 100 min estimate
        Map<String, Id> data = setupTestData(1, 150, true);

        Test.startTest();
        DurationOverageService.evaluateScheduledDuration(
            new Set<Id>{ data.get('saId') }
        );
        Test.stopTest();

        // Verify no approval record was created
        List<Duration_Overage_Approval__c> approvals = [
            SELECT Id FROM Duration_Overage_Approval__c
            WHERE Work_Order__c = :data.get('workOrderId')
        ];
        System.assertEquals(
            0, approvals.size(),
            'No approval record should be created when WO is already approved'
        );
    }

    // ========================================================================
    // 24h dedup -> suppressed
    // ========================================================================

    @isTest
    static void test24hDedupSuppressed() {
        Map<String, Id> data = setupTestData(1, 150);

        // Create an existing approval record within 24h
        Duration_Overage_Approval__c existingApproval = new Duration_Overage_Approval__c(
            Work_Order__c = data.get('workOrderId'),
            Status__c = 'Pending',
            Total_Scheduled_Minutes__c = 150,
            Estimated_Duration_Minutes__c = 100
        );
        insert existingApproval;

        Test.startTest();
        DurationOverageService.evaluateScheduledDuration(
            new Set<Id>{ data.get('saId') }
        );
        Test.stopTest();

        // Verify only one approval record exists (the original, not a duplicate)
        List<Duration_Overage_Approval__c> approvals = [
            SELECT Id FROM Duration_Overage_Approval__c
            WHERE Work_Order__c = :data.get('workOrderId')
        ];
        System.assertEquals(
            1, approvals.size(),
            'Only one approval record should exist — no duplicate within 24h'
        );
    }

    // ========================================================================
    // Null/zero DurationInMinutes -> no alert
    // ========================================================================

    @isTest
    static void testNullZeroDurationNoAlert() {
        // Create WO with DurationInMinutes = null
        Profile p = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        User owner = new User(
            Alias = 'ownr2',
            Email = 'owner2@test.example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'Owner2',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'America/New_York',
            UserName = 'owner2.test.' + System.currentTimeMillis() + '@example.com'
        );
        insert owner;

        WorkOrder wo = new WorkOrder(
            DurationInMinutes = null,
            OwnerId = owner.Id
        );
        insert wo;

        ServiceAppointment sa = new ServiceAppointment(
            FSSK__FSK_Work_Order__c = wo.Id,
            DurationInMinutes = 200,
            Status = 'Scheduled',
            SchedStartTime = System.now(),
            SchedEndTime = System.now().addHours(1)
        );
        insert sa;

        Test.startTest();
        DurationOverageService.evaluateScheduledDuration(
            new Set<Id>{ sa.Id }
        );
        Test.stopTest();

        // Verify no approval record was created
        List<Duration_Overage_Approval__c> approvals = [
            SELECT Id FROM Duration_Overage_Approval__c
            WHERE Work_Order__c = :wo.Id
        ];
        System.assertEquals(
            0, approvals.size(),
            'No approval record should be created when WO DurationInMinutes is null'
        );
    }

    @isTest
    static void testZeroDurationNoAlert() {
        // Create WO with DurationInMinutes = 0
        Profile p = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        User owner = new User(
            Alias = 'ownr3',
            Email = 'owner3@test.example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'Owner3',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'America/New_York',
            UserName = 'owner3.test.' + System.currentTimeMillis() + '@example.com'
        );
        insert owner;

        WorkOrder wo = new WorkOrder(
            DurationInMinutes = 0,
            OwnerId = owner.Id
        );
        insert wo;

        ServiceAppointment sa = new ServiceAppointment(
            FSSK__FSK_Work_Order__c = wo.Id,
            DurationInMinutes = 200,
            Status = 'Scheduled',
            SchedStartTime = System.now(),
            SchedEndTime = System.now().addHours(1)
        );
        insert sa;

        Test.startTest();
        DurationOverageService.evaluateScheduledDuration(
            new Set<Id>{ sa.Id }
        );
        Test.stopTest();

        // Verify no approval record was created
        List<Duration_Overage_Approval__c> approvals = [
            SELECT Id FROM Duration_Overage_Approval__c
            WHERE Work_Order__c = :wo.Id
        ];
        System.assertEquals(
            0, approvals.size(),
            'No approval record should be created when WO DurationInMinutes is zero'
        );
    }

    // ========================================================================
    // Bulk 200 SAs
    // ========================================================================

    @isTest
    static void testBulk200SAs() {
        // Create a WO with 200 SAs, each contributing 1 min -> 200 min total
        // WO estimate is 100 min -> exceeds estimate
        Profile p = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        User manager = new User(
            Alias = 'mgrblk',
            Email = 'manager.bulk@test.example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'MgrBulk',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'America/New_York',
            UserName = 'manager.bulk.' + System.currentTimeMillis() + '@example.com'
        );
        insert manager;

        User owner = new User(
            Alias = 'ownblk',
            Email = 'owner.bulk@test.example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'OwnerBulk',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'America/New_York',
            UserName = 'owner.bulk.' + System.currentTimeMillis() + '@example.com',
            ManagerId = manager.Id
        );
        insert owner;

        WorkOrder wo = new WorkOrder(
            DurationInMinutes = 100,
            OwnerId = owner.Id
        );
        insert wo;

        List<ServiceAppointment> sas = new List<ServiceAppointment>();
        for (Integer i = 0; i < 200; i++) {
            sas.add(new ServiceAppointment(
                FSSK__FSK_Work_Order__c = wo.Id,
                DurationInMinutes = 1,
                Status = 'Scheduled',
                SchedStartTime = System.now().addHours(i),
                SchedEndTime = System.now().addHours(i + 1)
            ));
        }
        insert sas;

        // Collect all SA IDs
        Set<Id> allSaIds = new Set<Id>();
        for (ServiceAppointment sa : sas) {
            allSaIds.add(sa.Id);
        }

        Test.startTest();
        DurationOverageService.evaluateScheduledDuration(allSaIds);
        Test.stopTest();

        // Verify one approval record was created
        List<Duration_Overage_Approval__c> approvals = [
            SELECT Id, Total_Scheduled_Minutes__c
            FROM Duration_Overage_Approval__c
            WHERE Work_Order__c = :wo.Id
        ];
        System.assertEquals(
            1, approvals.size(),
            'One approval record should be created for bulk 200 SAs'
        );
        System.assertEquals(
            200, approvals[0].Total_Scheduled_Minutes__c,
            'Total scheduled minutes should be 200 for 200 SAs at 1 min each'
        );
    }

    // ========================================================================
    // Invocable method test
    // ========================================================================

    @isTest
    static void testInvocableMethod() {
        Map<String, Id> data = setupTestData(1, 150);

        DurationOverageInvocable.Request req = new DurationOverageInvocable.Request();
        req.serviceAppointmentId = data.get('saId');

        List<DurationOverageInvocable.Request> requests = new List<DurationOverageInvocable.Request>();
        requests.add(req);

        Test.startTest();
        DurationOverageInvocable.check(requests);
        Test.stopTest();

        // Verify the invocable method triggered the service
        List<Duration_Overage_Approval__c> approvals = [
            SELECT Id FROM Duration_Overage_Approval__c
            WHERE Work_Order__c = :data.get('workOrderId')
        ];
        System.assertEquals(
            1, approvals.size(),
            'Invocable method should trigger alert creation'
        );
    }

    // ========================================================================
    // Edge case: empty/null SA IDs
    // ========================================================================

    @isTest
    static void testEmptySaIds() {
        Test.startTest();
        // Should not throw
        DurationOverageService.evaluateScheduledDuration(new Set<Id>());
        DurationOverageService.evaluateScheduledDuration(null);
        DurationOverageInvocable.check(null);
        DurationOverageInvocable.check(new List<DurationOverageInvocable.Request>());
        Test.stopTest();

        // If we get here, no exceptions were thrown
        System.assert(true, 'Empty/null inputs should not throw exceptions');
    }

    // ========================================================================
    // Edge case: SA with no WO link
    // ========================================================================

    @isTest
    static void testSaNoWorkOrder() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        User owner = new User(
            Alias = 'ownr4',
            Email = 'owner4@test.example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'Owner4',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'America/New_York',
            UserName = 'owner4.test.' + System.currentTimeMillis() + '@example.com'
        );
        insert owner;

        // SA with no WO link
        ServiceAppointment sa = new ServiceAppointment(
            DurationInMinutes = 50,
            Status = 'Scheduled',
            SchedStartTime = System.now(),
            SchedEndTime = System.now().addHours(1)
        );
        insert sa;

        Test.startTest();
        DurationOverageService.evaluateScheduledDuration(new Set<Id>{ sa.Id });
        Test.stopTest();

        // Should not throw — SAs without WO links are filtered out
        System.assert(true, 'SA with no WO link should not throw');
    }

    // ========================================================================
    // Multiple WOs in one call
    // ========================================================================

    @isTest
    static void testMultipleWOs() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        User manager = new User(
            Alias = 'mgrmul',
            Email = 'manager.multi@test.example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'MgrMulti',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'America/New_York',
            UserName = 'manager.multi.' + System.currentTimeMillis() + '@example.com'
        );
        insert manager;

        User owner = new User(
            Alias = 'ownmul',
            Email = 'owner.multi@test.example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'OwnerMulti',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'America/New_York',
            UserName = 'owner.multi.' + System.currentTimeMillis() + '@example.com',
            ManagerId = manager.Id
        );
        insert owner;

        // WO1: within estimate (50 min SA, 100 min estimate)
        WorkOrder wo1 = new WorkOrder(
            DurationInMinutes = 100,
            OwnerId = owner.Id
        );
        insert wo1;

        ServiceAppointment sa1 = new ServiceAppointment(
            FSSK__FSK_Work_Order__c = wo1.Id,
            DurationInMinutes = 50,
            Status = 'Scheduled',
            SchedStartTime = System.now(),
            SchedEndTime = System.now().addHours(1)
        );
        insert sa1;

        // WO2: exceeds estimate (150 min SA, 100 min estimate)
        WorkOrder wo2 = new WorkOrder(
            DurationInMinutes = 100,
            OwnerId = owner.Id
        );
        insert wo2;

        ServiceAppointment sa2 = new ServiceAppointment(
            FSSK__FSK_Work_Order__c = wo2.Id,
            DurationInMinutes = 150,
            Status = 'Scheduled',
            SchedStartTime = System.now(),
            SchedEndTime = System.now().addHours(1)
        );
        insert sa2;

        // WO3: null estimate, should be skipped
        WorkOrder wo3 = new WorkOrder(
            DurationInMinutes = null,
            OwnerId = owner.Id
        );
        insert wo3;

        ServiceAppointment sa3 = new ServiceAppointment(
            FSSK__FSK_Work_Order__c = wo3.Id,
            DurationInMinutes = 150,
            Status = 'Scheduled',
            SchedStartTime = System.now(),
            SchedEndTime = System.now().addHours(1)
        );
        insert sa3;

        Test.startTest();
        DurationOverageService.evaluateScheduledDuration(
            new Set<Id>{ sa1.Id, sa2.Id, sa3.Id }
        );
        Test.stopTest();

        // Only WO2 should have an approval record
        List<Duration_Overage_Approval__c> approvalsWO1 = [
            SELECT Id FROM Duration_Overage_Approval__c
            WHERE Work_Order__c = :wo1.Id
        ];
        System.assertEquals(0, approvalsWO1.size(), 'WO1 within estimate should have no alert');

        List<Duration_Overage_Approval__c> approvalsWO2 = [
            SELECT Id FROM Duration_Overage_Approval__c
            WHERE Work_Order__c = :wo2.Id
        ];
        System.assertEquals(1, approvalsWO2.size(), 'WO2 exceeding estimate should have alert');

        List<Duration_Overage_Approval__c> approvalsWO3 = [
            SELECT Id FROM Duration_Overage_Approval__c
            WHERE Work_Order__c = :wo3.Id
        ];
        System.assertEquals(0, approvalsWO3.size(), 'WO3 with null estimate should have no alert');
    }
}