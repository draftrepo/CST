/**
 * @description Controller class for Commission Management Lightning Web Component
 * @author Salesforce Development Team
 * @date September 2025
 */
public with sharing class CommissionController {
    
    /**
     * @description Inner class for opportunity data
     */
    public class OpportunityData {
        @AuraEnabled public Opportunity opportunity { get; set; }
        @AuraEnabled public List<OpportunityLineItem> lineItems { get; set; }
        @AuraEnabled public List<TeamMemberData> teamMembers { get; set; }
        @AuraEnabled public Decimal totalCommissionableAmount { get; set; }
    }
    
    /**
     * @description Inner class for team member data
     */
    public class TeamMemberData {
        @AuraEnabled public String userId { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String role { get; set; }
        @AuraEnabled public Decimal defaultRate { get; set; }
    }
    
    /**
     * @description Inner class for commission result
     */
    public class CommissionResult {
        @AuraEnabled public Boolean success { get; set; }
        @AuraEnabled public String errorMessage { get; set; }
        @AuraEnabled public Integer recordsCreated { get; set; }
        @AuraEnabled public Integer recordsUpdated { get; set; }
        @AuraEnabled public List<String> partialErrors { get; set; }
        
        public CommissionResult() {
            this.success = true;
            this.recordsCreated = 0;
            this.recordsUpdated = 0;
            this.partialErrors = new List<String>();
        }
    }
    
    /**
     * @description Inner class for matrix cell data
     */
    public class MatrixCellData {
        @AuraEnabled public String lineItemId { get; set; }
        @AuraEnabled public String userId { get; set; }
        @AuraEnabled public Boolean selected { get; set; }
        @AuraEnabled public Decimal percentage { get; set; }
        @AuraEnabled public Decimal amount { get; set; }
    }
    
    /**
     * @description Gets opportunity data including line items and team members
     * @param opportunityId The ID of the opportunity
     * @return OpportunityData wrapper with all necessary data
     */
    @AuraEnabled(cacheable=true)
    public static OpportunityData getOpportunityData(String opportunityId) {
        try {
            OpportunityData result = new OpportunityData();
            
            // Get opportunity
            result.opportunity = [
                SELECT Id, Name, Amount, AccountId, Account.Name, StageName, CloseDate
                FROM Opportunity 
                WHERE Id = :opportunityId
            ];
            
            // Get commission-eligible line items with positive margins
            // First, get all line items to debug
            List<OpportunityLineItem> allLineItems = [
                SELECT Id, Name, Product2Id, Product2.Name, UnitPrice, Quantity, 
                       TotalPrice, Line_Margin__c, Commission_Eligible__c
                FROM OpportunityLineItem 
                WHERE OpportunityId = :opportunityId
                ORDER BY Product2.Name
            ];
            
            System.debug('Total line items found: ' + allLineItems.size());
            
            // Filter for commission-eligible items
            result.lineItems = new List<OpportunityLineItem>();
            for (OpportunityLineItem item : allLineItems) {
                System.debug('Line Item: ' + item.Name + 
                           ', Commission_Eligible__c: ' + item.Commission_Eligible__c + 
                           ', Line_Margin__c: ' + item.Line_Margin__c);
                
                // More lenient criteria - just need commission eligible OR positive margin
                if (item.Commission_Eligible__c == true || 
                    (item.Line_Margin__c != null && item.Line_Margin__c > 0)) {
                    result.lineItems.add(item);
                }
            }
            
            System.debug('Filtered line items: ' + result.lineItems.size());
            
            // Get opportunity team members
            List<OpportunityTeamMember> teamMemberRecords = [
                SELECT Id, UserId, User.Name, User.Default_Commission_Rate__c, TeamMemberRole
                FROM OpportunityTeamMember 
                WHERE OpportunityId = :opportunityId
                AND User.IsActive = true
                ORDER BY User.Name
            ];
            
            // Convert to TeamMemberData list for the component
            result.teamMembers = new List<TeamMemberData>();
            for (OpportunityTeamMember member : teamMemberRecords) {
                TeamMemberData teamData = new TeamMemberData();
                teamData.userId = member.UserId;
                teamData.name = member.User.Name;
                teamData.role = member.TeamMemberRole;
                teamData.defaultRate = member.User.Default_Commission_Rate__c != null ?
                    member.User.Default_Commission_Rate__c : 0;
                result.teamMembers.add(teamData);
            }
            
            // Calculate total commissionable amount
            result.totalCommissionableAmount = 0;
            for (OpportunityLineItem line : result.lineItems) {
                if (line.Line_Margin__c != null) {
                    result.totalCommissionableAmount += line.Line_Margin__c;
                }
            }
            
            return result;
            
        } catch (Exception e) {
            throw new AuraHandledException('Error retrieving opportunity data: ' + e.getMessage());
        }
    }
    
    /**
     * @description Gets existing commission records for an opportunity
     * @param opportunityId The ID of the opportunity
     * @return List of existing commission records
     */
    @AuraEnabled
    public static List<Commission__c> getExistingCommissions(String opportunityId) {
        try {
            return [
                SELECT Id, OpportunityLineItem__c, User__c, Commission_Percentage__c, 
                       Commission_Amount__c, Status__c, Comments__c
                FROM Commission__c 
                WHERE Opportunity__c = :opportunityId
            ];
            
        } catch (Exception e) {
            throw new AuraHandledException('Error retrieving existing commissions: ' + e.getMessage());
        }
    }
    
    /**
     * @description Creates or updates commission records based on matrix selections
     * @param opportunityId The ID of the opportunity
     * @param matrixDataJson JSON string of MatrixCellData list
     * @return CommissionResult with success status and details
     */
    @AuraEnabled
    public static CommissionResult createUpdateCommissions(String opportunityId, String matrixDataJson) {
        CommissionResult result = new CommissionResult();
        
        try {
            // Parse the matrix data
            List<MatrixCellData> matrixData = (List<MatrixCellData>) JSON.deserialize(matrixDataJson, List<MatrixCellData>.class);
            
            // Filter selected cells
            List<MatrixCellData> selectedCells = new List<MatrixCellData>();
            for (MatrixCellData cell : matrixData) {
                if (cell.selected == true) {
                    selectedCells.add(cell);
                }
            }
            
            if (selectedCells.isEmpty()) {
                result.success = false;
                result.errorMessage = 'Please select at least one commission to create.';
                return result;
            }
            
            // Get OpportunityLineItems to access margin data for Gross_Margin__c field
            Map<Id, OpportunityLineItem> lineItemMap = new Map<Id, OpportunityLineItem>([
                SELECT Id, Line_Margin__c
                FROM OpportunityLineItem 
                WHERE OpportunityId = :opportunityId
            ]);
            
            // Get existing commissions for this opportunity
            Map<String, Commission__c> existingCommissionMap = new Map<String, Commission__c>();
            List<Commission__c> existingCommissions = [
                SELECT Id, OpportunityLineItem__c, User__c, Commission_Percentage__c, 
                       Commission_Amount__c, Gross_Margin__c
                FROM Commission__c 
                WHERE Opportunity__c = :opportunityId
            ];
            
            for (Commission__c comm : existingCommissions) {
                String key = comm.OpportunityLineItem__c + '_' + comm.User__c;
                existingCommissionMap.put(key, comm);
            }
            
            // Prepare commission records for upsert
            List<Commission__c> commissionsToUpsert = new List<Commission__c>();
            
            for (MatrixCellData cell : selectedCells) {
                String key = cell.lineItemId + '_' + cell.userId;
                Commission__c commission;
                
                // Get the line item for margin data
                OpportunityLineItem lineItem = lineItemMap.get(cell.lineItemId);
                
                if (existingCommissionMap.containsKey(key)) {
                    // Update existing commission
                    commission = existingCommissionMap.get(key);
                    result.recordsUpdated++;
                } else {
                    // Create new commission
                    commission = new Commission__c();
                    commission.Opportunity__c = opportunityId;
                    commission.OpportunityLineItem__c = cell.lineItemId;
                    commission.User__c = cell.userId;
                    commission.Status__c = 'Draft';
                    result.recordsCreated++;
                }
                
                // Set commission percentage - NO DIVISION for Percent field type!
                // Percent field expects the display value (10 for 10%), not decimal (0.10)
                if (cell.percentage != null) {
                    commission.Commission_Percentage__c = cell.percentage;
                }
                
                // Set the gross margin from the line item
                commission.Gross_Margin__c = lineItem != null && lineItem.Line_Margin__c != null ? 
                    lineItem.Line_Margin__c : 0;
                
                commissionsToUpsert.add(commission);
            }
            
            // Upsert commission records
            if (!commissionsToUpsert.isEmpty()) {
                Database.UpsertResult[] upsertResults = Database.upsert(commissionsToUpsert, false);
                
                // Check for partial failures
                for (Integer i = 0; i < upsertResults.size(); i++) {
                    if (!upsertResults[i].isSuccess()) {
                        String errorMsg = 'Record ' + (i+1) + ': ';
                        for (Database.Error error : upsertResults[i].getErrors()) {
                            errorMsg += error.getMessage() + '; ';
                        }
                        result.partialErrors.add(errorMsg);
                    }
                }
                
                // If there were any errors, mark as partial success
                if (!result.partialErrors.isEmpty()) {
                    result.errorMessage = 'Some records failed to save. See partial errors for details.';
                }
            }
            
        } catch (Exception e) {
            result.success = false;
            result.errorMessage = 'Error creating commissions: ' + e.getMessage();
        }
        
        return result;
    }
    
    /**
     * @description Deletes all existing commission records for an opportunity
     * @param opportunityId The ID of the opportunity
     * @return Number of records deleted
     */
    @AuraEnabled
    public static Integer deleteExistingCommissions(String opportunityId) {
        try {
            List<Commission__c> existingCommissions = [
                SELECT Id FROM Commission__c WHERE Opportunity__c = :opportunityId
            ];
            
            if (!existingCommissions.isEmpty()) {
                delete existingCommissions;
            }
            
            return existingCommissions.size();
            
        } catch (Exception e) {
            throw new AuraHandledException('Error deleting existing commissions: ' + e.getMessage());
        }
    }
}