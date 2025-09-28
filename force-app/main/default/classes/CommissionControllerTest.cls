/**
 * @description Test class for CommissionController
 * @author Salesforce Development Team
 * @date September 2025
 */
@isTest
private class CommissionControllerTest {
    
    /**
     * @description Test data setup
     */
    @TestSetup
    static void setupTestData() {
        // Create test account
        Account testAccount = new Account(
            Name = 'Test Account'
        );
        insert testAccount;
        
        // Create test users for team members
        List<User> testUsers = new List<User>();
        Profile standardProfile = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        
        User testUser1 = new User(
            FirstName = 'John',
            LastName = 'Smith',
            Email = 'john.smith@test.com',
            Username = 'john.smith@test.commissiontest.com',
            Alias = 'jsmith',
            TimeZoneSidKey = 'America/New_York',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            ProfileId = standardProfile.Id,
            Default_Commission_Rate__c = 5.0
        );
        testUsers.add(testUser1);
        
        User testUser2 = new User(
            FirstName = 'Sarah',
            LastName = 'Jones',
            Email = 'sarah.jones@test.com',
            Username = 'sarah.jones@test.commissiontest.com',
            Alias = 'sjones',
            TimeZoneSidKey = 'America/New_York',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            ProfileId = standardProfile.Id,
            Default_Commission_Rate__c = 3.0
        );
        testUsers.add(testUser2);
        
        insert testUsers;
        
        // Create test opportunity
        Opportunity testOpportunity = new Opportunity(
            Name = 'Test Opportunity',
            AccountId = testAccount.Id,
            StageName = 'Closed Won',
            CloseDate = Date.today(),
            Amount = 100000,
            Create_Renewal__c = 'No' // Fix validation rule
        );
        insert testOpportunity;
        
        // Create test products
        List<Product2> testProducts = new List<Product2>();
        
        Product2 product1 = new Product2(
            Name = 'Software License',
            IsActive = true,
            Commission_Eligible__c = true,
            Cost__c = 25000
        );
        testProducts.add(product1);
        
        Product2 product2 = new Product2(
            Name = 'Training Services',
            IsActive = true,
            Commission_Eligible__c = true,
            Cost__c = 5000
        );
        testProducts.add(product2);
        
        Product2 product3 = new Product2(
            Name = 'Non-Commission Product',
            IsActive = true,
            Commission_Eligible__c = false,
            Cost__c = 1000
        );
        testProducts.add(product3);
        
        insert testProducts;
        
        // Create pricebook entries
        Id standardPricebookId = Test.getStandardPricebookId();
        List<PricebookEntry> pricebookEntries = new List<PricebookEntry>();
        
        for (Product2 product : testProducts) {
            PricebookEntry entry = new PricebookEntry(
                Product2Id = product.Id,
                Pricebook2Id = standardPricebookId,
                UnitPrice = 1000,
                IsActive = true
            );
            pricebookEntries.add(entry);
        }
        insert pricebookEntries;
        
        // Create opportunity line items
        List<OpportunityLineItem> lineItems = new List<OpportunityLineItem>();
        
        OpportunityLineItem lineItem1 = new OpportunityLineItem(
            OpportunityId = testOpportunity.Id,
            PricebookEntryId = pricebookEntries[0].Id,
            Quantity = 1,
            UnitPrice = 50000,
            Cost__c = 25000,
            Commission_Eligible__c = true
        );
        lineItems.add(lineItem1);
        
        OpportunityLineItem lineItem2 = new OpportunityLineItem(
            OpportunityId = testOpportunity.Id,
            PricebookEntryId = pricebookEntries[1].Id,
            Quantity = 1,
            UnitPrice = 15000,
            Cost__c = 5000,
            Commission_Eligible__c = true
        );
        lineItems.add(lineItem2);
        
        OpportunityLineItem lineItem3 = new OpportunityLineItem(
            OpportunityId = testOpportunity.Id,
            PricebookEntryId = pricebookEntries[2].Id,
            Quantity = 1,
            UnitPrice = 5000,
            Cost__c = 1000,
            Commission_Eligible__c = false
        );
        lineItems.add(lineItem3);
        
        insert lineItems;
        
        // Create opportunity team members
        List<OpportunityTeamMember> teamMembers = new List<OpportunityTeamMember>();
        
        OpportunityTeamMember teamMember1 = new OpportunityTeamMember(
            OpportunityId = testOpportunity.Id,
            UserId = testUsers[0].Id,
            TeamMemberRole = 'Account Manager',
            Commission_Percentage__c = 0.06 // 6% as decimal for Percent field
        );
        teamMembers.add(teamMember1);
        
        OpportunityTeamMember teamMember2 = new OpportunityTeamMember(
            OpportunityId = testOpportunity.Id,
            UserId = testUsers[1].Id,
            TeamMemberRole = 'Sales Rep'
            // No commission percentage override - should use default
        );
        teamMembers.add(teamMember2);
        
        insert teamMembers;
    }
    
