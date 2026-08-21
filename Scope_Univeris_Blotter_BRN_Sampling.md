# Univeris Blotter BRN Sampling

## 1. Objective

Convert the existing Univeris blotter query into a stored procedure that retrieves transactions for a specified branch (BRN) and supports the extraction and classification of compliance samples from the results.

The procedure will use a rolling twelve-month period calculated from the execution date.

## 2. Existing source

The starting point is [`Univeris_Blotter_Finance_BRN.sql`](./Univeris_Blotter_Finance_BRN.sql), which retrieves Univeris blotter transactions and stages the results in a temporary report table.

## 3. Stored procedure scope

### Input

- `@BRN` — branch number/code used to restrict the transaction population.

### Date range

- End date: the execution date, based on `GETDATE()`.
- Start date: twelve months before the execution date.
- The date filtering should be applied to the appropriate transaction date field, expected to be `Trade_Date`; this will be confirmed while finalizing the query.
- The procedure should define the date boundaries consistently so that transactions are neither unintentionally omitted nor duplicated at the boundaries.

### Population

The procedure should return transactions that:

1. Belong to the supplied BRN.
2. Fall within the rolling twelve-month period.
3. Meet the existing query's required transaction, client, plan, product, and status conditions.

The existing output columns should be preserved unless the sampling design requires additional fields.

## 4. Sampling workflow

Sampling will be implemented as a series of steps. The detailed rules will be added as they are provided.

### Planned steps

1. Build the twelve-month BRN transaction population.
2. Apply required exclusions or eligibility rules.
3. Classify transactions into the defined sampling categories.
4. Determine the sample size for each category.
5. Select the required transactions using the agreed sampling method.
6. Return the selected samples together with the classification and audit-supporting fields.

### Sampling logic to be defined

- Population exclusions.
- Classification fields and category definitions.
- Priority when a transaction meets more than one category.
- Sample size by category.
- Random or deterministic selection method.
- Treatment of duplicate, related, or linked transactions.
- Handling of categories with fewer transactions than the required sample size.
- Reproducibility requirements for each run.
- Required output fields and sample identifiers.

## 5. Expected procedure behavior

- Accept a BRN as an input parameter.
- Calculate the rolling date range at execution time with `GETDATE()`.
- Query the Univeris data source using the existing blotter logic.
- Produce the final selected sample set, not only the full population, once the sampling rules are complete.
- Expose enough information to trace each selected sample back to the source transaction and its sampling category.

## 6. Open decisions

- Confirm the exact BRN column and source table/join where it is available.
- Confirm whether the twelve-month filter uses `Trade_Date`, `Settlement_Date`, `Entry_Date`, or another date.
- Confirm whether the current query's date filters should be replaced or supplemented.
- Confirm the SQL Server version and whether use of `TABLESAMPLE`, `NEWID()`, or another sampling approach is acceptable.
- Confirm whether the procedure should return the full eligible population in addition to the selected sample.

## 7. Change log

| Date | Change |
|---|---|
| 2026-08-21 | Initial scope created from the existing Univeris blotter query. |

