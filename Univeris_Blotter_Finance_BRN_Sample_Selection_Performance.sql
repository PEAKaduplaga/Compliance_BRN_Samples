/*
    Performance-version dry run for BRN transaction sampling.

    Main performance changes:
      - The initial transaction population contains only fields needed for joins,
        rule matching, ranking, and the final report.
      - Scalar KYC risk/goal functions are called only for selected samples.
      - No wide population update is performed before sampling.
      - ORD_SYSID indexes support the order-to-transaction join.
      - UNION ALL plus explicit ROW_NUMBER() deduplication is retained.
      - Branch and ENTRY_DATE filters are applied before order deduplication.

    This is a dry-run query. The existing procedure script is not changed.
*/

DECLARE @BRN varchar(10) = 'ON010';
DECLARE @BRN_OVERRIDE varchar(1) = 'N'; -- Y = individual branch, N = main branch plus sub-branches

/* Sampling controls. */
DECLARE @SupervisionSamplesPerRep int = 3;
DECLARE @DirectSamplesPerRep int = 1;
DECLARE @SeniorSamplesPerRep int = 1;
DECLARE @NewAccountSamplesPerRep int = 1;
DECLARE @SupervisionMinBranchTrx int = 10;
DECLARE @DirectMinBranchTrx int = 5;
DECLARE @SeniorMinBranchTrx int = 5;
DECLARE @NewAccountMinBranchAccounts int = 5;

DECLARE @DateTo datetime = GETDATE();
DECLARE @DateFrom datetime = DATEADD(MONTH, -12, @DateTo);
DECLARE @UseIndividualBranch bit =
    CASE
        WHEN UPPER(LTRIM(RTRIM(@BRN_OVERRIDE))) = 'Y' THEN 1
        WHEN UPPER(LTRIM(RTRIM(@BRN_OVERRIDE))) = 'N' THEN 0
        ELSE NULL
    END;

IF @UseIndividualBranch IS NULL
    THROW 50005, 'BRN override must be Y or N.', 1;

DECLARE @InputBRN_SYSID int;
DECLARE @InputBRN_TYPE char(1);
DECLARE @InputBRN_HEAD_CODE varchar(10);
DECLARE @RequestedBRN_NAME varchar(100);
DECLARE @RequestedBRN_STATUS varchar(2);
DECLARE @RequestedBRN_MGR varchar(100);
DECLARE @RequestedDLR_CD varchar(10);
DECLARE @ScopeBRN_CD varchar(10);

SELECT
    @InputBRN_SYSID = B.BRN_SYSID,
    @InputBRN_TYPE = B.BRN_TYPE,
    @InputBRN_HEAD_CODE = NULLIF(LTRIM(RTRIM(B.BRN_HEAD_CODE)), ''),
    @RequestedBRN_NAME = B.BRN_NAME,
    @RequestedBRN_STATUS = B.BRN_STATUS,
    @RequestedBRN_MGR = B.BRN_MGR,
    @RequestedDLR_CD = B.DLR_CD
FROM [MPS].[dbo].[BRN] B
WHERE B.BRN_CD = @BRN;

IF @InputBRN_SYSID IS NULL
    THROW 50001, 'The supplied BRN_CD was not found in MPS.dbo.BRN.', 1;

IF @UseIndividualBranch = 1
    SET @ScopeBRN_CD = @BRN;
ELSE IF @InputBRN_TYPE = 'S'
BEGIN
    IF @InputBRN_HEAD_CODE IS NULL
        THROW 50002, 'The supplied sub-branch has no BRN_HEAD_CODE for group resolution.', 1;

    SET @ScopeBRN_CD = @InputBRN_HEAD_CODE;

    IF NOT EXISTS
    (
        SELECT 1
        FROM [MPS].[dbo].[BRN] B
        WHERE B.BRN_CD = @ScopeBRN_CD
          AND B.BRN_TYPE = 'M'
    )
        THROW 50003, 'The sub-branch BRN_HEAD_CODE does not identify a valid main branch.', 1;
END;
ELSE
    SET @ScopeBRN_CD = @BRN;

CREATE TABLE #BranchScope
(
    BRN_SYSID int NOT NULL PRIMARY KEY,
    BRN_CD varchar(10) NOT NULL,
    BRN_TYPE char(1) NULL,
    BRN_NAME varchar(100) NULL,
    BRN_STATUS varchar(2) NULL,
    BRN_HEAD_CODE varchar(10) NULL,
    BRN_MGR varchar(100) NULL,
    BRN_MGR_CODE varchar(20) NULL,
    DLR_CD varchar(10) NULL,
    Scope_Source varchar(20) NOT NULL
);

