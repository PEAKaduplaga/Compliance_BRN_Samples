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
- Rank `1` is the highest priority and rank `4` is the lowest priority.
- Process candidates by ascending rank.
- Within rank `3`, process subranks in ascending order.
- Within each rank or subrank, select transactions in descending `Gross_Amount` order.
- If a transaction matches multiple rules, retain it once under the highest-priority matching rule.
- Continue to the next rank or subrank only when fewer than 3 transactions have been selected for the representative; lower-priority candidates backfill the remaining slots.

Current rule configuration from `Sheet1`:

| Rank | Subrank | Description | Transaction codes | Additional criteria |
|---:|---:|---|---|---|
| 1 | — | Representative under supervision | Any | `TRADE_WATCH = 1` |
| 2 | — | Leveraged account | Any | `PLN_CD IN (41, 18)` |
| 3 | 1 | Purchase | `2111, 2211` | `IVT_RISK_CD IN (35, 40, 45, 50, 100)` and `Gross_Amount >= 2500` |
| 3 | 2 | Purchase | `2111, 2211` | `IVT_RISK_CD = 30` and `Gross_Amount >= 5000` |
| 3 | 3 | Purchase | `2111, 2211` | `Gross_Amount >= 10000` |
| 3 | 4 | Switch In | `4611, 4711, 4911, 4910` | `Gross_Amount >= 10000` |
| 4 | — | Redemption | `7211, 7111, 7312, 7313, 7314, 7315` | `Gross_Amount >= 10000` |

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

## 8. KYC sampling (CVC in French)

### Objective

Add a KYC sample population for changes to the client's KYC information (`CVC` in the French version):

- Select 1 CVC change per representative.
- The branch must have at least 5 qualifying CVC changes during the twelve months preceding the review.
- The sample is filtered by branch and representative.
- The procedure should return selected samples only; the full population can be added later if required.
- Because CVC changes do not have a transaction amount, the current selection order is most recent `ADT_DATE`, then highest `ADT_SYSID` for ties.

### Source

The KYC audit data is located in the Fabric Lake `PEAK_LAKE_BI` Delta tables. The starting query is [`KYC_BRN_SAMPLE.sql`](./KYC_BRN_SAMPLE.sql), which reads the UVS audit data, including `[UVS].[adt]`, `[UVS].[ivr]`, `[UVS].[rep]`, and `[UVS].[brn]`.

### Initial population filters

The KYC population should use the audit event date (`ADT_DATE`) for the rolling twelve-month period and retain only records with a populated `ADT_AFTER` value.

The following audit fields must be excluded from the CVC-change population:

- `USER_SYSID`.
- Any field containing the literal `_DT`, such as `SETUP_DT` or `LAST_UPD_DT`.
- Any field containing `DATE`.

The active audit-table scope is maintained in `KYC_BRN_SAMPLE.sql` and currently includes KYC-related tables such as `KYC_PLN`, `PLN`, `IVR`, and related client/plan tables.

### Required output

Each selected KYC sample should include, at minimum:

- Branch code and branch details.
- Representative identifier and name.
- Client and plan identifiers.
- Audit event date.
- Audit table, activity, and changed field.
- Before and after values.
- Transaction/user context where available, excluding `USER_SYSID` as a changed field.
- A sample type and selection sequence.

### Modular controls

The KYC sample quantity per representative and the minimum qualifying changes per branch should be configurable, consistent with the other sample populations. The default values are 1 sample per representative and 5 qualifying CVC changes per branch. These controls are currently variables at the top of `KYC_BRN_SAMPLE.sql`.

## 9. Branch hierarchy and transaction population scope

### Branch structure

Branches have a hierarchy based on `BRN_TYPE`:

