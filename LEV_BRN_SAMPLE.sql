USE MPS;
GO

DECLARE @BAL_DT AS DATE = (SELECT MAX(BAL_DATE) FROM [MPS].[dbo].[PLN_BAL])

DECLARE @BRN varchar(10) = 'QC033';

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
FROM [MPS].[dbo].[BRN] B
WHERE B.BRN_CD = @BRN;

IF @BRN_SYSID IS NULL
BEGIN
    THROW 50001, 'The supplied BRN_CD was not found in MPS.dbo.BRN.', 1;
END;

SELECT @BRN AS BRN_CD
      ,@BRN_NAME AS BRN_NAME
      ,@BRN_STATUS AS BRN_STATUS
      ,@BRN_MGR AS BRN_MGR
      ,@DLR_CD AS DLR_CD
	  ,F.DLR_CD
      ,F.REP_CD
	  ,F.REP_FNAME
	  ,F.REP_LNAME
	  ,A.[IVR_SYSID]
      ,A.[PLN_SYSID]
	  ,C.IVR_PRIM_FNAME
	  ,C.IVR_PRIM_LNAME
	  ,C.OWNER_ENG
	  ,C.[IVR_PRIM_BDT]
      ,[PLN_MNEM]
      ,E.[PLN_DESC]
	  ,B.[SETUP_DT]
      ,[PLN_MV]
      ,[PLN_BV]
	  ,C.IVR_RES_CD
      --,[PLN_FC_BV]
      --,[PLN_FC_PCT]
      ,[BAL_DATE]
      --,[NI_T]
      --,[NI_P]
      --,[DLR_SYSID]
      --,[RGN_SYSID]
      --,[BRN_SYSID]
      --,[REP_SYSID]
      --,[PLN_MV_CNV]
      
      --,[PLN_MV_TRD_DT]
      --,[FREQ_CD]
      --,[PLN_MV_CNV_TRD_DT]
	     --   ,[AMOUNT]
      ,[START_DT]
      ,[STOP_DT]
      ,[STATUS] AS LOAN_STATUS
      ,[INST_CD]
      ,[LOAN_NO]
      ,[CONTACT_INFO]
      --,D.[ENTRY_SYSID]
      ,D.[LAST_UPD_DT] Loan_Last_Update
      --,D.[USER_SYSID]
      ,[COLL_CD]
      --,[PRE_QUAL]
      --,[APP_REC_DT]
      --,[VOID_CHQ_REC_DT]
      --,[INSTR_REC_DT]
      --,[INC_REC_DT]
      --,D.[MATURITY_DT]
      ,[REQ_LOAN_AMT]
      ,[LOAN_AMT]
      --,[LOAN_COLL_RATE]
      --,[LOAN_COLL_TERM]
      --,[LOAN_COLL_FREQ]
      --,[LOAN_COLL_PYMT_AMT]
      --,[LOAN_COLL_BAL]
      --,[PRINCIPAL_AMT]
      --,[MARGIN_CALL_PCNT]
      --,[TRADE_REST_CD]
      ,D.[CREATE_DT] Loan_Created_DT

  FROM [MPS].[dbo].[PLN_BAL] A
  LEFT OUTER JOIN [MPS].[dbo].[PLN] B ON A.PLN_SYSID  = B.PLN_SYSID
  LEFT OUTER JOIN [MPS].[dbo].[IVR] C ON A.IVR_SYSID = C.IVR_SYSID
  LEFT OUTER JOIN [MPS].[dbo].[PLN_COLLATERAL] D ON A.PLN_SYSID  = D.PLN_SYSID
  LEFT OUTER JOIN [MPS].[dbo].[S_PLN_CD] E ON B.PLN_CD = E.[PLN_CD]
  LEFT OUTER JOIN [MPS].[dbo].[REP] F ON A.REP_SYSID = F.[REP_SYSID]
  WHERE BAL_DATE = @BAL_DT AND B.PLN_STATUS = 'A' AND B.PLN_CD IN (18,41) AND A.BRN_SYSID = @BRN_SYSID