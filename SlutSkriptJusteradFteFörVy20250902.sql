
WITH JusteradFrånvaro AS(
select F.AnstNr,
F.Datum,
F.FrånvaroStart,
F.FrånvaroSlut,
SUM(F.FrånvaroAntalObetaldaDagar) AS AntalObetaldaDagar
from fact.FteFrånvaroJustering F
group by 
F.AnstNr,
YEAR(F.DATUM),
MONTH(F.DATUM),
F.Datum,
F.FrånvaroStart,
F.FrånvaroSlut
HAVING coalesce(SUM(F.FrånvaroAntalObetaldaDagar),0) <> 0
),

KolumnerInScoope as(
SELECT 
ff.*,
jf.AntalObetaldaDagar,
DATEDIFF(DAY, FF.Datum, EOMONTH(FF.DATUM))+1 AS AntalDagarMånad
FROM FACT.FactFTE FF
LEFT JOIN JusteradFrånvaro JF ON FF.AnstNr = JF.AnstNr AND FF.Datum = JF.Datum
),

JusteradFte as(
SELECT *,
-(cast(round(cast(AntalObetaldaDagar as decimal(10,4)) / cast(AntalDagarMånad as decimal(10,4)),2) as decimal(10,2))) * Sysselsättningsgrad/100 as JusteringFte
from KolumnerInScoope)

SELECT 
CAST(ROUND(JF.FTE,2) AS DECIMAL(10,2)) AS Fte,
JF.JusteringFte AS FrånvaroJustering,
CAST(ROUND(JF.FTE,2) AS DECIMAL(10,2))  + COALESCE(JF.JusteringFte,0) AS JusteradFte,
*
FROM JusteradFte JF


