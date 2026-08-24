/* A executer sur le serveur Univeris dans la BD PEAKProcs */
/* Modular BRN sample selection procedure */
CREATE OR ALTER PROCEDURE [dbo].[PEAK_COMPLIANCE_SP_UVS_BRN_SAMPLE_TRX]
    @BRN varchar(10)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @BRN_SYSID int;
    DECLARE @BRN_NAME varchar(100);
    DECLARE @BRN_STATUS varchar(2);
    DECLARE @BRN_MGR varchar(100);
    DECLARE @DLR_CD varchar(10);

    SELECT
        @BRN_SYSID = B.BRN_SYSID,
        @BRN_NAME = B.BRN_NAME,
        @BRN_STATUS = B.BRN_STATUS,
        @BRN_MGR = B.BRN_MGR,
        @DLR_CD = B.DLR_CD
    FROM MPS.dbo.BRN B
    WHERE B.BRN_CD = @BRN;

    IF @BRN_SYSID IS NULL
    BEGIN
        THROW 50001, 'The supplied BRN_CD was not found in MPS.dbo.BRN.', 1;
    END;

    /* Sampling controls: change here, or expose as procedure parameters later. */
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

    /* Rule configuration is defined below so ranks and thresholds can be changed independently. */
--drop table tmpReport
--go

create table #tmpReport (
    Client_ID int,
    Client_Name varchar(100),
	Client_Status varchar(2),
	Client_Setup datetime,
	Client_Stop datetime,
    Plan_Id int,
	PLN_CD varchar (10),
    Plan_Type varchar(100),
	Plan_Status varchar(1),
	Plan_Setup datetime,
	Plan_Close datetime,
	Plan_Last_Update datetime,
    Plan_KYC_Last_Update datetime,
    Rep_Name varchar(100),
    TRX_SYSID int,
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
	[TRADE_WATCH] tinyint,
	Trade_type varchar (1),
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
)


--create index idxClientId on #tmpReport(Client_ID)
--go

--create index idxPlanId on #tmpReport(Plan_Id)
--go

--set @dtDateFrom	= '2025-07-31'
--set @dtDateTo	= '2026-08-01'

insert into #tmpReport(Client_ID,Client_Name,Client_Status,Client_Setup,Client_Stop,Plan_Id,PLN_CD,Plan_Type,Rep_Code,Rep_Name,[TRADE_WATCH],Trade_type,TRX_SYSID,IVD_SYSID,Fund_Code,Fund_Name,Fund_Type,LOAD_Type,IVT_RISK_CD, Product_Risk,Dealer_Code,Trade_Date,Settlement_Date,Entry_Date,TRX_CD,Transaction_Type,Gross_Amount,Net_Amount,Dealer_Commission,DSC,TRX_COMM,
    TRX_COMM_PCNT,AGE,Jurisdiction,Client_DOB,ADMINISTRATOR,ADMINISTRATOR_ACCOUNT,ENTRY_USER)
select
    T.IVR_SYSID as Client_ID,
    case when isnull(I.IVR_PRIM_SIN,0)=0 or I.IVR_PRIM_SIN=0 then I.IVR_REG_2 else I.IVR_PRIM_LNAME +', ' + I.IVR_PRIM_FNAME end as Client_Name,
	I.IVR_STATUS,
	I.IVR_SETUP_DT,
	I.IVR_STOP_DT,
    T.PLN_SYSID as Plan_Id,
	P.PLN_CD,
    PC.PLN_DESC as Plan_Type,
	I.REP_CD as Rep_Code,
    R.REP_FNAME + ' ' + R.REP_LNAME as Rep_Name,
	R.[TRADE_WATCH],
	CASE WHEN T.TRX_WO_NUM IS NULL THEN 'D' ELSE 'W' END AS Trade_type,
	T.TRX_SYSID,
	T.IVD_SYSID,
    E.SYMBOL as Fund_Code,
    IT.IVT_NAME_ENG as Fund_Name,
	IT.IVT_TYPE as Fund_Type,
    E.IVD_LOAD_FLAG as LOAD_Type,
	IR.IVT_RISK_CD,
	IR.IVT_RISK_DESC_ENG as Product_Risk,
	I.DLR_CD as Dealer_Code,
    T.TRADE_DT as Trade_Date,
	T.SETTLE_DT as Settlement_Date,
	T.TRX_ENTRY_DT as Entry_Date,
	T.TRX_CD,
    TC.TRX_DESC_ENG as Transaction_Type,
    T.TRX_GROSS as Gross_Amount,
    T.TRX_NET as Net_Amount,
	T.TRX_DSC_COMM as Dealer_Commission,
    T.TRX_WTH_DSC as DSC,
	T.[TRX_COMM],
    T.[TRX_COMM_PCNT],
    case when isnull(I.IVR_PRIM_BDT,'')<>'' then datediff(year,I.IVR_PRIM_BDT,getdate()) else 0 end as AGE,
	I.IVR_RES_CD as Jurisdiction,
	case when isnull(I.IVR_PRIM_BDT,'')='' then '' else I.IVR_PRIM_BDT end as Client_DOB,
	P.PLN_ADM_CD as ADMINISTRATOR,
	P.PLN_ADM_ACCT as ADMINISTRATOR_ACCOUNT,
	case when isnull(T.ENTRY_SYSID,'')='' then 'Univeris Batch User' else U.USR_NAME end as ENTRY_USER
	
