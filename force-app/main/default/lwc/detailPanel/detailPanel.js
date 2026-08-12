import { LightningElement, api, track, wire } from 'lwc';
import getWODetails from '@salesforce/apex/ServicePriorityController.getWODetails';
import getConversationHistory from '@salesforce/apex/ServicePriorityController.getConversationHistory';
import getActivityFeed from '@salesforce/apex/ServicePriorityController.getActivityFeed';

export default class DetailPanel extends LightningElement {
    @api appointment;
    @api analysis;

    @track isLoadingDetails = false;
    @track workOrder = {};
    @track wolis = [];
    @track conversationEntries = [];
    @track feedItems = [];

    // ─── Lifecycle ──────────────────────────────────────────────

    connectedCallback() {
        this.loadDetails();
    }

    // ─── Data Loading ───────────────────────────────────────────

    async loadDetails() {
        if (!this.appointment || !this.appointment.workOrderId) {
            this.isLoadingDetails = false;
            return;
        }

        this.isLoadingDetails = true;

        try {
            // Load everything in parallel
            const [woDetail, entries, feed] = await Promise.all([
                getWODetails({ workOrderId: this.appointment.workOrderId }),
                getConversationHistory({ parentRecordId: this.appointment.workOrderId }),
                getActivityFeed({ parentRecordId: this.appointment.workOrderId })
            ]);

            this.workOrder = woDetail?.workOrder || {};
            this.wolis = woDetail?.workOrderLineItems || [];

            // Transform conversation entries
            this.conversationEntries = (entries || []).map(e => ({
                ...e,
                directionClass: e.Direction === 'Inbound' ? 'entry-inbound' : 'entry-outbound',
                directionIcon: e.Direction === 'Inbound' ? 'utility:forward' : 'utility:reply',
                directionLabel: e.Direction === 'Inbound' ? 'Customer → Us' : 'Us → Customer',
                receivedTime: this.formatDateTime(e.ReceivedTime)
            }));

            // Transform feed items
            this.feedItems = (feed || []).map(f => ({
                ...f,
                createdDate: this.formatDateTime(f.CreatedDate),
                hasComments: f.FeedComments && f.FeedComments.length > 0
            }));

        } catch (error) {
            console.error('Detail panel load error:', error);
        } finally {
            this.isLoadingDetails = false;
        }
    }

    // ─── Computed Properties ────────────────────────────────────

    get hasWOLIs() {
        return this.wolis && this.wolis.length > 0;
    }

    get hasNotes() {
        return !!(this.workOrder.Executive_Summary__c
            || this.workOrder.Service_Notes__c
            || this.workOrder.Next_Steps__c
            || this.workOrder.Risks__c);
    }

    get hasCorrespondence() {
        return this.conversationEntries && this.conversationEntries.length > 0;
    }

    get hasFeedItems() {
        return this.feedItems && this.feedItems.length > 0;
    }

    // ─── Event Handlers ─────────────────────────────────────────

    handleClose() {
        this.dispatchEvent(new CustomEvent('close', { bubbles: true, composed: true }));
    }

    handleBackdropClick() {
        this.handleClose();
    }

    handlePanelClick(event) {
        // Stop propagation so clicking inside the panel doesn't close it
        event.stopPropagation();
    }

    handleViewWO() {
        if (this.appointment.workOrderId) {
            window.open(`/${this.appointment.workOrderId}`, '_blank');
        }
    }

    handleViewAccount() {
        if (this.appointment.accountId) {
            window.open(`/${this.appointment.accountId}`, '_blank');
        }
    }

    handleCreateTask() {
        // Open the new task dialog via Salesforce URL hack
        // This opens the standard new task page prefilled with the WO as WhatId
        if (this.appointment.workOrderId) {
            const url = `/lightning/o/Task/new?what_id=${this.appointment.workOrderId}`;
            window.open(url, '_blank');
        }
    }

    // ─── Helpers ────────────────────────────────────────────────

    formatDateTime(dt) {
        if (!dt) return '';
        const d = new Date(dt);
        return d.toLocaleDateString('en-US', {
            month: 'short',
            day: 'numeric',
            hour: 'numeric',
            minute: '2-digit'
        });
    }
}