    /**
     * @description Test getOpportunityData method with valid opportunity
     */
    @isTest
    static void testGetOpportunityData_Success() {
        // Get test opportunity
        Opportunity testOpp = [SELECT Id FROM Opportunity LIMIT 1];
        
        Test.startTest();
        CommissionController.OpportunityData result = CommissionController.getOpportunityData(testOpp.Id);
        Test.stopTest();
        
        // Verify opportunity data (name might be auto-generated due to existing flows)
        System.assertNotEquals(null, result.opportunity);
        System.assert(result.opportunity.Name.contains('Test'));
        
        // Verify line items (should only include commission-eligible items with positive margin)
        System.assertEquals(2, result.lineItems.size());
        
        CommissionController.LineItemData lineItem1 = result.lineItems[0];
        System.assertEquals(true, lineItem1.commissionEligible);
        System.assert(lineItem1.lineMargin > 0);
        
        // Verify team members
        System.assertEquals(2, result.teamMembers.size());
        
        // Check that override rate is used for first team member (6% converted to display as 6.0)
        CommissionController.TeamMemberData teamMember1 = null;
        for (CommissionController.TeamMemberData tm : result.teamMembers) {
            if (tm.name.contains('John')) {
                teamMember1 = tm;
                break;
            }
        }
        System.assertNotEquals(null, teamMember1);
        System.assertEquals(6.0, teamMember1.defaultRate); // 0.06 * 100 = 6.0
        
        // Check that user default rate is used for second team member
        CommissionController.TeamMemberData teamMember2 = null;
        for (CommissionController.TeamMemberData tm : result.teamMembers) {
            if (tm.name.contains('Sarah')) {
                teamMember2 = tm;
                break;
            }
        }
        System.assertNotEquals(null, teamMember2);
        System.assertEquals(3.0, teamMember2.defaultRate); // User default rate
    }
    
    /**
     * @description Test getOpportunityData with invalid opportunity ID
     */
    @isTest
    static void testGetOpportunityData_InvalidId() {
        Test.startTest();
        try {
            CommissionController.getOpportunityData('001000000000000AAA'); // Valid format but non-existent ID
            System.assert(false, 'Expected exception was not thrown');
        } catch (Exception e) {
            // Any exception is acceptable - could be QueryException or AuraHandledException
            System.assertNotEquals(null, e.getMessage());
        }
        Test.stopTest();
    }
    
    /**
     * @description Test getExistingCommissions with no existing records
     */
    @isTest
    static void testGetExistingCommissions_NoRecords() {
        Opportunity testOpp = [SELECT Id FROM Opportunity LIMIT 1];
        
        Test.startTest();
        List<Commission__c> result = CommissionController.getExistingCommissions(testOpp.Id);
        Test.stopTest();
        
        System.assertEquals(0, result.size());
    }
    
    /**
     * @description Test getExistingCommissions with existing records
     */
    @isTest
    static void testGetExistingCommissions_WithRecords() {
        // Get test data
        Opportunity testOpp = [SELECT Id FROM Opportunity LIMIT 1];
        List<OpportunityLineItem> lineItems = [SELECT Id FROM OpportunityLineItem WHERE OpportunityId = :testOpp.Id LIMIT 1];
        List<User> testUsers = [SELECT Id FROM User WHERE FirstName IN ('John', 'Sarah')];
        
        // Create test commission
        Commission__c testCommission = new Commission__c(
            Opportunity__c = testOpp.Id,
            OpportunityLineItem__c = lineItems[0].Id,
            User__c = testUsers[0].Id,
            Commission_Percentage__c = 5.0,
            Status__c = 'Draft'
        );
        insert testCommission;
        
        Test.startTest();
        List<Commission__c> result = CommissionController.getExistingCommissions(testOpp.Id);
        Test.stopTest();
        
        System.assertEquals(1, result.size());
        System.assertEquals(testCommission.Id, result[0].Id);
    }
    
