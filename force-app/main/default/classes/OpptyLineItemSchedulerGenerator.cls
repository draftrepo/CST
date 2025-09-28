public class OpptyLineItemSchedulerGenerator {
    
    @InvocableMethod(label='Create OpportunityLineItemSchedule' description='Creates OpportunityLineItemSchedule records for renewal opportunities')
    public static void createSchedules(List<ScheduleRequest> requests) {
        if (requests == null || requests.isEmpty()) {
            return;
        }
        
        try {
            // Collect all IDs for bulk processing
            Map<Id, Id> oldToNewOpptyMap = new Map<Id, Id>();
            for (ScheduleRequest req : requests) {
                oldToNewOpptyMap.put(req.oldOpportunityId, req.opportunityId);
            }
            
            // Query all old opportunities with renewal dates
            Map<Id, Opportunity> oldOpptyMap = new Map<Id, Opportunity>(
                [SELECT Id, Renewal_Date__c, CloseDate 
                 FROM Opportunity 
                 WHERE Id IN :oldToNewOpptyMap.keySet()]
            );
            
            // Query all line items that should be renewed (using new field name)
            List<OpportunityLineItem> oldLineItems = [
                SELECT Id, Product2Id, OpportunityId, UnitPrice, TotalPrice, Quantity
                FROM OpportunityLineItem 
                WHERE OpportunityId IN :oldToNewOpptyMap.keySet() 
                AND Include_in_Renewal__c = 'Yes'  // Fixed field name
            ];
            
            // DEBUG: Add detailed logging
            System.debug('=== APEX CLASS DEBUG ===');
            System.debug('Querying line items for opportunities: ' + oldToNewOpptyMap.keySet());
            System.debug('Found ' + oldLineItems.size() + ' renewable line items');
            for (OpportunityLineItem oli : oldLineItems) {
                System.debug('Line Item: Product2Id=' + oli.Product2Id + ', OpptyId=' + oli.OpportunityId + ', Include_in_Renewal__c=Yes (hardcoded in query)');
            }
            
            if (oldLineItems.isEmpty()) {
                System.debug('No renewable line items found');
                return;
            }
            
            // Build map of old line item IDs and organize by opportunity
            Set<Id> oldLineItemIds = new Set<Id>();
            Map<Id, List<OpportunityLineItem>> oldLineItemsByOppty = new Map<Id, List<OpportunityLineItem>>();
            
            for (OpportunityLineItem oli : oldLineItems) {
                oldLineItemIds.add(oli.Id);
                
                if (!oldLineItemsByOppty.containsKey(oli.OpportunityId)) {
                    oldLineItemsByOppty.put(oli.OpportunityId, new List<OpportunityLineItem>());
                }
                oldLineItemsByOppty.get(oli.OpportunityId).add(oli);
            }
            
            // Query all old schedules, ordered for pattern analysis
            List<OpportunityLineItemSchedule> oldSchedules = [
                SELECT Id, Quantity, Revenue, ScheduleDate, Type, 
                       OpportunityLineItemId, OpportunityLineItem.Product2Id,
                       OpportunityLineItem.OpportunityId
                FROM OpportunityLineItemSchedule 
                WHERE OpportunityLineItemId IN :oldLineItemIds
                ORDER BY OpportunityLineItemId, ScheduleDate
            ];
            
            System.debug('Found ' + oldSchedules.size() + ' old schedules for processing');
            
            // Organize schedules by line item for easier processing
            Map<Id, List<OpportunityLineItemSchedule>> schedulesByLineItem = new Map<Id, List<OpportunityLineItemSchedule>>();
            for (OpportunityLineItemSchedule schedule : oldSchedules) {
                if (!schedulesByLineItem.containsKey(schedule.OpportunityLineItemId)) {
                    schedulesByLineItem.put(schedule.OpportunityLineItemId, new List<OpportunityLineItemSchedule>());
                }
                schedulesByLineItem.get(schedule.OpportunityLineItemId).add(schedule);
            }
            
            // Query all new line items - FIXED: Added Product2Id to SELECT clause
            List<OpportunityLineItem> newLineItems = [
                SELECT Id, Product2Id, OpportunityId, UnitPrice, TotalPrice, Quantity
                FROM OpportunityLineItem 
                WHERE OpportunityId IN :oldToNewOpptyMap.values()
            ];
            
            System.debug('Found ' + newLineItems.size() + ' new line items to match against');
            
            // Create lookup map for new line items (key: OpptyId_ProductId)
            Map<String, OpportunityLineItem> newLineItemMap = new Map<String, OpportunityLineItem>();
            Set<Id> newLineItemIds = new Set<Id>();
            for (OpportunityLineItem oli : newLineItems) {
                String key = oli.OpportunityId + '_' + oli.Product2Id;
                newLineItemMap.put(key, oli);
                newLineItemIds.add(oli.Id);
                System.debug('Added new line item to map: key=' + key + ', Product2Id=' + oli.Product2Id);
            }
            
            // DELETE ANY AUTO-CREATED SCHEDULES ON THE NEW LINE ITEMS
            // This is critical - removes schedules that were auto-created from product defaults
            List<OpportunityLineItemSchedule> schedulesToDelete = [
                SELECT Id 
                FROM OpportunityLineItemSchedule 
                WHERE OpportunityLineItemId IN :newLineItemIds
            ];
            
            if (!schedulesToDelete.isEmpty()) {
                System.debug('Deleting ' + schedulesToDelete.size() + ' auto-created schedules from renewal line items');
                delete schedulesToDelete;
            }
            
            // Process each renewal request
            List<OpportunityLineItemSchedule> newSchedules = new List<OpportunityLineItemSchedule>();
            List<Opportunity> opptysToUpdate = new List<Opportunity>();
            
            for (Id oldOpptyId : oldToNewOpptyMap.keySet()) {
                Id newOpptyId = oldToNewOpptyMap.get(oldOpptyId);
                Opportunity oldOppty = oldOpptyMap.get(oldOpptyId);
                
                System.debug('Processing opportunity: oldId=' + oldOpptyId + ', newId=' + newOpptyId);
                
                // Skip if no renewal date
                if (oldOppty == null || oldOppty.Renewal_Date__c == null) {
                    System.debug('Skipping opportunity ' + oldOpptyId + ' - no renewal date');
                    continue;
                }
                
                // Set the next renewal date on the new opportunity
                opptysToUpdate.add(new Opportunity(
                    Id = newOpptyId,
                    Renewal_Date__c = oldOppty.Renewal_Date__c.addYears(1)
                ));
                
                // Process each old line item for this opportunity
                List<OpportunityLineItem> lineItemsToProcess = oldLineItemsByOppty.get(oldOpptyId);
                if (lineItemsToProcess == null) {
                    System.debug('No line items to process for opportunity ' + oldOpptyId);
                    continue;
                }
                
                System.debug('Processing ' + lineItemsToProcess.size() + ' line items for opportunity ' + oldOpptyId);
                
                for (OpportunityLineItem oldLineItem : lineItemsToProcess) {
                    // Find corresponding new line item
                    String lookupKey = newOpptyId + '_' + oldLineItem.Product2Id;
                    OpportunityLineItem newLineItem = newLineItemMap.get(lookupKey);
                    
                    System.debug('Looking for new line item with key: ' + lookupKey);
                    
                    if (newLineItem == null) {
                        System.debug('No matching new line item for product ' + oldLineItem.Product2Id);
                        System.debug('Available keys in map: ' + newLineItemMap.keySet());
                        continue;
                    }
                    
                    System.debug('Found matching new line item: ' + newLineItem.Id);
                    
                    // Get schedules for this line item
                    List<OpportunityLineItemSchedule> lineItemSchedules = schedulesByLineItem.get(oldLineItem.Id);
                    if (lineItemSchedules == null || lineItemSchedules.isEmpty()) {
                        System.debug('No schedules found for line item ' + oldLineItem.Id);
                        continue;
                    }
                    
                    System.debug('Found ' + lineItemSchedules.size() + ' schedules for line item ' + oldLineItem.Id);
                    
                    // Create new schedules maintaining the pattern
                    List<OpportunityLineItemSchedule> productSchedules = createSchedulesForProduct(
                        newLineItem,
                        lineItemSchedules,
                        oldOppty.CloseDate,
                        oldOppty.Renewal_Date__c
                    );
                    
                    System.debug('Created ' + productSchedules.size() + ' new schedules for product');
                    newSchedules.addAll(productSchedules);
                }
            }
            
            // Insert all new schedules
            if (!newSchedules.isEmpty()) {
                insert newSchedules;
                System.debug('Created ' + newSchedules.size() + ' schedule records');
            } else {
                System.debug('No schedules to insert');
            }
            
            // Update renewal dates on new opportunities
            if (!opptysToUpdate.isEmpty()) {
                update opptysToUpdate;
                System.debug('Updated renewal dates for ' + opptysToUpdate.size() + ' opportunities');
            }
            
        } catch (Exception e) {
            System.debug('Error in schedule generation: ' + e.getMessage() + '\n' + e.getStackTraceString());
            throw new ScheduleGenerationException('Failed to create renewal schedules: ' + e.getMessage(), e);
        }
    }
    
    /**
     * Creates schedules for a single product, preserving the original pattern
     */
    private static List<OpportunityLineItemSchedule> createSchedulesForProduct(
        OpportunityLineItem newLineItem,
        List<OpportunityLineItemSchedule> originalSchedules,
        Date originalCloseDate,
        Date renewalStartDate
    ) {
        List<OpportunityLineItemSchedule> newSchedules = new List<OpportunityLineItemSchedule>();
        
        // Calculate the gap from close to first schedule in original
        Integer initialGapDays = 0;
        if (originalCloseDate != null && !originalSchedules.isEmpty()) {
            initialGapDays = originalCloseDate.daysBetween(originalSchedules[0].ScheduleDate);
        }
        
        // Start date for new schedules (renewal date plus original gap)
        Date currentDate = renewalStartDate.addDays(initialGapDays);
        
        // Calculate total amounts from original schedules
        Decimal totalOriginalRevenue = 0;
        Decimal totalOriginalQuantity = 0;
        for (OpportunityLineItemSchedule s : originalSchedules) {
            if (s.Revenue != null) totalOriginalRevenue += s.Revenue;
            if (s.Quantity != null) totalOriginalQuantity += s.Quantity;
        }
        
        // Create new schedules preserving proportions and intervals
        for (Integer i = 0; i < originalSchedules.size(); i++) {
            OpportunityLineItemSchedule original = originalSchedules[i];
            OpportunityLineItemSchedule newSchedule = new OpportunityLineItemSchedule();
            
            newSchedule.OpportunityLineItemId = newLineItem.Id;
            newSchedule.ScheduleDate = currentDate;
            newSchedule.Type = original.Type;
            
            // FIXED: Only set Revenue for Revenue type, only set Quantity for Quantity type
            if (original.Type == 'Revenue') {
                // For Revenue type, only set Revenue
                if (totalOriginalRevenue > 0 && original.Revenue != null) {
                    Decimal proportion = original.Revenue / totalOriginalRevenue;
                    newSchedule.Revenue = newLineItem.TotalPrice * proportion;
                } else {
                    // Equal distribution if no revenue data
                    newSchedule.Revenue = newLineItem.TotalPrice / originalSchedules.size();
                }
                // Do NOT set Quantity for Revenue type
                
            } else if (original.Type == 'Quantity') {
                // For Quantity type, only set Quantity
                if (totalOriginalQuantity > 0 && original.Quantity != null) {
                    Decimal proportion = original.Quantity / totalOriginalQuantity;
                    newSchedule.Quantity = newLineItem.Quantity * proportion;
                } else {
                    // Equal distribution if no quantity data
                    newSchedule.Quantity = newLineItem.Quantity / originalSchedules.size();
                }
                // Do NOT set Revenue for Quantity type
                
            } else {
                // For Both type or any other type, set both
                if (totalOriginalRevenue > 0 && original.Revenue != null) {
                    Decimal proportion = original.Revenue / totalOriginalRevenue;
                    newSchedule.Revenue = newLineItem.TotalPrice * proportion;
                } else {
                    newSchedule.Revenue = newLineItem.TotalPrice / originalSchedules.size();
                }
                
                if (totalOriginalQuantity > 0 && original.Quantity != null) {
                    Decimal proportion = original.Quantity / totalOriginalQuantity;
                    newSchedule.Quantity = newLineItem.Quantity * proportion;
                } else {
                    newSchedule.Quantity = newLineItem.Quantity / originalSchedules.size();
                }
            }
            
            newSchedules.add(newSchedule);
            
            // Calculate next date based on interval to next schedule
            if (i < originalSchedules.size() - 1) {
                Integer daysBetween = originalSchedules[i].ScheduleDate.daysBetween(
                    originalSchedules[i + 1].ScheduleDate
                );
                currentDate = currentDate.addDays(daysBetween);
            }
        }
        
        return newSchedules;
    }
    
    /**
     * Custom exception for better error handling
     */
    public class ScheduleGenerationException extends Exception {}
    
    /**
     * Request wrapper for invocable method
     */
    public class ScheduleRequest {
        @InvocableVariable(label='New Opportunity ID' required=true)
        public Id opportunityId;
        
        @InvocableVariable(label='Triggering Opportunity ID' required=true)
        public Id oldOpportunityId;
    }
}