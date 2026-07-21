/**
 * ST120GeneratorExtension
 * Visualforce extension for the ST120Certificate page.
 * Provides the data properties rendered in the PDF.
 *
 * HVAC-303 Option A — Purchase Order pivot (2026-07-08): the ST120Certificate
 * page's standardController is now AcctSeedERP__Purchase_Order__c instead of
 * Order. ApexPages.StandardController works against any SObject, so this class
 * is unchanged apart from this comment — stdController.getId() now returns a
 * Purchase Order Id, which ST120Generator.buildCertificateData() expects.
 * Getter names are unchanged; the VF page merge fields bind to them.
 */
public with sharing class ST120GeneratorExtension {

    public ST120Generator.CertificateData certData { get; private set; }

    // Expose all fields for Visualforce merge
    public String mjiName { get { return certData.mjiName; } }
    public String mjiStreet { get { return certData.mjiStreet; } }
    public String mjiCityStateZip { get { return certData.mjiCityStateZip; } }
    public String caNumber { get { return certData.caNumber; } }
    public String vendorName { get { return certData.vendorName; } }
    public String vendorStreet { get { return certData.vendorStreet; } }
    public String vendorCity { get { return certData.vendorCity; } }
    public String vendorState { get { return certData.vendorState; } }
    public String vendorZip { get { return certData.vendorZip; } }
    public String jobSiteAddress { get { return certData.jobSiteAddress; } }
    public String projectDescription { get { return certData.projectDescription; } }
    public String exemptOrgName { get { return certData.exemptOrgName; } }
    public String primeContractDate { get { return certData.primeContractDate; } }
    public String exemptionReasonBox { get { return certData.exemptionReasonBox; } }
    public String signerName { get { return certData.signerName; } }
    public String signerTitle { get { return certData.signerTitle; } }
    public String generationDate { get { return certData.generationDate; } }
    public String additionalInfo { get { return certData.additionalInfo; } }
    public String formVersion { get { return certData.formVersion; } }
    public String orderNumber { get { return certData.orderNumber; } }

    public ST120GeneratorExtension(ApexPages.StandardController stdController) {
        Id recordId = stdController.getId();
        this.certData = ST120Generator.buildCertificateData(recordId);

        // Apply any URL parameter overrides
        Map<String, String> params = ApexPages.currentPage().getParameters();
        if (params.containsKey('vendorName') && String.isNotBlank(params.get('vendorName'))) {
            this.certData.vendorName = params.get('vendorName');
        }
        if (params.containsKey('exemptionBox') && String.isNotBlank(params.get('exemptionBox'))) {
            this.certData.exemptionReasonBox = params.get('exemptionBox');
        }
        if (params.containsKey('additionalInfo') && String.isNotBlank(params.get('additionalInfo'))) {
            this.certData.additionalInfo = params.get('additionalInfo');
        }
    }
}