    /**
     * @description Test createUpdateCommissions with valid data
     */
    @isTest
    static void testCreateUpdateCommissions_Success() {
        // Get test data
        Opportunity testOpp = [SELECT Id FROM Opportunity LIMIT 1];
        List<OpportunityLineItem> lineItems = [SELECT Id FROM OpportunityLineItem WHERE OpportunityId = :testOpp.Id AND Commission_Eligible__c = true];
        List<User> testUsers = [SELECT Id FROM User WHERE FirstName IN ('John', 'Sarah')];
        
        // Create matrix data
        List<CommissionController.MatrixCellData> matrixData = new List<CommissionController.MatrixCellData>();
        
        CommissionController.MatrixCellData cell1 = new CommissionController.MatrixCellData();
        cell1.lineItemId = lineItems[0].Id;
        cell1.userId = testUsers[0].Id;
        cell1.selected = true;
        cell1.percentage = 5.0; // Will be converted to 0.05 in Apex
        cell1.amount = 2500.00;
        matrixData.add(cell1);
        
        CommissionController.MatrixCellData cell2 = new CommissionController.MatrixCellData();
        cell2.lineItemId = lineItems[1].Id;
        cell2.userId = testUsers[1].Id;
        cell2.selected = true;
        cell2.percentage = 3.0; // Will be converted to 0.03 in Apex
        cell2.amount = 300.00;
        matrixData.add(cell2);
        
        String matrixDataJson = JSON.serialize(matrixData);
        
        Test.startTest();
        CommissionController.CommissionResult result = CommissionController.createUpdateCommissions(testOpp.Id, matrixDataJson);
        Test.stopTest();
        
        // Verify results
        System.assertEquals(true, result.success);
        System.assertEquals(2, result.recordsCreated);
        System.assertEquals(0, result.recordsUpdated);
        
        // Verify commission records were created
        List<Commission__c> createdCommissions = [SELECT Id, Commission_Percentage__c FROM Commission__c WHERE Opportunity__c = :testOpp.Id];
        System.assertEquals(2, createdCommissions.size());
    }
    
    /**
     * @description Test createUpdateCommissions with no selections
     */
    @isTest
    static void testCreateUpdateCommissions_NoSelections() {
        Opportunity testOpp = [SELECT Id FROM Opportunity LIMIT 1];
        
        // Create matrix data with no selections
        List<CommissionController.MatrixCellData> matrixData = new List<CommissionController.MatrixCellData>();
        
        CommissionController.MatrixCellData cell1 = new CommissionController.MatrixCellData();
        cell1.selected = false; // Not selected
        cell1.percentage = 5.0;
        matrixData.add(cell1);
        
        String matrixDataJson = JSON.serialize(matrixData);
        
        Test.startTest();
        CommissionController.CommissionResult result = CommissionController.createUpdateCommissions(testOpp.Id, matrixDataJson);
        Test.stopTest();
        
        // Verify results
        System.assertEquals(false, result.success);
        System.assert(result.errorMessage.contains('Please select at least one commission'));
    }
    
    /**
     * @description Test createUpdateCommissions for updating existing records
     */
    @isTest
    static void testCreateUpdateCommissions_UpdateExisting() {
        // Get test data
        Opportunity testOpp = [SELECT Id FROM Opportunity LIMIT 1];
        List<OpportunityLineItem> lineItems = [SELECT Id FROM OpportunityLineItem WHERE OpportunityId = :testOpp.Id AND Commission_Eligible__c = true LIMIT 1];
        List<User> testUsers = [SELECT Id FROM User WHERE FirstName = 'John' LIMIT 1];
        
        // Create existing commission
        Commission__c existingCommission = new Commission__c(
            Opportunity__c = testOpp.Id,
            OpportunityLineItem__c = lineItems[0].Id,
            User__c = testUsers[0].Id,
            Commission_Percentage__c = 5.0,
            Status__c = 'Draft'
        );
        insert existingCommission;
        
        // Create matrix data to update the existing commission
        List<CommissionController.MatrixCellData> matrixData = new List<CommissionController.MatrixCellData>();
        
        CommissionController.MatrixCellData cell1 = new CommissionController.MatrixCellData();
        cell1.lineItemId = lineItems[0].Id;
        cell1.userId = testUsers[0].Id;
        cell1.selected = true;
        cell1.percentage = 7.0; // Updated percentage, will be converted to 0.07
        cell1.amount = 3500.00;
        cell1.existingCommissionId = existingCommission.Id;
        matrixData.add(cell1);
        
        String matrixDataJson = JSON.serialize(matrixData);
        
        Test.startTest();
        CommissionController.CommissionResult result = CommissionController.createUpdateCommissions(testOpp.Id, matrixDataJson);
        Test.stopTest();
        
        // Verify results
        System.assertEquals(true, result.success);
        System.assertEquals(0, result.recordsCreated);
        System.assertEquals(1, result.recordsUpdated);
        
        // Verify commission was updated (stored as decimal, so 7% = 0.07)
        Commission__c updatedCommission = [SELECT Commission_Percentage__c FROM Commission__c WHERE Id = :existingCommission.Id];
        System.assertEquals(0.07, updatedCommission.Commission_Percentage__c);
    }
    
