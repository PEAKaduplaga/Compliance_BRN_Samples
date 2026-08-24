# Univeris Blotter BRN Sampling

## 1. Objective

Convert the existing Univeris blotter query into a stored procedure that retrieves transactions for a specified branch (BRN) and supports the extraction and classification of compliance samples from the results.

The procedure will use a rolling twelve-month period calculated from the execution date.

## 2. Existing source

The starting point is [`Univeris_Blotter_Finance_BRN.sql`](./Univeris_Blotter_Finance_BRN.sql), which retrieves Univeris blotter transactions and stages the results in a temporary report table.

## 3. Stored procedure scope

### Input

- `@BRN` — `BRN_CD` supplied by the caller.
- The procedure resolves `@BRN` to `@BRN_SYSID` through `MPS.dbo.BRN` and uses the resolved key for transaction filtering.
- An invalid or unknown `BRN_CD` should stop the procedure with an explicit error.
- Selected samples include the retained branch metadata: `BRN_CD`, `BRN_NAME`, `BRN_STATUS`, `BRN_MGR`, and `DLR_CD`.

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

## 4.1 Confirmed sample-selection rules

The sampling rules are maintained as ordered rule definitions so that thresholds, transaction codes, risk codes, plan codes, and sample counts can be changed without rewriting the selection algorithm.

### Supervision sample

- Eligibility gate: the branch must have at least 10 qualifying transactions during the rolling twelve-month period.
- Current sample size: 3 transactions per representative; this must be configurable.
- Rank `1` is the highest priority and rank `6` is the lowest priority.
- Process candidates by ascending rank.
- Within each rank, select transactions in descending `Gross_Amount` order.
- Continue to the next rank only when fewer than 3 transactions have been selected for the representative; lower-ranked transactions backfill the remaining slots.

Current rule configuration from `Sheet1`:

| Rank | Description | Transaction codes | Additional criteria |
|---:|---|---|---|
| 1 | Representative under supervision | Any | `TRADE_WATCH = 1` |
| 2 | Leveraged account | Any | `PLN_CD IN ('41', '18')` |
| 3 | Redemption | `7211, 7111, 7312, 7313, 7314, 7315` | `Gross_Amount >= 10000` |
| 4 | Purchase | `2111, 2211` | `Gross_Amount >= 10000` |
| 5 | Purchase | `2111, 2211` | `IVT_RISK_CD = 30` and `Gross_Amount >= 5000` |
| 6 | Purchase | `2111, 2211` | `IVT_RISK_CD IN (35, 40, 45, 50, 100)` and `Gross_Amount >= 2500` |

### Direct/non-wired sample

- Eligibility gate: the branch must have at least 5 qualifying direct transactions during the rolling twelve-month period.
- Current sample size: 1 transaction per representative; this must be configurable.
- Require `Trade_type = 'D'`.
- Process the configured transaction-code ranks in ascending order.
- Select the highest `Gross_Amount` available for the representative, using the next rank only if the higher-priority rank has no candidate.

### Senior-client sample

- Eligibility gate: the branch must have at least 5 qualifying transactions during the rolling twelve-month period.
- Current sample size: 1 transaction per representative; this must be configurable.
- Require `AGE >= 70`.
- Process the configured transaction-code ranks in ascending order.
- Select the highest `Gross_Amount` available for the representative, using the next rank only if the higher-priority rank has no candidate.

### New-account sample

- Identify new accounts using `MPS.dbo.PLN.SETUP_DT` within the rolling twelve-month period.
- Eligibility gate: the branch must have at least 5 qualifying new accounts during the period.
- Current sample size: 1 new account per representative; this must be configurable.
- Search the complete transaction set for each qualifying plan so the initial transaction is not excluded by the normal transaction-code filter.
- Select the initial transaction by earliest `Trade_Date`, with `TRX_SYSID` as the tie-breaker.
- Select the representative's new-account sample by highest initial `Gross_Amount`.
- Return the initial transaction type, amount, product, and transaction date with the selected sample.

### Modular implementation design

The procedure should separate the following layers:

1. `Population` — the existing transaction query filtered by BRN and rolling date range.
2. `RuleConfig` — inline or temporary configuration rows containing sample type, rank, transaction-code set, risk-code set, plan-code set, amount threshold, age threshold, supervision flag, and required sample count. New-account candidates are added as a separate account-based population because their initial transaction must be found outside the normal filtered transaction population.
3. `CandidateMatches` — evaluates each population transaction against the active rule rows and records the matching rule/rank.
4. `RankedCandidates` — applies representative-level ordering: rank ascending, `Gross_Amount` descending, then stable transaction-key ordering for ties.
5. `SelectedSamples` — applies branch eligibility gates and takes the required number per representative, allowing lower-priority ranks to backfill.
6. Final output — returns the selected transactions with sample type, matched rule rank, and selection metadata.

The final result excludes `PLN_CD`, `TRX_CD`, `BRN_SYSID`, `BRN_TYPE`, `BRN_HEAD`, `BRN_HEAD_CODE`, `BRN_MGR_CODE`, `RGN_CD`, `Dealer_Commission`, `DSC`, `TRX_COMM`, `TRX_COMM_PCNT`, and `ENTRY_USER`. Fields required internally for rule matching remain in the working population.

The transaction-key tie-breaker still needs to be confirmed. A stable source transaction identifier should be used instead of relying on non-deterministic ordering when two transactions have the same gross amount.

### Configurable sample quantities

The procedure should not hardcode the number of samples in the selection queries. Instead, sample quantities should be held in configuration values, for example:

| Sample type | Current quantity per representative |
|---|---:|
| Supervision | 3 |
| Direct/non-wired | 1 |
| Senior client | 1 |
| New account | 1 |

The final procedure may expose these as optional parameters with the documented defaults, or load them from a rule/configuration table. The selection logic must use the configured quantity when applying the representative-level ranking and backfill.

## 5. Expected procedure behavior

- Accept a BRN as an input parameter.
- Calculate the rolling date range at execution time with `GETDATE()`.
- Query the Univeris data source using the existing blotter logic.
- Produce the final selected sample set, not only the full population, once the sampling rules are complete.
- Expose enough information to trace each selected sample back to the source transaction and its sampling category.

## 6. Open decisions

- Confirm the branch display columns to return from `MPS.dbo.BRN` (for example, branch code, name, and status).
- Confirm whether the twelve-month filter uses `Trade_Date`, `Settlement_Date`, `Entry_Date`, or another date.
- Confirm whether the current query's date filters should be replaced or supplemented.
- Confirm the SQL Server version and whether use of `TABLESAMPLE`, `NEWID()`, or another sampling approach is acceptable.
- Confirm whether the procedure should return the full eligible population in addition to the selected sample.

## 7. Change log

| Date | Change |
|---|---|
| 2026-08-21 | Initial scope created from the existing Univeris blotter query. |
