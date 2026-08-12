import { LightningElement, track, wire } from 'lwc';
import getAppointments from '@salesforce/apex/ServicePriorityController.getAppointments';
import getFollowUpAnalysis from '@salesforce/apex/ServicePriorityController.getFollowUpAnalysis';

export default class ServicePriorityDashboard extends LightningElement {
    // Date range
    @track startDate;
    @track endDate;
    @track quickFilter = 'yesterday';

    // Data
    @track appointments = [];
    @track analysisMap = {};
    @track isLoading = false;
    @track hasError = false;
    @track errorMessage = '';

    // Accordion state
    @track showUrgent = true;
    @track showHigh = true;
    @track showMedium = true;
    @track showLow = false;

    // Detail panel
    @track showDetailPanel = false;
    @track selectedAppointment = null;
    @track selectedAnalysis = null;

    // Lifecycle
    connectedCallback() {
        this.setYesterday();
    }

    // ─── Date Presets ───────────────────────────────────────────

    get yesterdayButtonVariant() {
        return this.quickFilter === 'yesterday' ? 'brand' : 'neutral';
    }
    get last3ButtonVariant() {
        return this.quickFilter === 'last3' ? 'brand' : 'neutral';
    }
    get thisWeekButtonVariant() {
        return this.quickFilter === 'thisWeek' ? 'brand' : 'neutral';
    }

    setYesterday() {
        const today = new Date();
        const yesterday = new Date(today);
        yesterday.setDate(yesterday.getDate() - 1);
        this.startDate = this.toDateString(yesterday);
        this.endDate = this.toDateString(yesterday);
        this.quickFilter = 'yesterday';
        this.loadData();
    }

    setLast3Days() {
        const today = new Date();
        const yesterday = new Date(today);
        yesterday.setDate(yesterday.getDate() - 1);
        const threeDaysAgo = new Date(yesterday);
        threeDaysAgo.setDate(threeDaysAgo.getDate() - 2);
        this.startDate = this.toDateString(threeDaysAgo);
        this.endDate = this.toDateString(yesterday);
        this.quickFilter = 'last3';
        this.loadData();
    }

    setThisWeek() {
        const today = new Date();
        const dayOfWeek = today.getDay();
        const monday = new Date(today);
        monday.setDate(today.getDate() - ((dayOfWeek + 6) % 7));
        this.startDate = this.toDateString(monday);
        this.endDate = this.toDateString(today);
        this.quickFilter = 'thisWeek';
        this.loadData();
    }

    // ─── Date Handlers ──────────────────────────────────────────

    handleStartDateChange(event) {
        this.startDate = event.target.value;
        this.quickFilter = null;
    }

    handleEndDateChange(event) {
        this.endDate = event.target.value;
        this.quickFilter = null;
    }

    // ─── Data Loading ───────────────────────────────────────────

    refreshData() {
        this.loadData();
    }

    async loadData() {
        if (!this.startDate || !this.endDate) return;

        this.isLoading = true;
        this.hasError = false;
        this.errorMessage = '';
        this.showDetailPanel = false;

        try {
            // Parse dates
            const sd = new Date(this.startDate);
            const ed = new Date(this.endDate);

            // Call Apex for appointments
            const rawAppts = await getAppointments({
                startDate: sd,
                endDate: ed
            });

            if (!rawAppts || rawAppts.length === 0) {
                this.appointments = [];
                this.analysisMap = {};
                this.isLoading = false;
                return;
            }

            this.appointments = rawAppts.map(a => ({
                ...a,
                schedStart: this.formatDateTime(a.schedStart),
                schedEnd: this.formatDateTime(a.schedEnd)
            }));

            // Get SA IDs for analysis
            const saIds = this.appointments.map(a => a.id);

            // Call Apex for follow-up analysis
            const analysis = await getFollowUpAnalysis({ saIds: saIds });

            this.analysisMap = {};
            if (analysis) {
                this.analysisMap = analysis;
            }

            // Attach analysis to each appointment
            this.appointments = this.appointments.map(appt => ({
                ...appt,
                analysis: this.analysisMap[appt.id] || {
                    needsFollowUp: false,
                    priority: 'Low',
                    reason: 'No analysis available.',
                    summary: '',
                    signalCount: 0,
                    signals: []
                }
            }));

        } catch (error) {
            this.hasError = true;
            this.errorMessage = error.body?.message || error.message || 'An unexpected error occurred while loading data.';
            console.error('Dashboard load error:', error);
        } finally {
            this.isLoading = false;
        }
    }

