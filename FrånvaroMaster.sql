/* ========= Parametrar ========= */
DECLARE @MaxCalendarGapSJ int = 5;     -- bryt SJ-kedja om glapp > 5 kalenderdagar (SJ/SE)
DECLARE @MaxCalendarGapFL int = 1;     -- bryt FL-kedja om glapp > 1 dag
DECLARE @MaxCalendarGapTJ int = 1;     -- bryt TJ-kedja om glapp > 1 dag
DECLARE @SickThresholdDays int = 14;   -- 14-dagarsregeln (kalenderdagar)
DECLARE @YearMin int = NULL;           -- t.ex. 2024

/* 1) Expandera till datum (inkl. SE som brygga) */
WITH UtbrutenFr�nvaro AS (
    SELECT 
        F.Ftgnr, F.Anstnr, F.Fomdatum, F.Tomdatum, F.Kalenderdagar,
        F.Procent, F.[Timestamp], F.Kortkod,
        DATEADD(DAY, n.number, F.Fomdatum) AS Fr�nvaroDatum
    FROM [MKBBIStage].[Agda].[Fr�nvaro] F
    JOIN master.dbo.spt_values n
      ON n.type = 'P'
     AND n.number BETWEEN 0 AND DATEDIFF(DAY, F.Fomdatum, F.Tomdatum)  -- inklusivt
    WHERE F.Kortkod IN ('SJ','FL','TJ','SE')    -- SE endast som brygga
),
/* 2) Senaste avl�sning per dag & typ */
SenastePerDatum AS (
    SELECT *
    FROM (
        SELECT *,
               ROW_NUMBER() OVER (
                 PARTITION BY Anstnr, Fr�nvaroDatum, Kortkod
                 ORDER BY [Timestamp] DESC
               ) AS rn
        FROM UtbrutenFr�nvaro
    ) t
    WHERE rn = 1
),

/* ===== SJ-kedja (SE bryggar och kan avsluta) ===== */
SJKedja AS (
    SELECT *,
           LAG(Fr�nvaroDatum) OVER (PARTITION BY Anstnr ORDER BY Fr�nvaroDatum) AS PrevDatum
    FROM SenastePerDatum
    WHERE Kortkod IN ('SJ','SE')
),
SJKedjaFlaggad AS (
    SELECT *,
           DATEDIFF(DAY, PrevDatum, Fr�nvaroDatum) AS DagGap,
           SUM(CASE
                 WHEN PrevDatum IS NULL
                   OR DATEDIFF(DAY, PrevDatum, Fr�nvaroDatum) > @MaxCalendarGapSJ
                 THEN 1 ELSE 0
               END) OVER (PARTITION BY Anstnr ORDER BY Fr�nvaroDatum ROWS UNBOUNDED PRECEDING) AS GruppID
    FROM SJKedja
),
-- Kedjegr�nser och filtrera bort kedjor utan SJ
SJBounds AS (
    SELECT
        Anstnr,
        GruppID,
        MIN(CASE WHEN Kortkod='SJ' THEN Fr�nvaroDatum END) AS PeriodStart_SJ,
        MAX(Fr�nvaroDatum)                                   AS KedjeSlut
    FROM SJKedjaFlaggad
    GROUP BY Anstnr, GruppID
),
SJKedjaValida AS (
    SELECT * FROM SJBounds WHERE PeriodStart_SJ IS NOT NULL
),
-- Full kalender f�r kedjan (alla datum fr�n f�rsta SJ till kedjeslut)
SJKalender AS (
    SELECT
        b.Anstnr, b.GruppID,
        DATEADD(DAY, n.number, b.PeriodStart_SJ) AS KalDag,
        ROW_NUMBER() OVER (
            PARTITION BY b.Anstnr, b.GruppID
            ORDER BY DATEADD(DAY, n.number, b.PeriodStart_SJ)
        ) AS CalendarDayNr
    FROM SJKedjaValida b
    JOIN master.dbo.spt_values n
      ON n.type = 'P'
     AND n.number BETWEEN 0 AND DATEDIFF(DAY, b.PeriodStart_SJ, b.KedjeSlut)
),
-- Observerade SJ-dagar (f�r procent/diagnostik)
SJ_ObserveradeDagar AS (
    SELECT 
        s.Anstnr,
        s.Fr�nvaroDatum,
        ABS(s.Procent) AS Procent,
        'SJ' AS Kortkod,
        g.GruppID
    FROM SenastePerDatum s
    JOIN SJKedjaFlaggad g
      ON g.Anstnr = s.Anstnr
     AND g.Fr�nvaroDatum = s.Fr�nvaroDatum
    WHERE s.Kortkod = 'SJ'
),
-- M�nads-agg f�r SJ: r�kna p� hela KALENDER-kedjan (inte bara SJ-dagar)
PerManad_SJ AS (
    SELECT
        k.Anstnr,
        'SJ' AS Kortkod,
        YEAR(k.KalDag) AS �r,
        MONTH(k.KalDag) AS M�nad,
        MIN(b.PeriodStart_SJ) AS PeriodStart,
        MAX(b.KedjeSlut)      AS PeriodEnd,
        COUNT(DISTINCT k.KalDag) AS KalenderdagarDennaManad,  -- t.ex. 21 f�r mars i ditt fall
        -- Genomsnittlig syssels�ttningsgrad baseras p� observerade SJ-dagar i m�naden (om 100% blir 100)
        AVG(CASE WHEN YEAR(s.Fr�nvaroDatum)=YEAR(k.KalDag) AND MONTH(s.Fr�nvaroDatum)=MONTH(k.KalDag)
                 THEN s.Procent END) AS GenomsnittligSysselsattningsgrad,
        COUNT(DISTINCT CASE WHEN k.CalendarDayNr > @SickThresholdDays THEN k.KalDag END) AS EjBetaldaDagarUtanProcent, -- t.ex. 9
        -- Om ni alltid behandlar obetalda efter dag 14 som 100%, s�tt lika med ovan.
        CAST(COUNT(DISTINCT CASE WHEN k.CalendarDayNr > @SickThresholdDays THEN k.KalDag END) AS decimal(18,7)) AS EjBetaldaDagarDennaManad,
        DAY(EOMONTH(MIN(k.KalDag))) AS DagarIM�naden
    FROM SJKalender k
    JOIN SJKedjaValida b
      ON b.Anstnr = k.Anstnr AND b.GruppID = k.GruppID
    LEFT JOIN SJ_ObserveradeDagar s
      ON s.Anstnr = k.Anstnr AND s.GruppID = k.GruppID
    GROUP BY k.Anstnr, YEAR(k.KalDag), MONTH(k.KalDag)
),

