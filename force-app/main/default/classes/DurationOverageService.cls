/**
 * @description Service class for detecting when scheduled Service Appointment
 * durations exceed a Work Order's estimated DurationInMinutes. Fires email
 * notification to the WO Owner's Manager when an overage is detected.
 *
 * Uses DurationInMinutes (not Duration) to avoid conflicts with flow-based
 * unit conversion (Convert WO/SA duration from Mins to Hrs).
 */
public without sharing class DurationOverageService {

    /**
     * @description Evaluates whether the sum of active SA durations for the
     * parent Work Orders exceeds their estimated DurationInMinutes. Creates
     * Duration_Overage_Approval__c records and sends email notifications.
     * @param saIds Set of Service Appointment Ids to evaluate
     */
    @future
    public static void evaluateScheduledDuration(Set<Id> saIds) {
        if (saIds == null || saIds.isEmpty()) {
            return;
        }

        // Step 1: Query the triggered SAs to get their parent WO IDs
        List<ServiceAppointment> triggeredSas = [
            SELECT Id, FSSK__FSK_Work_Order__c, DurationInMinutes
            FROM ServiceAppointment
            WHERE Id IN :saIds
                AND FSSK__FSK_Work_Order__c != null
            WITH SECURITY_ENFORCED
        ];

        if (triggeredSas.isEmpty()) {
            return;
        }

        // Collect unique WO IDs
        Set<Id> woIds = new Set<Id>();
        for (ServiceAppointment sa : triggeredSas) {
            woIds.add(sa.FSSK__FSK_Work_Order__c);
        }

        // Step 2: Query the parent Work Orders
        Map<Id, WorkOrder> woMap = new Map<Id, WorkOrder>([
            SELECT Id, WorkOrderNumber, DurationInMinutes,
                   Duration_Overage_Approved__c, OwnerId, Owner.Email,
                   Owner.ManagerId, Owner.Manager.Email, Owner.Manager.Name
            FROM WorkOrder
            WHERE Id IN :woIds
                AND DurationInMinutes != null
                AND DurationInMinutes > 0
            WITH SECURITY_ENFORCED
        ]);

        if (woMap.isEmpty()) {
            return;
        }

        // Step 3: Get all active SAs for these WOs
        List<ServiceAppointment> allActiveSas = [
            SELECT Id, DurationInMinutes, FSSK__FSK_Work_Order__c,
                   AppointmentNumber, SchedStartTime, SchedEndTime
            FROM ServiceAppointment
            WHERE FSSK__FSK_Work_Order__c IN :woIds
                AND Status NOT IN ('Canceled', 'Completed', 'Cannot Complete')
            WITH SECURITY_ENFORCED
        ];

        // Step 4: Aggregate DurationInMinutes per WO
        Map<Id, Decimal> woTotalMinutes = new Map<Id, Decimal>();
        for (ServiceAppointment sa : allActiveSas) {
            if (sa.DurationInMinutes != null) {
                Decimal currentTotal = woTotalMinutes.get(sa.FSSK__FSK_Work_Order__c);
                woTotalMinutes.put(
                    sa.FSSK__FSK_Work_Order__c,
                    (currentTotal != null ? currentTotal : 0) + sa.DurationInMinutes
                );
            }
        }

        // Step 5: Check for existing Duration_Overage_Approval__c records
        // within the last 24 hours for these WOs
        Datetime cutoff = System.now().addHours(-24);
        Set<Id> woIdsWithRecentApproval = new Set<Id>();
        List<Duration_Overage_Approval__c> existingApprovals = [
            SELECT Id, Work_Order__c
            FROM Duration_Overage_Approval__c
            WHERE Work_Order__c IN :woIds
                AND CreatedDate >= :cutoff
            WITH SECURITY_ENFORCED
        ];
        for (Duration_Overage_Approval__c app : existingApprovals) {
            woIdsWithRecentApproval.add(app.Work_Order__c);
        }

        // Step 6: Determine which WOs need alerts
        List<Duration_Overage_Approval__c> approvalsToCreate = new List<Duration_Overage_Approval__c>();
        List<WorkOrder> overageWOs = new List<WorkOrder>();

        for (Id woId : woMap.keySet()) {
            WorkOrder wo = woMap.get(woId);
            Decimal totalScheduled = woTotalMinutes.get(woId);

            // Skip if no active SAs or total is null/zero
            if (totalScheduled == null || totalScheduled == 0) {
                continue;
            }

            // Skip if total scheduled does not exceed estimate
            if (totalScheduled <= wo.DurationInMinutes) {
                continue;
            }

            // Skip if already approved
            if (wo.Duration_Overage_Approved__c == true) {
                continue;
            }

            // Skip if a recent approval record already exists (24h dedup)
            if (woIdsWithRecentApproval.contains(woId)) {
                continue;
            }

            // Create the approval record
            Duration_Overage_Approval__c approval = new Duration_Overage_Approval__c(
                Work_Order__c = woId,
                Total_Scheduled_Minutes__c = totalScheduled,
                Estimated_Duration_Minutes__c = wo.DurationInMinutes,
                Status__c = 'Pending',
                Notification_Sent_At__c = System.now()
            );
            approvalsToCreate.add(approval);
            overageWOs.add(wo);
        }

        if (approvalsToCreate.isEmpty()) {
            return;
        }

        // Step 7: Insert the approval records
        Savepoint sp = Database.setSavepoint();
        try {
            insert approvalsToCreate;
        } catch (DmlException e) {
            Database.rollback(sp);
            System.debug('Failed to create Duration_Overage_Approval__c records: ' + e.getMessage());
            return;
        }

        // Step 8: Send email notifications
        List<Messaging.SingleEmailMessage> emails = new List<Messaging.SingleEmailMessage>();

        for (Integer i = 0; i < overageWOs.size(); i++) {
            WorkOrder wo = overageWOs.get(i);
            Duration_Overage_Approval__c approval = approvalsToCreate.get(i);

            // Determine recipient: WO Owner's Manager, or WO Owner as fallback
            String recipientEmail;
            String recipientName;

            if (wo.Owner.ManagerId != null && wo.Owner.Manager.Email != null) {
                recipientEmail = wo.Owner.Manager.Email;
                recipientName = wo.Owner.Manager.Name;
            } else if (wo.Owner.Email != null) {
                recipientEmail = wo.Owner.Email;
                recipientName = wo.Owner.Name;
            } else {
                continue;
            }

            Decimal totalScheduled = woTotalMinutes.get(wo.Id);
            Decimal overageMinutes = totalScheduled - wo.DurationInMinutes;
            Decimal overagePercent = wo.DurationInMinutes > 0
                ? (overageMinutes / wo.DurationInMinutes) * 100
                : 0;

            Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
            email.setToAddresses(new String[]{ recipientEmail });
            email.setSubject(
                '[Duration Alert] WO #' + wo.WorkOrderNumber +
                ' — Scheduled hours exceeding estimate'
            );
            email.setPlainTextBody(
                'Duration Overage Alert\n\n' +
                'Work Order #' + wo.WorkOrderNumber + '\n' +
                'Work Order: ' + System.Url.getSalesforceBaseUrl().toExternalForm() +
                    '/' + wo.Id + '\n\n' +
                'Estimated Duration: ' + wo.DurationInMinutes + ' minutes\n' +
                'Total Scheduled: ' + totalScheduled + ' minutes\n' +
                'Overage: ' + overageMinutes + ' minutes (' +
                    overagePercent.setScale(1) + '%)\n\n' +
                'This alert was sent to ' + recipientName + '.\n' +
                'To approve this overage, mark Duration_Overage_Approved__c ' +
                'as True on the Work Order.'
            );
            emails.add(email);
        }

        if (!emails.isEmpty()) {
            Messaging.sendEmail(emails);
        }
    }
}