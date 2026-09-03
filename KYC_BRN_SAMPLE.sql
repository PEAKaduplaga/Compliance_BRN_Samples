/* KYC sample (CVC in French) - execute against the PEAK_LAKE_BI / UVS SQL endpoint */

/* Inputs and sampling controls: expose these as procedure parameters later if needed. */
DECLARE @BRN varchar(10) = 'ON010';
DECLARE @SamplesPerRep int = 1;
DECLARE @MinBranchChanges int = 5;

DECLARE @DateTo datetime = GETDATE();
DECLARE @DateFrom datetime = DATEADD(MONTH, -12, @DateTo);
DECLARE @BRN_SYSID int;
DECLARE @BRN_NAME varchar(100);
DECLARE @BRN_STATUS varchar(2);
DECLARE @BRN_MGR varchar(100);
DECLARE @DLR_CD varchar(10);

/* Resolve the supplied branch code to the branch primary key. */
SELECT
    @BRN_SYSID = B.BRN_SYSID,
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

/*
    A CVC change is treated as one ADT_SYSID event. If an event changes
    multiple fields, all eligible field rows for the selected event are returned.
*/
;WITH FilteredAudit AS
(
    SELECT
        A.[IVR_SYSID],
        CASE
            WHEN ISNULL(B.[IVR_PRIM_SIN], 0) = 0
                THEN B.[IVR_REG_2]
            ELSE B.[IVR_PRIM_LNAME] + ', ' + B.[IVR_PRIM_FNAME]
        END AS Client_Name,
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
    WHERE B.BRN_SYSID = @BRN_SYSID
      AND A.ADT_DATE >= @DateFrom
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
    @BRN AS BRN_CD,
    @BRN_NAME AS BRN_NAME,
    @BRN_STATUS AS BRN_STATUS,
    @BRN_MGR AS BRN_MGR,
    @DLR_CD AS DLR_CD,
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
    'KYC' AS Sample_Type,
    S.Sample_Sequence
FROM SelectedEvents S
JOIN FilteredAudit F
    ON F.ADT_SYSID = S.ADT_SYSID
ORDER BY
    F.Rep_Code,
    S.Sample_Sequence,
    F.ADT_SYSID,
    F.ADT_FIELD;