| `BRN_TYPE` | Meaning | Example behavior |
|---|---|---|
| `M` | Main branch | May operate alone or have multiple sub-branches. |
| `S` | Sub-branch | Belongs to a main branch through the branch-head relationship. |
| `O` | Office | Separate branch type to be handled according to the configured scope. |
| `T` | Outlet | Separate branch type to be handled according to the configured scope. |
| `N` | Multilevel | Separate branch type to be handled according to the configured scope. |

The branch records indicate the relationship using fields such as `BRN_SYSID`, `BRN_CD`, `BRN_TYPE`, `BRN_HEAD_CODE`, and `BRN_MGR_CODE`. For example, sub-branches with `BRN_HEAD_CODE = 'ON010'` belong to the main branch `ON010`.

### Default population behavior

When a main branch is supplied as the starting branch, the default transaction population should include:

1. The main branch itself.
2. All active sub-branches belonging to that main branch.
3. The complete combined transaction set for the branch group before applying transaction sampling.

If a main branch has no sub-branches, its own transactions form the complete population.

The branch group should be resolved before transaction filtering and should be reused consistently across all sampling categories. Branch-level minimums and sample counts must be calculated against the configured population scope, not accidentally against only the main branch row.

### Optional branch-scope override

The final procedure should support an override allowing the caller to choose between:

- `GROUP` — main branch plus all related sub-branches; default behavior.
- `INDIVIDUAL` — only the supplied branch.

The override should be configurable without rewriting the transaction-selection logic. The implementation should also define how the input behaves when a sub-branch is supplied: either sample that sub-branch only, or resolve it to its main branch group unless `INDIVIDUAL` is explicitly selected.

### Branch-code validation and scope resolution

The branch scope should be resolved from `[MPS].[dbo].[BRN]` before the transaction population is queried. The relevant identification fields are:

- `BRN_SYSID` — branch primary key used by transaction foreign keys.
- `BRN_CD` — caller-facing branch code.
- `BRN_TYPE` — identifies main, sub-branch, office, outlet, or multilevel branch types.
- `BRN_HEAD_CODE` — identifies the parent/main branch for a sub-branch.
- `BRN_STATUS` — used to determine whether the branch is active.
- `BRN_MGR_CODE` — branch manager identifier for later approval-source classification.

The stored procedure should create a temporary branch-scope table at the beginning of execution, for example `#BranchScope`, with at least:

| Column | Purpose |
|---|---|
| `BRN_SYSID` | Join key for transaction data. |
| `BRN_CD` | Branch code returned for auditability. |
| `BRN_TYPE` | Main/sub-branch classification. |
| `BRN_HEAD_CODE` | Parent/main branch relationship. |
| `BRN_MGR_CODE` | Branch-manager comparison for approval analysis. |
| `Scope_Source` | Indicates `INPUT`, `MAIN`, or `SUB_BRANCH`. |

Resolution sequence:

1. Find the input row using `BRN_CD`.
2. Stop with an explicit error if no branch row is found.
3. If the override is `TRUE`, insert only the supplied branch into `@BranchScope`.
4. If the override is `FALSE` and the input is a main branch (`BRN_TYPE = 'M'`), insert the main branch plus active rows where `BRN_HEAD_CODE` equals the main branch code.
5. If the override is `FALSE` and the input is a sub-branch (`BRN_TYPE = 'S'`), resolve its `BRN_HEAD_CODE`, then insert the parent main branch and all active sub-branches under that parent.
6. Require a valid parent/main branch code when group resolution is requested for a sub-branch; otherwise stop with an explicit error rather than silently sampling only one branch.
7. Use the resulting `@BranchScope.BRN_SYSID` set for all transaction filtering and branch-level population counts.

User-defined functions and table-valued functions should not be used for the KYC/Fabric Delta workflow because Fabric Delta Lake does not support the required function approach. The temporary `#BranchScope` table is the required implementation pattern. It is local to one procedure execution, supports the runtime override, and carries branch metadata into later approval-source classification.

### Approval-source distinction

The transaction population must preserve enough source information to determine whether an approval was performed by:

- The branch manager or branch-level approver.
- Head office or another centralized approver.

This distinction must be captured before sampling so that selected transactions can be classified by approval source. The relevant source fields, approval user identifiers, and approval-history table still need to be confirmed. Sampling should not collapse or discard this information when transactions from a main branch and its sub-branches are combined.

### Open decisions

- The input is `BRN_CD`; `GROUP` is the default unless the override is enabled.
- All branch types are in scope. A branch with `BRN_TYPE = 'S'` must have a `BRN_HEAD_CODE`; missing parent information should raise an explicit data-quality error.
- The transaction date basis is `ENTRY_DATE`, which is expected to be close to `ORD_TRADE_DT`.
- The archive table is normally the definitive source when an order appears in both current and archive data.
- Sampling and branch counts apply to the combined resolved branch group unless the individual-branch override is enabled.
- The final population is one row per logical order.

## 10. Tier-1 branch-manager approval

### Approval source

Tier-1 branch approval is identified through the primary approver records in `[MPS].[dbo].[CPL_APPROVER]`:

- `CPL_APPROVER.PRIM_IND = 1` identifies the primary/tier-1 approver record.
- `CPL_APPROVER.USER_SYSID` identifies the approving user.
- `CPL_APPROVER.BRN_SYSID` identifies the branch to which the approval authority is attached.
- `CPL_APPROVER.REP_SYSID` controls whether the authority applies branch-wide or to one representative.
- `[MPS].[dbo].[SYS_USER_CD].USR_NAME` provides the approver name.

The branch approver lookup should retain the approver user ID and name, branch ID/code, and `REP_SYSID` so the approval decision can be audited.

### Reference approver query

```sql
SELECT
    A.[BRN_SYSID],
    A.[DLR_SYSID],
    A.[RGN_SYSID],
    A.[BRN_CD],
    A.[BRN_TYPE],
    A.[BRN_NAME],
    A.[BRN_HEAD],
    A.[BRN_HEAD_CODE],
    A.[BRN_STATUS],
    A.[BRN_MGR],
    A.[BRN_MGR_CODE],
    A.[DLR_CD],
    A.[RGN_CD],
    B.[USER_SYSID] AS APPROVER_USER_SYSID,
    B.[BRN_SYSID] AS APPROVER_BRN_SYSID,
    B.[PRIM_IND],
    B.[REP_SYSID] AS APPROVER_REP_SYSID,
    C.[USR_NAME] AS APPROVER_USER_NAME
FROM [MPS].[dbo].[BRN] A
LEFT JOIN [MPS].[dbo].[CPL_APPROVER] B
    ON A.BRN_SYSID = B.BRN_SYSID
   AND B.[PRIM_IND] = 1
LEFT JOIN [MPS].[dbo].[SYS_USER_CD] C
    ON B.USER_SYSID = C.USER_SYSID
   AND C.BRN_SYSID <> 0
WHERE C.USER_SYSID IS NOT NULL
ORDER BY
    A.BRN_CD,
    A.BRN_TYPE;
```

### Representative authorization rule

For a transaction or audit event associated with representative `REP_SYSID`:

```sql
CPL_APPROVER.REP_SYSID = 0
OR CPL_APPROVER.REP_SYSID = Transaction.REP_SYSID
```

Interpretation:

- `REP_SYSID = 0`: the approver can approve transactions for any advisor attached to that branch.
- `REP_SYSID <> 0`: the approver can approve only transactions belonging to the matching representative.

The approval lookup should be restricted to `PRIM_IND = 1` and valid users, consistent with the supplied reference query. When a grouped branch scope is selected, the lookup must evaluate the applicable approver records for every branch in `#BranchScope`.

### Approval classification for sampled transactions

The transaction-sampling output should eventually identify whether the selected transaction was approved by a valid tier-1 branch approver. The first implementation can use a single validation step based on the order's recorded tier-1 reviewer and the branch approver table, rather than reproducing the full approval hierarchy. At minimum, the approval-enrichment fields should include:

- Approval user ID.
- Approval user name.
- Approval branch code/ID.
- Approval `REP_SYSID` scope.
- A classification such as `BRANCH_MANAGER`, `HEAD_OFFICE`, or `NO_MATCH`.

The approval record must be matched to the transaction's actual approval user and representative. A branch approver row alone is not proof that the user approved a particular transaction; the transaction or approval-history source still needs to be joined using the relevant approval-user and transaction identifiers.

### Open approval questions

- Confirm whether the first implementation should enforce the rep-specific `CPL_APPROVER.REP_SYSID` restriction, or only validate branch, primary approver, and matching reviewer user.
- Confirm how head-office approvals are identified and how they should be distinguished from branch-manager approvals.

## 11. Compliance-order population source

### Source tables

The transaction-sampling population should be built from both order snapshot tables:

- `[MPS].[dbo].[SNAPSHOT_CPL_ORD]`
- `[MPS].[dbo].[ARC_SNAPSHOT_CPL_ORD]`

The two sources contain the order, client/plan, product, branch, representative, and compliance-approval information required for sampling. The population must be combined before applying branch scope, approval classification, or sample-selection rules.

### Combined population requirements

The implementation should:

1. Select the common sampling columns from both tables.
2. Add a source indicator, such as `SNAPSHOT` or `ARCHIVE`, for auditability.
3. Combine the sources with `UNION ALL` so duplicate detection remains explicit and reviewable.
4. Deduplicate the combined set before any branch counts or transaction samples are calculated.
5. Preserve the selected source row and its `SNAPSHOT_ID` for traceability.

### Duplicate handling

`ORD_SYSID` will be treated as the logical order key for the first implementation because it is also the key used to join the approved-order population back to the transaction preselection. `CPL_ORD_ID` should be retained for auditability and used as a secondary validation key.

The deduplication step should use a deterministic `ROW_NUMBER()` rule and retain exactly one record per logical order. When the same order appears in both sources, the archive row should normally win because the archive is considered definitive. `SNAPSHOT_ID` or `ENTRY_DATE` can be used as the tie-breaker within the same source.

No branch minimum, representative quota, or rank should be calculated until deduplication is complete; otherwise an order present in both tables could be counted twice or selected twice.

### Sampling and approval fields

The combined order population includes the fields needed to drive the existing sampling logic, including:

- `ORD_SYSID`, `CPL_ORD_ID`, `ORD_TRADE_DT`, and `ORD_AMT`.
- `TYPE`, `ORD_DIRECT`, `ORD_CLIENT_SIG`, `ORD_INFRACTION`, `INFRACTION_TYPES`, and `OFF_BOOK`.
- `PLN_SYSID`, `PLN_LEVERAGED`, `PLN_LTA`, `PLN_TRADE_WATCH`, and `REP_TRADE_WATCH`.
- `REP_CD`, `BRN_CD`, `DLR_CD`, and `RGN_CD`.
- `CPL_TIER1`, `CPL_TIER1_DESCN`, `CPL_TIER1_ACTION`, `CPL_TIER1_OVR`, and `CPL_TIER1_PRIM_IND`.
- `CPL_TIER2` fields and pending-approval fields for later escalation analysis.

The branch-group scope should be applied using `BRN_CD` after the order population has been deduplicated. Tier-1 approval classification should use the order-level approval fields together with the branch approver rules documented above, so the final sample can distinguish branch-manager approval from head-office or unmatched approval.

### Open decisions

- Confirm whether `ORD_SYSID` identifies the same logical order in both current and archive sources.
- Confirm whether `SNAPSHOT_ID` is chronological and can be used as the tie-breaker within a source.
- Confirm whether `TYPE` values such as `PUR` and `RED` are the authoritative transaction classification for sampling.