/* ===== FL-kedja (SE bryggar) � r�knas dag-f�r-dag som tidigare ===== */
FLKedja AS (
    SELECT *,
           LAG(Fr�nvaroDatum) OVER (PARTITION BY Anstnr ORDER BY Fr�nvaroDatum) AS PrevDatum
    FROM SenastePerDatum
    WHERE Kortkod IN ('FL','SE')
),
FLKedjaFlaggad AS (
    SELECT *,
           DATEDIFF(DAY, PrevDatum, Fr�nvaroDatum) AS DagGap,
           SUM(CASE
                 WHEN PrevDatum IS NULL
                   OR DATEDIFF(DAY, PrevDatum, Fr�nvaroDatum) > @MaxCalendarGapFL
                 THEN 1 ELSE 0
               END) OVER (PARTITION BY Anstnr ORDER BY Fr�nvaroDatum ROWS UNBOUNDED PRECEDING) AS GruppID
    FROM FLKedja
),
FLBounds AS (
    SELECT
        Anstnr,
        GruppID,
        MIN(CASE WHEN Kortkod='FL' THEN Fr�nvaroDatum END) AS PeriodStart_FL,
        MAX(Fr�nvaroDatum)                                   AS KedjeSlut
    FROM FLKedjaFlaggad
    GROUP BY Anstnr, GruppID
),
-- Full kalender �ven f�r FL (s� helger inkluderas)
FLKalender AS (
    SELECT
        b.Anstnr, b.GruppID,
        DATEADD(DAY, n.number, b.PeriodStart_FL) AS KalDag
    FROM FLBounds b
    JOIN master.dbo.spt_values n
      ON n.type = 'P'
     AND b.PeriodStart_FL IS NOT NULL
     AND n.number BETWEEN 0 AND DATEDIFF(DAY, b.PeriodStart_FL, b.KedjeSlut)
),
PerManad_FL AS (
    SELECT
        k.Anstnr,
        'FL' AS Kortkod,
        YEAR(k.KalDag) AS �r,
        MONTH(k.KalDag) AS M�nad,
        MIN(b.PeriodStart_FL) AS PeriodStart,
        MAX(b.KedjeSlut)      AS PeriodEnd,
        COUNT(DISTINCT k.KalDag) AS KalenderdagarDennaManad,
        AVG(ABS(f.Procent)) AS GenomsnittligSysselsattningsgrad,
        COUNT(DISTINCT k.KalDag) AS EjBetaldaDagarUtanProcent,
        CAST(COUNT(DISTINCT k.KalDag) AS decimal(18,7)) AS EjBetaldaDagarDennaManad,
        DAY(EOMONTH(MIN(k.KalDag))) AS DagarIM�naden
    FROM FLKalender k
    JOIN FLBounds b ON b.Anstnr=k.Anstnr AND b.GruppID=k.GruppID
    LEFT JOIN SenastePerDatum f ON f.Anstnr=k.Anstnr AND f.Fr�nvaroDatum=k.KalDag AND f.Kortkod='FL'
    GROUP BY k.Anstnr, YEAR(k.KalDag), MONTH(k.KalDag)
),