    /**
     * @description Test deleteExistingCommissions with existing records
     */
    @isTest
    static void testDeleteExistingCommissions_WithRecords() {
        // Get test data
        Opportunity testOpp = [SELECT Id FROM Opportunity LIMIT 1];
        List<OpportunityLineItem> lineItems = [SELECT Id FROM OpportunityLineItem WHERE OpportunityId = :testOpp.Id LIMIT 1];
        List<User> testUsers = [SELECT Id FROM User WHERE FirstName = 'John' LIMIT 1];
        
        // Create test commissions
        List<Commission__c> testCommissions = new List<Commission__c>();
        for (Integer i = 0; i < 3; i++) {
            Commission__c commission = new Commission__c(
                Opportunity__c = testOpp.Id,
                OpportunityLineItem__c = lineItems[0].Id,
                User__c = testUsers[0].Id,
                Commission_Percentage__c = 5.0,
                Status__c = 'Draft'
            );
            testCommissions.add(commission);
        }
        insert testCommissions;
        
        Test.startTest();
        Integer deletedCount = CommissionController.deleteExistingCommissions(testOpp.Id);
        Test.stopTest();
        
        // Verify results
        System.assertEquals(3, deletedCount);
        
        // Verify records were deleted
        List<Commission__c> remainingCommissions = [SELECT Id FROM Commission__c WHERE Opportunity__c = :testOpp.Id];
        System.assertEquals(0, remainingCommissions.size());
    }
    
    /**
     * @description Test deleteExistingCommissions with no existing records
     */
    @isTest
    static void testDeleteExistingCommissions_NoRecords() {
        Opportunity testOpp = [SELECT Id FROM Opportunity LIMIT 1];
        
        Test.startTest();
        Integer deletedCount = CommissionController.deleteExistingCommissions(testOpp.Id);
        Test.stopTest();
        
        System.assertEquals(0, deletedCount);
    }
    
    /**
     * @description Test bulk operations to ensure governor limits are respected
     */
    @isTest
    static void testBulkOperations() {
        // Get test data
        Opportunity testOpp = [SELECT Id FROM Opportunity LIMIT 1];
        List<OpportunityLineItem> lineItems = [SELECT Id FROM OpportunityLineItem WHERE OpportunityId = :testOpp.Id AND Commission_Eligible__c = true];
        List<User> testUsers = [SELECT Id FROM User WHERE FirstName IN ('John', 'Sarah')];
        
        // Create large matrix data set
        List<CommissionController.MatrixCellData> matrixData = new List<CommissionController.MatrixCellData>();
        
        // Create multiple combinations to test bulk processing
        for (OpportunityLineItem lineItem : lineItems) {
            for (User testUser : testUsers) {
                CommissionController.MatrixCellData cell = new CommissionController.MatrixCellData();
                cell.lineItemId = lineItem.Id;
                cell.userId = testUser.Id;
                cell.selected = true;
                cell.percentage = 2.5; // Will be converted to 0.025
                cell.amount = 1000.00;
                matrixData.add(cell);
            }
        }
        
        String matrixDataJson = JSON.serialize(matrixData);
        
        Test.startTest();
        CommissionController.CommissionResult result = CommissionController.createUpdateCommissions(testOpp.Id, matrixDataJson);
        Test.stopTest();
        
        // Verify bulk creation succeeded
        System.assertEquals(true, result.success);
        System.assertEquals(4, result.recordsCreated); // 2 line items * 2 users
        
        // Verify all records were created
        List<Commission__c> createdCommissions = [SELECT Id FROM Commission__c WHERE Opportunity__c = :testOpp.Id];
        System.assertEquals(4, createdCommissions.size());
    }
}