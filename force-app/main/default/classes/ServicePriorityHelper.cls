/**
 * ServicePriorityHelper
 *
 * Classification engine for the Service Priority Dashboard.
 * Determines if a service appointment needs follow-up action and
 * assigns a priority level (Urgent, High, Medium, Low) based on
 * status signals, work performed notes, customer correspondence,
 * and other contextual signals.
 */
public with sharing class ServicePriorityHelper {

    // Keyword lists and scoring weights/thresholds are loaded from Custom
    // Metadata (Priority_Keyword_Category__mdt, Priority_Scoring_Setting__mdt)
    // instead of being hardcoded here, so an admin can retune classification
    // in Setup without an Apex deploy. Loaded once and cached for the rest of
    // the transaction -- see ensureConfigLoaded().
    private static Map<String, Set<String>> keywordsByCategory;
    private static Map<String, Decimal> scoringSettings;

    // Statuses on SA that automatically require follow-up
    private static final Set<String> FOLLOW_UP_SA_STATUSES = new Set<String>{
        'Cannot Complete', 'Canceled'
    };

    // Statuses on WO that automatically require follow-up
    private static final Set<String> FOLLOW_UP_WO_STATUSES = new Set<String>{
        'Cannot Complete'
    };

    // How far into a correspondence Task's body to scan for keywords. These are
    // legacy "Email to Salesforce" Tasks whose Description is the raw email text
    // with the newest reply at the TOP followed by the full quoted thread history
    // below it -- scanning only the first ~500 chars targets the latest message
    // and avoids false-positive keyword hits buried in old quoted replies.
    private static final Integer CORRESPONDENCE_SCAN_LENGTH = 500;

    // Words that, immediately before a matched keyword, flip its meaning --
    // e.g. "No follow-up actions were noted" contains "follow-up" but is
    // saying the opposite of what that keyword implies.
    private static final Set<String> NEGATORS = new Set<String>{
        'no ', 'not ', 'none', 'n/a', 'never', 'without', 'did not', 'didn\'t', 'no further'
    };

    /**
     * Loads (and caches) keyword lists + scoring settings from Custom
     * Metadata. Falls back to the original hardcoded defaults for any
     * setting whose CMT record is missing, so classification degrades
     * gracefully instead of breaking if a record gets deleted.
     */
    private static void ensureConfigLoaded() {
        if (keywordsByCategory != null && scoringSettings != null) {
            return;
        }

        keywordsByCategory = new Map<String, Set<String>>();
        for (Priority_Keyword_Category__mdt cat : [
            SELECT DeveloperName, Keywords__c
            FROM Priority_Keyword_Category__mdt
        ]) {
            Set<String> kws = new Set<String>();
            if (String.isNotBlank(cat.Keywords__c)) {
                for (String kw : cat.Keywords__c.split(';')) {
                    String trimmed = kw.trim().toLowerCase();
                    if (String.isNotBlank(trimmed)) {
                        kws.add(trimmed);
                    }
                }
            }
            keywordsByCategory.put(cat.DeveloperName, kws);
        }

        scoringSettings = new Map<String, Decimal>();
        for (Priority_Scoring_Setting__mdt setting : [
            SELECT DeveloperName, Value__c
            FROM Priority_Scoring_Setting__mdt
        ]) {
            scoringSettings.put(setting.DeveloperName, setting.Value__c);
        }

        applyDefaultIfMissing('SA_Cannot_Complete_Points', 100);
        applyDefaultIfMissing('SA_Canceled_Points', 60);
        applyDefaultIfMissing('SA_Not_Completed_Points', 40);
        applyDefaultIfMissing('WO_Cannot_Complete_Points', 80);
        applyDefaultIfMissing('Callback_Points', 50);
        applyDefaultIfMissing('Urgent_Keyword_Points', 100);
        applyDefaultIfMissing('Recommendation_Keyword_Points', 50);
        applyDefaultIfMissing('Followup_Woli_Points', 20);
        applyDefaultIfMissing('Followup_Service_Notes_Points', 15);
        applyDefaultIfMissing('Followup_Exec_Summary_Points', 15);
        applyDefaultIfMissing('Followup_Next_Steps_Points', 20);
        applyDefaultIfMissing('Status_Inquiry_Points', 30);
        applyDefaultIfMissing('Followup_Flag_Points', 60);
        applyDefaultIfMissing('Low_Completion_Score_Points', 40);
        applyDefaultIfMissing('Low_Completion_Score_Threshold', 65);
        applyDefaultIfMissing('Urgent_Threshold', 80);
        applyDefaultIfMissing('High_Threshold', 50);
        applyDefaultIfMissing('Medium_Threshold', 20);
        applyDefaultIfMissing('NeedsFollowUp_Threshold', 15);
    }

    private static void applyDefaultIfMissing(String key, Decimal defaultValue) {
        if (!scoringSettings.containsKey(key) || scoringSettings.get(key) == null) {
            scoringSettings.put(key, defaultValue);
        }
    }

    private static Integer points(String settingKey) {
        return Integer.valueOf(scoringSettings.get(settingKey));
    }

    private static Set<String> keywords(String category) {
        Set<String> kws = keywordsByCategory.get(category);
        return kws != null ? kws : new Set<String>();
    }

    /**
     * Returns the first keyword from the set found in the (already
     * lowercased) text, or null if none match (or every match is
     * suppressed -- see isSuppressed). Set iteration order isn't
     * guaranteed, but any one real match is informative enough to display.
     */
    private static String firstMatch(String textLower, Set<String> kws) {
        for (String kw : kws) {
            if (textLower.contains(kw) && !isSuppressed(textLower, kw)) {
                return kw;
            }
        }
        return null;
    }

    /**
     * A keyword match is suppressed (treated as if it never matched) when:
     *
     * 1. It's directly negated in the same clause -- e.g. "No follow-up
     *    actions were noted" contains "follow-up" but says the opposite of
     *    what that keyword implies. Only the text since the last sentence
     *    break is checked, so an unrelated negation earlier in the
     *    paragraph ("not engaging. Recommend...") doesn't bleed into a
     *    later, unrelated keyword's context.
     * 2. Resolution language appears anywhere else in the same field --
     *    e.g. "identified a pump failure ... removed and replaced ...
     *    operation was verified" is describing the INITIAL diagnosis, not
     *    an unresolved issue, once the rest of the note documents the fix.
     *    Configured via the "Resolution" Priority_Keyword_Category__mdt
     *    record; if that category has no keywords configured, this check
     *    simply never suppresses (the safe default).
     */
    private static Boolean isSuppressed(String textLower, String keyword) {
        Integer idx = textLower.indexOf(keyword);
        if (idx < 0) {
            return false;
        }

        Integer windowStart = Math.max(0, idx - 25);
        String before = textLower.substring(windowStart, idx);
        Integer lastBreak = Math.max(before.lastIndexOf('.'),
            Math.max(before.lastIndexOf(';'), before.lastIndexOf('\n')));
        if (lastBreak >= 0) {
            before = before.substring(lastBreak + 1);
        }
        for (String negator : NEGATORS) {
            if (before.contains(negator)) {
                return true;
            }
        }

        if (rawContainsAny(textLower, keywords('Resolution')) != null) {
            return true;
        }

        return false;
    }

    /**
     * Plain substring search with no suppression logic -- used to check for
     * Resolution-category language without recursing back into firstMatch.
     */
    private static String rawContainsAny(String textLower, Set<String> kws) {
        for (String kw : kws) {
            if (textLower.contains(kw)) {
                return kw;
            }
        }
        return null;
    }

    /**
     * Main classification entry point.
     *
     * @param sa            The ServiceAppointment record
     * @param wo            The related WorkOrder (fetched separately via
     *                      ParentRecordId -- ServiceAppointment has no direct
     *                      WorkOrder relationship field). May be null.
     * @param wolis         List of WorkOrderLineItems attributed specifically
     *                      to THIS appointment (see wolisBySA in
     *                      ServicePriorityController) -- used for per-visit
     *                      signal detection (Signal 5) and the summary.
     * @param correspondence Recent customer-correspondence Task records
     *                      (TaskSubtype='Email') for the parent WO
     * @param allWolisOnWO  ALL WorkOrderLineItems on the parent WO,
     *                      regardless of which appointment they're
     *                      attributed to -- used only to find the truly
     *                      most recent visit's completion score, so a
     *                      whole-job flag like Callback__c that's actually
     *                      been resolved by a later visit isn't kept
     *                      showing on every appointment on the WO.
     * @return FollowUpResult with classification and summary
     */
    public static ServicePriorityController.FollowUpResult classify(
        ServiceAppointment sa,
        WorkOrder wo,
        List<WorkOrderLineItem> wolis,
        List<Task> correspondence,
        List<WorkOrderLineItem> allWolisOnWO
    ) {
        ensureConfigLoaded();

        ServicePriorityController.FollowUpResult result = new ServicePriorityController.FollowUpResult();
        // Each signal is tagged with a source label and the detailPanel tab
        // value it lives on, so the UI can show the reader exactly where to
        // look instead of just a flat list of reasons.
        List<ServicePriorityController.SignalDetail> signalDetails = new List<ServicePriorityController.SignalDetail>();
        Integer totalScore = 0;

        // Tracks reasons the tech may NOT have finished everything the
        // customer/dispatcher originally asked for (WorkOrder.Description,
        // labeled "Work requested" in this org). This is a heuristic, not a
        // real comparison of request text against work performed -- it
        // reuses the same status/keyword signals already being detected
        // below, since those (Cannot Complete, callback, "pending", "unable
        // to", "on order", etc.) are exactly the language that shows up when
        // a job wasn't fully wrapped up.
        // Split by scope so the completion note (and the signal pills above
        // it) can tell the reader "this visit's own findings" apart from
        // "other findings on this Work Order" instead of blending both into
        // one sentence as if they all describe the appointment being viewed.
        List<String> thisVisitConcerns = new List<String>();
        List<String> otherConcerns = new List<String>();

        // Find the most recent visit across the WHOLE Work Order (not just
        // the WOLI(s) attributed to this appointment) that has a completion
        // score recorded. Whole-job flags like Callback__c don't get
        // auto-cleared in this org when a later visit actually resolves
        // things, so a good, recent score is a more reliable signal that
        // the job is done than a stale flag from an earlier visit. If no
        // visit has a score at all, this stays null and the flag-gating
        // below is simply skipped (can't determine either way).
        WorkOrderLineItem mostRecentScoredWoli = null;
        if (allWolisOnWO != null) {
            for (WorkOrderLineItem w : allWolisOnWO) {
                if (w.Work_Performed_Summary_Score__c == null || w.Work_Performed_Date__c == null) {
                    continue;
                }
                if (mostRecentScoredWoli == null
                    || w.Work_Performed_Date__c > mostRecentScoredWoli.Work_Performed_Date__c) {
                    mostRecentScoredWoli = w;
                }
            }
        }
        Boolean mostRecentVisitResolved = mostRecentScoredWoli != null
            && mostRecentScoredWoli.Work_Performed_Summary_Score__c >= points('Low_Completion_Score_Threshold')
            && mostRecentScoredWoli.Follow_up_work_required__c != 'Required';

        // Which ONE WOLI (if any, among the ones attributed to this
        // appointment) is THIS visit's own -- same idea as
        // ServicePriorityController.findNearestWoliId, duplicated here in
        // miniature since that helper lives on a different class and this
        // only needs to pick among wolis already scoped to this SA (no
        // cross-appointment "claimed elsewhere" exclusion required). A job
        // with several WorkOrderLineItems (e.g. one per piece of equipment
        // touched) but only one ServiceAppointment on record will have all
        // of them attributed here, even though only one describes what THIS
        // appointment's own write-up says -- the rest are other findings on
        // the same Work Order, not this visit's.
        Id primaryWoliId = null;
        if (wolis != null && !wolis.isEmpty()) {
            if (String.isNotBlank(sa?.Description)) {
                String saDescNorm = sa.Description.trim().toLowerCase();
                Id matchedId = null;
                Integer matchCount = 0;
                for (WorkOrderLineItem w : wolis) {
                    if (String.isNotBlank(w.Description) && w.Description.trim().toLowerCase() == saDescNorm) {
                        matchedId = w.Id;
                        matchCount++;
                    }
                }
                if (matchCount == 1) {
                    primaryWoliId = matchedId;
                }
            }
            if (primaryWoliId == null) {
                DateTime apptRef = sa?.SchedEndTime != null ? sa.SchedEndTime : sa?.SchedStartTime;
                if (apptRef != null) {
                    Long smallestDiff = null;
                    for (WorkOrderLineItem w : wolis) {
                        if (w.Work_Performed_Date__c == null) {
                            continue;
                        }
                        Long diff = Math.abs(w.Work_Performed_Date__c.getTime() - apptRef.getTime());
                        if (smallestDiff == null || diff < smallestDiff) {
                            smallestDiff = diff;
                            primaryWoliId = w.Id;
                        }
                    }
                }
            }
            if (primaryWoliId == null) {
                primaryWoliId = wolis[0].Id; // last resort: just call the first one primary
            }
        }

        // --- Signal 1: SA Status Check ---
        if (sa.Status != null && FOLLOW_UP_SA_STATUSES.contains(sa.Status)) {
            signalDetails.add(new ServicePriorityController.SignalDetail(
                'Appointment status: ' + sa.Status, 'Appointment Status', 'workorder'));
            thisVisitConcerns.add('Appointment status is "' + sa.Status + '"');
            if (sa.Status == 'Cannot Complete') {
                totalScore += points('SA_Cannot_Complete_Points'); // Urgent territory
            } else {
                totalScore += points('SA_Canceled_Points');        // High territory
            }
        }

        // --- Signal 2: SA Never Completed ---
        if (sa.Status != 'Completed' && sa.Status != 'None' && sa.Status != 'Scheduled' && !mostRecentVisitResolved) {
            // Was it dispatched but never completed?
            signalDetails.add(new ServicePriorityController.SignalDetail(
                'Appointment not completed (status: ' + sa.Status + ')', 'Appointment Status', 'workorder'));
            totalScore += points('SA_Not_Completed_Points');
        }

        // --- Signal 3: WO Status Check ---
        if (wo != null && wo.Status != null) {
            if (FOLLOW_UP_WO_STATUSES.contains(wo.Status)) {
                signalDetails.add(new ServicePriorityController.SignalDetail(
                    'Work Order status: ' + wo.Status, 'Work Order Status', 'workorder', true));
                otherConcerns.add('Work Order status is "' + wo.Status + '"');
                totalScore += points('WO_Cannot_Complete_Points');
            }
        }

        // --- Signal 4: Callback Flag ---
        // Suppressed when the most recent visit on the WO scored well and
        // wasn't itself flagged for follow-up -- otherwise a callback flag
        // set during an earlier visit (e.g. the initial diagnostic trip)
        // keeps showing on every appointment on the job even after a later
        // visit resolved it.
        if (wo?.Callback__c == true && !mostRecentVisitResolved) {
            signalDetails.add(new ServicePriorityController.SignalDetail(
                'Customer callback requested', 'Callback Requested', 'workorder', true));
            otherConcerns.add('a customer callback is still required');
            totalScore += points('Callback_Points');
        }

        // --- Signal 5: WOLI Analysis (native per-visit completion fields) ---
        // Each WorkOrderLineItem represents one specific visit.
        // woli.Description is the customer's original "Work requested" text
        // for that visit -- still a legitimate source for Urgent-language
        // detection since it's the customer's own words. woli.Service_Notes__c
        // (labeled "Work Performed" -- a DIFFERENT field than the
        // WorkOrder-level field of the same API name) is the tech's own
        // per-visit write-up. Follow_up_work_required__c and
        // Work_Performed_Summary_Score__c/Work_Performed_Feedback__c are
        // structured, purpose-built completion signals already computed by
        // an existing process in this org -- more reliable than re-deriving
        // completion from keywords, so they replace the old keyword-based
        // follow-up check on this object.
        if (wolis != null && !wolis.isEmpty()) {
            for (WorkOrderLineItem woli : wolis) {
                String visitLabel = woli.Work_Performed_Date__c != null
                    ? woli.Work_Performed_Date__c.format('MMM d')
                    : 'a visit';
                // True for every WOLI except the one identified above as
                // THIS appointment's own -- a WO with several line items
                // (e.g. one per piece of equipment) but only one
                // ServiceAppointment on record will have all of them
                // attributed here, but only one is what this visit's own
                // write-up actually says.
                Boolean isOtherVisitWoli = (primaryWoliId != null && woli.Id != primaryWoliId);
                List<String> concernBucket = isOtherVisitWoli ? otherConcerns : thisVisitConcerns;

                if (String.isNotBlank(woli.Description)) {
                    String urgentHit = firstMatch(woli.Description.toLowerCase(), keywords('Urgent'));
                    if (urgentHit != null) {
                        signalDetails.add(new ServicePriorityController.SignalDetail(
                            'Urgent language in customer request: "'
                                + extractSentenceContaining(woli.Description, urgentHit) + '"',
                            'Work Performed', 'workperformed', isOtherVisitWoli));
                        totalScore += points('Urgent_Keyword_Points');
                    }
                }

                if (String.isNotBlank(woli.Service_Notes__c)) {
                    String recommendHit = firstMatch(woli.Service_Notes__c.toLowerCase(), keywords('Recommendation'));
                    if (recommendHit != null) {
                        signalDetails.add(new ServicePriorityController.SignalDetail(
                            'Recommendation noted in work performed: "'
                                + extractSentenceContaining(woli.Service_Notes__c, recommendHit) + '"',
                            'Work Performed', 'workperformed', isOtherVisitWoli));
                        totalScore += points('Recommendation_Keyword_Points');
                    }
                }

                if (woli.Follow_up_work_required__c == 'Required') {
                    signalDetails.add(new ServicePriorityController.SignalDetail(
                        'Follow-up flagged as required (' + visitLabel + ')', 'Work Performed', 'workperformed', isOtherVisitWoli));
                    concernBucket.add('a visit on ' + visitLabel + ' was flagged "Follow-up Required"');
                    totalScore += points('Followup_Flag_Points');
                }

                if (woli.Work_Performed_Summary_Score__c != null
                    && woli.Work_Performed_Summary_Score__c < points('Low_Completion_Score_Threshold')) {
                    Integer scoreInt = Integer.valueOf(woli.Work_Performed_Summary_Score__c);
                    String feedbackSnippet = String.isNotBlank(woli.Work_Performed_Feedback__c)
                        ? truncateForDisplay(woli.Work_Performed_Feedback__c, 100)
                        : '';
                    signalDetails.add(new ServicePriorityController.SignalDetail(
                        'Low completion score (' + scoreInt + '/100) on ' + visitLabel
                            + (String.isNotBlank(feedbackSnippet) ? ': ' + feedbackSnippet : ''),
                        'Work Performed', 'workperformed', isOtherVisitWoli));
                    concernBucket.add('a visit on ' + visitLabel + ' scored ' + scoreInt + '/100 for completion'
                        + (String.isNotBlank(feedbackSnippet) ? ' ("' + feedbackSnippet + '")' : ''));
                    totalScore += points('Low_Completion_Score_Points');
                }
            }
        }

        // --- Signal 6: Service Notes Analysis ---
        String serviceNotes = wo?.Service_Notes__c;
        if (String.isNotBlank(serviceNotes) && !mostRecentVisitResolved) {
            String hit = firstMatch(serviceNotes.toLowerCase(), keywords('FollowUp'));
            if (hit != null) {
                String sentence = extractSentenceContaining(serviceNotes, hit);
                signalDetails.add(new ServicePriorityController.SignalDetail(
                    'Follow-up signal in service notes: "' + sentence + '"', 'Service Notes', 'servicenotes', true));
                otherConcerns.add('service notes mention "' + sentence + '"');
                totalScore += points('Followup_Service_Notes_Points');
            }
        }

        // --- Signal 7: Executive Summary Analysis ---
        String execSummary = wo?.Executive_Summary__c;
        if (String.isNotBlank(execSummary) && !mostRecentVisitResolved) {
            String hit = firstMatch(execSummary.toLowerCase(), keywords('FollowUp'));
            if (hit != null) {
                String sentence = extractSentenceContaining(execSummary, hit);
                signalDetails.add(new ServicePriorityController.SignalDetail(
                    'Follow-up signal in executive summary: "' + sentence + '"', 'Executive Summary', 'servicenotes', true));
                otherConcerns.add('the executive summary mentions "' + sentence + '"');
                totalScore += points('Followup_Exec_Summary_Points');
            }
        }

        // --- Signal 8: Next Steps Analysis ---
        // Any populated Next Steps text is itself a strong signal that work
        // remains -- flag it as a completion concern even if it doesn't
        // happen to contain one of the FollowUp keywords.
        String nextSteps = wo?.Next_Steps__c;
        if (String.isNotBlank(nextSteps) && !mostRecentVisitResolved) {
            String hit = firstMatch(nextSteps.toLowerCase(), keywords('FollowUp'));
            if (hit != null) {
                String sentence = extractSentenceContaining(nextSteps, hit);
                signalDetails.add(new ServicePriorityController.SignalDetail(
                    'Follow-up signal in next steps: "' + sentence + '"', 'Next Steps', 'servicenotes', true));
                otherConcerns.add('next steps mention "' + sentence + '"');
                totalScore += points('Followup_Next_Steps_Points');
            } else {
                otherConcerns.add('a "Next Steps" note was left for future work');
            }
        }

        // --- Signal 9: Customer Correspondence Analysis ---
        // Sourced from Task(TaskSubtype='Email') Description text -- see class
        // header on ServicePriorityController for why ConversationEntry isn't
        // used. No structured Direction field exists here, so this checks the
        // most recent message content for status-inquiry language regardless
        // of who sent it, within the last 24h.
        if (correspondence != null && !correspondence.isEmpty()) {
            Integer recentMsgCount = 0;
            DateTime oneDayAgo = System.now().addHours(-24);
            for (Task t : correspondence) {
                if (t.CreatedDate >= oneDayAgo) {
                    recentMsgCount++;
                    String scanText = truncateForDisplay(t.Description, CORRESPONDENCE_SCAN_LENGTH);
                    if (String.isNotBlank(scanText)) {
                        String hit = firstMatch(scanText.toLowerCase(), keywords('StatusInquiry'));
                        if (hit != null) {
                            signalDetails.add(new ServicePriorityController.SignalDetail(
                                'Customer correspondence inquired about status: "' + hit + '" ('
                                    + recentMsgCount + ' recent message(s))',
                                'Customer Correspondence', 'correspondence', true));
                            totalScore += points('Status_Inquiry_Points');
                        }
                    }
                }
            }
        }

        // --- Prioritize ---
        if (totalScore >= points('Urgent_Threshold')) {
            result.priority = 'Urgent';
        } else if (totalScore >= points('High_Threshold')) {
            result.priority = 'High';
        } else if (totalScore >= points('Medium_Threshold')) {
            result.priority = 'Medium';
        } else {
            result.priority = 'Low';
        }

        // Multiple WOLIs (or multiple text fields) commonly trip the same
        // keyword check repeatedly, producing identical signal strings.
        // Scoring above still counts every hit (more real occurrences =
        // higher severity), but the displayed signal list/reason should
        // only show each distinct signal once.
        List<ServicePriorityController.SignalDetail> dedupedDetails = dedupeSignalDetails(signalDetails);
        List<String> dedupedSignals = new List<String>();
        for (ServicePriorityController.SignalDetail sd : dedupedDetails) {
            dedupedSignals.add(sd.text);
        }

        result.needsFollowUp = (totalScore >= points('NeedsFollowUp_Threshold'));
        result.signalCount = dedupedDetails.size();
        result.signals = dedupedSignals;
        result.signalDetails = dedupedDetails;
        result.reason = buildReason(result.priority, dedupedDetails);

        // Build a 1-2 sentence summary
        result.summary = buildSummary(sa, wo, wolis);

        // Completion assessment: did the tech appear to finish everything
        // that was originally requested? Heuristic only (see comment where
        // thisVisitConcerns/otherConcerns are declared) -- not a guarantee,
        // a prompt for the reader to check the Work Requested text against
        // the notes. Built as two separate sentences (this visit's own
        // findings vs. other findings on the Work Order) so a reader
        // looking at one specific appointment isn't told it's "possibly
        // incomplete" for reasons that actually belong to a different visit
        // or a WO-level field.
        List<String> dedupedThisVisit = dedupeStrings(thisVisitConcerns);
        List<String> dedupedOther = dedupeStrings(otherConcerns);

        if (dedupedThisVisit.isEmpty() && dedupedOther.isEmpty()) {
            result.completionStatus = 'Appears Complete';
            result.completionNote = 'No indicators of incomplete or pending work found in the technician\'s notes.';
        } else {
            result.completionStatus = 'Possibly Incomplete';
            List<String> noteParts = new List<String>();
            if (!dedupedThisVisit.isEmpty()) {
                noteParts.add('This visit: ' + String.join(dedupedThisVisit, '; ') + '.');
            }
            if (!dedupedOther.isEmpty()) {
                noteParts.add('Other findings on this Work Order: ' + String.join(dedupedOther, '; ') + '.');
            }
            result.completionNote = String.join(noteParts, ' ');
        }

        return result;
    }

    /**
     * De-dupes a list of strings while preserving first-seen order (same
     * reasoning as dedupeSignalDetails below, just for plain strings).
     */
    private static List<String> dedupeStrings(List<String> values) {
        List<String> deduped = new List<String>();
        Set<String> seen = new Set<String>();
        for (String v : values) {
            if (!seen.contains(v)) {
                seen.add(v);
                deduped.add(v);
            }
        }
        return deduped;
    }

    /**
     * Removes signals with exact-duplicate display text while preserving
     * first-seen order (Apex's Set<String> does not guarantee iteration
     * order, so this is done manually with a List + Set-based membership
     * check).
     */
    private static List<ServicePriorityController.SignalDetail> dedupeSignalDetails(
        List<ServicePriorityController.SignalDetail> details
    ) {
        List<ServicePriorityController.SignalDetail> deduped = new List<ServicePriorityController.SignalDetail>();
        Set<String> seen = new Set<String>();
        for (ServicePriorityController.SignalDetail sd : details) {
            if (!seen.contains(sd.text)) {
                seen.add(sd.text);
                deduped.add(sd);
            }
        }
        return deduped;
    }

    /**
     * Builds a human-readable reason string based on priority and signals.
     */
    /**
     * Builds the one-line reason shown as the badge on the main dashboard
     * card. Leads with THIS appointment's own findings only -- a WO can be
     * Urgent because of what happened on a DIFFERENT visit (or a WO-level
     * field like Callback), and the card shouldn't claim this specific
     * visit said something it didn't. When this visit itself has nothing
     * concerning but the overall priority is still elevated by other
     * findings on the Work Order, that's called out explicitly instead of
     * silently going quiet or (worse) listing findings from other visits as
     * if they were this one's.
     */
    private static String buildReason(String priority, List<ServicePriorityController.SignalDetail> dedupedDetails) {
        List<String> thisVisitTexts = new List<String>();
        Integer otherCount = 0;
        if (dedupedDetails != null) {
            for (ServicePriorityController.SignalDetail sd : dedupedDetails) {
                if (sd.isOtherVisit) {
                    otherCount++;
                } else {
                    thisVisitTexts.add(sd.text);
                }
            }
        }

        if (thisVisitTexts.isEmpty() && otherCount == 0) {
            return 'Routine appointment — no follow-up needed.';
        }

        String otherSuffix = otherCount > 0
            ? ' (+' + otherCount + ' other finding' + (otherCount == 1 ? '' : 's') + ' on this Work Order)'
            : '';

        // This visit itself has nothing concerning, but the overall
        // priority (driven by totalScore, which includes other-visit/WO-
        // level signals) may still be Urgent/High -- match the emoji and
        // urgency wording to that real priority instead of always showing
        // the calm "🟡 routine" phrasing, which previously made an Urgent
        // card read as if it were only Medium.
        if (thisVisitTexts.isEmpty()) {
            String otherFindingsPhrase = otherCount + ' other finding' + (otherCount == 1 ? '' : 's');
            if (priority == 'Urgent') {
                return '⚠️ This visit looks routine, but this Work Order requires immediate attention due to ' + otherFindingsPhrase + '.';
            } else if (priority == 'High') {
                return '🔶 This visit looks routine, but this Work Order needs prompt follow-up due to ' + otherFindingsPhrase + '.';
            } else if (priority == 'Medium') {
                return '🟡 This visit looks routine, but this Work Order should be reviewed due to ' + otherFindingsPhrase + '.';
            } else {
                return '🟢 This visit looks routine. ' + otherFindingsPhrase + ' noted elsewhere on this Work Order.';
            }
        }

        if (priority == 'Urgent') {
            return '⚠️ Requires immediate attention. ' + String.join(thisVisitTexts, '; ') + otherSuffix;
        } else if (priority == 'High') {
            return '🔶 Needs prompt follow-up. ' + String.join(thisVisitTexts, '; ') + otherSuffix;
        } else if (priority == 'Medium') {
            return '🟡 Should be reviewed. ' + String.join(thisVisitTexts, '; ') + otherSuffix;
        } else {
            return '🟢 Routine — minor items noted.' + otherSuffix;
        }
    }

    /**
     * Builds a concise 1-2 sentence summary from available text fields.
     *
     * Prioritizes THIS appointment's own attributed content first --
     * wolis here is already scoped by the caller to just the WOLI(s)
     * actually matched to this SA (see getFollowUpAnalysis' wolisBySA), so
     * using it before the WorkOrder-level rollups is what stops a
     * parts-pickup appointment from showing the exact same summary text as
     * the sibling appointment that did the real repair. Only falls back to
     * the whole-WorkOrder fields when this specific appointment has no
     * attributed WOLI content of its own.
     */
    private static String buildSummary(ServiceAppointment sa, WorkOrder wo, List<WorkOrderLineItem> wolis) {
        // Prefer the most recent WOLI actually attributed to THIS
        // appointment's own "Work Performed" write-up (real per-visit text).
        if (wolis != null && !wolis.isEmpty()) {
            String mostRecentWorkPerformed = null;
            for (WorkOrderLineItem woli : wolis) {
                if (String.isNotBlank(woli.Service_Notes__c)) {
                    mostRecentWorkPerformed = woli.Service_Notes__c;
                }
            }
            if (mostRecentWorkPerformed != null) {
                return truncateForDisplay(mostRecentWorkPerformed, 150);
            }
        }

        // Next: this appointment's own dispatch instruction (SA.Description
        // -- e.g. "Pick up PO 25989 at Grainger Maspeth"). Specific to this
        // visit even when no WOLI write-up was attributed to it, so it's
        // preferred over the generic whole-job rollups below.
        if (String.isNotBlank(sa?.Description)) {
            return truncateForDisplay(sa.Description, 150);
        }

        // Fallback: Executive Summary (WO-level -- it's AI-generated and
        // most structured, but covers the whole job, not just this visit)
        if (String.isNotBlank(wo?.Executive_Summary__c)) {
            return truncateForDisplay(wo.Executive_Summary__c, 150);
        }

        // Fallback: Next Steps
        if (String.isNotBlank(wo?.Next_Steps__c)) {
            return truncateForDisplay(wo.Next_Steps__c, 150);
        }

        // Fallback: Service Notes
        if (String.isNotBlank(wo?.Service_Notes__c)) {
            return truncateForDisplay(wo.Service_Notes__c, 150);
        }

        // Last resort: combine WOLI descriptions (the customer's original
        // request text, if nothing else is available)
        if (wolis != null && !wolis.isEmpty()) {
            List<String> descs = new List<String>();
            for (WorkOrderLineItem woli : wolis) {
                if (String.isNotBlank(woli.Description)) {
                    descs.add(woli.Description);
                }
            }
            if (!descs.isEmpty()) {
                return truncateForDisplay(String.join(descs, '; '), 150);
            }
        }

        // Nothing available
        return sa.Status == 'Completed'
            ? 'Appointment completed. No detailed notes available.'
            : 'Appointment status: ' + sa.Status + '. Review details for more information.';
    }

    /**
     * Truncates text to maxLength characters, appending '...' if cut off.
     * Shared by summary-building and correspondence display/scanning.
     */
    public static String truncateForDisplay(String text, Integer maxLength) {
        if (String.isBlank(text)) return text;
        if (text.length() <= maxLength) return text;
        return text.substring(0, Math.max(0, maxLength - 3)) + '...';
    }

    /**
     * Given the full text a keyword was matched in, returns the whole
     * sentence the keyword appears in (from the last sentence break before
     * it to the next one after), instead of just the bare matched word --
     * e.g. for a "Recommendation" hit on "recommend", this returns
     * "...I am going to recommend coming back on a cooler day...clean the
     * condenser...re-asses the pressures after cleaning." rather than just
     * showing the word "recommend" with no context. Falls back to the
     * keyword itself if a sentence boundary can't be found for some reason.
     */
    private static String extractSentenceContaining(String text, String keywordLower) {
        if (String.isBlank(text) || String.isBlank(keywordLower)) {
            return keywordLower;
        }
        String textLower = text.toLowerCase();
        Integer idx = textLower.indexOf(keywordLower);
        if (idx < 0) {
            return keywordLower;
        }

        Integer sentenceStart = 0;
        for (Integer i = idx; i > 0; i--) {
            String ch = text.substring(i - 1, i);
            if (ch == '.' || ch == ';' || ch == '\n') {
                sentenceStart = i;
                break;
            }
        }
        Integer sentenceEnd = text.length();
        for (Integer i = idx; i < text.length(); i++) {
            String ch = text.substring(i, i + 1);
            if (ch == '.' || ch == ';' || ch == '\n') {
                sentenceEnd = i + 1; // include the period itself
                break;
            }
        }

        String sentence = text.substring(sentenceStart, sentenceEnd).trim();
        return String.isNotBlank(sentence) ? truncateForDisplay(sentence, 180) : keywordLower;
    }

    /**
     * Best-effort inference of whether a legacy "Email to Salesforce" Task
     * represents an inbound (customer-initiated) or outbound (company-sent)
     * message. These Tasks store the raw email as plain text ("To: ...\nCC:
     * ...\nBody: ...") rather than structured fields, so there's no reliable
     * Direction value to read -- this checks whether the primary "To:"
     * recipient is an internal @mjiservices.com address (implying an external
     * party wrote in) versus external (implying the company wrote out).
     * Not exact -- a defensible default, not a guarantee.
     */
    public static String deriveDirection(String description) {
        if (String.isBlank(description)) return 'Unknown';
        Integer toIdx = description.indexOf('To:');
        if (toIdx < 0) return 'Unknown';
        Integer toLineEnd = description.indexOf('\n', toIdx);
        String toLine = toLineEnd > toIdx
            ? description.substring(toIdx, toLineEnd)
            : description.substring(toIdx, Math.min(description.length(), toIdx + 200));
        return toLine.containsIgnoreCase('@mjiservices.com') ? 'Inbound' : 'Outbound';
    }
}