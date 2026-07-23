/**
 * ST120Generator
 * --------------
 * Generates NYS ST-120.1 "Contractor Exempt Purchase Certificate" PDFs and manages
 * their delivery/logging.
 *
 * HVAC-303 Option A — Purchase Order pivot (2026-07-08)
 * ------------------------------------------------------
 * This class was migrated off the standard Order object onto the AcctSeedERP
 * managed-package Purchase Order object (AcctSeedERP__Purchase_Order__c). All
 * SOQL, field references, and derived values (vendor, work order, exempt
 * organization, prime contract date, file/subject naming) now target the PO
 * object and its AcctSeedERP__Vendor__c / Work_Order__c lookups. See the
 * VERIFY block below buildCertificateData() for the one place to touch if the
 * Work Order lookup API name differs from what was confirmed against prod on
 * 2026-07-07.
 *
 * HVAC-317 — Work Order tax exempt fields (2026-07-14)
 * -----------------------------------------------------
 * Tax-exempt fields moved from PO to WorkOrder. POs inherit from WO by default.
 * When PO.Override_Tax_Exempt__c is true, the PO uses its own field values.
 * The delivery mode, contact email, and contact name remain PO-specific (each
 * vendor/PO may have different delivery preferences).
 *
 * HVAC-407 — Field requirements and button logic cleanup (2026-07-23)
 * ----------------------------------------------------------------
 * Removed Tax_Exempt_Purchase__c from SOQL queries in buildCertificateData()
 * since it is no longer the source of truth. Exemption_Reason__c is now the
 * determinant for tax exempt eligibility. The three fields Tax_Exempt_Contact_Name__c,
 * Tax_Exempt_Contact_Email__c, and Cert_Delivery_Mode__c are no longer required
 * on the Work Order page layout — they remain on the PO where they are used for
 * delivery-specific configuration.
 *
 * HVAC-408 — Vendor Contact lookup replaces individual text/email fields (2026-07-23)
 * -----------------------------------------------------------------------------------
 * Removed Tax_Exempt_Contact_Name__c and Tax_Exempt_Contact_Email__c from the PO.
 * Replaced with a single Vendor_Contact__c lookup to Contact, filtered to contacts
 * associated with the PO's vendor (AcctSeedERP__Vendor__r). The lookup is ready for
 * future automation use (PO email, tax forms) but does not drive behavior yet.
 * The SOQL now queries Vendor_Contact__r.Email and Vendor_Contact__r.Name for
 * future use; GenerateRequest.contactEmail/contactName remain as flow-input
 * overrides for the existing delivery mechanism.
 *
 * Invocable member names/labels on GenerateRequest (e.g. "orderId" / "Order ID")
 * are UNCHANGED from the Order-based version so the existing Screen Flow that
 * calls this action does not need to be touched. They now carry Purchase Order
 * Ids, not Order Ids.
 */
