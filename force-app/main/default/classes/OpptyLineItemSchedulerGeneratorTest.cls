@isTest
private class OpptyLineItemSchedulerGeneratorTest {
    
    @TestSetup
    static void setupTestData() {
        // Create test account
        Account testAccount = new Account(
            Name = 'Test Renewal Account',
            Type = 'Customer',
            Industry = 'Technology'
        );
        insert testAccount;
        
        // Create test products with revenue scheduling enabled
        List<Product2> products = new List<Product2>();
        products.add(new Product2(
            Name = 'Monthly Subscription',
            IsActive = true,
            ProductCode = 'MONTHLY-001',
            CanUseRevenueSchedule = true  // Enable revenue scheduling
        ));
        products.add(new Product2(
            Name = 'Quarterly Service',
            IsActive = true,
            ProductCode = 'QUARTERLY-001',
            CanUseRevenueSchedule = true  // Enable revenue scheduling
        ));
        products.add(new Product2(
            Name = 'One-Time Setup',
            IsActive = true,
            ProductCode = 'SETUP-001',
            CanUseRevenueSchedule = true  // Enable revenue scheduling
        ));
        insert products;
        
        // Get standard price book
        Id pricebookId = Test.getStandardPricebookId();
        
        // Create price book entries
        List<PricebookEntry> pbes = new List<PricebookEntry>();
        for (Product2 product : products) {
            pbes.add(new PricebookEntry(
                Pricebook2Id = pricebookId,
                Product2Id = product.Id,
                UnitPrice = 1200.00,
                IsActive = true
            ));
        }
        insert pbes;
    }
    
