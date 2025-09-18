# Generic Paginator (Keyset) — SFDX Package

Componentes para paginação *keyset* no LWC com busca genérica baseada em Field Set + extras relacionais.

## Instalação (SFDX)

```bash
sfdx force:auth:web:login -a myOrg
sfdx force:source:push -u myOrg
```

## Uso

1. Crie um **Field Set** no objeto alvo (ex.: `Pedido__c` -> Field Set `Lista`).
2. Adicione o LWC **Generic Paginator (Keyset)** no App Builder.
3. Configure as props:
   - **Objeto (API)**: `Pedido__c` (ou `Order` etc)
   - **Field Set (API)**: `Lista`
   - **Campos extras**: `Account.Name,Owner.Name` (opcional)
   - **Itens por página**: 25
   - **Ordenar por**: `CreatedDate`
   - **Direção**: `DESC`

### Atualizar filtros via JavaScript (ex.: outro LWC pai)
```js
const filtros = {
  eq: { Marca__c: 'ACME', Cadeia__c: 'Varejo' },
  like: { Name: '123' },
  between: { CreatedDate: ['2025-01-01','2025-12-31'] }
};
this.template.querySelector('c-generic-paginator')
  .refreshWithFilters(filtros);
```

## Observações
- **Keyset**: sem `OFFSET`, usa cursor `(SortField, Id)`.
- **Total**: `COUNT()` separado.
- **Segurança**: whitelists, `queryWithBinds`, `with sharing`, `stripInaccessible`.
- **Ordenação**: por campo direto (não relacional). Evite campos com muitos `null`.
