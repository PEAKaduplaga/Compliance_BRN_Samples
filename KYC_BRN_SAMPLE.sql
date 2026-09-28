/* KYC sample (CVC in French) - execute against the PEAK_LAKE_BI / UVS SQL endpoint */

/* Inputs and sampling controls: expose these as procedure parameters later if needed. */
DECLARE @BRN varchar(10) = 'ON010';
DECLARE @BRN_OVERRIDE varchar(1) = 'N'; -- Y = individual branch, N = main branch plus sub-branches
DECLARE @SamplesPerRep int = 1;
DECLARE @MinBranchChanges int = 5;

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

DECLARE @BRN_SYSID int;
DECLARE @InputBRN_TYPE char(1);
DECLARE @InputBRN_HEAD_CODE varchar(10);
DECLARE @BRN_NAME varchar(100);
DECLARE @BRN_STATUS varchar(2);
DECLARE @BRN_MGR varchar(100);
DECLARE @DLR_CD varchar(10);
DECLARE @ScopeBRN_CD varchar(10);

/* Resolve the supplied branch code to the branch primary key. */
SELECT
    @BRN_SYSID = B.BRN_SYSID,
    @InputBRN_TYPE = B.BRN_TYPE,
    @InputBRN_HEAD_CODE = NULLIF(LTRIM(RTRIM(B.BRN_HEAD_CODE)), ''),
    @BRN_NAME = B.BRN_NAME,
    @BRN_STATUS = B.BRN_STATUS,
    @BRN_MGR = B.BRN_MGR,
    @DLR_CD = B.DLR_CD
FROM [PEAK_LAKE_BI].[UVS].[brn] B
WHERE B.BRN_CD = @BRN;

IF @BRN_SYSID IS NULL
BEGIN
    THROW 50001, 'The supplied BRN_CD was not found in MPS.dbo.BRN.', 1;
END;

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
        FROM [PEAK_LAKE_BI].[UVS].[brn] B
        WHERE B.BRN_CD = @ScopeBRN_CD
          AND B.BRN_TYPE = 'M'
    )
        THROW 50003, 'The sub-branch BRN_HEAD_CODE does not identify a valid main branch.', 1;
END;
ELSE
    SET @ScopeBRN_CD = @BRN;

IF NOT EXISTS
(
    SELECT 1
    FROM [PEAK_LAKE_BI].[UVS].[brn] B
    WHERE
        (@UseIndividualBranch = 1 AND B.BRN_CD = @BRN)
        OR
        (
            @UseIndividualBranch = 0
            AND B.BRN_STATUS = 'A'
            AND
            (
                B.BRN_CD = @ScopeBRN_CD
                OR (B.BRN_TYPE = 'S' AND B.BRN_HEAD_CODE = @ScopeBRN_CD)
            )
        )
)
    THROW 50004, 'No active branch rows were found for the requested branch scope.', 1;

