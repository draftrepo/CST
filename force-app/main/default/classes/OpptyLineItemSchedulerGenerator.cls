public class OpptyLineItemSchedulerGenerator {
    
    @InvocableMethod(label='Create OpportunityLineItemSchedule' description='Creates OpportunityLineItemSchedule records')
    public static void createSchedules(List<ScheduleRequest> requests) {
        List<OpportunityLineItemSchedule> schedulesList = new List<OpportunityLineItemSchedule>();
        Set<Id> opptyIds = new Set<Id>();
        Set<Id> oldOpptyIds = new Set<Id>();
        Set<Id> opptyLineItemIds = new Set<Id>();
        Set<Id> oldOpptyLineItemIds = new Set<Id>();        
        Map<Id,OpportunityLineItemSchedule> opptyLineItemSchedMap = new Map<Id,OpportunityLineItemSchedule>();
        
        for (ScheduleRequest req : requests) {
            oldOpptyIds.add(req.oldOpportunityId);
        }
        
        Opportunity oldOppty = [Select Id,Renewal_Date__c FROM Opportunity WHERE Id =: oldOpptyIds LIMIT 1];
        List<OpportunityLineItem> oldOpportunityLineItemList = [Select Id,Product2Id FROM OpportunityLineItem where OpportunityId =: oldOpptyIds AND
                                                                                                     Renewal_Status__c = 'Yes'];
        
        for (OpportunityLineItem oli : oldOpportunityLineItemList) {
            oldOpptyLineItemIds.add(oli.Id);
        }
        
        List<OpportunityLineItemSchedule> oldOpportunityLineItemScheduleList = [SELECT Id,Quantity,Revenue,ScheduleDate,
                                                                                Type,OpportunityLineItemId,OpportunityLineItem.Product2Id FROM 
                                                                                OpportunityLineItemSchedule where 
                                                                                OpportunityLineItemId =: oldOpptyLineItemIds];
        
        for(OpportunityLineItemSchedule ops: oldOpportunityLineItemScheduleList){
            opptyLineItemSchedMap.put(ops.OpportunityLineItem.Product2Id,ops);
        }
        
        
        for (ScheduleRequest req : requests) {
            opptyIds.add(req.opportunityId);
        }
        List<OpportunityLineItem> newOpportunityLineItemList = [Select Id,Product2Id FROM OpportunityLineItem where OpportunityId =: opptyIds];
        
        Date startDate = oldOppty.Renewal_Date__c;
        Date recurringDate = startDate;
        for(OpportunityLineItem otps : newOpportunityLineItemList){
            for(OpportunityLineItemSchedule opSched : oldOpportunityLineItemScheduleList){
                if(otps.Product2Id == opSched.OpportunityLineItem.Product2Id){
                    OpportunityLineItemSchedule os = new OpportunityLineItemSchedule();
                    os.OpportunityLineItemId = otps.Id;
                    //os.ScheduleDate = opSched.ScheduleDate.AddMonths(12);
                    os.ScheduleDate = recurringDate;
                    os.Revenue = opSched.Revenue;
                    os.Quantity = opSched.Quantity;
                    os.Type = opSched.Type;
                    schedulesList.add(os);
                    recurringDate = recurringDate.AddMonths(1);
                } 
            }

        }
        
        if (!schedulesList.isEmpty()) {
            insert schedulesList;
        }
    }
    
    public class ScheduleRequest {
        @InvocableVariable(label='New Opportunity ID' required=true)
        public Id opportunityId;
        
        @InvocableVariable(label='Triggering Opportunity ID' required=true)
        public Id oldOpportunityId;
        

    }
}