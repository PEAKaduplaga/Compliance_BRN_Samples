/* A executer sur le serveur Univeris dans la BD PEAKProcs */
/* Blotter MFDA */
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
go

create index idxClientId on #tmpReport(Client_ID)
go

create index idxPlanId on #tmpReport(Plan_Id)
go

declare @dtDateFrom	varchar(10)
declare @dtDateTo	varchar(10)

set @dtDateFrom	= '2025-07-31'
set @dtDateTo	= '2026-08-01'

insert into #tmpReport(Client_ID,Client_Name,Client_Status,Client_Setup,Client_Stop,Plan_Id,PLN_CD,Plan_Type,Rep_Code,Rep_Name,[TRADE_WATCH],Trade_type,Fund_Code,Fund_Name,Fund_Type,LOAD_Type,IVT_RISK_CD, Product_Risk,Dealer_Code,Trade_Date,Settlement_Date,Entry_Date,TRX_CD,Transaction_Type,Gross_Amount,Net_Amount,Dealer_Commission,DSC,TRX_COMM,
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
                    JOIN MPS.dbo.S_TRX_CD S ON T.TRX_CD = S.TRX_CD           
where
    T.TRADE_DT between @dtDateFrom and @dtDateTo
	and T.BRN_SYSID = 58279485
	  --AND S.TRX_MNEM_ENG IN ('PUR','RED')--,'XIN','XINK')
	 AND T.TRX_CD IN (2211, 7211, 4511,4611,6511, 6611, 2260, 2111, 7111, 7312, 7313, 7314, 7315)
  AND T.TRX_NET IS NOT NULL
  AND IT.IVT_TYPE <> 'CMA'
	--and I.IVR_SYSID = 39107712
	--and upper(ltrim(rtrim(I.IVR_RES_CD))) not in ('PQ','QC')

update A set
	A.CIFSC_Cat=isnull(AC.CIFSC_LINK,'')
from
    #tmpReport A
		join MPS.dbo.IVD B on A.Fund_Code=B.SYMBOL
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
								

select --top 100 
	* 
from 
	#tmpReport
	--order by 

	drop table #tmpReport
/*
	and TC.TRX_MNEM_ENG in ('PUR','PURR','RED','REDR')
    and T.TRX_GROSS >= 25000
    and I.IVR_RES_CD not in ('PQ','QC')


select top 10 * from S_IVT_RISK

select A.name,A.object_id,B.object_id,B.name 
from sys.all_columns A join sys.all_objects B on A.object_id=B.object_id 
where A.name='IVT_RISK_CD'

select top 10 * from MPS.dbo.IVR
select * from MPS.dbo.S_SALARY
select * from MPS.dbo.S_NET_WORTH
select * from MPS.dbo.IVD where SYMBOL='CIG677'
select * from MPS.dbo.IVT where IVT_SYSID=107810
select * from MPS.dbo.S_ASSET_CLASS


select * from tmpReport where Trade_Date >= '2021-06-30' and Trade_Date <= '2021-07-31'
*/
