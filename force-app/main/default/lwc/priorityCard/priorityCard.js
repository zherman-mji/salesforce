import { LightningElement, api } from 'lwc';

export default class PriorityCard extends LightningElement {
    @api appointment;
    @api analysis;

    get appointmentLink() {
        const saId = this.appointment.id;
        return `/${saId}`;
    }

    /**
     * Handle click on the card (opens detail panel).
     * Fires a custom event that the parent dashboard listens for.
     */
    handleClick() {
        // Fire event to parent to open detail panel
        this.dispatchEvent(
            new CustomEvent('viewdetails', {
                detail: this.appointment.id,
                bubbles: true,
                composed: true
            })
        );
    }

    /**
     * Handle click on the appointment number link.
     * Navigate directly to the SA record — stop propagation to avoid
     * also triggering the detail panel.
     */
    handleApptLink(event) {
        // Let the anchor navigate naturally
        event.stopPropagation();
    }
}