    @isTest
    static void testSuccessfulScheduleCreation() {
        // Get test data
        Account acc = [SELECT Id FROM Account WHERE Name = 'Test Renewal Account' LIMIT 1];
        List<Product2> products = [SELECT Id, ProductCode FROM Product2 WHERE ProductCode LIKE '%-001' ORDER BY ProductCode];
        Id pricebookId = Test.getStandardPricebookId();
        List<PricebookEntry> pbes = [SELECT Id, Product2Id, UnitPrice FROM PricebookEntry WHERE Product2Id IN :products];
        
        // Create original opportunity
        Date closeDate = Date.today();
        Date renewalDate = closeDate.addYears(1);
        
        Opportunity originalOpp = new Opportunity(
            Name = 'Original Opportunity',
            AccountId = acc.Id,
            StageName = 'Closed Won',
            CloseDate = closeDate,
            Pricebook2Id = pricebookId,
            Renewal_Date__c = renewalDate,
            Create_Renewal__c = 'Yes'
        );
        insert originalOpp;
        
        // Create opportunity line items with renewal status
        List<OpportunityLineItem> originalLineItems = new List<OpportunityLineItem>();
        for (PricebookEntry pbe : pbes) {
            OpportunityLineItem oli = new OpportunityLineItem(
                OpportunityId = originalOpp.Id,
                PricebookEntryId = pbe.Id,
                Quantity = 12,
                UnitPrice = pbe.UnitPrice
                // Don't set Include_in_Renewal__c on insert - will update after
            );
            originalLineItems.add(oli);
        }
        insert originalLineItems;
        
        // FIXED: Update line items with renewal status after insert
        for (PricebookEntry pbe : pbes) {
            Product2 prod = [SELECT ProductCode FROM Product2 WHERE Id = :pbe.Product2Id];
            String includeStatus = 'Yes';
            // Set one product to not renew
            if (prod.ProductCode == 'SETUP-001') {
                includeStatus = 'No';
            }
            
            // Find the corresponding line item and update it
            for (OpportunityLineItem oli : originalLineItems) {
                if (oli.PricebookEntryId == pbe.Id) {
                    oli.Include_in_Renewal__c = includeStatus;
                    break;
                }
            }
        }
        update originalLineItems;
        
        // Create schedules for original opportunity (monthly for first product, quarterly for second)
        List<OpportunityLineItemSchedule> originalSchedules = new List<OpportunityLineItemSchedule>();
        
        // Monthly schedules for first product (12 months)
        OpportunityLineItem monthlyItem = [SELECT Id FROM OpportunityLineItem 
                                          WHERE OpportunityId = :originalOpp.Id 
                                          AND Product2.ProductCode = 'MONTHLY-001' LIMIT 1];
        Date scheduleDate = closeDate.addMonths(1); // Start 1 month after close
        for (Integer i = 0; i < 12; i++) {
            originalSchedules.add(new OpportunityLineItemSchedule(
                OpportunityLineItemId = monthlyItem.Id,
                ScheduleDate = scheduleDate.addMonths(i),
                Revenue = 100.00,
                Type = 'Revenue'
            ));
        }
        
        // Quarterly schedules for second product (4 quarters)
        OpportunityLineItem quarterlyItem = [SELECT Id FROM OpportunityLineItem 
                                            WHERE OpportunityId = :originalOpp.Id 
                                            AND Product2.ProductCode = 'QUARTERLY-001' LIMIT 1];
        scheduleDate = closeDate.addMonths(3); // Start 3 months after close
        for (Integer i = 0; i < 4; i++) {
            originalSchedules.add(new OpportunityLineItemSchedule(
                OpportunityLineItemId = quarterlyItem.Id,
                ScheduleDate = scheduleDate.addMonths(i * 3),
                Revenue = 300.00,
                Type = 'Revenue'
            ));
        }
        
        insert originalSchedules;
        
        // Create renewal opportunity
        Opportunity renewalOpp = new Opportunity(
            Name = 'Renewal Opportunity',
            AccountId = acc.Id,
            StageName = 'Negotiation',
            CloseDate = renewalDate,
            Pricebook2Id = pricebookId
        );
        insert renewalOpp;
        
        // Create renewal opportunity line items for products that should renew
        List<OpportunityLineItem> renewalLineItems = new List<OpportunityLineItem>();
        for (PricebookEntry pbe : pbes) {
            Product2 prod = [SELECT ProductCode FROM Product2 WHERE Id = :pbe.Product2Id];
            // Only create line items for products that were marked for renewal
            if (prod.ProductCode != 'SETUP-001') {
                renewalLineItems.add(new OpportunityLineItem(
                    OpportunityId = renewalOpp.Id,
                    PricebookEntryId = pbe.Id,
                    Quantity = 12,
                    UnitPrice = pbe.UnitPrice
                ));
            }
        }
        insert renewalLineItems;
        
        // Prepare request
        OpptyLineItemSchedulerGenerator.ScheduleRequest request = new OpptyLineItemSchedulerGenerator.ScheduleRequest();
        request.oldOpportunityId = originalOpp.Id;
        request.opportunityId = renewalOpp.Id;
        
        Test.startTest();
        OpptyLineItemSchedulerGenerator.createSchedules(new List<OpptyLineItemSchedulerGenerator.ScheduleRequest>{request});
        Test.stopTest();
        
        // Verify schedules were created only for renewable products
        List<OpportunityLineItemSchedule> newSchedules = [
            SELECT Id, ScheduleDate, Revenue, Quantity, Type, 
                   OpportunityLineItem.Product2.ProductCode
            FROM OpportunityLineItemSchedule
            WHERE OpportunityLineItem.OpportunityId = :renewalOpp.Id
            ORDER BY OpportunityLineItem.Product2.ProductCode, ScheduleDate
        ];
        
        // Should have 16 schedules total (12 monthly + 4 quarterly, setup product excluded)
        System.assertEquals(16, newSchedules.size(), 'Should create 16 schedule records (setup product excluded)');
        
        // Verify monthly schedules
        List<OpportunityLineItemSchedule> monthlySchedules = new List<OpportunityLineItemSchedule>();
        for (OpportunityLineItemSchedule s : newSchedules) {
            if (s.OpportunityLineItem.Product2.ProductCode == 'MONTHLY-001') {
                monthlySchedules.add(s);
            }
        }
        System.assertEquals(12, monthlySchedules.size(), 'Should have 12 monthly schedules');
        
        // Verify first monthly schedule starts 1 month after renewal date
        System.assertEquals(renewalDate.addMonths(1), monthlySchedules[0].ScheduleDate, 
                          'First monthly schedule should start 1 month after renewal date');
        
        // Verify quarterly schedules
        List<OpportunityLineItemSchedule> quarterlySchedules = new List<OpportunityLineItemSchedule>();
        for (OpportunityLineItemSchedule s : newSchedules) {
            if (s.OpportunityLineItem.Product2.ProductCode == 'QUARTERLY-001') {
                quarterlySchedules.add(s);
            }
        }
        System.assertEquals(4, quarterlySchedules.size(), 'Should have 4 quarterly schedules');
        
        // Verify first quarterly schedule starts 3 months after renewal date
        System.assertEquals(renewalDate.addMonths(3), quarterlySchedules[0].ScheduleDate, 
                          'First quarterly schedule should start 3 months after renewal date');
        
        // Verify renewal date was updated on new opportunity
        Opportunity updatedRenewalOpp = [SELECT Renewal_Date__c FROM Opportunity WHERE Id = :renewalOpp.Id];
        System.assertEquals(renewalDate.addYears(1), updatedRenewalOpp.Renewal_Date__c, 
                          'Renewal opportunity should have next renewal date set');
    }
    
