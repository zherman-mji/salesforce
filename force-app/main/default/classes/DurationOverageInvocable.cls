/**
 * @description Invocable wrapper for DurationOverageService. Enables
 * invocation from Flow (Record-Triggered Flow on ServiceAppointment).
 *
 * Accepts a list of SA IDs, batches them, and calls the @future
 * evaluateScheduledDuration method.
 */
public class DurationOverageInvocable {

    /**
     * @description Request wrapper for the invocable method
     */
    public class Request {
        @InvocableVariable(
            label='Service Appointment ID'
            description='The ID of the Service Appointment to evaluate'
            required=true
        )
        public Id serviceAppointmentId;
    }

    /**
     * @description Invocable method called by Flow after SA insert/update.
     * Batches SA IDs and delegates to DurationOverageService.evaluateScheduledDuration.
     * @param requests List of Request objects containing SA IDs
     */
    @InvocableMethod(
        label='Check Duration Overage'
        description='Checks if scheduled SA durations exceed the Work Order estimate and alerts the manager'
        category='Work Order'
    )
    public static void check(List<Request> requests) {
        if (requests == null || requests.isEmpty()) {
            return;
        }

        Set<Id> saIds = new Set<Id>();
        for (Request req : requests) {
            if (req != null && req.serviceAppointmentId != null) {
                saIds.add(req.serviceAppointmentId);
            }
        }

        if (saIds.isEmpty()) {
            return;
        }

        DurationOverageService.evaluateScheduledDuration(saIds);
    }
}