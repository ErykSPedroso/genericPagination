// GenericKeysetBrowserController.cls
public with sharing class GenericKeysetBrowserController {

    public class PageRequest {
        @AuraEnabled public String objectApiName;
        @AuraEnabled public String fieldSetApiName;        // ex.: 'Lista'
        @AuraEnabled public List<String> extraSelect;      // ex.: ['Account.Name']
        @AuraEnabled public Integer pageSize;
        @AuraEnabled public String sortBy;                 // ex.: 'CreatedDate'
        @AuraEnabled public String sortDirection;          // 'ASC'|'DESC'
        @AuraEnabled public Map<String, Object> filters;   // { 'eq':{'Marca__c':'ACME'}, 'like':{'OrderNumber':'123'}, ...}
        @AuraEnabled public String cursor;                 // token base64 (opcional)
        @AuraEnabled public String direction;              // 'next' | 'prev' | null(inicial)
    }
    public class PageResult {
        @AuraEnabled public List<SObject> records;
        @AuraEnabled public Integer total;
        @AuraEnabled public String cursorFirst; // token p/ voltar para "antes" desta página
        @AuraEnabled public String cursorLast;  // token p/ ir para "depois" desta página
        @AuraEnabled public String sortBy;
        @AuraEnabled public String sortDirection;
        @AuraEnabled public Integer pageSize;
    }
    private class CursorParts {
        public Object sortVal;
        public Id idVal;
    }

    // ======= CONFIG =======
    // Limite os objetos/fields para segurança (ajuste conforme sua org)
    private static final Set<String> ALLOWED_OBJECTS = new Set<String>{
        'Order', 'Account', 'Contact', 'Opportunity', 'Pedido__c'
    };
    // Campos que aceitam filtro mesmo que não estejam no field set
    private static final Set<String> ALLOWED_FILTER_FIELDS = new Set<String>{
        'Marca__c','Cadeia__c','Status','CreatedDate','EffectiveDate','OrderNumber','AccountId','Name','LastModifiedDate'
    };
    // Campo padrão p/ sort (não nulo e bem distribuído é ideal)
    private static final String DEFAULT_SORT_BY = 'CreatedDate';
    private static final String DEFAULT_SORT_DIR = 'DESC';
    private static final Integer DEFAULT_PAGE_SIZE = 25;
    private static final Integer MAX_PAGE_SIZE = 200;

    @AuraEnabled(cacheable=true)
    public static PageResult fetchPage(PageRequest req) {
        // ---- Validações básicas
        if (req == null) throwAura('Requisição inválida.');
        if (String.isBlank(req.objectApiName)) throwAura('Object API Name é obrigatório.');
        if (!ALLOWED_OBJECTS.contains(req.objectApiName)) throwAura('Objeto não permitido.');
        Integer pageSize = (req.pageSize == null || req.pageSize <= 0) ? DEFAULT_PAGE_SIZE : Math.min(req.pageSize, MAX_PAGE_SIZE);
        String sortBy = String.isBlank(req.sortBy) ? DEFAULT_SORT_BY : req.sortBy;
        String sortDir = (req.sortDirection == 'ASC' ? 'ASC' : 'DESC');

        // Describe
        Schema.SObjectType sType = Schema.getGlobalDescribe().get(req.objectApiName);
        if (sType == null) throwAura('Objeto inválido.');
        Schema.DescribeSObjectResult dObj = sType.getDescribe();
        Map<String, Schema.SObjectField> fieldsMap = dObj.fields.getMap();

        // ---- Monta SELECT a partir do Field Set (+ extras opcionais)
        Set<String> selectSet = new Set<String>{ 'Id' }; // sempre inclui Id
        if (!String.isBlank(req.fieldSetApiName)) {
            Schema.FieldSet fs = dObj.fieldSets.getMap().get(req.fieldSetApiName);
            if (fs == null) throwAura('Field Set não encontrado: ' + req.fieldSetApiName);
            for (Schema.FieldSetMember m : fs.getFields()) {
                String api = m.getFieldPath(); // Field set só aceita campos diretos
                if (fieldsMap.containsKey(api)) selectSet.add(api);
            }
        }
        if (req.extraSelect != null) {
            for (String extra : req.extraSelect) {
                if (!String.isBlank(extra)) selectSet.add(extra.trim());
            }
        }
        if (!fieldsMap.containsKey(sortBy)) {
            // sort por relacional não é suportado em keyset; force fallback seguro
            sortBy = DEFAULT_SORT_BY;
        }

        // ---- WHERE dinâmico
        List<String> whereClauses = new List<String>();
        Map<String, Object> binds = new Map<String, Object>();

        // Suporte simples a operadores: eq, like, in, ge, le, between (datas/num)
        if (req.filters != null && !req.filters.isEmpty()) {
            // eq
            addOpEquals(req.filters.get('eq'), ALLOWED_FILTER_FIELDS, whereClauses, binds);
            // like
            addOpLike(req.filters.get('like'), ALLOWED_FILTER_FIELDS, whereClauses, binds);
            // in
            addOpIn(req.filters.get('in'), ALLOWED_FILTER_FIELDS, whereClauses, binds);
            // ge/le (>=, <=)
            addOpCmp(req.filters.get('ge'), ALLOWED_FILTER_FIELDS, whereClauses, binds, '>=');
            addOpCmp(req.filters.get('le'), ALLOWED_FILTER_FIELDS, whereClauses, binds, '<=');
            // between: { 'CreatedDate': ['2025-01-01','2025-12-31'] }
            addOpBetween(req.filters.get('between'), ALLOWED_FILTER_FIELDS, whereClauses, binds);
        }

        // ---- Keyset cursor (WHERE adicional dependente da direção)
        CursorParts cp = parseCursor(req.cursor);
        if (!String.isBlank(req.direction) && cp != null) {
            // Regras lexicográficas estáveis: (SortField, Id)
            // ASC: (sf > :val) OR (sf = :val AND Id > :id)
            // DESC: (sf < :val) OR (sf = :val AND Id < :id)
            String cmp1 = (sortDir == 'ASC') ? '>' : '<';
            String cmp2 = (sortDir == 'ASC') ? '>' : '<';
            String sfBind = 'curSortVal';
            String idBind = 'curIdVal';
            binds.put(sfBind, cp.sortVal);
            binds.put(idBind, cp.idVal);

            whereClauses.add('((' + sortBy + ' ' + cmp1 + ' :' + sfBind + ') OR (' + sortBy + ' = :' + sfBind + ' AND Id ' + cmp2 + ' :' + idBind + '))');
        }

        String whereSoql = whereClauses.isEmpty() ? '' : (' WHERE ' + String.join(whereClauses, ' AND '));

        // ---- COUNT total
        Integer total = (Integer)Database.countQuery('SELECT COUNT() FROM ' + req.objectApiName + whereSoql);

        // ---- QUERY page (sem OFFSET)
        String orderClause = ' ORDER BY ' + sortBy + ' ' + sortDir + ', Id ' + sortDir;
        String selectClause = 'SELECT ' + String.join(new List<String>(selectSet), ',') + ' FROM ' + req.objectApiName;
        String soql = selectClause + whereSoql + orderClause + ' LIMIT :pageSize';

        List<SObject> rows = (List<SObject>)Database.queryWithBinds(soql, binds, pageSize);

        // FLS hardening
        rows = (List<SObject>)Security.stripInaccessible(AccessType.READABLE, rows).getRecords();

        // ---- Calcula cursores first/last da página
        String firstToken, lastToken;
        if (!rows.isEmpty()) {
            SObject first = rows[0];
            SObject last  = rows[rows.size()-1];

            Object firstSortVal = first.get(sortBy);
            Object lastSortVal  = last.get(sortBy);
            firstToken = encodeCursor(firstSortVal, (Id)first.get('Id'));
            lastToken  = encodeCursor(lastSortVal,  (Id)last.get('Id'));
        }

        PageResult res = new PageResult();
        res.records = rows;
        res.total = total;
        res.cursorFirst = firstToken;
        res.cursorLast = lastToken;
        res.sortBy = sortBy;
        res.sortDirection = sortDir;
        res.pageSize = pageSize;
        return res;
    }

    // ===== Helpers (filtros)
    private static void addOpEquals(Object op, Set<String> allowed, List<String> where, Map<String,Object> binds) {
        Map<String,Object> m = (Map<String,Object>)op;
        if (m == null) return;
        for (String f : m.keySet()) {
            if (!allowed.contains(f)) continue;
            String b = 'eq_' + f;
            where.add(f + ' = :' + b);
            binds.put(b, m.get(f));
        }
    }
    private static void addOpLike(Object op, Set<String> allowed, List<String> where, Map<String,Object> binds) {
        Map<String,Object> m = (Map<String,Object>)op;
        if (m == null) return;
        for (String f : m.keySet()) {
            if (!allowed.contains(f)) continue;
            String b = 'lk_' + f;
            where.add('(' + f + ' LIKE :' + b + ')');
            binds.put(b, '%' + String.valueOf(m.get(f)) + '%');
        }
    }
    private static void addOpIn(Object op, Set<String> allowed, List<String> where, Map<String,Object> binds) {
        Map<String,Object> m = (Map<String,Object>)op;
        if (m == null) return;
        for (String f : m.keySet()) {
            if (!allowed.contains(f)) continue;
            List<Object> vals = (List<Object>)m.get(f);
            if (vals == null || vals.isEmpty()) continue;
            String b = 'in_' + f;
            where.add(f + ' IN :' + b);
            binds.put(b, vals);
        }
    }
    private static void addOpCmp(Object op, Set<String> allowed, List<String> where, Map<String,Object> binds, String sym) {
        Map<String,Object> m = (Map<String,Object>)op;
        if (m == null) return;
        for (String f : m.keySet()) {
            if (!allowed.contains(f)) continue;
            String b = (sym == '>=') ? 'ge_' + f : 'le_' + f;
            where.add(f + ' ' + sym + ' :' + b);
            binds.put(b, m.get(f));
        }
    }
    private static void addOpBetween(Object op, Set<String> allowed, List<String> where, Map<String,Object> binds) {
        Map<String,Object> m = (Map<String,Object>)op;
        if (m == null) return;
        for (String f : m.keySet()) {
            if (!allowed.contains(f)) continue;
            List<Object> vals = (List<Object>)m.get(f);
            if (vals == null || vals.size() != 2) continue;
            String b1 = 'bt1_' + f, b2 = 'bt2_' + f;
            where.add('(' + f + ' >= :' + b1 + ' AND ' + f + ' <= :' + b2 + ')');
            binds.put(b1, vals[0]); binds.put(b2, vals[1]);
        }
    }

    // ===== Cursor helpers
    private static String encodeCursor(Object sortVal, Id idVal) {
        Map<String, Object> m = new Map<String, Object>{ 'sortVal' => sortVal, 'idVal' => idVal };
        String json = JSON.serialize(m);
        return EncodingUtil.base64Encode(Blob.valueOf(json));
    }
    private static CursorParts parseCursor(String token) {
        if (String.isBlank(token)) return null;
        try {
            Blob raw = EncodingUtil.base64Decode(token);
            String json = Blob.toString(raw);
            Map<String,Object> m = (Map<String,Object>)JSON.deserializeUntyped(json);
            CursorParts cp = new CursorParts();
            cp.sortVal = m.get('sortVal');
            cp.idVal = (Id)m.get('idVal');
            return cp;
        } catch (Exception e) {
            return null;
        }
    }

    private static void throwAura(String msg) { throw new AuraHandledException(msg); }
}