from
    MPS.dbo.TRX T join MPS.dbo.S_TRX_CD TC on T.TRX_CD=TC.TRX_CD
                    join MPS.dbo.IVR I on T.IVR_SYSID=I.IVR_SYSID
                    join MPS.dbo.PLN P on T.PLN_SYSID=P.PLN_SYSID
                    join MPS.dbo.S_PLN_CD PC on P.PLN_CD=PC.PLN_CD
                    join MPS.dbo.IVD E on T.IVD_SYSID=E.IVD_SYSID
                    join MPS.dbo.IVT IT on E.IVT_SYSID=IT.IVT_SYSID
                    join MPS.dbo.REP R on I.REP_CD=R.REP_CD
					left join MPS.dbo.SYS_USER_CD U ON T.ENTRY_SYSID=U.USER_SYSID
					left join MPS.dbo.S_IVT_RISK IR on IR.IVT_RISK_CD=IT.IVT_RISK_CD
                    --JOIN MPS.dbo.S_TRX_CD S ON T.TRX_CD = S.TRX_CD           
where
    T.TRADE_DT >= @DateFrom and T.TRADE_DT < @DateTo
	and T.BRN_SYSID = @BRN_SYSID
	  --AND TC.TRX_MNEM_ENG IN ('PUR','RED')--,'XIN','XINK')
 	 AND
    (
        T.TRX_CD IN (2211, 7211, 4511,4611,6511, 6611, 2260, 2111, 7111, 7312, 7313, 7314, 7315)
        OR EXISTS
        (
            SELECT 1
            FROM MPS.dbo.PLN PNA
            WHERE PNA.PLN_SYSID = T.PLN_SYSID
              AND PNA.SETUP_DT >= @DateFrom
              AND PNA.SETUP_DT < @DateTo
        )
    )
  AND T.TRX_NET IS NOT NULL
  AND
  (
      IT.IVT_TYPE <> 'CMA'
      OR EXISTS
      (
          SELECT 1
          FROM MPS.dbo.PLN PNA
          WHERE PNA.PLN_SYSID = T.PLN_SYSID
            AND PNA.SETUP_DT >= @DateFrom
            AND PNA.SETUP_DT < @DateTo
      )
  )
	--and I.IVR_SYSID = 39107712
	--and upper(ltrim(rtrim(I.IVR_RES_CD))) not in ('PQ','QC')

create index idxClientId on #tmpReport(Client_ID)

create index idxPlanId on #tmpReport(Plan_Id)

update A set
	A.CIFSC_Cat=isnull(AC.CIFSC_LINK,'')
from
    #tmpReport A
		join MPS.dbo.IVD B on A.IVD_SYSID=B.IVD_SYSID
		join MPS.dbo.IVT C on B.IVT_SYSID=C.IVT_SYSID
		join MPS.dbo.S_ASSET_CLASS AC on C.ASSET_CLASS=AC.ASSET_CLASS

