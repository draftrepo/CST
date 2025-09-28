import { LightningElement, api, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { CloseActionScreenEvent } from 'lightning/actions';
import { NavigationMixin } from 'lightning/navigation';
import getOpportunityData from '@salesforce/apex/CommissionController.getOpportunityData';
import getExistingCommissions from '@salesforce/apex/CommissionController.getExistingCommissions';
import createUpdateCommissions from '@salesforce/apex/CommissionController.createUpdateCommissions';
import deleteExistingCommissions from '@salesforce/apex/CommissionController.deleteExistingCommissions';

export default class CommissionCreator extends NavigationMixin(LightningElement) {
    // Flow properties
    @api opportunityId;
    @api commissionsCreated = '0';
    
    // Component state
    @track opportunityData = {};
    @track matrixData = [];
    @track existingCommissions = [];
    @track totalCommissions = 0;
    @track totalAmount = 0;
    @track isLoading = true;
    @track hasExistingCommissions = false;
    @track showDuplicateOptions = false;
    @track error = null;

    // UI state - track this to force re-renders
    @track refreshKey = 0;
    @track isProcessing = false;

    connectedCallback() {
        this.loadData();
    }

    async loadData() {
        try {
            this.isLoading = true;
            this.error = null;

            // Load opportunity data and existing commissions in parallel
            const [oppData, existingComm] = await Promise.all([
                getOpportunityData({ opportunityId: this.opportunityId }),
                getExistingCommissions({ opportunityId: this.opportunityId })
            ]);

            console.log('Raw opportunity data from Apex:', oppData);
            console.log('Line items:', oppData.lineItems);
            console.log('Team members:', oppData.teamMembers);

            this.opportunityData = oppData;
            this.existingCommissions = existingComm;
            this.hasExistingCommissions = existingComm.length > 0;

            // Always initialize matrix, but show duplicate options if needed
            this.initializeMatrix();
            
            if (this.hasExistingCommissions) {
                this.showDuplicateOptions = true;
            }

        } catch (error) {
            console.error('Error in loadData:', error);
            this.error = 'Error loading data: ' + error.body?.message || error.message;
            this.showErrorToast(this.error);
        } finally {
            this.isLoading = false;
        }
    }

    initializeMatrix() {
        const matrix = [];
        
        // Create matrix cells for each line item × team member combination
        this.opportunityData.lineItems?.forEach(lineItem => {
            this.opportunityData.teamMembers?.forEach(teamMember => {
                const existingCommission = this.findExistingCommission(lineItem.Id, teamMember.userId);
                
                // Handle percentage conversion properly
                let percentageValue = teamMember.defaultRate || 0;
                if (existingCommission && existingCommission.Commission_Percentage__c !== undefined) {
                    let commissionPercentage = existingCommission.Commission_Percentage__c;
                    console.log(`Raw commission percentage from Apex: ${commissionPercentage}`);
                    
                    // If the value is already in percentage format (like 10 for 10%), use as-is
                    // If it's in decimal format (like 0.10 for 10%), convert to percentage
                    if (commissionPercentage <= 1) {
                        percentageValue = commissionPercentage * 100;
                    } else {
                        percentageValue = commissionPercentage;
                    }
                    
                    console.log(`Converted to display percentage: ${percentageValue}%`);
                }
                
                // Access the correct property names from Apex response
                const cell = {
                    id: `${lineItem.Id}-${teamMember.userId}`,
                    lineItemId: lineItem.Id,
                    userId: teamMember.userId,
                    lineItemName: lineItem.Product2?.Name || lineItem.Name,
                    teamMemberName: teamMember.name,
                    teamMemberRole: teamMember.role,
                    lineMargin: lineItem.Line_Margin__c || 0,
                    selected: existingCommission ? true : false,
                    percentage: percentageValue,
                    defaultPercentage: teamMember.defaultRate || 0,
                    amount: 0,
                    existingCommissionId: existingCommission?.Id || null
                };
                
                console.log(`Initialized cell ${cell.id}: percentage=${cell.percentage}%, margin=${cell.lineMargin}, amount will be calculated as ${cell.lineMargin} × ${cell.percentage}% = ${cell.lineMargin * cell.percentage / 100}`);
                matrix.push(cell);
            });
        });

        this.matrixData = matrix;
        this.calculateTotals();
        this.showDuplicateOptions = false;
    }

    findExistingCommission(lineItemId, userId) {
        return this.existingCommissions.find(comm => 
            comm.OpportunityLineItem__c === lineItemId && comm.User__c === userId
        );
    }

    // Handle duplicate commission options
    handleEditExisting() {
        this.initializeMatrix();
    }

    handleCancel() {
        this.showDuplicateOptions = false;
        this.closeFlowAndRefresh();
    }

    async handleDeleteAndRecreate() {
        try {
            this.isProcessing = true;
            await deleteExistingCommissions({ opportunityId: this.opportunityId });
            this.existingCommissions = [];
            this.hasExistingCommissions = false;
            this.initializeMatrix();
            this.showSuccessToast('Existing commissions deleted. You can now create new ones.');
        } catch (error) {
            this.showErrorToast('Error deleting existing commissions: ' + error.body?.message);
        } finally {
            this.isProcessing = false;
        }
    }

    // Force UI refresh
    forceRefresh() {
        this.refreshKey += 1;
    }

    // Matrix interaction handlers
    handleCheckboxChange(event) {
        const lineItemId = event.target.dataset.lineItemId || event.target.getAttribute('data-line-item-id');
        const userId = event.target.dataset.userId || event.target.getAttribute('data-user-id');
        const isChecked = event.target.checked;
        const cellId = `${lineItemId}-${userId}`;
        
        console.log(`Individual cell selection: lineItem=${lineItemId}, user=${userId}, checked=${isChecked}`);
        console.log('Full dataset:', JSON.stringify(event.target.dataset));
        
        if (!lineItemId || !userId) {
            console.error('Missing data attributes in handleCheckboxChange');
            console.error('lineItemId:', lineItemId, 'userId:', userId);
            return;
        }
        
        // Update the matrix data
        const newMatrix = this.matrixData.map(cell => {
            if (cell.id === cellId) {
                console.log(`Updating cell ${cellId} selected=${isChecked}`);
                return { ...cell, selected: isChecked };
            }
            return cell;
        });
        
        this.matrixData = newMatrix;
        this.calculateTotals();
        this.forceRefresh();
    }

    // Alias for HTML template compatibility
    handleCellSelection(event) {
        this.handleCheckboxChange(event);
    }

    handlePercentageChange(event) {
        const lineItemId = event.target.dataset.lineItemId || event.target.getAttribute('data-line-item-id');
        const userId = event.target.dataset.userId || event.target.getAttribute('data-user-id');
        const percentageInput = parseFloat(event.target.value) || 0;
        const cellId = `${lineItemId}-${userId}`;
        
        console.log(`Percentage change: lineItem=${lineItemId}, user=${userId}, percentage=${percentageInput}`);
        
        if (!lineItemId || !userId) {
            console.error('Missing data attributes in handlePercentageChange');
            return;
        }
        
        // Update the matrix data
        const newMatrix = this.matrixData.map(cell => {
            if (cell.id === cellId) {
                console.log(`Updating cell ${cellId} percentage=${percentageInput}`);
                return { ...cell, percentage: percentageInput };
            }
            return cell;
        });
        
        this.matrixData = newMatrix;
        this.calculateTotals();
        this.forceRefresh();
    }

    // Select all handlers - FIXED to properly update percentage and checkboxes
    handleSelectAllForLineItem(event) {
        const lineItemId = event.target.dataset.lineItemId || event.target.getAttribute('data-line-item-id');
        const isChecked = event.target.checked;
        
        console.log(`Select All Team Members: lineItem=${lineItemId}, checked=${isChecked}`);
        console.log('Full dataset:', JSON.stringify(event.target.dataset));
        
        if (!lineItemId) {
            console.error('Missing lineItemId in handleSelectAllForLineItem');
            return;
        }
        
        // Update the matrix data - when selecting all team members for a line item
        const newMatrix = this.matrixData.map(cell => {
            if (cell.lineItemId === lineItemId) {
                console.log(`Updating cell ${cell.id} selected=${isChecked}`);
                // If selecting and cell doesn't have a percentage, apply the default
                if (isChecked && cell.percentage === 0) {
                    return { ...cell, selected: isChecked, percentage: cell.defaultPercentage };
                }
                return { ...cell, selected: isChecked };
            }
            return cell;
        });
        
        this.matrixData = newMatrix;
        this.calculateTotals();
        this.forceRefresh();
    }

    handleSelectAllForTeamMember(event) {
        const userId = event.target.dataset.userId;
        const isChecked = event.target.checked;
        
        console.log(`Select All Products: user=${userId}, checked=${isChecked}`);
        
        if (!userId) {
            console.error('Missing userId in handleSelectAllForTeamMember');
            return;
        }
        
        // Update the matrix data - when selecting all products for a team member
        const newMatrix = this.matrixData.map(cell => {
            if (cell.userId === userId) {
                console.log(`Updating cell ${cell.id} selected=${isChecked}, applying default percentage=${cell.defaultPercentage}`);
                // When selecting, always apply the user's default percentage
                if (isChecked) {
                    return { ...cell, selected: isChecked, percentage: cell.defaultPercentage };
                }
                return { ...cell, selected: isChecked };
            }
            return cell;
        });
        
        this.matrixData = newMatrix;
        this.calculateTotals();
        this.forceRefresh();
    }

    calculateTotals() {
        let totalComm = 0;
        let totalAmt = 0;
        
        console.log('Calculating totals for matrix data:', this.matrixData);
        
        // Update amounts in the matrix data
        const newMatrix = this.matrixData.map(cell => {
            const decimalPercentage = cell.percentage / 100;
            const amount = cell.selected ? (cell.lineMargin * decimalPercentage) : 0;
            
            console.log(`Calculating for ${cell.id}: selected=${cell.selected}, ${cell.lineMargin} × ${cell.percentage}% = ${amount}`);
            
            if (cell.selected) {
                totalComm++;
                totalAmt += amount;
            }
            
            return { ...cell, amount: amount };
        });
        
        this.matrixData = newMatrix;
        this.totalCommissions = totalComm;
        this.totalAmount = totalAmt;
        
        console.log(`Final totals: ${totalComm} commissions, ${this.formatCurrency(totalAmt)}`);
    }

    // Generate commissions
    async handleGenerateCommissions() {
        try {
            this.isProcessing = true;
            
            const selectedCells = this.matrixData.filter(cell => cell.selected);
            
            if (selectedCells.length === 0) {
                this.showErrorToast('Please select at least one commission to create.');
                return;
            }

            // Send the data with proper percentage format
            const cellsForApex = selectedCells.map(cell => ({
                lineItemId: cell.lineItemId,
                userId: cell.userId,
                selected: cell.selected,
                percentage: cell.percentage, // Send as 10 for 10%, Apex will convert to 0.10
                amount: cell.amount
            }));

            console.log('Sending to Apex:', cellsForApex);

            const result = await createUpdateCommissions({
                opportunityId: this.opportunityId,
                matrixDataJson: JSON.stringify(cellsForApex)
            });

            if (result.success) {
                const totalCreated = result.recordsCreated + result.recordsUpdated;
                this.commissionsCreated = totalCreated.toString();
                
                this.showSuccessToast(
                    `Successfully processed ${totalCreated} commission records ` +
                    `(${result.recordsCreated} created, ${result.recordsUpdated} updated)`
                );
                
                // Close the flow and refresh the opportunity page
                setTimeout(() => {
                    this.closeFlowAndRefresh();
                }, 1500);
                
            } else {
                let errorMsg = result.errorMessage || 'Unknown error occurred';
                if (result.partialErrors && result.partialErrors.length > 0) {
                    errorMsg += '\n\nDetails:\n' + result.partialErrors.join('\n');
                }
                this.showErrorToast(errorMsg);
            }

        } catch (error) {
            this.showErrorToast('Error creating commissions: ' + error.body?.message);
        } finally {
            this.isProcessing = false;
        }
    }

    // Close flow and refresh page
    closeFlowAndRefresh() {
        // Close the flow
        const closeEvent = new CloseActionScreenEvent();
        this.dispatchEvent(closeEvent);
        
        // Navigate to refresh the opportunity page
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: this.opportunityId,
                actionName: 'view'
            }
        });
    }

    // Utility methods
    showSuccessToast(message) {
        this.dispatchEvent(new ShowToastEvent({
            title: 'Success',
            message: message,
            variant: 'success'
        }));
    }

    showErrorToast(message) {
        this.dispatchEvent(new ShowToastEvent({
            title: 'Error',
            message: message,
            variant: 'error'
        }));
    }

    // Getters for template
    get hasData() {
        return this.opportunityData.lineItems?.length > 0 && this.opportunityData.teamMembers?.length > 0;
    }

    get formattedTotalAmount() {
        return this.formatCurrency(this.totalAmount);
    }

    get buttonDisabled() {
        return !this.hasData || this.isProcessing || this.totalCommissions === 0;
    }

    get opportunityName() {
        return this.opportunityData.opportunity?.Name || 'Loading...';
    }

    // FIXED: Added getters for badge labels
    get productCountLabel() {
        const count = this.lineItems.length;
        return `${count} Product${count !== 1 ? 's' : ''}`;
    }

    get teamMemberCountLabel() {
        const count = this.teamMembers.length;
        return `${count} Team Member${count !== 1 ? 's' : ''}`;
    }

    // FIXED: Added getter for formatted opportunity amount
    get formattedOpportunityAmount() {
        return this.opportunityData?.opportunity?.Amount 
            ? this.formatCurrency(this.opportunityData.opportunity.Amount)
            : '';
    }

    // FIXED: Added getter for opportunity currency - CHANGED USD TO GBP
    get opportunityCurrency() {
        return this.opportunityData.opportunity?.CurrencyIsoCode || 'GBP';
    }

    get lineItems() {
        console.log('Getting lineItems:', this.opportunityData.lineItems);
        // Add formatted margin to each line item
        return (this.opportunityData.lineItems || []).map(item => ({
            ...item,
            formattedMargin: this.formatCurrency(item.Line_Margin__c || 0)
        }));
    }

    get teamMembers() {
        console.log('Getting teamMembers:', this.opportunityData.teamMembers);
        return this.opportunityData.teamMembers || [];
    }

    // Helper method to get matrix cell by line item and team member
    // This method is called from the template and needs to return current data
    getMatrixCell(lineItemId, userId) {
        // Add refreshKey dependency to force re-evaluation
        const refreshCheck = this.refreshKey;
        
        const cell = this.matrixData.find(cell => 
            cell.lineItemId === lineItemId && cell.userId === userId
        );
        
        if (cell) {
            return {
                selected: cell.selected,
                percentage: cell.percentage,
                amount: cell.amount,
                formattedAmount: this.formatCurrency(cell.amount),
                match: true,
                key: cell.id
            };
        }
        return { 
            selected: false, 
            percentage: 0, 
            amount: 0, 
            formattedAmount: this.formatCurrency(0),
            match: false,
            key: `${lineItemId}_${userId}`
        };
    }

    // NEW: Helper method to get cell ID for template
    getCellId(lineItemId, userId) {
        return `cell_${lineItemId}_${userId}`;
    }
    
    // Create a computed property for the matrix display
    get matrixDisplay() {
        // Force refresh dependency
        const refreshCheck = this.refreshKey;
        
        const display = [];
        
        (this.opportunityData.lineItems || []).forEach(lineItem => {
            const row = {
                lineItem: {
                    ...lineItem,
                    formattedMargin: this.formatCurrency(lineItem.Line_Margin__c || 0)
                },
                cells: []
            };
            
            (this.opportunityData.teamMembers || []).forEach(teamMember => {
                const cellData = this.getMatrixCell(lineItem.Id, teamMember.userId);
                row.cells.push({
                    lineItemId: lineItem.Id,
                    userId: teamMember.userId,
                    teamMemberName: teamMember.name,
                    ...cellData
                });
            });
            
            display.push(row);
        });
        
        return display;
    }

    // Format currency for display - FIXED to use proper currency symbol and respect opportunity currency
    formatCurrency(amount) {
        const currencyCode = this.opportunityData.opportunity?.CurrencyIsoCode || 'GBP';
        
        // Map currency codes to their locale formats
        const currencyLocaleMap = {
            'GBP': 'en-GB',
            'EUR': 'de-DE',
            'USD': 'en-US',
            'CAD': 'en-CA',
            'AUD': 'en-AU',
            'JPY': 'ja-JP',
            'CNY': 'zh-CN',
            'INR': 'en-IN'
        };
        
        const locale = currencyLocaleMap[currencyCode] || 'en-US';
        
        return new Intl.NumberFormat(locale, {
            style: 'currency',
            currency: currencyCode,
            minimumFractionDigits: 2,
            maximumFractionDigits: 2
        }).format(amount || 0);
    }
}