IF @UseIndividualBranch = 1
BEGIN
    INSERT INTO #BranchScope
    (
        BRN_SYSID, BRN_CD, BRN_TYPE, BRN_NAME, BRN_STATUS,
        BRN_HEAD_CODE, BRN_MGR, BRN_MGR_CODE, DLR_CD, Scope_Source
    )
    SELECT
        B.BRN_SYSID, B.BRN_CD, B.BRN_TYPE, B.BRN_NAME, B.BRN_STATUS,
        B.BRN_HEAD_CODE, B.BRN_MGR, B.BRN_MGR_CODE, B.DLR_CD, 'INPUT'
    FROM [MPS].[dbo].[BRN] B
    WHERE B.BRN_CD = @BRN;
END;
ELSE
BEGIN
    INSERT INTO #BranchScope
    (
        BRN_SYSID, BRN_CD, BRN_TYPE, BRN_NAME, BRN_STATUS,
        BRN_HEAD_CODE, BRN_MGR, BRN_MGR_CODE, DLR_CD, Scope_Source
    )
    SELECT
        B.BRN_SYSID,
        B.BRN_CD,
        B.BRN_TYPE,
        B.BRN_NAME,
        B.BRN_STATUS,
        B.BRN_HEAD_CODE,
        B.BRN_MGR,
        B.BRN_MGR_CODE,
        B.DLR_CD,
        CASE WHEN B.BRN_CD = @ScopeBRN_CD THEN 'MAIN' ELSE 'SUB_BRANCH' END
    FROM [MPS].[dbo].[BRN] B
    WHERE B.BRN_STATUS = 'A'
      AND
      (
          B.BRN_CD = @ScopeBRN_CD
          OR (B.BRN_TYPE = 'S' AND B.BRN_HEAD_CODE = @ScopeBRN_CD)
      );
END;

