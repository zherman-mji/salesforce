/**
 * ServicePriorityController
 *
 * Apex controller for the Service Priority Dashboard LWC.
 * Provides data extraction for service appointments within a date range,
 * follow-up detection, classification, and related record retrieval.
 *
 * @auraEnabled All methods are cachable where possible.
 * @see ServicePriorityHelper
 */
public with sharing class ServicePriorityController {

    /**
     * Returns service appointments within the given date range with all
     * related records needed for the dashboard. Defaults to yesterday
     * when called with null arguments.
     *
     * @param startDate  Start of range (nullable - defaults to yesterday)
     * @param endDate    End of range (nullable - defaults to yesterday)
     * @return List of AppointmentWrapper objects
     */
    @AuraEnabled(cacheable=true)
    public static List<AppointmentWrapper> getAppointments(Date startDate, Date endDate) {
        // Default to yesterday when no range is provided
        if (startDate == null && endDate == null) {
            Date yesterday = Date.today().addDays(-1);
            startDate = yesterday;
            endDate = yesterday;
        } else if (startDate == null) {
            startDate = endDate;
        } else if (endDate == null) {
            endDate = startDate;
        }

        // Validate range
        if (startDate > endDate) {
            throw new AuraHandledException('Start date must be before or equal to end date.');
        }

        // Safety: cap range to 31 days to prevent excessive query volume
        if (startDate.daysBetween(endDate) > 31) {
            throw new AuraHandledException('Date range cannot exceed 31 days.');
        }

        // Convert Date to DateTime for SOQL (service appointments use Datetime fields)
        DateTime startDT = DateTime.newInstance(startDate, Time.newInstance(0, 0, 0, 0));
        DateTime endDT = DateTime.newInstance(endDate, Time.newInstance(23, 59, 59, 0));

        List<ServiceAppointment> sas = [
            SELECT Id, AppointmentNumber, Status,
                   EarliestStartTime, DueDate, SchedStartTime, SchedEndTime,
                   ActualStartTime, ActualEndTime,
                   FSL__GanttColor__c, FSL__InJeopardy__c, FSL__Emergency__c,
                   ServiceTerritoryId,
                   ParentRecordId,
                   (SELECT Id, ServiceResourceId, ServiceResource.Name
                    FROM AssignedResources
                    ORDER BY ServiceResource.Name),
                   WorkOrder__r.Id,
                   WorkOrder__r.WorkOrderNumber,
                   WorkOrder__r.Status,
                   WorkOrder__r.StatusCategory,
                   WorkOrder__r.AccountId,
                   WorkOrder__r.Account.Name,
                   WorkOrder__r.Account.Credit_hold__c,
                   WorkOrder__r.ContactId,
                   WorkOrder__r.Contact.Name,
                   WorkOrder__r.Contact.Phone,
                   WorkOrder__r.Contact.Email,
                   WorkOrder__r.AssetId,
                   WorkOrder__r.Asset.Name,
                   WorkOrder__r.Asset.SerialNumber,
                   WorkOrder__r.Asset.Model_Number__c,
                   WorkOrder__r.Service_Notes__c,
                   WorkOrder__r.Executive_Summary__c,
                   WorkOrder__r.Next_Steps__c,
                   WorkOrder__r.Risks__c,
                   WorkOrder__r.Callback__c,
                   WorkOrder__r.Credit_hold__c,
                   WorkOrder__r.Customer_PO__c,
                   WorkOrder__r.ServiceContractId,
                   WorkOrder__r.ServiceContract__r.ContractNumber,
                   WorkOrder__r.ServiceContract__r.Status
            FROM ServiceAppointment
            WHERE SchedStartTime >= :startDT
              AND SchedStartTime <= :endDT
            WITH SECURITY_ENFORCED
            ORDER BY SchedStartTime ASC
            LIMIT 200
        ];

        List<AppointmentWrapper> results = new List<AppointmentWrapper>();
        for (ServiceAppointment sa : sas) {
            results.add(new AppointmentWrapper(sa));
        }

        return results;
    }

    /**
     * Runs follow-up detection and priority classification on a list of
     * Service Appointment IDs. Returns the analysis result for each SA.
     *
     * @param saIds List of Service Appointment IDs
     * @return Map<Id, FollowUpResult> keyed by SA Id
     */
    @AuraEnabled(cacheable=true)
    public static Map<Id, FollowUpResult> getFollowUpAnalysis(List<Id> saIds) {
        if (saIds == null || saIds.isEmpty()) {
            return new Map<Id, FollowUpResult>();
        }

        // Fetch WOLIs, ConversationEntries, and FeedItems for all SAs
        Map<Id, ServiceAppointment> sas = new Map<Id, ServiceAppointment>([
            SELECT Id, AppointmentNumber, Status, WorkOrder__r.Id,
                   WorkOrder__r.Status, WorkOrder__r.Service_Notes__c,
                   WorkOrder__r.Executive_Summary__c, WorkOrder__r.Next_Steps__c,
                   WorkOrder__r.Callback__c
            FROM ServiceAppointment
            WHERE Id IN :saIds
            WITH SECURITY_ENFORCED
        ]);

        Set<Id> woIds = new Set<Id>();
        for (ServiceAppointment sa : sas.values()) {
            if (sa.WorkOrder__r.Id != null) {
                woIds.add(sa.WorkOrder__r.Id);
            }
        }

        // Fetch WOLIs
        List<WorkOrderLineItem> wolis = [
            SELECT Id, WorkOrderId, Description, Status
            FROM WorkOrderLineItem
            WHERE WorkOrderId IN :woIds
            WITH SECURITY_ENFORCED
        ];
        Map<Id, List<WorkOrderLineItem>> wolisByWO = new Map<Id, List<WorkOrderLineItem>>();
        for (WorkOrderLineItem woli : wolis) {
            if (!wolisByWO.containsKey(woli.WorkOrderId)) {
                wolisByWO.put(woli.WorkOrderId, new List<WorkOrderLineItem>());
            }
            wolisByWO.get(woli.WorkOrderId).add(woli);
        }

        // Fetch recent ConversationEntries (last 48h, max 5 per parent)
        DateTime twoDaysAgo = System.now().addHours(-48);
        List<ConversationEntry> entries = [
            SELECT Id, ParentRecordId, MessageBody, ReceivedTime, Direction
            FROM ConversationEntry
            WHERE ParentRecordId IN :woIds
              AND ReceivedTime >= :twoDaysAgo
            ORDER BY ReceivedTime DESC
            LIMIT 200
        ];
        Map<Id, List<ConversationEntry>> entriesByWO = new Map<Id, List<ConversationEntry>>();
        for (ConversationEntry e : entries) {
            if (!entriesByWO.containsKey(e.ParentRecordId)) {
                entriesByWO.put(e.ParentRecordId, new List<ConversationEntry>());
            }
            entriesByWO.get(e.ParentRecordId).add(e);
        }

        // Run classification per SA
        Map<Id, FollowUpResult> results = new Map<Id, FollowUpResult>();
        for (ServiceAppointment sa : sas.values()) {
            List<WorkOrderLineItem> saWolis = wolisByWO.get(sa.WorkOrder__r.Id);
            List<ConversationEntry> saEntries = entriesByWO.get(sa.WorkOrder__r.Id);

            results.put(sa.Id, ServicePriorityHelper.classify(
                sa, saWolis, saEntries
            ));
        }

        return results;
    }

    /**
     * Returns recent ConversationEntry records for a parent record (WO or Account).
     *
     * @param parentRecordId The parent record ID
     * @return List of ConversationEntry (most recent 20)
     */
    @AuraEnabled(cacheable=true)
    public static List<ConversationEntry> getConversationHistory(Id parentRecordId) {
        return [
            SELECT Id, ParentRecordId, MessageBody, ReceivedTime, Direction, MessageType, MessageChannel
            FROM ConversationEntry
            WHERE ParentRecordId = :parentRecordId
            ORDER BY ReceivedTime DESC
            LIMIT 20
            WITH SECURITY_ENFORCED
        ];
    }

    /**
     * Returns FeedItem records (activity feed) for a parent record.
     *
     * @param parentRecordId The parent record ID (WO, Account)
     * @return List of FeedItem (most recent 20)
     */
    @AuraEnabled(cacheable=true)
    public static List<FeedItem> getActivityFeed(Id parentRecordId) {
        return [
            SELECT Id, ParentId, Title, Body, Type, CreatedDate, LastModifiedDate,
                   CreatedBy.Id, CreatedBy.Name, CreatedBy.SmallPhotoUrl,
                   (SELECT Id, CommentBody, CreatedDate, CreatedBy.Name
                    FROM FeedComments
                    ORDER BY CreatedDate DESC
                    LIMIT 5)
            FROM FeedItem
            WHERE ParentId = :parentRecordId
            ORDER BY CreatedDate DESC
            LIMIT 20
            WITH SECURITY_ENFORCED
        ];
    }

    /**
     * Returns full WorkOrder details including all child records.
     *
     * @param workOrderId The WorkOrder ID
     * @return WorkOrderDetailWrapper with all related data
     */
    @AuraEnabled(cacheable=true)
    public static WorkOrderDetailWrapper getWODetails(Id workOrderId) {
        WorkOrder wo = [
            SELECT Id, WorkOrderNumber, Status, StatusCategory,
                   AccountId, Account.Name, Account.Phone,
                   ContactId, Contact.Name, Contact.Phone, Contact.Email,
                   AssetId, Asset.Name, Asset.SerialNumber, Asset.Model_Number__c,
                   ServiceTerritoryId,
                   Service_Notes__c, Executive_Summary__c,
                   Next_Steps__c, Risks__c,
                   Callback__c, Credit_hold__c, Customer_PO__c,
                   ServiceContract__r.ContractNumber,
                   ServiceContract__r.Status,
                   StartDate, EndDate, DurationInMinutes
            FROM WorkOrder
            WHERE Id = :workOrderId
            WITH SECURITY_ENFORCED
            LIMIT 1
        ];

        List<WorkOrderLineItem> wolis = [
            SELECT Id, Description, Status, Quantity, UnitPrice, TotalPrice,
                   AssetId, Asset.Name, Asset.SerialNumber
            FROM WorkOrderLineItem
            WHERE WorkOrderId = :workOrderId
            ORDER BY CreatedDate ASC
            WITH SECURITY_ENFORCED
        ];

        return new WorkOrderDetailWrapper(wo, wolis);
    }

    /**
     * Wrapper class for the main dashboard list view.
     */
    public with sharing class AppointmentWrapper {
        @AuraEnabled public Id id;
        @AuraEnabled public String appointmentNumber;
        @AuraEnabled public String status;
        @AuraEnabled public DateTime schedStart;
        @AuraEnabled public DateTime schedEnd;
        @AuraEnabled public DateTime actualStart;
        @AuraEnabled public DateTime actualEnd;
        @AuraEnabled public Boolean isEmergency;
        @AuraEnabled public Boolean isInJeopardy;
        @AuraEnabled public String ganttColor;
        @AuraEnabled public String territoryId;
        @AuraEnabled public Id workOrderId;
        @AuraEnabled public String workOrderNumber;
        @AuraEnabled public String workOrderStatus;
        @AuraEnabled public String accountName;
        @AuraEnabled public String accountId;
        @AuraEnabled public Boolean creditHold;
        @AuraEnabled public String contactName;
        @AuraEnabled public String contactPhone;
        @AuraEnabled public String contactEmail;
        @AuraEnabled public String assetName;
        @AuraEnabled public String assetSerial;
        @AuraEnabled public String assetModel;
        @AuraEnabled public String serviceNotes;
        @AuraEnabled public String executiveSummary;
        @AuraEnabled public String nextSteps;
        @AuraEnabled public String risks;
        @AuraEnabled public Boolean callbackRequested;
        @AuraEnabled public String serviceContractNumber;
        @AuraEnabled public String assignedTechName;

        public AppointmentWrapper(ServiceAppointment sa) {
            this.id = sa.Id;
            this.appointmentNumber = sa.AppointmentNumber;
            this.status = sa.Status;
            this.schedStart = sa.SchedStartTime;
            this.schedEnd = sa.SchedEndTime;
            this.actualStart = sa.ActualStartTime;
            this.actualEnd = sa.ActualEndTime;
            this.isEmergency = sa.FSL__Emergency__c;
            this.isInJeopardy = sa.FSL__InJeopardy__c;
            this.ganttColor = sa.FSL__GanttColor__c;
            this.territoryId = sa.ServiceTerritoryId;

            if (sa.WorkOrder__r != null) {
                this.workOrderId = sa.WorkOrder__r.Id;
                this.workOrderNumber = sa.WorkOrder__r.WorkOrderNumber;
                this.workOrderStatus = sa.WorkOrder__r.Status;
                this.accountName = sa.WorkOrder__r.Account?.Name;
                this.accountId = sa.WorkOrder__r.AccountId;
                this.creditHold = sa.WorkOrder__r.Account?.Credit_hold__c;
                this.contactName = sa.WorkOrder__r.Contact?.Name;
                this.contactPhone = sa.WorkOrder__r.Contact?.Phone;
                this.contactEmail = sa.WorkOrder__r.Contact?.Email;
                this.assetName = sa.WorkOrder__r.Asset?.Name;
                this.assetSerial = sa.WorkOrder__r.Asset?.SerialNumber;
                this.assetModel = sa.WorkOrder__r.Asset?.Model_Number__c;
                this.serviceNotes = sa.WorkOrder__r.Service_Notes__c;
                this.executiveSummary = sa.WorkOrder__r.Executive_Summary__c;
                this.nextSteps = sa.WorkOrder__r.Next_Steps__c;
                this.risks = sa.WorkOrder__r.Risks__c;
                this.callbackRequested = sa.WorkOrder__r.Callback__c;
                this.serviceContractNumber = sa.WorkOrder__r.ServiceContract__r?.ContractNumber;
            }

            // Get the first assigned tech name
            if (sa.AssignedResources != null && !sa.AssignedResources.isEmpty()) {
                this.assignedTechName = sa.AssignedResources[0].ServiceResource?.Name;
            }
        }
    }

    /**
     * Result of follow-up detection and priority classification for one SA.
     */
    public with sharing class FollowUpResult {
        @AuraEnabled public Boolean needsFollowUp;
        @AuraEnabled public String priority;       // Urgent, High, Medium, Low
        @AuraEnabled public String reason;          // Why it was flagged
        @AuraEnabled public String summary;         // 1-2 sentence auto-summary
        @AuraEnabled public Integer signalCount;    // How many detection signals fired
        @AuraEnabled public List<String> signals;   // Individual signal descriptions

        public FollowUpResult() {
            this.needsFollowUp = false;
            this.priority = 'Low';
            this.reason = '';
            this.summary = '';
            this.signalCount = 0;
            this.signals = new List<String>();
        }
    }

    /**
     * Detailed WorkOrder view for the side panel.
     */
    public with sharing class WorkOrderDetailWrapper {
        @AuraEnabled public WorkOrder workOrder;
        @AuraEnabled public List<WorkOrderLineItem> workOrderLineItems;

        public WorkOrderDetailWrapper(WorkOrder wo, List<WorkOrderLineItem> wolis) {
            this.workOrder = wo;
            this.workOrderLineItems = wolis;
        }
    }
}