/*
    A CVC change is treated as one ADT_SYSID event. If an event changes
    multiple fields, all eligible field rows for the selected event are returned.
*/
;WITH BranchScope AS
(
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
        CASE
            WHEN @UseIndividualBranch = 1 THEN 'INPUT'
            WHEN B.BRN_CD = @ScopeBRN_CD THEN 'MAIN'
            ELSE 'SUB_BRANCH'
        END AS Scope_Source
    FROM [PEAK_LAKE_BI].[UVS].[brn] B
    WHERE
        (@UseIndividualBranch = 1 AND B.BRN_CD = @BRN)
        OR
        (
            @UseIndividualBranch = 0
            AND B.BRN_STATUS = 'A'
            AND
            (
                B.BRN_CD = @ScopeBRN_CD
                OR (B.BRN_TYPE = 'S' AND B.BRN_HEAD_CODE = @ScopeBRN_CD)
            )
        )
), FilteredAudit AS
(
    SELECT
        A.[IVR_SYSID],
        CASE
            WHEN ISNULL(B.[IVR_PRIM_SIN], 0) = 0
                THEN B.[IVR_REG_2]
            ELSE B.[IVR_PRIM_LNAME] + ', ' + B.[IVR_PRIM_FNAME]
        END AS Client_Name,
        B.[IVR_SETUP_DT] AS Client_Setup_Date,
        A.[PLN_SYSID],
        A.[ACT_SYSID],
        A.[USER_SYSID],
        A.[ADT_SYSID],
        A.[ADT_DATE],
        A.[ADT_ACTIVITY],
        A.[ADT_TABLE],
        A.[ADT_FIELD],
        A.[ADT_FIELD_TYPE],
        A.[ADT_BEFORE],
        A.[ADT_AFTER],
        A.[SUSER_NAME],
        B.[REP_SYSID],
        C.[REP_CD] AS Rep_Code,
        C.[REP_FNAME] + ' ' + C.[REP_LNAME] AS Rep_Name,
        B.[BRN_SYSID]
    FROM [PEAK_LAKE_BI].[UVS].[adt] A
    LEFT JOIN [PEAK_LAKE_BI].[UVS].[ivr] B
        ON A.IVR_SYSID = B.IVR_SYSID
    LEFT JOIN [PEAK_LAKE_BI].[UVS].[rep] C
        ON B.REP_SYSID = C.REP_SYSID
    JOIN BranchScope BS
        ON BS.BRN_SYSID = B.BRN_SYSID
    WHERE A.ADT_DATE >= @DateFrom
      AND A.ADT_DATE < @DateTo
      AND A.ADT_AFTER IS NOT NULL
      AND A.ADT_AFTER <> ''
      AND A.ADT_FIELD <> 'USER_SYSID'
      AND A.ADT_FIELD NOT LIKE '%[_]DT%'
      AND A.ADT_FIELD NOT LIKE '%DATE%'
      AND A.ADT_TABLE IN
      (
          'KYC_PLN',
          'PLN_COLLATERAL',
          'IVR',
          'CET_EFT',
          'PLN_BENE',
          'PLN',
          'IVR_MKTG',
          'CET_ADR',
          'CET_FOREIGN_TAX',
          'KYC',
          'CET_PHN',
          'CET_FOREIGN_TAX_STATUS'
      )
), ChangeEvents AS
(
    SELECT
        F.ADT_SYSID,
        F.IVR_SYSID,
        F.PLN_SYSID,
        F.ACT_SYSID,
        F.REP_SYSID,
        F.Rep_Code,
        F.Rep_Name,
        F.BRN_SYSID,
        MIN(F.ADT_DATE) AS Change_Date
    FROM FilteredAudit F
    GROUP BY
        F.ADT_SYSID,
        F.IVR_SYSID,
        F.PLN_SYSID,
        F.ACT_SYSID,
        F.REP_SYSID,
        F.Rep_Code,
        F.Rep_Name,
        F.BRN_SYSID
), BranchEligibility AS
(
    SELECT E.BRN_SYSID
    FROM ChangeEvents E
    GROUP BY E.BRN_SYSID
    HAVING COUNT(*) >= @MinBranchChanges
), RankedEvents AS
(
    SELECT
        E.ADT_SYSID,
        E.IVR_SYSID,
        E.PLN_SYSID,
        E.ACT_SYSID,
        E.REP_SYSID,
        E.Rep_Code,
        E.Rep_Name,
        E.BRN_SYSID,
        E.Change_Date,
        ROW_NUMBER() OVER
        (
            PARTITION BY E.REP_SYSID
            ORDER BY E.Change_Date DESC, E.ADT_SYSID DESC
        ) AS Sample_Sequence
    FROM ChangeEvents E
    JOIN BranchEligibility B
        ON E.BRN_SYSID = B.BRN_SYSID
), SelectedEvents AS
(
    SELECT R.*
    FROM RankedEvents R
    WHERE R.Sample_Sequence <= @SamplesPerRep
)
SELECT
    BS.BRN_CD,
    BS.BRN_NAME,
    BS.BRN_STATUS,
    BS.BRN_MGR,
    BS.DLR_CD,
    F.Rep_Code,
    F.Rep_Name,
    F.IVR_SYSID,
    F.Client_Name,
    F.PLN_SYSID,
    F.ACT_SYSID,
    F.USER_SYSID,
    F.ADT_SYSID,
    F.ADT_DATE,
    F.ADT_ACTIVITY,
    F.ADT_TABLE,
    F.ADT_FIELD,
    F.ADT_FIELD_TYPE,
    F.ADT_BEFORE,
    F.ADT_AFTER,
    F.SUSER_NAME,
    --F.REP_SYSID,

    S.Change_Date,
    F.Client_Setup_Date,
    P.[SETUP_DT] AS Plan_Setup_Date,
    CASE
        WHEN F.Client_Setup_Date IS NOT NULL
         AND CAST(F.ADT_DATE AS date) = CAST(F.Client_Setup_Date AS date)
            THEN 'New Client'
        WHEN P.[SETUP_DT] IS NOT NULL
         AND CAST(F.ADT_DATE AS date) = CAST(P.[SETUP_DT] AS date)
            THEN 'New Plan'
        ELSE 'KYC Update'
    END AS KYC_Change_Type,
    'KYC' AS Sample_Type,
    S.Sample_Sequence
FROM SelectedEvents S
JOIN FilteredAudit F
    ON F.ADT_SYSID = S.ADT_SYSID
JOIN BranchScope BS
    ON BS.BRN_SYSID = F.BRN_SYSID
LEFT JOIN [PEAK_LAKE_BI].[UVS].[pln] P
    ON P.[PLN_SYSID] = F.[PLN_SYSID]
ORDER BY
    F.Rep_Code,
    S.Sample_Sequence,
    F.ADT_SYSID,
    F.ADT_FIELD;