update A set
    A.Personal_Income = S.SALARY_DESC_ENG, 
    A.Net_Worth = NW.NET_WORTH_DESC_ENG, 
    A.Investment_Knowledge = case ltrim(rtrim(K.IVR_INV_KNOW))
								when 'N' then 'Poor'
								when 'M' then 'Fair'
								when 'H' then 'Good'
								when 'E' then 'Excellent'
								else ltrim(rtrim(K.IVR_INV_KNOW))
							end, 
    A.RISK_LOW = dbo.ufn_GetMPSPlanRisks(P.KYC_PLN_SYSID,'10'),
	A.RISK_LOW_TO_MEDIUM = dbo.ufn_GetMPSPlanRisks(P.KYC_PLN_SYSID,'20'),
    A.RISK_MEDIUM = dbo.ufn_GetMPSPlanRisks(P.KYC_PLN_SYSID,'40'),
	A.RISK_MEDIUM_TO_HIGH = dbo.ufn_GetMPSPlanRisks(P.KYC_PLN_SYSID,'60'),
    A.RISK_HIGH = dbo.ufn_GetMPSPlanRisks(P.KYC_PLN_SYSID,'80'),
    A.OBJ_SEC_CAPITAL = dbo.ufn_GetMPSPlanGoals(P.KYC_PLN_SYSID,'L'),
    A.OBJ_INCOME = dbo.ufn_GetMPSPlanGoals(P.KYC_PLN_SYSID,'I'),
    A.OBJ_GROWTH = dbo.ufn_GetMPSPlanGoals(P.KYC_PLN_SYSID,'G'),
    A.OBJ_MAX_GROWTH = dbo.ufn_GetMPSPlanGoals(P.KYC_PLN_SYSID,'M'), 
    A.OBJ_LONG_TERM = 0, --InvestObjLongTerm 
    A.OBJ_SPECULATIVE = dbo.ufn_GetMPSPlanGoals(P.KYC_PLN_SYSID,'S'),
    A.OBJ_MEDIUM = 0,
	A.TIME_HORIZON = TH.[KYC_TH_DESC_ENG],
	A.Plan_Setup = P.SETUP_DT,
	A.Plan_Close = P.CLOSE_DT,
	A.Plan_Last_Update = P.LAST_UPD_DT,
	A.Plan_KYC_Last_Update = KP.[CPL_UPD_DT],
	A.Plan_Status = P.PLN_STATUS

    --A.TIME_HORIZON	= case KP.TIME_HORIZON_CD
				--		when 1 then '< 1 an'
				--		when 2 then '< 5 ans'
				--		when 3 then '5-10 ans'
				--		when 4 then '> 10 ans'
				--	end
	

from
	#tmpReport A join MPS.dbo.PLN P on A.Plan_Id=P.PLN_SYSID 
				left join MPS.dbo.KYC K on A.Client_ID=K.IVR_SYSID
                left join MPS.dbo.KYC_PLN KP on P.KYC_PLN_SYSID=KP.KYC_PLN_SYSID
                left join MPS.dbo.S_SALARY S on K.SALARY_CD=S.SALARY_CD
                left join MPS.dbo.S_NET_WORTH NW on K.NET_WORTH_CD=NW.NET_WORTH_CD
				left join [MPS].[dbo].[S_KYC_TIME_HORIZON] TH ON KP.TIME_HORIZON_CD = TH.KYC_TH_CD
								

/* Sample quantities and branch gates are separate from the rule definitions. */
DECLARE @SampleConfig TABLE
(
    Sample_Type varchar(20) NOT NULL PRIMARY KEY,
    Samples_Per_Rep int NOT NULL,
    Min_Branch_Trx int NOT NULL
);

INSERT INTO @SampleConfig (Sample_Type, Samples_Per_Rep, Min_Branch_Trx)
VALUES
    ('SUPERVISION', @SupervisionSamplesPerRep, @SupervisionMinBranchTrx),
    ('DIRECT',      @DirectSamplesPerRep,      @DirectMinBranchTrx),
    ('SENIOR',      @SeniorSamplesPerRep,      @SeniorMinBranchTrx),
    ('NEW_ACCOUNT', @NewAccountSamplesPerRep, @NewAccountMinBranchAccounts);