/* ===== TJ-kedja (SE bryggar) � helger inkluderas ===== */
TJKedja AS (
    SELECT *,
           LAG(Fr�nvaroDatum) OVER (PARTITION BY Anstnr ORDER BY Fr�nvaroDatum) AS PrevDatum
    FROM SenastePerDatum
    WHERE Kortkod IN ('TJ','SE')
),
TJKedjaFlaggad AS (
    SELECT *,
           DATEDIFF(DAY, PrevDatum, Fr�nvaroDatum) AS DagGap,
           SUM(CASE
                 WHEN PrevDatum IS NULL
                   OR DATEDIFF(DAY, PrevDatum, Fr�nvaroDatum) > @MaxCalendarGapTJ
                 THEN 1 ELSE 0
               END) OVER (PARTITION BY Anstnr ORDER BY Fr�nvaroDatum ROWS UNBOUNDED PRECEDING) AS GruppID
    FROM TJKedja
),
TJBounds AS (
    SELECT
        Anstnr,
        GruppID,
        MIN(CASE WHEN Kortkod='TJ' THEN Fr�nvaroDatum END) AS PeriodStart_TJ,
        MAX(Fr�nvaroDatum)                                   AS KedjeSlut
    FROM TJKedjaFlaggad
    GROUP BY Anstnr, GruppID
),
TJKalender AS (
    SELECT
        b.Anstnr, b.GruppID,
        DATEADD(DAY, n.number, b.PeriodStart_TJ) AS KalDag
    FROM TJBounds b
    JOIN master.dbo.spt_values n
      ON n.type = 'P'
     AND b.PeriodStart_TJ IS NOT NULL
     AND n.number BETWEEN 0 AND DATEDIFF(DAY, b.PeriodStart_TJ, b.KedjeSlut)
),
PerManad_TJ AS (
    SELECT
        k.Anstnr,
        'TJ' AS Kortkod,
        YEAR(k.KalDag) AS �r,
        MONTH(k.KalDag) AS M�nad,
        MIN(b.PeriodStart_TJ) AS PeriodStart,
        MAX(b.KedjeSlut)      AS PeriodEnd,
        COUNT(DISTINCT k.KalDag) AS KalenderdagarDennaManad,
        AVG(ABS(t.Procent)) AS GenomsnittligSysselsattningsgrad,
        COUNT(DISTINCT k.KalDag) AS EjBetaldaDagarUtanProcent,
        CAST(COUNT(DISTINCT k.KalDag) AS decimal(18,7)) AS EjBetaldaDagarDennaManad,
        DAY(EOMONTH(MIN(k.KalDag))) AS DagarIM�naden
    FROM TJKalender k
    JOIN TJBounds b ON b.Anstnr=k.Anstnr AND b.GruppID=k.GruppID
    LEFT JOIN SenastePerDatum t ON t.Anstnr=k.Anstnr AND t.Fr�nvaroDatum=k.KalDag AND t.Kortkod='TJ'
    GROUP BY k.Anstnr, YEAR(k.KalDag), MONTH(k.KalDag)
)

/* ===== Slutresultat ===== */
SELECT *
FROM(
SELECT * FROM PerManad_SJ
WHERE (@YearMin IS NULL OR �r >= @YearMin)
UNION ALL
SELECT * FROM PerManad_FL
WHERE (@YearMin IS NULL OR �r >= @YearMin)
UNION ALL
SELECT * FROM PerManad_TJ
WHERE (@YearMin IS NULL OR �r >= @YearMin)
--ORDER BY Anstnr, PeriodStart, �r, M�nad
) X
WHERE X.�r in (2024, 2025)
AND X.Anstnr = 1290
and x.PeriodStart = '2024-11-27'
order by x.PeriodStart asc