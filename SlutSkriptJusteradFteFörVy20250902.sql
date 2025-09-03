
WITH JusteradFrånvaro AS(
select 
f.AnstNr,
CAST(CONCAT(YEAR(f.Datum), '-', MONTH(F.DATUM),'-', '01') AS DATE) AS Datum,
sum(f.ObetaldDagJusterad) AS JusteringFrånvaroDagar
from fact.FteFrånvaroJustering F
GROUP BY 
f.AnstNr,
YEAR(f.Datum),
MONTH(F.DATUM)
),

KolumnerInScoope as(
SELECT 
ff.*,
jf.JusteringFrånvaroDagar,
DATEDIFF(DAY, FF.Datum, EOMONTH(FF.DATUM))+1 AS AntalDagarMånad
FROM FACT.FactFTE FF
LEFT JOIN JusteradFrånvaro JF ON FF.AnstNr = JF.AnstNr AND FF.Datum = JF.Datum
),

JusteradFte as(
SELECT *,
-(cast(round(cast(JusteringFrånvaroDagar as decimal(10,4)) / cast(AntalDagarMånad as decimal(10,4)),2) as decimal(10,2))) as JusteringFte
from KolumnerInScoope)


SELECT *
FROM(


SELECT 
JF.AnställdsSk,
JF.ANSTNR AS AnställningsNr,
JF.KOSTNADSSTÄLLE AS KostnadsStälle,
JF.ANSTÄLLNINGSFORM AS AnställningsForm,
JF.DATUM AS Datum,
JF.KontraktStartMånad,
JF.KontraktsSlutMånad,
JF.SYSSELSÄTTNINGSGRAD AS SysselSättningsGrad,
CAST(ROUND(JF.FTE,2) AS DECIMAL(10,2)) AS Fte,
round(cast(JF.JusteringFte as decimal(10,2)), 2) AS FrånvaroJustering,
CASE WHEN CAST(ROUND(JF.FTE,2) AS DECIMAL(10,2))  + COALESCE(cast(JF.JusteringFte as decimal(10,2)),0) < 0 THEN 0 ELSE CAST(ROUND(JF.FTE,2) AS DECIMAL(10,2))  + COALESCE(cast(JF.JusteringFte as decimal(10,2)),0) END AS JusteradFte,
JF.ANTALDAGARMÅNAD AS AntalDagarMånad,
JF.JusteringFrånvaroDagar,
JF.TillTrädesDatum,
JF.TillTrädeTomDatum
FROM JusteradFte JF
) x
--where x.JusteradFte <0

---- Något verkar vara fel med joinen för den genererar fler rader än ursprung !!!! ---
