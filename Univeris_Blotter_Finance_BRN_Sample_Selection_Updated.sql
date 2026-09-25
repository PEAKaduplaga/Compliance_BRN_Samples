/*
    Updated modular BRN transaction sampling procedure.

    This version keeps the existing procedure untouched and incorporates:
      - BRN_CD input with GROUP/INDIVIDUAL branch scope override.
      - Main-branch and sub-branch population resolution.
      - Rolling twelve-month filtering using TRADE_DT and GETDATE().
      - CMA exclusion, with the prior exception logic preserved as comments.
      - Snapshot and archive compliance-order population with explicit deduplication.
      - Tier-1 branch-approver filtering and approver enrichment.
      - Configurable sample quantities.
      - Updated supervision ranks and rank-3 subranks.

    Validate the source column types in the target environment before deployment.
*/
CREATE OR ALTER PROCEDURE [dbo].[PEAK_COMPLIANCE_SP_UVS_BRN_SAMPLE_TRX]
    @BRN varchar(10),
    @BRN_OVERRIDE bit = 0
AS
BEGIN
    SET NOCOUNT ON;

    /* Sampling controls. Keep these local so they can later become parameters or table-driven rules. */
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

    DECLARE @InputBRN_SYSID int;
    DECLARE @InputBRN_TYPE char(1);
    DECLARE @InputBRN_HEAD_CODE varchar(10);
    DECLARE @BRN_NAME varchar(100);
    DECLARE @BRN_STATUS varchar(2);
    DECLARE @BRN_MGR varchar(100);
    DECLARE @DLR_CD varchar(10);
    DECLARE @ScopeBRN_CD varchar(10);

    SELECT
        @InputBRN_SYSID = B.BRN_SYSID,
        @InputBRN_TYPE = B.BRN_TYPE,
        @InputBRN_HEAD_CODE = NULLIF(LTRIM(RTRIM(B.BRN_HEAD_CODE)), ''),
        @BRN_NAME = B.BRN_NAME,
        @BRN_STATUS = B.BRN_STATUS,
        @BRN_MGR = B.BRN_MGR,
        @DLR_CD = B.DLR_CD
    FROM [MPS].[dbo].[BRN] B
    WHERE B.BRN_CD = @BRN;

    IF @InputBRN_SYSID IS NULL
        THROW 50001, 'The supplied BRN_CD was not found in MPS.dbo.BRN.', 1;

    IF @BRN_OVERRIDE = 1
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

    IF @BRN_OVERRIDE = 1
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

    /* Primary tier-1 approver records for every branch in the resolved scope. */
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
    JOIN #BranchScope BS
        ON BS.BRN_SYSID = B.BRN_SYSID
    JOIN [MPS].[dbo].[CPL_APPROVER] A
        ON A.BRN_SYSID = B.BRN_SYSID
       AND A.PRIM_IND = 1
    JOIN [MPS].[dbo].[SYS_USER_CD] U
        ON U.USER_SYSID = A.USER_SYSID
       AND U.BRN_SYSID <> 0
    WHERE A.USER_SYSID IS NOT NULL;

    /* Internal preselection population. Final output columns are selected explicitly below. */
    CREATE TABLE #tmpReport
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
        CIFSC_Cat varchar(5),
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
        Dealer_Commission float,
        DSC float,
        TRX_COMM float,
        TRX_COMM_PCNT float,
        AGE smallint,
        Personal_Income varchar(30),
        Net_Worth varchar(30),
        Investment_Knowledge varchar(15),
        RISK_LOW smallint,
        RISK_LOW_TO_MEDIUM smallint,
        RISK_MEDIUM smallint,
        RISK_MEDIUM_TO_HIGH smallint,
        RISK_HIGH smallint,
        OBJ_SEC_CAPITAL smallint,
        OBJ_INCOME smallint,
        OBJ_GROWTH smallint,
        OBJ_MAX_GROWTH smallint,
        OBJ_LONG_TERM smallint,
        OBJ_SPECULATIVE smallint,
        OBJ_MEDIUM smallint,
        TIME_HORIZON varchar(50),
        Jurisdiction varchar(20),
        Client_DOB datetime,
        ADMINISTRATOR varchar(50),
        ADMINISTRATOR_ACCOUNT varchar(30),
        ENTRY_USER varchar(100)
    );

    INSERT INTO #tmpReport
    (
        Client_ID, Client_Name, Client_Status, Client_Setup, Client_Stop,
        Plan_Id, PLN_CD, Plan_Type, Rep_SYSID, Rep_Code, Rep_Name,
        TRADE_WATCH, Trade_type, TRX_SYSID, ORD_SYSID, BRN_SYSID, IVD_SYSID,
        Fund_Code, Fund_Name, Fund_Type, LOAD_Type, IVT_RISK_CD, Product_Risk,
        Dealer_Code, Trade_Date, Settlement_Date, Entry_Date, TRX_CD,
        Transaction_Type, Gross_Amount, Net_Amount, Dealer_Commission, DSC,
        TRX_COMM, TRX_COMM_PCNT, AGE, Jurisdiction, Client_DOB,
        ADMINISTRATOR, ADMINISTRATOR_ACCOUNT, ENTRY_USER
    )
    SELECT
        T.IVR_SYSID,
        CASE
            WHEN ISNULL(I.IVR_PRIM_SIN, 0) = 0
                THEN I.IVR_REG_2
            ELSE I.IVR_PRIM_LNAME + ', ' + I.IVR_PRIM_FNAME
        END,
        I.IVR_STATUS,
        I.IVR_SETUP_DT,
        I.IVR_STOP_DT,
        T.PLN_SYSID,
        P.PLN_CD,
        PC.PLN_DESC,
        R.REP_SYSID,
        I.REP_CD,
        R.REP_FNAME + ' ' + R.REP_LNAME,
        R.TRADE_WATCH,
        CASE WHEN T.TRX_WO_NUM IS NULL THEN 'D' ELSE 'W' END,
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
        T.TRADE_DT,
        T.SETTLE_DT,
        T.TRX_ENTRY_DT,
        T.TRX_CD,
        TC.TRX_DESC_ENG,
        T.TRX_GROSS,
        T.TRX_NET,
        T.TRX_DSC_COMM,
        T.TRX_WTH_DSC,
        T.TRX_COMM,
        T.TRX_COMM_PCNT,
        CASE
            WHEN ISNULL(I.IVR_PRIM_BDT, '') <> ''
                THEN DATEDIFF(YEAR, I.IVR_PRIM_BDT, GETDATE())
            ELSE 0
        END,
        I.IVR_RES_CD,
        CASE WHEN ISNULL(I.IVR_PRIM_BDT, '') = '' THEN NULL ELSE I.IVR_PRIM_BDT END,
        P.PLN_ADM_CD,
        P.PLN_ADM_ACCT,
        CASE WHEN ISNULL(T.ENTRY_SYSID, '') = '' THEN 'Univeris Batch User' ELSE U.USR_NAME END
    FROM [MPS].[dbo].[TRX] T
    JOIN #BranchScope BS
        ON BS.BRN_SYSID = T.BRN_SYSID
    JOIN [MPS].[dbo].[S_TRX_CD] TC
        ON T.TRX_CD = TC.TRX_CD
    JOIN [MPS].[dbo].[IVR] I
        ON T.IVR_SYSID = I.IVR_SYSID
    JOIN [MPS].[dbo].[PLN] P
        ON T.PLN_SYSID = P.PLN_SYSID
    JOIN [MPS].[dbo].[S_PLN_CD] PC
        ON P.PLN_CD = PC.PLN_CD
    JOIN [MPS].[dbo].[IVD] E
        ON T.IVD_SYSID = E.IVD_SYSID
    JOIN [MPS].[dbo].[IVT] IT
        ON E.IVT_SYSID = IT.IVT_SYSID
    JOIN [MPS].[dbo].[REP] R
        ON I.REP_CD = R.REP_CD
    LEFT JOIN [MPS].[dbo].[SYS_USER_CD] U
        ON T.ENTRY_SYSID = U.USER_SYSID
    LEFT JOIN [MPS].[dbo].[S_IVT_RISK] IR
        ON IR.IVT_RISK_CD = IT.IVT_RISK_CD
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
      /* CMA transactions remain excluded from the sampling population. */
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
      --)
      ;

    CREATE INDEX IX_tmpReport_Plan ON #tmpReport (Plan_Id);

    UPDATE A
       SET A.CIFSC_Cat = ISNULL(AC.CIFSC_LINK, '')
    FROM #tmpReport A
    JOIN [MPS].[dbo].[IVD] B ON A.IVD_SYSID = B.IVD_SYSID
    JOIN [MPS].[dbo].[IVT] C ON B.IVT_SYSID = C.IVT_SYSID
    JOIN [MPS].[dbo].[S_ASSET_CLASS] AC ON C.ASSET_CLASS = AC.ASSET_CLASS;

    UPDATE A
       SET A.Personal_Income = S.SALARY_DESC_ENG,
           A.Net_Worth = NW.NET_WORTH_DESC_ENG,
           A.Investment_Knowledge =
                CASE LTRIM(RTRIM(K.IVR_INV_KNOW))
                    WHEN 'N' THEN 'Poor'
                    WHEN 'M' THEN 'Fair'
                    WHEN 'H' THEN 'Good'
                    WHEN 'E' THEN 'Excellent'
                    ELSE LTRIM(RTRIM(K.IVR_INV_KNOW))
                END,
           A.RISK_LOW = dbo.ufn_GetMPSPlanRisks(P.KYC_PLN_SYSID, '10'),
           A.RISK_LOW_TO_MEDIUM = dbo.ufn_GetMPSPlanRisks(P.KYC_PLN_SYSID, '20'),
           A.RISK_MEDIUM = dbo.ufn_GetMPSPlanRisks(P.KYC_PLN_SYSID, '40'),
           A.RISK_MEDIUM_TO_HIGH = dbo.ufn_GetMPSPlanRisks(P.KYC_PLN_SYSID, '60'),
           A.RISK_HIGH = dbo.ufn_GetMPSPlanRisks(P.KYC_PLN_SYSID, '80'),
           A.OBJ_SEC_CAPITAL = dbo.ufn_GetMPSPlanGoals(P.KYC_PLN_SYSID, 'L'),
           A.OBJ_INCOME = dbo.ufn_GetMPSPlanGoals(P.KYC_PLN_SYSID, 'I'),
           A.OBJ_GROWTH = dbo.ufn_GetMPSPlanGoals(P.KYC_PLN_SYSID, 'G'),
           A.OBJ_MAX_GROWTH = dbo.ufn_GetMPSPlanGoals(P.KYC_PLN_SYSID, 'M'),
           A.OBJ_LONG_TERM = 0,
           A.OBJ_SPECULATIVE = dbo.ufn_GetMPSPlanGoals(P.KYC_PLN_SYSID, 'S'),
           A.OBJ_MEDIUM = 0,
           A.TIME_HORIZON = TH.KYC_TH_DESC_ENG,
           A.Plan_Setup = P.SETUP_DT,
           A.Plan_Close = P.CLOSE_DT,
           A.Plan_Last_Update = P.LAST_UPD_DT,
           A.Plan_KYC_Last_Update = KP.CPL_UPD_DT,
           A.Plan_Status = P.PLN_STATUS
    FROM #tmpReport A
    JOIN [MPS].[dbo].[PLN] P ON A.Plan_Id = P.PLN_SYSID
    LEFT JOIN [MPS].[dbo].[KYC] K ON A.Client_ID = K.IVR_SYSID
    LEFT JOIN [MPS].[dbo].[KYC_PLN] KP ON P.KYC_PLN_SYSID = KP.KYC_PLN_SYSID
    LEFT JOIN [MPS].[dbo].[S_SALARY] S ON K.SALARY_CD = S.SALARY_CD
    LEFT JOIN [MPS].[dbo].[S_NET_WORTH] NW ON K.NET_WORTH_CD = NW.NET_WORTH_CD
    LEFT JOIN [MPS].[dbo].[S_KYC_TIME_HORIZON] TH ON KP.TIME_HORIZON_CD = TH.KYC_TH_CD;

    /*
        Combine current and archive order snapshots with UNION ALL, then deduplicate.
        The archive record wins when the same ORD_SYSID exists in both sources.
    */
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
            SO.PLN_SYSID,
            SO.PLN_LEVERAGED,
            SO.PLN_LTA,
            SO.PLN_TRADE_WATCH,
            SO.REP_TRADE_WATCH,
            SO.REP_CD,
            SO.BRN_CD,
            SO.DLR_CD,
            SO.RGN_CD,
            SO.ENTRY_DATE,
            SO.ORD_DIRECT,
            SO.CPL_TIER1,
            SO.CPL_TIER1_DESCN,
            SO.CPL_TIER1_ACTION,
            SO.CPL_TIER1_PRIM_IND,
            SO.CPL_TIER2,
            SO.CPL_TIER2_DESCN,
            SO.CPL_TIER2_ACTION
        FROM [MPS].[dbo].[SNAPSHOT_CPL_ORD] SO

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
            SO.PLN_SYSID,
            SO.PLN_LEVERAGED,
            SO.PLN_LTA,
            SO.PLN_TRADE_WATCH,
            SO.REP_TRADE_WATCH,
            SO.REP_CD,
            SO.BRN_CD,
            SO.DLR_CD,
            SO.RGN_CD,
            SO.ENTRY_DATE,
            SO.ORD_DIRECT,
            SO.CPL_TIER1,
            SO.CPL_TIER1_DESCN,
            SO.CPL_TIER1_ACTION,
            SO.CPL_TIER1_PRIM_IND,
            SO.CPL_TIER2,
            SO.CPL_TIER2_DESCN,
            SO.CPL_TIER2_ACTION
        FROM [MPS].[dbo].[ARC_SNAPSHOT_CPL_ORD] SO
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
        D.PLN_SYSID,
        D.PLN_LEVERAGED,
        D.PLN_LTA,
        D.PLN_TRADE_WATCH,
        D.REP_TRADE_WATCH,
        D.REP_CD,
        D.BRN_CD,
        D.DLR_CD,
        D.RGN_CD,
        D.ENTRY_DATE,
        D.ORD_DIRECT,
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

    CREATE INDEX IX_OrderPopulation_Ord ON #OrderPopulation (ORD_SYSID);

    /* Keep only preselected transactions with a matching tier-1 branch approver. */
    ;WITH ApprovedOrders AS
    (
        SELECT
            T.TRX_SYSID,
            T.Rep_SYSID,
            O.Order_Source,
            O.CPL_ORD_ID,
            O.ORD_SYSID,
            O.ORD_TRADE_DT,
            O.ORD_AMT,
            O.SNAPSHOT_ID,
            O.Order_Type,
            O.ENTRY_DATE AS Order_Entry_Date,
            O.CPL_TIER1 AS TIER1_REVIEWER_USER_SYSID,
            UT1.USR_NAME AS TIER1_REVIEWER_NAME,
            O.CPL_TIER1_PRIM_IND,
            O.CPL_TIER1_ACTION AS BRANCH_REVIEW_ACTION,
            O.CPL_TIER1_DESCN AS BRANCH_REVIEW_DATE,
            O.CPL_TIER2_ACTION AS HO_REVIEW_ACTION,
            O.CPL_TIER2_DESCN AS HO_REVIEW_DATE,
            A.APPROVER_BRN_SYSID,
            A.APPROVER_BRN_CD,
            A.APPROVER_USER_SYSID,
            A.APPROVER_USER_NAME,
            A.APPROVER_REP_SYSID,
            CASE
                WHEN A.APPROVER_USER_SYSID IS NOT NULL THEN 'BRANCH_MANAGER'
                ELSE 'NO_MATCH'
            END AS Approval_Classification
        FROM #tmpReport T
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
    )
    SELECT *
    INTO #SamplePopulation
    FROM ApprovedOrders
    WHERE APPROVER_USER_SYSID IS NOT NULL;

    /* Add the transaction detail to the approved-order population. */
    ALTER TABLE #SamplePopulation ADD
        Client_ID int NULL,
        Client_Name varchar(100) NULL,
        Client_Status varchar(2) NULL,
        Client_Setup datetime NULL,
        Client_Stop datetime NULL,
        Plan_Id int NULL,
        PLN_CD varchar(10) NULL,
        Plan_Type varchar(100) NULL,
        Plan_Status varchar(1) NULL,
        Plan_Setup datetime NULL,
        Plan_Close datetime NULL,
        Plan_Last_Update datetime NULL,
        Plan_KYC_Last_Update datetime NULL,
        Rep_Code varchar(15) NULL,
        Rep_Name varchar(100) NULL,
        BRN_SYSID int NULL,
        IVD_SYSID int NULL,
        Fund_Code varchar(20) NULL,
        Fund_Name varchar(100) NULL,
        Fund_Type varchar(5) NULL,
        LOAD_Type varchar(20) NULL,
        CIFSC_Cat varchar(5) NULL,
        IVT_RISK_CD smallint NULL,
        Product_Risk varchar(50) NULL,
        Dealer_Code char(4) NULL,
        TRADE_WATCH tinyint NULL,
        Trade_type varchar(1) NULL,
        Trade_Date datetime NULL,
        Settlement_Date datetime NULL,
        Entry_Date datetime NULL,
        TRX_CD smallint NULL,
        Transaction_Type varchar(100) NULL,
        Gross_Amount float NULL,
        Net_Amount float NULL,
        AGE smallint NULL,
        Personal_Income varchar(30) NULL,
        Net_Worth varchar(30) NULL,
        Investment_Knowledge varchar(15) NULL,
        RISK_LOW smallint NULL,
        RISK_LOW_TO_MEDIUM smallint NULL,
        RISK_MEDIUM smallint NULL,
        RISK_MEDIUM_TO_HIGH smallint NULL,
        RISK_HIGH smallint NULL,
        OBJ_SEC_CAPITAL smallint NULL,
        OBJ_INCOME smallint NULL,
        OBJ_GROWTH smallint NULL,
        OBJ_MAX_GROWTH smallint NULL,
        OBJ_LONG_TERM smallint NULL,
        OBJ_SPECULATIVE smallint NULL,
        OBJ_MEDIUM smallint NULL,
        TIME_HORIZON varchar(50) NULL,
        Jurisdiction varchar(20) NULL,
        Client_DOB datetime NULL,
        ADMINISTRATOR varchar(50) NULL,
        ADMINISTRATOR_ACCOUNT varchar(30) NULL;

    UPDATE S
       SET S.Client_ID = T.Client_ID,
           S.Client_Name = T.Client_Name,
           S.Client_Status = T.Client_Status,
           S.Client_Setup = T.Client_Setup,
           S.Client_Stop = T.Client_Stop,
           S.Plan_Id = T.Plan_Id,
           S.PLN_CD = T.PLN_CD,
           S.Plan_Type = T.Plan_Type,
           S.Plan_Status = T.Plan_Status,
           S.Plan_Setup = T.Plan_Setup,
           S.Plan_Close = T.Plan_Close,
           S.Plan_Last_Update = T.Plan_Last_Update,
           S.Plan_KYC_Last_Update = T.Plan_KYC_Last_Update,
           S.Rep_Code = T.Rep_Code,
           S.Rep_Name = T.Rep_Name,
           S.BRN_SYSID = T.BRN_SYSID,
           S.IVD_SYSID = T.IVD_SYSID,
           S.Fund_Code = T.Fund_Code,
           S.Fund_Name = T.Fund_Name,
           S.Fund_Type = T.Fund_Type,
           S.LOAD_Type = T.LOAD_Type,
           S.CIFSC_Cat = T.CIFSC_Cat,
           S.IVT_RISK_CD = T.IVT_RISK_CD,
           S.Product_Risk = T.Product_Risk,
           S.Dealer_Code = T.Dealer_Code,
           S.TRADE_WATCH = T.TRADE_WATCH,
           S.Trade_type = T.Trade_type,
           S.Trade_Date = T.Trade_Date,
           S.Settlement_Date = T.Settlement_Date,
           S.Entry_Date = T.Entry_Date,
           S.TRX_CD = T.TRX_CD,
           S.Transaction_Type = T.Transaction_Type,
           S.Gross_Amount = T.Gross_Amount,
           S.Net_Amount = T.Net_Amount,
           S.AGE = T.AGE,
           S.Personal_Income = T.Personal_Income,
           S.Net_Worth = T.Net_Worth,
           S.Investment_Knowledge = T.Investment_Knowledge,
           S.RISK_LOW = T.RISK_LOW,
           S.RISK_LOW_TO_MEDIUM = T.RISK_LOW_TO_MEDIUM,
           S.RISK_MEDIUM = T.RISK_MEDIUM,
           S.RISK_MEDIUM_TO_HIGH = T.RISK_MEDIUM_TO_HIGH,
           S.RISK_HIGH = T.RISK_HIGH,
           S.OBJ_SEC_CAPITAL = T.OBJ_SEC_CAPITAL,
           S.OBJ_INCOME = T.OBJ_INCOME,
           S.OBJ_GROWTH = T.OBJ_GROWTH,
           S.OBJ_MAX_GROWTH = T.OBJ_MAX_GROWTH,
           S.OBJ_LONG_TERM = T.OBJ_LONG_TERM,
           S.OBJ_SPECULATIVE = T.OBJ_SPECULATIVE,
           S.OBJ_MEDIUM = T.OBJ_MEDIUM,
           S.TIME_HORIZON = T.TIME_HORIZON,
           S.Jurisdiction = T.Jurisdiction,
           S.Client_DOB = T.Client_DOB,
           S.ADMINISTRATOR = T.ADMINISTRATOR,
           S.ADMINISTRATOR_ACCOUNT = T.ADMINISTRATOR_ACCOUNT
    FROM #SamplePopulation S
    JOIN #tmpReport T ON T.TRX_SYSID = S.TRX_SYSID;

    CREATE INDEX IX_SamplePopulation_Rep ON #SamplePopulation (Rep_Code, TRX_SYSID);

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

    /* Lower rank and lower subrank are higher priority. */
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

    /* Choose one rule per transaction and sample type. A lower subrank wins ties within rank 3. */
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
        FROM #SamplePopulation T
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
                    SELECT 1
                    FROM @RuleTrxCode X
                    WHERE X.Rule_ID = R.Rule_ID
                      AND X.TRX_CD = T.TRX_CD
                )
            )
            AND
            (
                NOT EXISTS (SELECT 1 FROM @RuleRiskCode X WHERE X.Rule_ID = R.Rule_ID)
                OR EXISTS
                (
                    SELECT 1
                    FROM @RuleRiskCode X
                    WHERE X.Rule_ID = R.Rule_ID
                      AND X.IVT_RISK_CD = T.IVT_RISK_CD
                )
            )
            AND
            (
                NOT EXISTS (SELECT 1 FROM @RulePlanCode X WHERE X.Rule_ID = R.Rule_ID)
                OR EXISTS
                (
                    SELECT 1
                    FROM @RulePlanCode X
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

    /* New-account candidates use the complete preselected transaction set for recently opened plans. */
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
        FROM #SamplePopulation T
        JOIN [MPS].[dbo].[PLN] P
            ON P.PLN_SYSID = T.Plan_Id
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
        JOIN #SamplePopulation T
            ON T.TRX_SYSID = C.TRX_SYSID
        JOIN @EligibleSampleTypes E
            ON E.Sample_Type = C.Sample_Type
    ), SelectedSamples AS
    (
        SELECT R.*
        FROM RankedCandidates R
        JOIN @SampleConfig S
            ON S.Sample_Type = R.Sample_Type
        WHERE R.Sample_Sequence <= S.Samples_Per_Rep
    )
    SELECT
        @BRN AS Requested_BRN_CD,
        @BRN_NAME AS Requested_BRN_NAME,
        @BRN_STATUS AS Requested_BRN_STATUS,
        @BRN_MGR AS Requested_BRN_MGR,
        @DLR_CD AS Requested_DLR_CD,
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
        T.CIFSC_Cat,
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
    JOIN #SamplePopulation T
        ON T.TRX_SYSID = S.TRX_SYSID
    JOIN #BranchScope BS
        ON BS.BRN_SYSID = T.BRN_SYSID
    LEFT JOIN @RuleConfig RC
        ON RC.Rule_ID = S.Rule_ID
    ORDER BY
        S.Sample_Type,
        T.Rep_Code,
        S.Sample_Sequence;

    DROP TABLE #SamplePopulation;
    DROP TABLE #OrderPopulation;
    DROP TABLE #tmpReport;
    DROP TABLE #ApproverScope;
    DROP TABLE #BranchScope;
END;
