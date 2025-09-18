import { LightningElement, api, track } from 'lwc';
import fetchPage from '@salesforce/apex/GenericKeysetBrowserController.fetchPage';

export default class GenericPaginator extends LightningElement {
    // ===== API =====
    @api title = 'Lista';
    @api objectApiName;           // 'Order' | 'Pedido__c'
    @api fieldSetApiName;         // ex.: 'Lista'
    @api extraSelect = [];        // ex.: ['Account.Name']
    @api pageSize = 25;
    @api sortBy = 'CreatedDate';
    @api sortDirection = 'DESC';  // 'ASC'|'DESC'
    @api filters = {};            // { eq:{Marca__c:'ACME'}, like:{OrderNumber:'123'} }
    @api columnsOverride = [];    // opcional: define colunas manualmente

    // ===== State =====
    @track rows = [];
    @track total = 0;
    isLoading = false;

    // keyset cursors (stack p/ voltar)
    cursorStack = [];  // cada item = token (cursorFirst da página anterior)
    cursorCurrent = null; // cursor usado p/ buscar a página atual (para avançar)
    direction = null;     // 'next' | 'prev' | null

    get sortDirectionLower() {
        return (this.sortDirection || 'DESC').toLowerCase();
    }

    pageSizeOptions = [
        { label: '10', value: 10 },
        { label: '25', value: 25 },
        { label: '50', value: 50 },
        { label: '100', value: 100 }
    ];

    connectedCallback() {
        // Se extraSelect vier como string no App Builder, normaliza para array
        if (typeof this.extraSelect === 'string') {
            this.extraSelect = this.extraSelect.split(',').map(s => s.trim()).filter(Boolean);
        }
        this.loadInitial();
    }

    get disablePrev() {
        return this.cursorStack.length === 0;
    }
    get disableNext() {
        return !this.rows || this.rows.length < this.pageSize;
    }

    get columns() {
        if (this.columnsOverride && this.columnsOverride.length) return this.columnsOverride;
        // Gera colunas simples quando não vier override
        if (this.rows && this.rows.length) {
            const sample = this.rows[0];
            const cols = [];
            Object.keys(sample).forEach(k => {
                if (k === 'attributes') return;
                cols.push({ label: k, fieldName: k, type: (k.endsWith('Id') ? 'text' : 'text'), sortable: true });
            });
            if (cols.length) return cols;
        }
        return [{ label: 'Id', fieldName: 'Id', type: 'text', sortable: true }];
    }

    async loadInitial() {
        this.cursorStack = [];
        this.cursorCurrent = null;
        this.direction = null;
        await this.loadPage();
    }

    async loadPage() {
        this.isLoading = true;
        try {
            const req = {
                objectApiName: this.objectApiName,
                fieldSetApiName: this.fieldSetApiName,
                extraSelect: this.extraSelect,
                pageSize: this.pageSize,
                sortBy: this.sortBy,
                sortDirection: this.sortDirection,
                filters: this.filters,
                cursor: this.cursorCurrent,
                direction: this.direction
            };
            const res = await fetchPage(req);

            this.rows = (res.records || []).map(r => {
                // Flatten relacionais simples (Account.Name -> AccountName) para aparecer na tabela auto
                const clone = JSON.parse(JSON.stringify(r));
                Object.keys(clone).forEach(key => {
                    if (clone[key] && typeof clone[key] === 'object' && clone[key].Name) {
                        clone[key + 'Name'] = clone[key].Name;
                    }
                });
                return clone;
            });

            this.total = res.total || 0;

            if (this.direction === 'next') {
                if (res.cursorFirst) this.cursorStack.push(res.cursorFirst);
                this.cursorCurrent = res.cursorLast || null;
            } else if (this.direction === 'prev') {
                this.cursorCurrent = res.cursorFirst || null;
            } else {
                this.cursorCurrent = res.cursorLast || null;
                if (res.cursorFirst) this.cursorStack = [res.cursorFirst];
            }

        } catch (e) {
            // eslint-disable-next-line no-console
            console.error(e);
        } finally {
            this.isLoading = false;
            this.direction = null;
        }
    }

    handleNext() {
        if (this.disableNext) return;
        this.direction = 'next';
        this.loadPage();
    }

    handlePrev() {
        if (this.disablePrev) return;
        this.cursorStack.pop();
        const prevCursor = this.cursorStack.length ? this.cursorStack[this.cursorStack.length - 1] : null;
        this.cursorCurrent = prevCursor;
        this.direction = 'prev';
        this.loadPage();
    }

    handlePageSizeChange(e) {
        this.pageSize = parseInt(e.detail.value, 10);
        this.loadInitial();
    }

    handleSort(e) {
        const { fieldName, sortDirection } = e.detail;
        this.sortBy = fieldName;
        this.sortDirection = (sortDirection || 'ASC').toUpperCase();
        this.loadInitial();
    }

    // API para atualizar filtros dinamicamente
    @api
    refreshWithFilters(newFilters) {
        this.filters = newFilters || {};
        this.loadInitial();
    }
}