    @isTest
    static void testNoRenewableProducts() {
        // Get test data
        Account acc = [SELECT Id FROM Account WHERE Name = 'Test Renewal Account' LIMIT 1];
        Id pricebookId = Test.getStandardPricebookId();
        List<PricebookEntry> pbes = [SELECT Id, Product2Id, UnitPrice FROM PricebookEntry];
        
        // Create original opportunity
        Opportunity originalOpp = new Opportunity(
            Name = 'Original Opportunity',
            AccountId = acc.Id,
            StageName = 'Closed Won',
            CloseDate = Date.today(),
            Pricebook2Id = pricebookId,
            Renewal_Date__c = Date.today().addYears(1),
            Create_Renewal__c = 'No'
        );
        insert originalOpp;
        
        // Create line items with 'No' renewal status
        List<OpportunityLineItem> originalLineItems = new List<OpportunityLineItem>();
        for (PricebookEntry pbe : pbes) {
            originalLineItems.add(new OpportunityLineItem(
                OpportunityId = originalOpp.Id,
                PricebookEntryId = pbe.Id,
                Quantity = 1,
                UnitPrice = pbe.UnitPrice,
                Include_in_Renewal__c = 'No'
            ));
        }
        insert originalLineItems;
        
        // Create renewal opportunity
        Opportunity renewalOpp = new Opportunity(
            Name = 'Renewal Opportunity',
            AccountId = acc.Id,
            StageName = 'Negotiation',
            CloseDate = originalOpp.Renewal_Date__c,
            Pricebook2Id = pricebookId
        );
        insert renewalOpp;
        
        // Prepare request
        OpptyLineItemSchedulerGenerator.ScheduleRequest request = new OpptyLineItemSchedulerGenerator.ScheduleRequest();
        request.oldOpportunityId = originalOpp.Id;
        request.opportunityId = renewalOpp.Id;
        
        Test.startTest();
        OpptyLineItemSchedulerGenerator.createSchedules(new List<OpptyLineItemSchedulerGenerator.ScheduleRequest>{request});
        Test.stopTest();
        
        // Verify no schedules were created
        List<OpportunityLineItemSchedule> newSchedules = [
            SELECT Id FROM OpportunityLineItemSchedule
            WHERE OpportunityLineItem.OpportunityId = :renewalOpp.Id
        ];
        
        System.assertEquals(0, newSchedules.size(), 'Should not create schedules for non-renewing products');
    }
    
