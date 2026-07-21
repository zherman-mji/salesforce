public with sharing class ST120CertificatePageController {

    public String poId { get; private set; }
    public String orderNumber { get; private set; }
    public String vendorName { get; private set; }
    public String vendorStreet { get; private set; }
    public String vendorCity { get; private set; }
    public String vendorState { get; private set; }
    public String vendorZip { get; private set; }
    public String mjiName { get; private set; }
    public String mjiStreet { get; private set; }
    public String mjiCityStateZip { get; private set; }
    public String caNumber { get; private set; }
    public String projectDescription { get; private set; }
    public String jobSiteAddress { get; private set; }
    public String exemptOrgName { get; private set; }
    public String primeContractDate { get; private set; }
    public String signerName { get; private set; }
    public String signerTitle { get; private set; }
    public String generationDate { get; private set; }
    public String exemptionReason { get; private set; }
    public String exemptionReasonBox { get; private set; }
    public String vendorId { get; private set; }
    public String workOrderId { get; private set; }
    public String exemptOrgId { get; private set; }
    public String dataSourceLabel { get; private set; }
    public Boolean isOverride { get; private set; }

    public ST120CertificatePageController() {
        String idParam = ApexPages.currentPage().getParameters().get('id');
        if (String.isBlank(idParam)) {
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, 'No Purchase Order ID provided.'));
            return;
        }
        try {
            ST120Generator.CertificateData data = ST120Generator.buildCertificateData(idParam);
            this.poId = idParam;
            this.orderNumber = data.orderNumber;
            this.vendorName = data.vendorName;
            this.vendorStreet = data.vendorStreet;
            this.vendorCity = data.vendorCity;
            this.vendorState = data.vendorState;
            this.vendorZip = data.vendorZip;
            this.mjiName = data.mjiName;
            this.mjiStreet = data.mjiStreet;
            this.mjiCityStateZip = data.mjiCityStateZip;
            this.caNumber = data.caNumber;
            this.projectDescription = data.projectDescription;
            this.jobSiteAddress = data.jobSiteAddress;
            this.exemptOrgName = data.exemptOrgName;
            this.primeContractDate = data.primeContractDate;
            this.signerName = data.signerName;
            this.signerTitle = data.signerTitle;
            this.generationDate = data.generationDate;
            this.exemptionReason = data.exemptionReasonText;
            this.exemptionReasonBox = data.exemptionReasonBox;
            this.vendorId = data.vendorId;
            this.workOrderId = data.workOrderId;
            this.exemptOrgId = data.exemptOrgId;
            this.dataSourceLabel = data.dataSourceLabel;
            this.isOverride = data.isOverride;
        } catch (Exception e) {
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, 'Error loading Purchase Order: ' + e.getMessage()));
        }
    }
}