IF NOT EXISTS (SELECT 1 FROM #BranchScope)
    THROW 50004, 'No active branch rows were found for the requested branch scope.', 1;

CREATE TABLE #ApproverScope
(
    APPROVER_BRN_SYSID int NOT NULL,
    APPROVER_BRN_CD varchar(10) NOT NULL,
    APPROVER_USER_SYSID int NOT NULL,
    APPROVER_USER_NAME varchar(200) NULL,
    APPROVER_REP_SYSID int NOT NULL,
    PRIMARY KEY (APPROVER_BRN_SYSID, APPROVER_USER_SYSID, APPROVER_REP_SYSID)
);

INSERT INTO #ApproverScope
(
    APPROVER_BRN_SYSID,
    APPROVER_BRN_CD,
    APPROVER_USER_SYSID,
    APPROVER_USER_NAME,
    APPROVER_REP_SYSID
)
SELECT DISTINCT
    B.BRN_SYSID,
    B.BRN_CD,
    A.USER_SYSID,
    U.USR_NAME,
    ISNULL(A.REP_SYSID, 0)
FROM [MPS].[dbo].[BRN] B
JOIN #BranchScope BS ON BS.BRN_SYSID = B.BRN_SYSID
JOIN [MPS].[dbo].[CPL_APPROVER] A
    ON A.BRN_SYSID = B.BRN_SYSID
   AND A.PRIM_IND = 1
JOIN [MPS].[dbo].[SYS_USER_CD] U
    ON U.USER_SYSID = A.USER_SYSID
   AND U.BRN_SYSID <> 0
WHERE A.USER_SYSID IS NOT NULL;

/*
    Slim transaction population. The scalar risk/goal functions are intentionally
    not called here; they are evaluated only for final selected rows.
*/
CREATE TABLE #TransactionPopulation
(
    Client_ID int,
    Client_Name varchar(100),
    Client_Status varchar(2),
    Client_Setup datetime,
    Client_Stop datetime,
    Plan_Id int,
    PLN_CD varchar(10),
    Plan_Type varchar(100),
    Plan_Status varchar(1),
    Plan_Setup datetime,
    Plan_Close datetime,
    Plan_Last_Update datetime,
    Plan_KYC_Last_Update datetime,
    KYC_PLN_SYSID int,
    Rep_SYSID int,
    Rep_Name varchar(100),
    TRX_SYSID int NOT NULL PRIMARY KEY,
    ORD_SYSID bigint,
    BRN_SYSID int,
    IVD_SYSID int,
    Fund_Code varchar(20),
    Fund_Name varchar(100),
    Fund_Type varchar(5),
    LOAD_Type varchar(20),
    IVT_RISK_CD smallint,
    Product_Risk varchar(50),
    Dealer_Code char(4),
    Rep_Code varchar(15),
    TRADE_WATCH tinyint,
    Trade_type varchar(1),
    Trade_Date datetime,
    Settlement_Date datetime,
    Entry_Date datetime,
    TRX_CD smallint,
    Transaction_Type varchar(100),
    Gross_Amount float,
    Net_Amount float,
    AGE smallint,
    Jurisdiction varchar(20),
    Client_DOB datetime,
    ADMINISTRATOR varchar(50),
    ADMINISTRATOR_ACCOUNT varchar(30)
);

INSERT INTO #TransactionPopulation
(
    Client_ID, Client_Name, Client_Status, Client_Setup, Client_Stop,
    Plan_Id, PLN_CD, Plan_Type, Plan_Status, Plan_Setup, Plan_Close,
    Plan_Last_Update, Plan_KYC_Last_Update, KYC_PLN_SYSID,
    Rep_SYSID, Rep_Name, TRX_SYSID, ORD_SYSID, BRN_SYSID, IVD_SYSID,
    Fund_Code, Fund_Name, Fund_Type, LOAD_Type, IVT_RISK_CD, Product_Risk,
    Dealer_Code, Rep_Code, TRADE_WATCH, Trade_type, Trade_Date,
    Settlement_Date, Entry_Date, TRX_CD, Transaction_Type, Gross_Amount,
    Net_Amount, AGE, Jurisdiction, Client_DOB, ADMINISTRATOR,
    ADMINISTRATOR_ACCOUNT
)
SELECT
    T.IVR_SYSID,
    CASE
        WHEN ISNULL(I.IVR_PRIM_SIN, 0) = 0 THEN I.IVR_REG_2
        ELSE I.IVR_PRIM_LNAME + ', ' + I.IVR_PRIM_FNAME
    END,
    I.IVR_STATUS,
    I.IVR_SETUP_DT,
    I.IVR_STOP_DT,
    T.PLN_SYSID,
    P.PLN_CD,
    PC.PLN_DESC,
    P.PLN_STATUS,
    P.SETUP_DT,
    P.CLOSE_DT,
    P.LAST_UPD_DT,
    KP.CPL_UPD_DT,
    P.KYC_PLN_SYSID,
    R.REP_SYSID,
    R.REP_FNAME + ' ' + R.REP_LNAME,
    T.TRX_SYSID,
    T.ORD_SYSID,
    T.BRN_SYSID,
    T.IVD_SYSID,
    E.SYMBOL,
    IT.IVT_NAME_ENG,
    IT.IVT_TYPE,
    E.IVD_LOAD_FLAG,
    IR.IVT_RISK_CD,
    IR.IVT_RISK_DESC_ENG,
    I.DLR_CD,
    I.REP_CD,
    R.TRADE_WATCH,
    CASE WHEN T.TRX_WO_NUM IS NULL THEN 'D' ELSE 'W' END,
    T.TRADE_DT,
    T.SETTLE_DT,
    T.TRX_ENTRY_DT,
    T.TRX_CD,
    TC.TRX_DESC_ENG,
    T.TRX_GROSS,
    T.TRX_NET,
    CASE
        WHEN ISNULL(I.IVR_PRIM_BDT, '') <> ''
            THEN DATEDIFF(YEAR, I.IVR_PRIM_BDT, GETDATE())
        ELSE 0
    END,
    I.IVR_RES_CD,
    CASE WHEN ISNULL(I.IVR_PRIM_BDT, '') = '' THEN NULL ELSE I.IVR_PRIM_BDT END,
    P.PLN_ADM_CD,
    P.PLN_ADM_ACCT
FROM [MPS].[dbo].[TRX] T
JOIN #BranchScope BS ON BS.BRN_SYSID = T.BRN_SYSID
JOIN [MPS].[dbo].[S_TRX_CD] TC ON T.TRX_CD = TC.TRX_CD
JOIN [MPS].[dbo].[IVR] I ON T.IVR_SYSID = I.IVR_SYSID
JOIN [MPS].[dbo].[PLN] P ON T.PLN_SYSID = P.PLN_SYSID
JOIN [MPS].[dbo].[S_PLN_CD] PC ON P.PLN_CD = PC.PLN_CD
JOIN [MPS].[dbo].[IVD] E ON T.IVD_SYSID = E.IVD_SYSID
JOIN [MPS].[dbo].[IVT] IT ON E.IVT_SYSID = IT.IVT_SYSID
JOIN [MPS].[dbo].[REP] R ON I.REP_CD = R.REP_CD
OUTER APPLY
(
    SELECT TOP (1)
        KP.CPL_UPD_DT
    FROM [MPS].[dbo].[KYC_PLN] KP
    WHERE KP.KYC_PLN_SYSID = P.KYC_PLN_SYSID
    ORDER BY KP.CPL_UPD_DT DESC
) KP
LEFT JOIN [MPS].[dbo].[S_IVT_RISK] IR ON IR.IVT_RISK_CD = IT.IVT_RISK_CD
WHERE T.TRADE_DT >= @DateFrom
  AND T.TRADE_DT < @DateTo
  AND T.TRX_NET IS NOT NULL
  AND
  (
      T.TRX_CD IN
      (
          2111, 2211, 4611, 4711, 4911, 4910,
          7211, 7111, 7312, 7313, 7314, 7315,
          4511, 6511, 6611, 2260
      )
      OR EXISTS
      (
          SELECT 1
          FROM [MPS].[dbo].[PLN] PNA
          WHERE PNA.PLN_SYSID = T.PLN_SYSID
            AND PNA.SETUP_DT >= @DateFrom
            AND PNA.SETUP_DT < @DateTo
      )
  )
  AND IT.IVT_TYPE <> 'CMA'
  --AND
  --(
  --    IT.IVT_TYPE <> 'CMA'
  --    OR EXISTS
  --    (
  --        SELECT 1
  --        FROM [MPS].[dbo].[PLN] PNA
  --        WHERE PNA.PLN_SYSID = T.PLN_SYSID
  --          AND PNA.SETUP_DT >= @DateFrom
  --          AND PNA.SETUP_DT < @DateTo
  --    )
  --);
;

CREATE INDEX IX_TransactionPopulation_ORD ON #TransactionPopulation (ORD_SYSID);
CREATE INDEX IX_TransactionPopulation_Plan ON #TransactionPopulation (Plan_Id);

/* Combine and deduplicate the order snapshots. Archive wins for duplicate ORD_SYSID. */
;WITH CombinedOrders AS
(
    SELECT
        'SNAPSHOT' AS Order_Source,
        2 AS Source_Priority,
        SO.CPL_ORD_ID,
        SO.ORD_SYSID,
        SO.ORD_TRADE_DT,
        SO.ORD_AMT,
        SO.SNAPSHOT_ID,
        SO.TYPE AS Order_Type,
        SO.BRN_CD,
        SO.ENTRY_DATE,
        SO.CPL_TIER1,
        SO.CPL_TIER1_DESCN,
        SO.CPL_TIER1_ACTION,
        SO.CPL_TIER1_PRIM_IND,
        SO.CPL_TIER2,
        SO.CPL_TIER2_DESCN,
        SO.CPL_TIER2_ACTION
    FROM [MPS].[dbo].[SNAPSHOT_CPL_ORD] SO
    JOIN #BranchScope BS ON BS.BRN_CD = SO.BRN_CD
    WHERE SO.ENTRY_DATE >= @DateFrom
      AND SO.ENTRY_DATE < @DateTo

    UNION ALL

    SELECT
        'ARCHIVE' AS Order_Source,
        1 AS Source_Priority,
        SO.CPL_ORD_ID,
        SO.ORD_SYSID,
        SO.ORD_TRADE_DT,
        SO.ORD_AMT,
        SO.SNAPSHOT_ID,
        SO.TYPE AS Order_Type,
        SO.BRN_CD,
        SO.ENTRY_DATE,
        SO.CPL_TIER1,
        SO.CPL_TIER1_DESCN,
        SO.CPL_TIER1_ACTION,
        SO.CPL_TIER1_PRIM_IND,
        SO.CPL_TIER2,
        SO.CPL_TIER2_DESCN,
        SO.CPL_TIER2_ACTION
    FROM [MPS].[dbo].[ARC_SNAPSHOT_CPL_ORD] SO
    JOIN #BranchScope BS ON BS.BRN_CD = SO.BRN_CD
    WHERE SO.ENTRY_DATE >= @DateFrom
      AND SO.ENTRY_DATE < @DateTo
), DedupedOrders AS
(
    SELECT
        C.*,
        ROW_NUMBER() OVER
        (
            PARTITION BY C.ORD_SYSID
            ORDER BY
                C.Source_Priority ASC,
                C.SNAPSHOT_ID DESC,
                C.ENTRY_DATE DESC,
                C.CPL_ORD_ID DESC
        ) AS Order_Sequence
    FROM CombinedOrders C
)
SELECT
    D.Order_Source,
    D.CPL_ORD_ID,
    D.ORD_SYSID,
    D.ORD_TRADE_DT,
    D.ORD_AMT,
    D.SNAPSHOT_ID,
    D.Order_Type,
    D.BRN_CD,
    D.ENTRY_DATE,
    D.CPL_TIER1,
    D.CPL_TIER1_DESCN,
    D.CPL_TIER1_ACTION,
    D.CPL_TIER1_PRIM_IND,
    D.CPL_TIER2,
    D.CPL_TIER2_DESCN,
    D.CPL_TIER2_ACTION
INTO #OrderPopulation
FROM DedupedOrders D
WHERE D.Order_Sequence = 1
  AND D.ENTRY_DATE >= @DateFrom
  AND D.ENTRY_DATE < @DateTo;

CREATE INDEX IX_OrderPopulation_ORD ON #OrderPopulation (ORD_SYSID);

/*
    Approval filtering occurs before rule matching. No scalar KYC functions are
    called in this stage.
*/
SELECT
    T.*,
    O.Order_Source,
    O.CPL_ORD_ID,
    O.ORD_TRADE_DT,
    O.ORD_AMT,
    O.SNAPSHOT_ID,
    O.Order_Type,
    O.ENTRY_DATE AS Order_Entry_Date,
    O.CPL_TIER1 AS TIER1_REVIEWER_USER_SYSID,
    UT1.USR_NAME AS TIER1_REVIEWER_NAME,
    O.CPL_TIER1_ACTION AS BRANCH_REVIEW_ACTION,
    O.CPL_TIER1_DESCN AS BRANCH_REVIEW_DATE,
    O.CPL_TIER2_ACTION AS HO_REVIEW_ACTION,
    O.CPL_TIER2_DESCN AS HO_REVIEW_DATE,
    A.APPROVER_BRN_CD,
    A.APPROVER_USER_SYSID,
    A.APPROVER_USER_NAME,
    A.APPROVER_REP_SYSID,
    CASE WHEN A.APPROVER_USER_SYSID IS NOT NULL THEN 'BRANCH_MANAGER' ELSE 'NO_MATCH' END AS Approval_Classification
INTO #ApprovedPopulation
FROM #TransactionPopulation T
JOIN #OrderPopulation O
    ON O.ORD_SYSID = T.ORD_SYSID
JOIN #BranchScope BS
    ON BS.BRN_CD = O.BRN_CD
LEFT JOIN [MPS].[dbo].[SYS_USER_CD] UT1
    ON UT1.USER_SYSID = O.CPL_TIER1
OUTER APPLY
(
    SELECT TOP (1)
        A1.APPROVER_BRN_SYSID,
        A1.APPROVER_BRN_CD,
        A1.APPROVER_USER_SYSID,
        A1.APPROVER_USER_NAME,
        A1.APPROVER_REP_SYSID
    FROM #ApproverScope A1
    WHERE A1.APPROVER_BRN_SYSID = BS.BRN_SYSID
      AND A1.APPROVER_USER_SYSID = O.CPL_TIER1
      AND
      (
          A1.APPROVER_REP_SYSID = 0
          OR A1.APPROVER_REP_SYSID = T.Rep_SYSID
      )
    ORDER BY
        CASE WHEN A1.APPROVER_REP_SYSID = T.Rep_SYSID THEN 0 ELSE 1 END,
        A1.APPROVER_REP_SYSID
) A
WHERE O.CPL_TIER1 IS NOT NULL
  AND O.CPL_TIER1_PRIM_IND = 1
  AND A.APPROVER_USER_SYSID IS NOT NULL;

CREATE INDEX IX_ApprovedPopulation_Rep ON #ApprovedPopulation (Rep_Code, TRX_SYSID);
CREATE INDEX IX_ApprovedPopulation_Plan ON #ApprovedPopulation (Plan_Id);

DECLARE @SampleConfig TABLE
(
    Sample_Type varchar(20) NOT NULL PRIMARY KEY,
    Samples_Per_Rep int NOT NULL,
    Min_Branch_Trx int NOT NULL
);

INSERT INTO @SampleConfig (Sample_Type, Samples_Per_Rep, Min_Branch_Trx)
VALUES
    ('SUPERVISION', @SupervisionSamplesPerRep, @SupervisionMinBranchTrx),
    ('DIRECT', @DirectSamplesPerRep, @DirectMinBranchTrx),
    ('SENIOR', @SeniorSamplesPerRep, @SeniorMinBranchTrx),
    ('NEW_ACCOUNT', @NewAccountSamplesPerRep, @NewAccountMinBranchAccounts);

DECLARE @RuleConfig TABLE
(
    Rule_ID int NOT NULL PRIMARY KEY,
    Sample_Type varchar(20) NOT NULL,
    Rule_Rank int NOT NULL,
    Rule_SubRank int NULL,
    Min_Gross_Amount float NULL,
    Min_Age smallint NULL,
    Trade_Type char(1) NULL,
    Trade_Watch tinyint NULL,
    Rule_Description varchar(150) NOT NULL
);

DECLARE @RuleTrxCode TABLE
(
    Rule_ID int NOT NULL,
    TRX_CD smallint NOT NULL,
    PRIMARY KEY (Rule_ID, TRX_CD)
);

DECLARE @RuleRiskCode TABLE
(
    Rule_ID int NOT NULL,
    IVT_RISK_CD smallint NOT NULL,
    PRIMARY KEY (Rule_ID, IVT_RISK_CD)
);

DECLARE @RulePlanCode TABLE
(
    Rule_ID int NOT NULL,
    PLN_CD varchar(10) NOT NULL,
    PRIMARY KEY (Rule_ID, PLN_CD)
);

INSERT INTO @RuleConfig
(
    Rule_ID, Sample_Type, Rule_Rank, Rule_SubRank, Min_Gross_Amount,
    Min_Age, Trade_Type, Trade_Watch, Rule_Description
)
VALUES
    (101, 'SUPERVISION', 1, NULL, NULL, NULL, NULL, 1, 'Representative under supervision'),
    (102, 'SUPERVISION', 2, NULL, NULL, NULL, NULL, NULL, 'Leveraged account'),
    (103, 'SUPERVISION', 3, 1, 2500, NULL, NULL, NULL, 'Purchase higher risk $2,500+'),
    (104, 'SUPERVISION', 3, 2, 5000, NULL, NULL, NULL, 'Purchase medium risk $5,000+'),
    (105, 'SUPERVISION', 3, 3, 10000, NULL, NULL, NULL, 'Purchase $10,000+'),
    (106, 'SUPERVISION', 3, 4, 10000, NULL, NULL, NULL, 'Switch In $10,000+'),
    (107, 'SUPERVISION', 4, NULL, 10000, NULL, NULL, NULL, 'Redemption $10,000+'),
    (201, 'DIRECT', 1, NULL, NULL, NULL, 'D', NULL, 'Non-wired purchase'),
    (202, 'DIRECT', 2, NULL, NULL, NULL, 'D', NULL, 'Non-wired redemption'),
    (203, 'DIRECT', 3, NULL, NULL, NULL, 'D', NULL, 'Non-wired switch'),
    (301, 'SENIOR', 1, NULL, NULL, 70, NULL, NULL, 'Senior purchase'),
    (302, 'SENIOR', 2, NULL, NULL, 70, NULL, NULL, 'Senior redemption'),
    (303, 'SENIOR', 3, NULL, NULL, 70, NULL, NULL, 'Senior switch');

INSERT INTO @RuleTrxCode (Rule_ID, TRX_CD)
VALUES
    (103, 2111), (103, 2211),
    (104, 2111), (104, 2211),
    (105, 2111), (105, 2211),
    (106, 4611), (106, 4711), (106, 4911), (106, 4910),
    (107, 7211), (107, 7111), (107, 7312), (107, 7313), (107, 7314), (107, 7315),
    (201, 2111), (201, 2211),
    (202, 7211), (202, 7111), (202, 7312), (202, 7313), (202, 7314), (202, 7315),
    (203, 4511), (203, 4611), (203, 6511), (203, 6611), (203, 2260),
    (301, 2111), (301, 2211),
    (302, 7211), (302, 7111), (302, 7312), (302, 7313), (302, 7314), (302, 7315),
    (303, 4511), (303, 4611), (303, 6511), (303, 6611), (303, 2260);

INSERT INTO @RuleRiskCode (Rule_ID, IVT_RISK_CD)
VALUES
    (103, 35), (103, 40), (103, 45), (103, 50), (103, 100),
    (104, 30);

INSERT INTO @RulePlanCode (Rule_ID, PLN_CD)
VALUES
    (102, '41'), (102, '18');

DECLARE @CandidateMatches TABLE
(
    Sample_Type varchar(20) NOT NULL,
    TRX_SYSID int NOT NULL,
    Rep_Code varchar(15) NULL,
    Rule_ID int NOT NULL,
    Rule_Rank int NOT NULL,
    Rule_SubRank int NULL,
    PRIMARY KEY (Sample_Type, TRX_SYSID)
);

;WITH MatchingRules AS
(
    SELECT
        R.Sample_Type,
        T.TRX_SYSID,
        T.Rep_Code,
        R.Rule_ID,
        R.Rule_Rank,
        R.Rule_SubRank,
        ROW_NUMBER() OVER
        (
            PARTITION BY R.Sample_Type, T.TRX_SYSID
            ORDER BY R.Rule_Rank ASC, R.Rule_SubRank ASC, R.Rule_ID ASC
        ) AS Rule_Sequence
    FROM #ApprovedPopulation T
    JOIN @RuleConfig R
        ON (R.Trade_Type IS NULL OR R.Trade_Type = T.Trade_type)
       AND (R.Trade_Watch IS NULL OR R.Trade_Watch = T.TRADE_WATCH)
       AND (R.Min_Gross_Amount IS NULL OR T.Gross_Amount >= R.Min_Gross_Amount)
       AND (R.Min_Age IS NULL OR T.AGE >= R.Min_Age)
    WHERE
        (
            NOT EXISTS (SELECT 1 FROM @RuleTrxCode X WHERE X.Rule_ID = R.Rule_ID)
            OR EXISTS
            (
                SELECT 1 FROM @RuleTrxCode X
                WHERE X.Rule_ID = R.Rule_ID
                  AND X.TRX_CD = T.TRX_CD
            )
        )
        AND
        (
            NOT EXISTS (SELECT 1 FROM @RuleRiskCode X WHERE X.Rule_ID = R.Rule_ID)
            OR EXISTS
            (
                SELECT 1 FROM @RuleRiskCode X
                WHERE X.Rule_ID = R.Rule_ID
                  AND X.IVT_RISK_CD = T.IVT_RISK_CD
            )
        )
        AND
        (
            NOT EXISTS (SELECT 1 FROM @RulePlanCode X WHERE X.Rule_ID = R.Rule_ID)
            OR EXISTS
            (
                SELECT 1 FROM @RulePlanCode X
                WHERE X.Rule_ID = R.Rule_ID
                  AND X.PLN_CD = T.PLN_CD
            )
        )
)
INSERT INTO @CandidateMatches
(
    Sample_Type, TRX_SYSID, Rep_Code, Rule_ID, Rule_Rank, Rule_SubRank
)
SELECT
    M.Sample_Type,
    M.TRX_SYSID,
    M.Rep_Code,
    M.Rule_ID,
    M.Rule_Rank,
    M.Rule_SubRank
FROM MatchingRules M
WHERE M.Rule_Sequence = 1;

;WITH NewAccountTransactions AS
(
    SELECT
        T.TRX_SYSID,
        T.Rep_Code,
        T.Plan_Id,
        ROW_NUMBER() OVER
        (
            PARTITION BY T.Plan_Id
            ORDER BY T.Trade_Date ASC, T.TRX_SYSID ASC
        ) AS Initial_Transaction_Sequence
    FROM #ApprovedPopulation T
    JOIN [MPS].[dbo].[PLN] P ON P.PLN_SYSID = T.Plan_Id
    WHERE P.SETUP_DT >= @DateFrom
      AND P.SETUP_DT < @DateTo
)
INSERT INTO @CandidateMatches
(
    Sample_Type, TRX_SYSID, Rep_Code, Rule_ID, Rule_Rank, Rule_SubRank
)
SELECT
    'NEW_ACCOUNT',
    N.TRX_SYSID,
    N.Rep_Code,
    401,
    1,
    NULL
FROM NewAccountTransactions N
WHERE N.Initial_Transaction_Sequence = 1;

DECLARE @EligibleSampleTypes TABLE
(
    Sample_Type varchar(20) NOT NULL PRIMARY KEY
);

INSERT INTO @EligibleSampleTypes (Sample_Type)
SELECT C.Sample_Type
FROM @CandidateMatches C
JOIN @SampleConfig S ON S.Sample_Type = C.Sample_Type
GROUP BY C.Sample_Type, S.Min_Branch_Trx
HAVING COUNT(*) >= S.Min_Branch_Trx;

;WITH RankedCandidates AS
(
    SELECT
        C.Sample_Type,
        C.TRX_SYSID,
        C.Rep_Code,
        C.Rule_ID,
        C.Rule_Rank,
        C.Rule_SubRank,
        T.Gross_Amount,
        ROW_NUMBER() OVER
        (
            PARTITION BY C.Sample_Type, C.Rep_Code
            ORDER BY
                C.Rule_Rank ASC,
                C.Rule_SubRank ASC,
                T.Gross_Amount DESC,
                C.TRX_SYSID ASC
        ) AS Sample_Sequence
    FROM @CandidateMatches C
    JOIN #ApprovedPopulation T ON T.TRX_SYSID = C.TRX_SYSID
    JOIN @EligibleSampleTypes E ON E.Sample_Type = C.Sample_Type
), SelectedSamples AS
(
    SELECT R.*
    FROM RankedCandidates R
    JOIN @SampleConfig S ON S.Sample_Type = R.Sample_Type
    WHERE R.Sample_Sequence <= S.Samples_Per_Rep
)
SELECT
    @BRN AS Requested_BRN_CD,
    @RequestedBRN_NAME AS Requested_BRN_NAME,
    @RequestedBRN_STATUS AS Requested_BRN_STATUS,
    @RequestedBRN_MGR AS Requested_BRN_MGR,
    @RequestedDLR_CD AS Requested_DLR_CD,
    BS.BRN_CD,
    BS.BRN_NAME,
    BS.BRN_STATUS,
    BS.BRN_MGR,
    BS.DLR_CD,
    @DateFrom AS Sample_Date_From,
    @DateTo AS Sample_Date_To,
    T.Client_ID,
    T.Client_Name,
    T.Client_Status,
    T.Client_Setup,
    T.Client_Stop,
    T.Plan_Id,
    T.Plan_Type,
    T.Plan_Status,
    T.Plan_Setup,
    T.Plan_Close,
    T.Plan_Last_Update,
    T.Plan_KYC_Last_Update,
    T.Rep_Name,
    T.TRX_SYSID,
    T.IVD_SYSID,
    T.Fund_Code,
    T.Fund_Name,
    T.Fund_Type,
    T.LOAD_Type,
    ISNULL(AC.CIFSC_LINK, '') AS CIFSC_Cat,
    T.IVT_RISK_CD,
    T.Product_Risk,
    T.Dealer_Code,
    T.Rep_Code,
    T.TRADE_WATCH,
    T.Trade_type,
    T.Trade_Date,
    T.Settlement_Date,
    T.Entry_Date,
    T.Transaction_Type,
    T.Gross_Amount,
    T.Net_Amount,
    T.AGE,
    K_SALARY.SALARY_DESC_ENG AS Personal_Income,
    NW.NET_WORTH_DESC_ENG AS Net_Worth,
    CASE LTRIM(RTRIM(K.IVR_INV_KNOW))
        WHEN 'N' THEN 'Poor'
        WHEN 'M' THEN 'Fair'
        WHEN 'H' THEN 'Good'
        WHEN 'E' THEN 'Excellent'
        ELSE LTRIM(RTRIM(K.IVR_INV_KNOW))
    END AS Investment_Knowledge,
    dbo.ufn_GetMPSPlanRisks(T.KYC_PLN_SYSID, '10') AS RISK_LOW,
    dbo.ufn_GetMPSPlanRisks(T.KYC_PLN_SYSID, '20') AS RISK_LOW_TO_MEDIUM,
    dbo.ufn_GetMPSPlanRisks(T.KYC_PLN_SYSID, '40') AS RISK_MEDIUM,
    dbo.ufn_GetMPSPlanRisks(T.KYC_PLN_SYSID, '60') AS RISK_MEDIUM_TO_HIGH,
    dbo.ufn_GetMPSPlanRisks(T.KYC_PLN_SYSID, '80') AS RISK_HIGH,
    dbo.ufn_GetMPSPlanGoals(T.KYC_PLN_SYSID, 'L') AS OBJ_SEC_CAPITAL,
    dbo.ufn_GetMPSPlanGoals(T.KYC_PLN_SYSID, 'I') AS OBJ_INCOME,
    dbo.ufn_GetMPSPlanGoals(T.KYC_PLN_SYSID, 'G') AS OBJ_GROWTH,
    dbo.ufn_GetMPSPlanGoals(T.KYC_PLN_SYSID, 'M') AS OBJ_MAX_GROWTH,
    0 AS OBJ_LONG_TERM,
    dbo.ufn_GetMPSPlanGoals(T.KYC_PLN_SYSID, 'S') AS OBJ_SPECULATIVE,
    0 AS OBJ_MEDIUM,
    TH.KYC_TH_DESC_ENG AS TIME_HORIZON,
    T.Jurisdiction,
    T.Client_DOB,
    T.ADMINISTRATOR,
    T.ADMINISTRATOR_ACCOUNT,
    T.Order_Source,
    T.CPL_ORD_ID,
    T.ORD_SYSID,
    T.ORD_TRADE_DT,
    T.ORD_AMT,
    T.SNAPSHOT_ID,
    T.Order_Type,
    T.Order_Entry_Date,
    T.TIER1_REVIEWER_USER_SYSID,
    T.TIER1_REVIEWER_NAME,
    T.APPROVER_BRN_CD,
    T.APPROVER_USER_SYSID,
    T.APPROVER_USER_NAME,
    T.APPROVER_REP_SYSID,
    T.Approval_Classification,
    T.BRANCH_REVIEW_ACTION,
    T.BRANCH_REVIEW_DATE,
    T.HO_REVIEW_ACTION,
    T.HO_REVIEW_DATE,
    S.Sample_Type,
    S.Rule_Rank AS Selection_Rank,
    S.Rule_SubRank AS Selection_SubRank,
    COALESCE(RC.Rule_Description, 'New account initial transaction') AS Selection_Rule,
    S.Sample_Sequence
FROM SelectedSamples S
JOIN #ApprovedPopulation T ON T.TRX_SYSID = S.TRX_SYSID
JOIN #BranchScope BS ON BS.BRN_SYSID = T.BRN_SYSID
LEFT JOIN [MPS].[dbo].[IVD] E ON E.IVD_SYSID = T.IVD_SYSID
LEFT JOIN [MPS].[dbo].[IVT] IT ON IT.IVT_SYSID = E.IVT_SYSID
LEFT JOIN [MPS].[dbo].[S_ASSET_CLASS] AC ON AC.ASSET_CLASS = IT.ASSET_CLASS
LEFT JOIN [MPS].[dbo].[KYC] K ON K.IVR_SYSID = T.Client_ID
LEFT JOIN [MPS].[dbo].[S_SALARY] K_SALARY ON K_SALARY.SALARY_CD = K.SALARY_CD
LEFT JOIN [MPS].[dbo].[S_NET_WORTH] NW ON NW.NET_WORTH_CD = K.NET_WORTH_CD
LEFT JOIN [MPS].[dbo].[S_KYC_TIME_HORIZON] TH ON TH.KYC_TH_CD =
(
    SELECT TOP (1) KP.TIME_HORIZON_CD
    FROM [MPS].[dbo].[KYC_PLN] KP
    WHERE KP.KYC_PLN_SYSID = T.KYC_PLN_SYSID
    ORDER BY KP.CPL_UPD_DT DESC
)
LEFT JOIN @RuleConfig RC ON RC.Rule_ID = S.Rule_ID
ORDER BY
    S.Sample_Type,
    T.Rep_Code,
    S.Sample_Sequence;

DROP TABLE #ApprovedPopulation;
DROP TABLE #OrderPopulation;
DROP TABLE #TransactionPopulation;
DROP TABLE #ApproverScope;
DROP TABLE #BranchScope;
