USE [MKBBIDW]
GO

/****** Object:  View [dbo].[ViewFactFte]    Script Date: 2025-09-15 11:44:48 ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO





CREATE VIEW  [dbo].[ViewFactFte]
AS
WITH JusteradFrånvaro AS(
select 
f.AnstNr,
CAST(CONCAT(YEAR(f.Datum), '-', MONTH(F.DATUM),'-', '01') AS DATE) AS Datum,
sum(f.ObetaldDagJusterad) AS JusteringFrånvaroDagar
from [MKBBIDW].fact.FteFrånvaroJustering F
GROUP BY 
f.AnstNr,
YEAR(f.Datum),
MONTH(F.DATUM)
HAVING sum(f.ObetaldDagJusterad) <> 0
),

KolumnerInScoope as(
SELECT 
ff.*,
jf.JusteringFrånvaroDagar,
DATEDIFF(DAY, FF.Datum, EOMONTH(FF.DATUM))+1 AS AntalDagarMånad
FROM [MKBBIDW].FACT.FTE FF
LEFT JOIN JusteradFrånvaro JF ON FF.AnstNr = JF.AnstNr AND FF.Datum = JF.Datum
),

JusteradFte as(
SELECT *,
-(cast(round(cast(JusteringFrånvaroDagar as decimal(10,4)) / cast(AntalDagarMånad as decimal(10,4)),2) as decimal(10,2))) as JusteringFte
from KolumnerInScoope)



SELECT *
FROM (

SELECT *
FROM(
SELECT 
JF.AnställdsSk as 'Anställd SK',
JF.ANSTNR AS Anställningsnummer,
JF.KOSTNADSSTÄLLE AS Kostnadsställe,
JF.ANSTÄLLNINGSFORM AS Anställningsform,
CASE WHEN  JF.RapporteradeTimmar <> 0 THEN 'Timavlönad' ELSE 'Månadsavlönad' END AS Lönekategori,
JF.DATUM AS Datum,
JF.Källa AS 'FTE Beräkning',
JF.KontraktStartMånad as 'Kontrakt Start Månad',
JF.KontraktsSlutMånad as 'Kontrakt Slut Månad',
JF.SYSSELSÄTTNINGSGRAD AS Sysselsättningsgrad,
JF.RapporteradeTimmar as 'Rapporterade Timmar',
CASE WHEN JF.KÄLLA = 'TimRapportering' THEN JF.NormalArbetsTid END AS 'Normal arbetstid',
CAST(ROUND(JF.FTE,2) AS DECIMAL(10,2)) AS 'FTE före justering',
COALESCE(round(cast(JF.JusteringFte as decimal(10,2)), 2),0) AS 'Frånvaro justering',
CASE WHEN CAST(ROUND(JF.FTE,2) AS DECIMAL(10,2))  + COALESCE(cast(JF.JusteringFte as decimal(10,2)),0) < 0 THEN 0 ELSE CAST(ROUND(JF.FTE,2) AS DECIMAL(10,2))  + COALESCE(cast(JF.JusteringFte as decimal(10,2)),0) END AS FTE,
COALESCE(JF.JusteringFrånvaroDagar,0) AS 'Dagar frånvaro justering',
CASE WHEN JF.RapporteradeTimmar <> 0 THEN JF.ANTALDAGARMÅNAD END AS 'Dagar totalt',
JF.TillTrädesDatum as 'SCD2 ändring datum',
JF.TillTrädeTomDatum as 'SCD2 ändring tom datum',
JF.Månadslön,
JF.Lönetillägg,
JF.MånadsLönPlusTillägg,
JF.[Lönetillägg Startdatum],
JF.[Lönetillägg Slutdatum],
JF.Timlön,
JF.[Timmar*Timlön]
FROM JusteradFte JF
) JF2
where year(JF2.datum) > 2024
UNION ALL
SELECT VB.AnställdSK,
VB.AnställningsNummer AS AnställningsNr,
VB.KostnadsStälle,
VB.AnställningsForm,
NULL,
VB.Datum,
VB.Source   AS FTEBeräkning,
NULL,
NULL, 
NULL AS SysselSättningsGrad,
NULL AS RapporteradeTimmar,
NULL AS NormalArbetsTid,
VB.Fte AS FTEFöreJustering,
NULL AS FrånvaroJustering,
VB.Fte AS FTE,
NULL AS DagarFrånvaroJustering,
NULL AS DagarTotalt,
VB.TillTrädesDatum AS SCD2ÄndringDatum,
VB.FrånTrädesDatum AS SCD2ÄndringTomDatum,
NULL,
NULL,
NULL,
NULL,
NULL,
NULL,
NULL
FROM [MKBBIDW].[dbo].[ViewFactFteBef2025] VB
) F
WHERE NOT (F.Anställningsform = 'Intermittent-/behovsanst' AND YEAR(F.DATUM) > 2024 AND F.[Rapporterade Timmar] = 0)
GO