    @isTest
    static void testMissingRenewalDate() {
        // Get test data
        Account acc = [SELECT Id FROM Account WHERE Name = 'Test Renewal Account' LIMIT 1];
        Id pricebookId = Test.getStandardPricebookId();
        
        // Create original opportunity without renewal date
        Opportunity originalOpp = new Opportunity(
            Name = 'Original Opportunity',
            AccountId = acc.Id,
            StageName = 'Closed Won',
            CloseDate = Date.today(),
            Pricebook2Id = pricebookId,
            Renewal_Date__c = null,
            Create_Renewal__c = 'No'
        );
        insert originalOpp;
        
        // Create renewal opportunity
        Opportunity renewalOpp = new Opportunity(
            Name = 'Renewal Opportunity',
            AccountId = acc.Id,
            StageName = 'Negotiation',
            CloseDate = Date.today().addYears(1),
            Pricebook2Id = pricebookId
        );
        insert renewalOpp;
        
        // Prepare request
        OpptyLineItemSchedulerGenerator.ScheduleRequest request = new OpptyLineItemSchedulerGenerator.ScheduleRequest();
        request.oldOpportunityId = originalOpp.Id;
        request.opportunityId = renewalOpp.Id;
        
        Test.startTest();
        OpptyLineItemSchedulerGenerator.createSchedules(new List<OpptyLineItemSchedulerGenerator.ScheduleRequest>{request});
        Test.stopTest();
        
        // Verify no schedules were created and no exception was thrown
        List<OpportunityLineItemSchedule> newSchedules = [
            SELECT Id FROM OpportunityLineItemSchedule
            WHERE OpportunityLineItem.OpportunityId = :renewalOpp.Id
        ];
        
        System.assertEquals(0, newSchedules.size(), 'Should not create schedules without renewal date');
    }
    
