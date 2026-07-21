/**
 * ST120DataProvider
 * ------------------
 * Thin Flow-callable wrapper around ST120Generator.buildCertificateData(), used to
 * pre-populate Screen Flow variables with ST-120.1 certificate values without
 * running the full PDF generation pipeline.
 *
 * HVAC-303 Option A — Purchase Order pivot (2026-07-08): no logic here changed;
 * this class simply forwards to ST120Generator, which now targets
 * AcctSeedERP__Purchase_Order__c. The `orderIds` parameter and this class's
 * @InvocableVariable member names/labels are UNCHANGED for Screen Flow
 * compatibility — they carry Purchase Order Ids now, not Order Ids.
 */
public with sharing class ST120DataProvider {

    @InvocableMethod(label='Prepare ST-120.1 Certificate Data' description='Returns pre-populated certificate data for the given Order ID')
    public static List<CertificateDataOutput> prepareData(List<Id> orderIds) {
        List<CertificateDataOutput> outputs = new List<CertificateDataOutput>();
        if (orderIds == null) {
            return outputs;
        }
        for (Id orderId : orderIds) {
            ST120Generator.CertificateData data = ST120Generator.buildCertificateData(orderId);
            outputs.add(toOutput(data));
        }
        return outputs;
    }

    private static CertificateDataOutput toOutput(ST120Generator.CertificateData data) {
        CertificateDataOutput output = new CertificateDataOutput();
        output.orderId = data.orderId != null ? String.valueOf(data.orderId) : null;
        output.orderNumber = data.orderNumber;
        output.vendorName = data.vendorName;
        output.vendorStreet = data.vendorStreet;
        output.vendorCity = data.vendorCity;
        output.vendorState = data.vendorState;
        output.vendorZip = data.vendorZip;
        output.vendorFullAddress = data.vendorFullAddress;
        output.jobSiteAddress = data.jobSiteAddress;
        output.projectDescription = data.projectDescription;
        output.projectDescriptionSource = data.projectDescriptionSource;
        output.exemptOrgName = data.exemptOrgName;
        output.primeContractDate = data.primeContractDate;
        output.exemptionReasonBox = data.exemptionReasonBox;
        output.signerName = data.signerName;
        output.signerTitle = data.signerTitle;
        output.formVersion = data.formVersion;
        output.fileName = data.fileName;
        return output;
    }

    public class CertificateDataOutput {
        // Member names, types, and labels kept EXACTLY as in the pre-pivot version
        // for Screen Flow compatibility (orderId stays String — the flow's output
        // variable was created as Text).
        @InvocableVariable(label='Order ID')
        public String orderId;
        @InvocableVariable(label='Order Number')
        public String orderNumber;
        @InvocableVariable(label='Vendor Name')
        public String vendorName;
        @InvocableVariable(label='Vendor Street')
        public String vendorStreet;
        @InvocableVariable(label='Vendor City')
        public String vendorCity;
        @InvocableVariable(label='Vendor State')
        public String vendorState;
        @InvocableVariable(label='Vendor Zip')
        public String vendorZip;
        @InvocableVariable(label='Vendor Full Address')
        public String vendorFullAddress;
        @InvocableVariable(label='Job Site Address')
        public String jobSiteAddress;
        @InvocableVariable(label='Project Description')
        public String projectDescription;
        @InvocableVariable(label='Project Description Source')
        public String projectDescriptionSource;
        @InvocableVariable(label='Exempt Organization Name')
        public String exemptOrgName;
        @InvocableVariable(label='Prime Contract Date')
        public String primeContractDate;
        @InvocableVariable(label='Exemption Reason Box')
        public String exemptionReasonBox;
        @InvocableVariable(label='Signer Name')
        public String signerName;
        @InvocableVariable(label='Signer Title')
        public String signerTitle;
        @InvocableVariable(label='Form Version')
        public String formVersion;
        @InvocableVariable(label='File Name')
        public String fileName;
    }
}