DECLARE @RuleConfig TABLE
(
    Rule_ID int NOT NULL PRIMARY KEY,
    Sample_Type varchar(20) NOT NULL,
    Rule_Rank int NOT NULL,
    Min_Gross_Amount float NULL,
    Min_Age smallint NULL,
    Trade_Type char(1) NULL,
    Trade_Watch tinyint NULL,
    Rule_Description varchar(100) NOT NULL
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

/*
    Rule ranks are ascending priority: rank 1 is selected before rank 2, etc.
    Add or change rows here without changing the candidate-ranking algorithm.
*/
INSERT INTO @RuleConfig
    (Rule_ID, Sample_Type, Rule_Rank, Min_Gross_Amount, Min_Age, Trade_Type, Trade_Watch, Rule_Description)
VALUES
    (101, 'SUPERVISION', 1, NULL, NULL, NULL, 1, 'Representative under supervision'),
    (102, 'SUPERVISION', 2, NULL, NULL, NULL, NULL, 'Leveraged account'),
    (103, 'SUPERVISION', 3, 10000, NULL, NULL, NULL, 'Redemption $10,000+'),
    (104, 'SUPERVISION', 4, 10000, NULL, NULL, NULL, 'Purchase $10,000+'),
    (105, 'SUPERVISION', 5, 5000,  NULL, NULL, NULL, 'Purchase medium risk $5,000+'),
    (106, 'SUPERVISION', 6, 2500,  NULL, NULL, NULL, 'Purchase higher risk $2,500+'),
    (201, 'DIRECT',      1, NULL, NULL, 'D', NULL, 'Non-wired purchase'),
    (202, 'DIRECT',      2, NULL, NULL, 'D', NULL, 'Non-wired redemption'),
    (203, 'DIRECT',      3, NULL, NULL, 'D', NULL, 'Non-wired switch'),
    (301, 'SENIOR',      1, NULL, 70,   NULL, NULL, 'Senior purchase'),
    (302, 'SENIOR',      2, NULL, 70,   NULL, NULL, 'Senior redemption'),
    (303, 'SENIOR',      3, NULL, 70,   NULL, NULL, 'Senior switch');

INSERT INTO @RuleTrxCode (Rule_ID, TRX_CD)
VALUES
    (103, 7211), (103, 7111), (103, 7312), (103, 7313), (103, 7314), (103, 7315),
    (104, 2111), (104, 2211),
    (105, 2111), (105, 2211),
    (106, 2111), (106, 2211),
    (201, 2111), (201, 2211),
    (202, 7211), (202, 7111), (202, 7312), (202, 7313), (202, 7314), (202, 7315),
    (203, 4511), (203, 4611), (203, 6511), (203, 6611),
    (301, 2111), (301, 2211),
    (302, 7211), (302, 7111), (302, 7312), (302, 7313), (302, 7314), (302, 7315),
    (303, 4511), (303, 4611), (303, 6511), (303, 6611);

INSERT INTO @RuleRiskCode (Rule_ID, IVT_RISK_CD)
VALUES
    (105, 30),
    (106, 35), (106, 40), (106, 45), (106, 50), (106, 100);

INSERT INTO @RulePlanCode (Rule_ID, PLN_CD)
VALUES
    (102, '41'), (102, '18');

/* Add the leveraged-account rule's plan-code match without embedding it in the algorithm. */
DECLARE @CandidateMatches TABLE
(
    Sample_Type varchar(20) NOT NULL,
    TRX_SYSID int NOT NULL,
    Rep_Code varchar(15) NULL,
    Rule_Rank int NOT NULL,
    PRIMARY KEY (Sample_Type, TRX_SYSID)
);

INSERT INTO @CandidateMatches (Sample_Type, TRX_SYSID, Rep_Code, Rule_Rank)
SELECT
    R.Sample_Type,
    T.TRX_SYSID,
    T.Rep_Code,
    MIN(R.Rule_Rank) AS Rule_Rank
FROM #tmpReport T
JOIN @RuleConfig R
    ON (R.Trade_Type IS NULL OR R.Trade_Type = T.Trade_type)
   AND (R.Trade_Watch IS NULL OR R.Trade_Watch = T.TRADE_WATCH)
   AND (R.Min_Gross_Amount IS NULL OR T.Gross_Amount >= R.Min_Gross_Amount)
   AND (R.Min_Age IS NULL OR T.AGE >= R.Min_Age)
WHERE
    (NOT EXISTS (SELECT 1 FROM @RuleTrxCode X WHERE X.Rule_ID = R.Rule_ID)
        OR EXISTS (SELECT 1 FROM @RuleTrxCode X WHERE X.Rule_ID = R.Rule_ID AND X.TRX_CD = T.TRX_CD))
AND (NOT EXISTS (SELECT 1 FROM @RuleRiskCode X WHERE X.Rule_ID = R.Rule_ID)
        OR EXISTS (SELECT 1 FROM @RuleRiskCode X WHERE X.Rule_ID = R.Rule_ID AND X.IVT_RISK_CD = T.IVT_RISK_CD))
AND (NOT EXISTS (SELECT 1 FROM @RulePlanCode X WHERE X.Rule_ID = R.Rule_ID)
        OR EXISTS (SELECT 1 FROM @RulePlanCode X WHERE X.Rule_ID = R.Rule_ID AND X.PLN_CD = T.PLN_CD))
GROUP BY
    R.Sample_Type,
    T.TRX_SYSID,
    T.Rep_Code;

/*
    New-account candidates use the complete transaction set for plans opened
    during the period. One initial transaction is retained per plan.
*/
;WITH NewAccountTransactions AS
(
    SELECT
        T.TRX_SYSID,
        T.Rep_Code,
        T.Plan_Id,
        T.Gross_Amount,
        T.Trade_Date,
        ROW_NUMBER() OVER
        (
            PARTITION BY T.Plan_Id
            ORDER BY T.Trade_Date ASC, T.TRX_SYSID ASC
        ) AS Initial_Transaction_Sequence
    FROM #tmpReport T
    JOIN MPS.dbo.PLN P
        ON P.PLN_SYSID = T.Plan_Id
    WHERE P.SETUP_DT >= @DateFrom
      AND P.SETUP_DT < @DateTo
)
INSERT INTO @CandidateMatches (Sample_Type, TRX_SYSID, Rep_Code, Rule_Rank)
SELECT
    'NEW_ACCOUNT',
    N.TRX_SYSID,
    N.Rep_Code,
    1
FROM NewAccountTransactions N
WHERE N.Initial_Transaction_Sequence = 1;

/* Branch gates are evaluated independently for each sample type. */
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

/*
    A transaction matching multiple rules is retained once at its best rank.
    The amount is the primary within-rank selector; TRX_SYSID is the stable tie-breaker.
*/
;WITH RankedCandidates AS
(
    SELECT
        C.Sample_Type,
        C.TRX_SYSID,
        C.Rep_Code,
        C.Rule_Rank,
        T.Gross_Amount,
        ROW_NUMBER() OVER
        (
            PARTITION BY C.Sample_Type, C.Rep_Code
            ORDER BY C.Rule_Rank ASC, T.Gross_Amount DESC, C.TRX_SYSID ASC
        ) AS Sample_Sequence
    FROM @CandidateMatches C
    JOIN #tmpReport T ON T.TRX_SYSID = C.TRX_SYSID
    JOIN @EligibleSampleTypes E ON E.Sample_Type = C.Sample_Type
), SelectedSamples AS
(
    SELECT R.*
    FROM RankedCandidates R
    JOIN @SampleConfig S ON S.Sample_Type = R.Sample_Type
    WHERE R.Sample_Sequence <= S.Samples_Per_Rep
)
SELECT
    @BRN AS BRN_CD,
    @BRN_NAME AS BRN_NAME,
    @BRN_STATUS AS BRN_STATUS,
    @BRN_MGR AS BRN_MGR,
    @DLR_CD AS DLR_CD,
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
    T.AGE,
    T.Personal_Income,
    T.Net_Worth,
    T.Investment_Knowledge,
    T.RISK_LOW,
    T.RISK_LOW_TO_MEDIUM,
    T.RISK_MEDIUM,
    T.RISK_MEDIUM_TO_HIGH,
    T.RISK_HIGH,
    T.OBJ_SEC_CAPITAL,
    T.OBJ_INCOME,
    T.OBJ_GROWTH,
    T.OBJ_MAX_GROWTH,
    T.OBJ_LONG_TERM,
    T.OBJ_SPECULATIVE,
    T.OBJ_MEDIUM,
    T.TIME_HORIZON,
    T.Jurisdiction,
    T.Client_DOB,
    T.ADMINISTRATOR,
    T.ADMINISTRATOR_ACCOUNT,
    S.Sample_Type,
    S.Rule_Rank AS Selection_Rank,
    COALESCE(RC.Rule_Description, 'New account initial transaction') AS Selection_Rule,
    S.Sample_Sequence
FROM SelectedSamples S
JOIN #tmpReport T ON T.TRX_SYSID = S.TRX_SYSID
LEFT JOIN @RuleConfig RC
    ON RC.Sample_Type = S.Sample_Type
   AND RC.Rule_Rank = S.Rule_Rank
ORDER BY
    S.Sample_Type,
    T.Rep_Code,
    S.Sample_Sequence;

DROP TABLE #tmpReport;
END;
