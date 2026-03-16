USE [MKBBIDW]
GO

/****** Object:  View [dbo].[TestFte20250527]    Script Date: 2026-03-16 15:28:59 ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO



CREATE VIEW [dbo].[TestFte20250527]
AS
WITH DistinctFte AS(
SELECT *,
ROW_NUMBER() OVER(PARTITION BY F.ANST_NR ORDER BY F.ANST_NR DESC) AS RowNum
FROM ViewDimFTE F),

 DistinctFte2 AS(
SELECT *
FROM DistinctFte DF
where DF.RowNum = 1),


DistinctKonstnadsStälle AS(
SELECT *,
ROW_NUMBER() OVER(PARTITION BY X.ANST_NR ORDER BY X.KONTERING_ID DESC) AS RowNum
FROM dim.Konteringar X
WHERE  X.KONTERING = 'Kostnadsställe'),

AktuelltKostnadsStälle as (
SELECT *
FROM DistinctKonstnadsStälle D
WHERE D.RowNum = 1
)


SELECT *
FROM(

SELECT 
a.ANST_NR AS AnställningsNummer,
P.NAMN AS Namn,
A.AR AS År,
A.MANDAD_NR AS Månad,
DATEFROMPARTS(A.AR,A.MANDAD_NR,1) AS Datum,
K.DATA AS KostnadsStälle,
B.Befattning,
K2.FunktionsId AS Funktion,
round(A.FTE/100,2) AS Fte
FROM [MKBBIDW].fact.MonthlyFTE A
LEFT JOIN DistinctFte2 F ON CAST(A.ANST_NR AS INT)  = CAST(F.ANST_NR AS INT)
LEFT JOIN  AGDA.V_DimPersoner P ON CAST(A.ANST_NR AS INT) = CAST(P.Anställningsnummer AS INT)
LEFT JOIN AGDA.V_DimBefattningar B ON CAST(A.ANST_NR AS INT) = CAST(B.Anställningsnummer AS INT)
LEFT JOIN AktuelltKostnadsStälle K ON CAST(A.ANST_NR AS INT) = CAST(K.ANST_NR AS INT)
LEFT JOIN ViewDimKostnadsställe K2 ON K.DATA = k2.KostnadsställeNr
--WHERE A.AR = 2024
UNION ALL
SELECT 
T.Anställningsnummer,
P.Namn AS Namn,
YEAR(T.PERIOD) as Year,
MONTH(T.PERIOD) as Month,
DATEFROMPARTS(YEAR(T.PERIOD),MONTH(T.PERIOD), 1) AS Datum,
K.DATA AS KostnadsStälle,
B.Befattning,
K2.FunktionsId,
ROUND(SUM(T.Antal)/165,2)
FROM fact.Timanställningar T
LEFT JOIN DistinctFte2 F ON T.Anställningsnummer = F.ANST_NR
LEFT JOIN  AGDA.V_DimPersoner P ON CAST(T.Anställningsnummer AS INT) = CAST(P.Anställningsnummer AS INT)
LEFT JOIN AGDA.V_DimBefattningar B ON CAST(T.Anställningsnummer AS INT) = CAST(B.Anställningsnummer AS INT)
LEFT JOIN AktuelltKostnadsStälle K ON CAST(t.Anställningsnummer AS INT) = CAST(K.ANST_NR AS INT)

LEFT JOIN ViewDimKostnadsställe K2 ON K.DATA = k2.KostnadsställeNr
--WHERE T.Period BETWEEN '2024-01-01' AND '2024-12-31'
GROUP BY 
T.Anställningsnummer,
F.Namn,
YEAR(T.Period),
MONTH(T.Period),
F.Kostnadsställe,
K2.FunktionsId,
P.namn,
B.Befattning,
K.DATA
) Tot
WHERE Tot.Datum <= GETDATE()



/*SELECT top 1000 *
FROM fact.Timanställningar T
GROUP BY 


SELECT *
FROM ViewDimFTE*/


/*select *
from viewDimPersoner*/

--- Prognos ----
/*SELECT 
K.KostnadsställeNr,
K.KostnadsställeNamn,
K2.FunktionsId,
X.ANTALFTE as Total,
SUM(X.ANTALFTE) OVER() AS XXX
FROM ViewFactFTEPrognos X
LEFT JOIN ViewDimKostnadsställe K ON X.KostnadsställeSK = K.KostnadsställeSK
LEFT JOIN ViewDimKostnadsställe K2 ON K.KostnadsställeNr = K2.KostnadsställeNr
WHERE X.PrognosPeriod = '2024T2'*/





--select *
--from ViewDimFunktion

--select *
--from ViewDimKostnadsställe
--order by 2 asc



/*SELECT *
FROM ViewDimFTE*/




/*SELECT *
FROM fact.Timanställningar T*/
GO