public with sharing class ST120Generator {

    private static final String MJI_NAME = 'Michael James Industries, Inc.';
    // MJI address sourced from Custom Metadata Type; fallback hardcoded values.
    private static String mjiStreet { get { return formConfig?.MJI_Street__c ?? '11 Drew Court'; } }
    private static String mjiCity { get { return formConfig?.MJI_City__c ?? 'Ronkonkoma'; } }
    private static String mjiState { get { return formConfig?.MJI_State__c ?? 'NY'; } }
    private static String mjiZip { get { return formConfig?.MJI_Zip__c ?? '11741'; } }

    // ------------------------------------------------------------------
    // VERIFY: Work Order lookup field/relationship on AcctSeedERP__Purchase_Order__c.
    // Confirmed against prod on 2026-07-07 as Work_Order__c / Work_Order__r.
    // These constants are declared for documentation/traceability; the SOQL in
    // buildCertificateData() below uses static literals for compile-time safety.
    // If prod schema differs, update BOTH of these constants AND the matching
    // literal tokens in the SOQL (see the comment block directly above the query).
    // ------------------------------------------------------------------
    private static final String WO_LOOKUP_FIELD = 'Work_Order__c';
    private static final String WO_LOOKUP_RELATIONSHIP = 'Work_Order__r';

    private static Tax_Exempt_Form_Config__mdt formConfig {
        get {
            if (formConfig == null) {
                formConfig = Tax_Exempt_Form_Config__mdt.getInstance('ST120_Current');
            }
            return formConfig;
        }
        set;
    }

    public class CertificateData {
        public String mjiName { get { return MJI_NAME; } }
        public String mjiStreet { get; set; }
        public String mjiCityStateZip { get; set; }
        public String caNumber { get { return formConfig?.Certificate_of_Authority__c ?? '11-3507369'; } }
        public String vendorName { get; set; }
        public String vendorStreet { get; set; }
        public String vendorCity { get; set; }
        public String vendorState { get; set; }
        public String vendorZip { get; set; }
        public String vendorFullAddress { get; set; }
        public String jobSiteName { get; set; }
        public String jobSiteStreet { get; set; }
        public String jobSiteCity { get; set; }
        public String jobSiteState { get; set; }
        public String jobSiteZip { get; set; }
        public String jobSiteAddress { get; set; }
        public String projectDescription { get; set; }
        public String projectDescriptionSource { get; set; }
        public String exemptOrgName { get; set; }
        public String primeContractDate { get; set; }
        public String exemptionReasonBox { get; set; }
        public String exemptionReasonText { get; set; }
        public String signerName { get; set; }
        public String signerTitle { get; set; }
        public String generationDate { get; set; }
        public String additionalInfo { get; set; }
        public String formVersion { get; set; }
        // Kept named "orderNumber"/"orderId" for minimal diff; these now hold the
        // Purchase Order Name and Id, respectively.
        public String orderNumber { get; set; }
        public Id orderId { get; set; }
        public Id vendorId { get; set; }
        public Id workOrderId { get; set; }
        public Id exemptOrgId { get; set; }
        public String fileName { get; set; }
        public Boolean isOverride { get; set; }
        public String dataSourceLabel { get; set; }
    }

    /**
     * Builds the certificate data model for a single Purchase Order.
     * @param orderId  Id of the AcctSeedERP__Purchase_Order__c record. Parameter name
     *                 kept as "orderId" for minimal diff vs. the pre-pivot version.
     */
    public static CertificateData buildCertificateData(Id orderId) {
        CertificateData data = new CertificateData();

        // MJI address from CMDT with fallback.
        data.mjiStreet = mjiStreet;
        data.mjiCityStateZip = mjiCity + ', ' + mjiState + ' ' + mjiZip;

        // ------------------------------------------------------------------
        // VERIFY BLOCK — Work Order lookup on Purchase Order
        // If AcctSeedERP__Purchase_Order__c's Work Order lookup is renamed in prod,
        // this SOQL is the ONLY place that needs to change: swap every occurrence
        // of `Work_Order__c` / `Work_Order__r` below (and update the
        // WO_LOOKUP_FIELD / WO_LOOKUP_RELATIONSHIP constants above to match).
        // Confirmed against prod 2026-07-07. Run scripts/verify_schema.apex to
        // re-check if this class fails to deploy/compile.
        // ------------------------------------------------------------------
        AcctSeedERP__Purchase_Order__c po = [
            SELECT Id, Name, CreatedDate,
                   AcctSeedERP__Vendor__c, AcctSeedERP__Vendor__r.Name,
                   AcctSeedERP__Vendor__r.BillingStreet, AcctSeedERP__Vendor__r.BillingCity,
                   AcctSeedERP__Vendor__r.BillingState, AcctSeedERP__Vendor__r.BillingPostalCode,
                   AcctSeedERP__Vendor__r.Tax_Exempt_Policy__c, AcctSeedERP__Vendor__r.Tax_Exempt_Notes__c,
                   AcctSeedERP__Vendor__r.Vendor_Type__c,
                   Cert_Delivery_Mode__c,
                   Prime_Contract_Date__c,
                   Exemption_Reason__c,
                   Override_Tax_Exempt__c,
                   Vendor_Contact__c, Vendor_Contact__r.Email, Vendor_Contact__r.Name,
                   Work_Order__c,
                   Work_Order__r.WorkOrderNumber,
                   Work_Order__r.WorkTypeId, Work_Order__r.WorkType.Name,
                   Work_Order__r.Project__c, Work_Order__r.Project__r.Name,
                   Work_Order__r.AccountId, Work_Order__r.Account.Name,
                   Work_Order__r.Street, Work_Order__r.City,
                   Work_Order__r.State, Work_Order__r.PostalCode,
                   // HVAC-407: Exemption_Reason__c is the source of truth (not Tax_Exempt_Purchase__c)
                   Work_Order__r.Exemption_Reason__c,
                   Work_Order__r.Prime_Contract_Date__c
            FROM AcctSeedERP__Purchase_Order__c
            WHERE Id = :orderId
            LIMIT 1
        ];

        data.vendorName = po.AcctSeedERP__Vendor__r.Name;
        data.vendorStreet = po.AcctSeedERP__Vendor__r.BillingStreet;
        data.vendorCity = po.AcctSeedERP__Vendor__r.BillingCity;
        data.vendorState = po.AcctSeedERP__Vendor__r.BillingState;
        data.vendorZip = po.AcctSeedERP__Vendor__r.BillingPostalCode;
        data.vendorFullAddress = buildAddress(
            po.AcctSeedERP__Vendor__r.BillingStreet, po.AcctSeedERP__Vendor__r.BillingCity,
            po.AcctSeedERP__Vendor__r.BillingState, po.AcctSeedERP__Vendor__r.BillingPostalCode
        );

        // Single direct Work_Order__r lookup replaces the old WorkOrderLineItems
        // child-relationship / "firstWoli" handling — there is no list to walk anymore.
        WorkOrder wo = po.Work_Order__r;
        if (wo != null) {
            data.jobSiteName = wo.WorkOrderNumber;
            data.jobSiteStreet = wo.Street;
            data.jobSiteCity = wo.City;
            data.jobSiteState = wo.State;
            data.jobSiteZip = wo.PostalCode;
            data.jobSiteAddress = buildAddress(
                data.jobSiteStreet, data.jobSiteCity,
                data.jobSiteState, data.jobSiteZip
            );
            String workType = wo.WorkType?.Name;
            if (workType != null) {
                String wtLower = workType.toLowerCase();
                if (wtLower.contains('installation') || wtLower.contains('construction')) {
                    if (wo.Project__c != null) {
                        data.projectDescription = wo.Project__r.Name;
                        data.projectDescriptionSource = 'From Project record';
                    } else {
                        data.projectDescription = 'HVAC Services and Repairs';
                        data.projectDescriptionSource = 'Warning: No project found for Install job';
                    }
                } else {
                    data.projectDescription = 'HVAC Services and Repairs';
                    data.projectDescriptionSource = 'Standard service description';
                }
            } else {
                data.projectDescription = 'HVAC Services and Repairs';
                data.projectDescriptionSource = 'Standard service description';
            }
        } else {
            data.projectDescription = 'HVAC Services and Repairs';
            data.projectDescriptionSource = 'Standard service description (no Work Order linked to PO)';
        }

        if (wo != null && wo.AccountId != null) {
            data.exemptOrgName = wo.Account.Name;
        } else {
            data.exemptOrgName = po.AcctSeedERP__Vendor__r.Name;
        }

        // HVAC-317: PO Override logic — when Override_Tax_Exempt__c is checked,
        // PO uses its own values; otherwise values are inherited from the Work Order.
        Boolean isOverride = po.Override_Tax_Exempt__c == true;
        data.isOverride = isOverride;

        // Prime Contract Date — WO default, PO override, fallback to CreatedDate
        if (isOverride && po.Prime_Contract_Date__c != null) {
            data.primeContractDate = po.Prime_Contract_Date__c.format();
        } else if (wo != null && wo.Prime_Contract_Date__c != null) {
            data.primeContractDate = wo.Prime_Contract_Date__c.format();
        } else {
            data.primeContractDate = po.CreatedDate.date().format();
        }

        // Exemption Reason — WO default, PO override, fallback to Box A
        String effectiveReason = isOverride ? po.Exemption_Reason__c : (wo?.Exemption_Reason__c);
        data.exemptionReasonBox = 'A';
        if (String.isNotBlank(effectiveReason)) {
            String er = effectiveReason;
            if (er.length() >= 1) {
                data.exemptionReasonBox = er.substring(0, 1).toUpperCase();
            }
        }
        data.exemptionReasonText = effectiveReason ?? 'A - Capital Improvement';

        // Data source label for VF page display
        if (isOverride) {
            data.dataSourceLabel = 'Values from Purchase Order (override)';
        } else if (wo != null) {
            data.dataSourceLabel = 'Values inherited from Work Order';
        } else {
            data.dataSourceLabel = 'Default values (no Work Order linked)';
        }
        data.signerName = formConfig?.Authorized_Signer_Name__c ?? 'Michael Herman';
        data.signerTitle = formConfig?.Authorized_Signer_Title__c ?? 'President';
        data.generationDate = Date.today().format();
        data.formVersion = formConfig?.Form_Version_Date__c ?? '5/24';
        data.orderNumber = po.Name;
        data.orderId = po.Id;
        data.vendorId = po.AcctSeedERP__Vendor__c;
        data.workOrderId = po.Work_Order__c;
        if (po.Work_Order__r != null && po.Work_Order__r.AccountId != null) {
            data.exemptOrgId = po.Work_Order__r.AccountId;
        }
        data.fileName = 'ST120_' + cleanFileName(po.AcctSeedERP__Vendor__r.Name) + '_' + po.Name + '_' + Date.today().format().replace('/', '-') + '.pdf';
        return data;
    }

    @InvocableMethod(label='Generate ST-120.1 PDF' description='Generates the ST-120.1 PDF and attaches it to the Purchase Order')
    public static List<String> generatePdf(List<GenerateRequest> requests) {
        List<String> result = new List<String>();
        for (GenerateRequest req : requests) {
            result.add(generateSinglePdf(req));
        }
        return result;
    }

    public class GenerateRequest {
        // Member name/label kept as "orderId"/"Order ID" for Screen Flow compatibility;
        // this now holds the AcctSeedERP__Purchase_Order__c Id.
        @InvocableVariable(label='Order ID' required=true)
        public Id orderId;
        @InvocableVariable(label='Vendor Name Override')
        public String vendorNameOverride;
        @InvocableVariable(label='Job Site Address Override')
        public String jobSiteOverride;
        @InvocableVariable(label='Exemption Reason Box')
        public String exemptionBox;
        @InvocableVariable(label='Additional Info')
        public String additionalInfo;
        @InvocableVariable(label='Delivery Mode')
        public String deliveryMode;
        @InvocableVariable(label='Tax Exempt Contact Email')
        public String contactEmail;
        @InvocableVariable(label='Tax Exempt Contact Name')
        public String contactName;
    }

    private static String generateSinglePdf(GenerateRequest req) {
        CertificateData data = buildCertificateData(req.orderId);
        if (String.isNotBlank(req.vendorNameOverride)) { data.vendorName = req.vendorNameOverride; }
        if (String.isNotBlank(req.jobSiteOverride)) { data.jobSiteAddress = req.jobSiteOverride; }
        if (String.isNotBlank(req.exemptionBox)) { data.exemptionReasonBox = req.exemptionBox; }
        if (String.isNotBlank(req.additionalInfo)) { data.additionalInfo = req.additionalInfo; }

        PageReference pdfPage = Page.ST120Certificate;
        // BUG FIX (HVAC-303 PO pivot): the VF page uses a standard controller extension,
        // whose record Id URL parameter is "id" — not "orderId". Set the standard
        // parameter name so the page actually receives the record Id.
        pdfPage.getParameters().put('id', req.orderId);
        if (String.isNotBlank(req.vendorNameOverride)) { pdfPage.getParameters().put('vendorName', req.vendorNameOverride); }
        if (String.isNotBlank(req.exemptionBox)) { pdfPage.getParameters().put('exemptionBox', req.exemptionBox); }
        if (String.isNotBlank(req.additionalInfo)) { pdfPage.getParameters().put('additionalInfo', req.additionalInfo); }

        Blob pdfBlob;
        try {
            pdfBlob = Test.isRunningTest() ? Blob.valueOf('TEST PDF CONTENT') : pdfPage.getContentAsPDF();
        } catch (Exception e) {
            throw new AuraHandledException('Failed to generate PDF: ' + e.getMessage());
        }

        ContentVersion cv = new ContentVersion();
        cv.Title = data.fileName.removeEndIgnoreCase('.pdf');
        cv.PathOnClient = data.fileName;
        cv.VersionData = pdfBlob;
        cv.IsMajorVersion = true;
        insert cv;

        ContentDocumentLink cdl = new ContentDocumentLink();
        cdl.ContentDocumentId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        cdl.LinkedEntityId = req.orderId;
        cdl.ShareType = 'V';
        cdl.Visibility = 'AllUsers';
        insert cdl;

        String deliveryMode = req.deliveryMode;
        if (String.isBlank(deliveryMode)) { deliveryMode = 'Email'; }
        if (deliveryMode == 'Separate' && String.isNotBlank(req.contactEmail)) {
            sendSeparateEmail(req.orderId, req.contactEmail, req.contactName, cv.Id, data);
        }
        return cv.Id;
    }

    private static void sendSeparateEmail(Id orderId, String toEmail, String toName, Id contentVersionId, CertificateData data) {
        ContentVersion cv = [SELECT Id, ContentDocumentId, VersionData FROM ContentVersion WHERE Id = :contentVersionId];
        Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
        mail.setToAddresses(new String[]{ toEmail });
        mail.setSubject('Tax Exempt Purchase Certificate – ' + data.vendorName + ' – ' + data.orderNumber);
        mail.setPlainTextBody(
            'Dear ' + (String.isNotBlank(toName) ? toName : 'Vendor Representative') + ',\n\n' +
            'Please find attached the New York State ST-120.1 Contractor Exempt Purchase Certificate ' +
            'for Purchase Order #' + data.orderNumber + '.\n\n' +
            'Job Site: ' + data.jobSiteAddress + '\n' +
            'Project: ' + data.projectDescription + '\n\n' +
            'If you have any questions, please contact your MJI Services representative.\n\n' +
            'Regards,\n' +
            'Michael James Industries, Inc.'
        );
        Messaging.EmailFileAttachment attachment = new Messaging.EmailFileAttachment();
        attachment.setFileName(data.fileName);
        attachment.setBody(cv.VersionData);
        mail.setFileAttachments(new Messaging.EmailFileAttachment[]{ attachment });
        Messaging.SendEmailResult[] sendResults = Messaging.sendEmail(new Messaging.SingleEmailMessage[]{ mail });
        if (sendResults[0].isSuccess()) {
            // Custom objects (including AcctSeedERP__Purchase_Order__c) only accept
            // EmailMessage.RelatedToId if Activities are enabled on that object. Wrap
            // the log-only insert in try/catch so an org where Activities are not
            // enabled on Purchase Order does not break the email send above.
            try {
                EmailMessage em = new EmailMessage();
                em.RelatedToId = orderId;
                em.FromAddress = UserInfo.getUserEmail();
                em.ToAddress = toEmail;
                em.Subject = mail.getSubject();
                em.TextBody = mail.getPlainTextBody();
                em.Status = '3';
                insert em;
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'ST120Generator.sendSeparateEmail: could not log EmailMessage against Purchase Order (Activities may not be enabled on AcctSeedERP__Purchase_Order__c) - ' + e.getMessage());
            }
        }
    }

    @AuraEnabled
    public static void resendCertificate(Id orderId, String toEmail, String toName) {
        Set<Id> docIds = new Set<Id>();
        for (ContentDocumentLink link : [
            SELECT ContentDocumentId FROM ContentDocumentLink WHERE LinkedEntityId = :orderId
        ]) {
            docIds.add(link.ContentDocumentId);
        }
        List<ContentVersion> cvs = docIds.isEmpty()
            ? new List<ContentVersion>()
            : [ SELECT Id, Title, FileExtension FROM ContentVersion
                WHERE ContentDocumentId IN :docIds AND FileExtension = 'pdf'
                AND Title LIKE 'ST120_%' ORDER BY CreatedDate DESC LIMIT 1 ];
        if (cvs.isEmpty()) {
            throw new AuraHandledException('No ST-120.1 certificate found for this Purchase Order.');
        }
        CertificateData data = buildCertificateData(orderId);
        sendSeparateEmail(orderId, toEmail, toName, cvs[0].Id, data);
    }

    private static String buildAddress(String street, String city, String state, String zip) {
        String addr = '';
        if (String.isNotBlank(street)) addr += street;
        if (String.isNotBlank(city)) { addr += (String.isNotBlank(addr) ? ', ' : '') + city; }
        if (String.isNotBlank(state)) { addr += (String.isNotBlank(addr) ? ', ' : '') + state; }
        if (String.isNotBlank(zip)) { addr += (String.isNotBlank(addr) ? ' ' : '') + zip; }
        return addr;
    }

    private static String cleanFileName(String name) {
        if (String.isBlank(name)) return 'Vendor';
        return name.replaceAll('[^a-zA-Z0-9\\s-]', '').replaceAll('\\s+', '_').left(40);
    }

    @AuraEnabled
    public static String checkVendorPolicy(Id orderId) {
        AcctSeedERP__Purchase_Order__c po = [
            SELECT Id, AcctSeedERP__Vendor__r.Tax_Exempt_Policy__c, AcctSeedERP__Vendor__r.Tax_Exempt_Notes__c
            FROM AcctSeedERP__Purchase_Order__c WHERE Id = :orderId LIMIT 1
        ];
        String policy = po.AcctSeedERP__Vendor__r?.Tax_Exempt_Policy__c;
        if (policy == 'Do Not Send') { return 'BLOCKED: This vendor is flagged as Do Not Send. Certificate generation is not available.'; }
        if (policy == 'Short Pay Only') { return 'WARNING: This vendor only accepts short-pay arrangements. The certificate will be flagged accordingly.'; }
        if (policy == 'After Invoice Only') { return 'WARNING: This vendor requires the certificate after invoice. PDF will be generated and saved but not sent.'; }
        if (policy == 'Manual Process Required') {
            String notes = po.AcctSeedERP__Vendor__r?.Tax_Exempt_Notes__c;
            return 'INFO: Manual process required. ' + (String.isNotBlank(notes) ? notes : '');
        }
        return null;
    }

    @RemoteAction
    public static Map<String, Object> uploadCertificate(String orderId, String base64Data, String fileName) {
        Map<String, Object> result = new Map<String, Object>();
        try {
            Blob pdfBlob = EncodingUtil.base64Decode(base64Data);
            ContentVersion cv = new ContentVersion(
                Title = fileName.removeEndIgnoreCase('.pdf'),
                PathOnClient = fileName,
                VersionData = pdfBlob,
                IsMajorVersion = true
            );
            insert cv;

            ContentVersion saved = [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id LIMIT 1];
            ContentDocumentLink link = new ContentDocumentLink(
                ContentDocumentId = saved.ContentDocumentId,
                LinkedEntityId = orderId,
                ShareType = 'V',
                Visibility = 'AllUsers'
            );
            insert link;

            result.put('success', true);
            result.put('contentVersionId', saved.Id);
            result.put('contentDocumentId', saved.ContentDocumentId);
        } catch (Exception e) {
            result.put('success', false);
            result.put('error', e.getMessage());
        }
        return result;
    }
}