    @isTest
    static void testBulkOperation() {
        // Get test data
        Account acc = [SELECT Id FROM Account WHERE Name = 'Test Renewal Account' LIMIT 1];
        Id pricebookId = Test.getStandardPricebookId();
        
        // Use a product with scheduling enabled
        Product2 schedulableProduct = new Product2(
            Name = 'Bulk Test Product',
            IsActive = true,
            ProductCode = 'BULK-001',
            CanUseRevenueSchedule = true  // Enable revenue scheduling
        );
        insert schedulableProduct;
        
        PricebookEntry pbe = new PricebookEntry(
            Pricebook2Id = pricebookId,
            Product2Id = schedulableProduct.Id,
            UnitPrice = 100.00,
            IsActive = true
        );
        insert pbe;
        
        // Create multiple opportunities with renewal dates
        List<Opportunity> originalOpps = new List<Opportunity>();
        List<Opportunity> renewalOpps = new List<Opportunity>();
        
        for (Integer i = 0; i < 5; i++) {
            originalOpps.add(new Opportunity(
                Name = 'Original Opportunity ' + i,
                AccountId = acc.Id,
                StageName = 'Closed Won',
                CloseDate = Date.today(),
                Pricebook2Id = pricebookId,
                Renewal_Date__c = Date.today().addYears(1),
                Create_Renewal__c = 'Yes'  // FIXED: Set renewal flag
            ));
            
            renewalOpps.add(new Opportunity(
                Name = 'Renewal Opportunity ' + i,
                AccountId = acc.Id,
                StageName = 'Negotiation',
                CloseDate = Date.today().addYears(1),
                Pricebook2Id = pricebookId
            ));
        }
        
        insert originalOpps;
        insert renewalOpps;
        
        // Add line items to original opportunities
        List<OpportunityLineItem> allLineItems = new List<OpportunityLineItem>();
        for (Opportunity opp : originalOpps) {
            allLineItems.add(new OpportunityLineItem(
                OpportunityId = opp.Id,
                PricebookEntryId = pbe.Id,
                Quantity = 1,
                UnitPrice = 100
                // Don't set Include_in_Renewal__c on insert - will update after
            ));
        }
        insert allLineItems;
        
        // FIXED: Update line items with renewal flag after insert
        for (OpportunityLineItem oli : allLineItems) {
            oli.Include_in_Renewal__c = 'Yes';
        }
        update allLineItems;
        
        // Add schedules - Only set Revenue for Revenue type
        List<OpportunityLineItemSchedule> allSchedules = new List<OpportunityLineItemSchedule>();
        for (OpportunityLineItem oli : allLineItems) {
            allSchedules.add(new OpportunityLineItemSchedule(
                OpportunityLineItemId = oli.Id,
                ScheduleDate = Date.today().addMonths(1),
                Revenue = 100,
                Type = 'Revenue'
            ));
        }
        insert allSchedules;
        
        // Add line items to renewal opportunities - REQUIRED for the APEX class to work
        List<OpportunityLineItem> renewalLineItems = new List<OpportunityLineItem>();
        for (Opportunity opp : renewalOpps) {
            renewalLineItems.add(new OpportunityLineItem(
                OpportunityId = opp.Id,
                PricebookEntryId = pbe.Id,
                Quantity = 1,
                UnitPrice = 100
            ));
        }
        insert renewalLineItems;
        
        // DEBUG: Verify test data setup
        System.debug('=== TEST DATA VERIFICATION ===');
        List<Opportunity> verifyOpps = [SELECT Id, Name, Create_Renewal__c, Renewal_Date__c 
                                       FROM Opportunity WHERE Id IN :originalOpps];
        for (Opportunity opp : verifyOpps) {
            System.debug('Opp: ' + opp.Name + ' - Create_Renewal__c: ' + opp.Create_Renewal__c);
        }
        
        List<OpportunityLineItem> verifyOLIs = [SELECT Id, Include_in_Renewal__c, Product2.Name 
                                               FROM OpportunityLineItem WHERE Id IN :allLineItems];
        for (OpportunityLineItem oli : verifyOLIs) {
            System.debug('OLI: ' + oli.Product2.Name + ' - Include_in_Renewal__c: ' + oli.Include_in_Renewal__c);
        }
        
        // DEBUG: Verify test data setup before calling APEX
        System.debug('=== TEST DEBUG VERIFICATION ===');
        List<OpportunityLineItem> debugOLIs = [SELECT Id, Include_in_Renewal__c, Product2.Name, OpportunityId 
                                               FROM OpportunityLineItem 
                                               WHERE OpportunityId IN :originalOpps];
        System.debug('Line items in database: ' + debugOLIs.size());
        for (OpportunityLineItem oli : debugOLIs) {
            System.debug('DB Line Item: ' + oli.Product2.Name + ' - Include_in_Renewal__c: ' + oli.Include_in_Renewal__c + ' - OpptyId: ' + oli.OpportunityId);
        }
        
        // Prepare bulk requests
        List<OpptyLineItemSchedulerGenerator.ScheduleRequest> requests = new List<OpptyLineItemSchedulerGenerator.ScheduleRequest>();
        for (Integer i = 0; i < originalOpps.size(); i++) {
            OpptyLineItemSchedulerGenerator.ScheduleRequest request = new OpptyLineItemSchedulerGenerator.ScheduleRequest();
            request.oldOpportunityId = originalOpps[i].Id;
            request.opportunityId = renewalOpps[i].Id;
            requests.add(request);
        }
        
        Test.startTest();
        OpptyLineItemSchedulerGenerator.createSchedules(requests);
        Test.stopTest();
        
        // Verify schedules were created for all
        Integer scheduleCount = [
            SELECT COUNT() FROM OpportunityLineItemSchedule
            WHERE OpportunityLineItem.OpportunityId IN :renewalOpps
        ];
        
        System.debug('=== RESULTS ===');
        System.debug('Expected schedules: 5, Actual schedules: ' + scheduleCount);
        
        System.assertEquals(5, scheduleCount, 'Should handle bulk operations: Expected: 5, Actual: ' + scheduleCount);
    }
    
    @isTest
    static void testEmptyRequest() {
        Test.startTest();
        // Test with null
        OpptyLineItemSchedulerGenerator.createSchedules(null);
        
        // Test with empty list
        OpptyLineItemSchedulerGenerator.createSchedules(new List<OpptyLineItemSchedulerGenerator.ScheduleRequest>());
        Test.stopTest();
        
        // Should not throw exception
        System.assert(true, 'Should handle null and empty requests gracefully');
    }
    
