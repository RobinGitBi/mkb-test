USE MKBBIDW
GO
ALTER VIEW  dbo.ViewFactFte
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
FROM(
SELECT 
JF.AnställdsSk as AnställdSk,
JF.ANSTNR AS AnställningsNr,
JF.KOSTNADSSTÄLLE AS KostnadsStälle,
JF.ANSTÄLLNINGSFORM AS AnställningsForm,
JF.DATUM AS Datum,
JF.Källa AS FTEBeräkning,
JF.KontraktStartMånad,
JF.KontraktsSlutMånad,
JF.SYSSELSÄTTNINGSGRAD AS SysselSättningsGrad,
JF.RapporteradeTimmar,
CASE WHEN JF.KÄLLA = 'TimRapportering' THEN JF.NormalArbetsTid END AS NormalArbetsTid,
CAST(ROUND(JF.FTE,2) AS DECIMAL(10,2)) AS FTEFöreJustering,
COALESCE(round(cast(JF.JusteringFte as decimal(10,2)), 2),0) AS FrånvaroJustering,
CASE WHEN CAST(ROUND(JF.FTE,2) AS DECIMAL(10,2))  + COALESCE(cast(JF.JusteringFte as decimal(10,2)),0) < 0 THEN 0 ELSE CAST(ROUND(JF.FTE,2) AS DECIMAL(10,2))  + COALESCE(cast(JF.JusteringFte as decimal(10,2)),0) END AS FTE,
COALESCE(JF.JusteringFrånvaroDagar,0) AS DagarFrånvaroJustering,
JF.ANTALDAGARMÅNAD AS DagarTotalt,
JF.TillTrädesDatum as SCD2ÄndringDatum,
JF.TillTrädeTomDatum as SCD2ÄndringTomDatum
FROM JusteradFte JF
) JF2
where year(JF2.datum) > 2024
UNION ALL
SELECT VB.AnställdSK,
VB.AnställningsNummer AS AnställningsNr,
VB.KostnadsStälle,
VB.AnställningsForm,
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
VB.FrånTrädesDatum AS SCD2ÄndringTomDatum
FROM [MKBBIDW].[dbo].[ViewFactFteBef2025] VB