    // ─── Computed Properties ────────────────────────────────────

    get totalAppointmentCount() {
        return this.appointments.length;
    }

    get followUpCount() {
        return this.appointments.filter(a => a.analysis && a.analysis.needsFollowUp).length;
    }

    get summaryLabel() {
        return `${this.followUpCount} needing attention of ${this.totalAppointmentCount} total`;
    }

    get isEmpty() {
        return !this.isLoading && this.appointments.length === 0;
    }

    // Priority-sorted appointments
    get urgentAppointments() {
        return this.sortedByPriority('Urgent');
    }
    get highAppointments() {
        return this.sortedByPriority('High');
    }
    get mediumAppointments() {
        return this.sortedByPriority('Medium');
    }
    get lowAppointments() {
        return this.sortedByPriority('Low');
    }

    get urgentCount() { return this.urgentAppointments.length; }
    get highCount() { return this.highAppointments.length; }
    get mediumCount() { return this.mediumAppointments.length; }
    get lowCount() { return this.lowAppointments.length; }

    sortedByPriority(priority) {
        return this.appointments
            .filter(a => a.analysis && a.analysis.priority === priority)
            .sort((a, b) => {
                // Sort by signal count descending within same priority
                const sigA = a.analysis.signalCount || 0;
                const sigB = b.analysis.signalCount || 0;
                return sigB - sigA;
            });
    }

    // ─── Accordion Icons ────────────────────────────────────────

    get urgentIcon() {
        return this.showUrgent ? 'utility:chevrondown' : 'utility:chevronright';
    }
    get highIcon() {
        return this.showHigh ? 'utility:chevrondown' : 'utility:chevronright';
    }
    get mediumIcon() {
        return this.showMedium ? 'utility:chevrondown' : 'utility:chevronright';
    }
    get lowIcon() {
        return this.showLow ? 'utility:chevrondown' : 'utility:chevronright';
    }

    toggleUrgent() { this.showUrgent = !this.showUrgent; }
    toggleHigh() { this.showHigh = !this.showHigh; }
    toggleMedium() { this.showMedium = !this.showMedium; }
    toggleLow() { this.showLow = !this.showLow; }

    // ─── Detail Panel ───────────────────────────────────────────

    handleViewDetails(event) {
        const apptId = event.detail;
        this.selectedAppointment = this.appointments.find(a => a.id === apptId) || null;
        this.selectedAnalysis = this.selectedAppointment
            ? (this.analysisMap[this.selectedAppointment.id] || null)
            : null;
        this.showDetailPanel = true;
    }

    handleClosePanel() {
        this.showDetailPanel = false;
        this.selectedAppointment = null;
        this.selectedAnalysis = null;
    }

    // ─── Helpers ────────────────────────────────────────────────

    toDateString(date) {
        const y = date.getFullYear();
        const m = String(date.getMonth() + 1).padStart(2, '0');
        const d = String(date.getDate()).padStart(2, '0');
        return `${y}-${m}-${d}`;
    }

    formatDateTime(dt) {
        if (!dt) return '';
        // Salesforce ISO datetime -> readable time
        const d = new Date(dt);
        return d.toLocaleTimeString('en-US', {
            hour: 'numeric',
            minute: '2-digit',
            timeZoneName: 'short'
        });
    }
}