    @isTest
    static void testProportionalRevenueSplit() {
        // Get test data
        Account acc = [SELECT Id FROM Account WHERE Name = 'Test Renewal Account' LIMIT 1];
        Id pricebookId = Test.getStandardPricebookId();
        
        // Create a product with scheduling enabled
        Product2 schedulableProduct = new Product2(
            Name = 'Proportional Test Product',
            IsActive = true,
            ProductCode = 'PROP-001',
            CanUseRevenueSchedule = true  // Enable revenue scheduling
        );
        insert schedulableProduct;
        
        PricebookEntry pbe = new PricebookEntry(
            Pricebook2Id = pricebookId,
            Product2Id = schedulableProduct.Id,
            UnitPrice = 1000.00,
            IsActive = true
        );
        insert pbe;
        
        // Create original opportunity
        Opportunity originalOpp = new Opportunity(
            Name = 'Original Opportunity',
            AccountId = acc.Id,
            StageName = 'Closed Won',
            CloseDate = Date.today(),
            Pricebook2Id = pricebookId,
            Renewal_Date__c = Date.today().addYears(1),
            Create_Renewal__c = 'Yes'
        );
        insert originalOpp;
        
        // Create line item
        OpportunityLineItem originalLineItem = new OpportunityLineItem(
            OpportunityId = originalOpp.Id,
            PricebookEntryId = pbe.Id,
            Quantity = 10,
            UnitPrice = 1000
            // Don't set Include_in_Renewal__c on insert - will update after
        );
        insert originalLineItem;
        
        // FIXED: Update line item with renewal flag after insert
        originalLineItem.Include_in_Renewal__c = 'Yes';
        update originalLineItem;
        
        // Create uneven revenue split (40% upfront, 60% on delivery)
        // Only set Revenue for Revenue type schedules
        List<OpportunityLineItemSchedule> originalSchedules = new List<OpportunityLineItemSchedule>{
            new OpportunityLineItemSchedule(
                OpportunityLineItemId = originalLineItem.Id,
                ScheduleDate = Date.today().addMonths(1),
                Revenue = 4000,  // 40%
                Type = 'Revenue'
            ),
            new OpportunityLineItemSchedule(
                OpportunityLineItemId = originalLineItem.Id,
                ScheduleDate = Date.today().addMonths(6),
                Revenue = 6000,  // 60%
                Type = 'Revenue'
            )
        };
        insert originalSchedules;
        
        // Create renewal opportunity
        Opportunity renewalOpp = new Opportunity(
            Name = 'Renewal Opportunity',
            AccountId = acc.Id,
            StageName = 'Negotiation',
            CloseDate = originalOpp.Renewal_Date__c,
            Pricebook2Id = pricebookId
        );
        insert renewalOpp;
        
        // Create renewal line item with different quantity
        OpportunityLineItem renewalLineItem = new OpportunityLineItem(
            OpportunityId = renewalOpp.Id,
            PricebookEntryId = pbe.Id,
            Quantity = 20,  // Double the quantity
            UnitPrice = 1000
        );
        insert renewalLineItem;
        
        // Prepare request
        OpptyLineItemSchedulerGenerator.ScheduleRequest request = new OpptyLineItemSchedulerGenerator.ScheduleRequest();
        request.oldOpportunityId = originalOpp.Id;
        request.opportunityId = renewalOpp.Id;
        
        Test.startTest();
        OpptyLineItemSchedulerGenerator.createSchedules(new List<OpptyLineItemSchedulerGenerator.ScheduleRequest>{request});
        Test.stopTest();
        
        // Verify proportions are maintained
        List<OpportunityLineItemSchedule> newSchedules = [
            SELECT Revenue, Quantity FROM OpportunityLineItemSchedule
            WHERE OpportunityLineItem.OpportunityId = :renewalOpp.Id
            ORDER BY ScheduleDate
        ];
        
        System.assertEquals(2, newSchedules.size(), 'Should create 2 schedules');
        System.assertEquals(8000, newSchedules[0].Revenue, 'First schedule should be 40% of 20000');
        System.assertEquals(12000, newSchedules[1].Revenue, 'Second schedule should be 60% of 20000');
        // Note: We're not setting or checking Quantity for Revenue type schedules
    }
}