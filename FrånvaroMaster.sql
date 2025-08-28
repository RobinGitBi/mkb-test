/* ========= Parametrar ========= */
DECLARE @MaxCalendarGapSJ int = 5;     -- bryt SJ-kedja om glapp > 5 kalenderdagar (SJ/SE)
DECLARE @MaxCalendarGapFL int = 1;     -- bryt FL-kedja om glapp > 1 dag
DECLARE @MaxCalendarGapTJ int = 1;     -- bryt TJ-kedja om glapp > 1 dag
DECLARE @SickThresholdDays int = 14;   -- 14-dagarsregeln (kalenderdagar)
DECLARE @YearMin int = NULL;           -- t.ex. 2024

/* 1) Expandera till datum (inkl. SE som brygga) */
WITH UtbrutenFrånvaro AS (
    SELECT 
        F.Ftgnr, F.Anstnr, F.Fomdatum, F.Tomdatum, F.Kalenderdagar,
        F.Procent, F.[Timestamp], F.Kortkod,
        DATEADD(DAY, n.number, F.Fomdatum) AS FrånvaroDatum
    FROM [MKBBIStage].[Agda].[Frånvaro] F
    JOIN master.dbo.spt_values n
      ON n.type = 'P'
     AND n.number BETWEEN 0 AND DATEDIFF(DAY, F.Fomdatum, F.Tomdatum)  -- inklusivt
    WHERE F.Kortkod IN ('SJ','FL','TJ','SE')    -- SE endast som brygga
),
/* 2) Senaste avläsning per dag & typ */
SenastePerDatum AS (
    SELECT *
    FROM (
        SELECT *,
               ROW_NUMBER() OVER (
                 PARTITION BY Anstnr, FrånvaroDatum, Kortkod
                 ORDER BY [Timestamp] DESC
               ) AS rn
        FROM UtbrutenFrånvaro
    ) t
    WHERE rn = 1
),

/* ===== SJ-kedja (SE bryggar och kan avsluta) ===== */
SJKedja AS (
    SELECT *,
           LAG(FrånvaroDatum) OVER (PARTITION BY Anstnr ORDER BY FrånvaroDatum) AS PrevDatum
    FROM SenastePerDatum
    WHERE Kortkod IN ('SJ','SE')
),
SJKedjaFlaggad AS (
    SELECT *,
           DATEDIFF(DAY, PrevDatum, FrånvaroDatum) AS DagGap,
           SUM(CASE
                 WHEN PrevDatum IS NULL
                   OR DATEDIFF(DAY, PrevDatum, FrånvaroDatum) > @MaxCalendarGapSJ
                 THEN 1 ELSE 0
               END) OVER (PARTITION BY Anstnr ORDER BY FrånvaroDatum ROWS UNBOUNDED PRECEDING) AS GruppID
    FROM SJKedja
),
-- Kedjegränser och filtrera bort kedjor utan SJ
SJBounds AS (
    SELECT
        Anstnr,
        GruppID,
        MIN(CASE WHEN Kortkod='SJ' THEN FrånvaroDatum END) AS PeriodStart_SJ,
        MAX(FrånvaroDatum)                                   AS KedjeSlut
    FROM SJKedjaFlaggad
    GROUP BY Anstnr, GruppID
),
SJKedjaValida AS (
    SELECT * FROM SJBounds WHERE PeriodStart_SJ IS NOT NULL
),
-- Full kalender för kedjan (alla datum från första SJ till kedjeslut)
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
-- Observerade SJ-dagar (för procent/diagnostik)
SJ_ObserveradeDagar AS (
    SELECT 
        s.Anstnr,
        s.FrånvaroDatum,
        ABS(s.Procent) AS Procent,
        'SJ' AS Kortkod,
        g.GruppID
    FROM SenastePerDatum s
    JOIN SJKedjaFlaggad g
      ON g.Anstnr = s.Anstnr
     AND g.FrånvaroDatum = s.FrånvaroDatum
    WHERE s.Kortkod = 'SJ'
),
-- Månads-agg för SJ: räkna på hela KALENDER-kedjan (inte bara SJ-dagar)
PerManad_SJ AS (
    SELECT
        k.Anstnr,
        'SJ' AS Kortkod,
        YEAR(k.KalDag) AS År,
        MONTH(k.KalDag) AS Månad,
        MIN(b.PeriodStart_SJ) AS PeriodStart,
        MAX(b.KedjeSlut)      AS PeriodEnd,
        COUNT(DISTINCT k.KalDag) AS KalenderdagarDennaManad,  -- t.ex. 21 för mars i ditt fall
        -- Genomsnittlig sysselsättningsgrad baseras på observerade SJ-dagar i månaden (om 100% blir 100)
        AVG(CASE WHEN YEAR(s.FrånvaroDatum)=YEAR(k.KalDag) AND MONTH(s.FrånvaroDatum)=MONTH(k.KalDag)
                 THEN s.Procent END) AS GenomsnittligSysselsattningsgrad,
        COUNT(DISTINCT CASE WHEN k.CalendarDayNr > @SickThresholdDays THEN k.KalDag END) AS EjBetaldaDagarUtanProcent, -- t.ex. 9
        -- Om ni alltid behandlar obetalda efter dag 14 som 100%, sätt lika med ovan.
        CAST(COUNT(DISTINCT CASE WHEN k.CalendarDayNr > @SickThresholdDays THEN k.KalDag END) AS decimal(18,7)) AS EjBetaldaDagarDennaManad,
        DAY(EOMONTH(MIN(k.KalDag))) AS DagarIMånaden
    FROM SJKalender k
    JOIN SJKedjaValida b
      ON b.Anstnr = k.Anstnr AND b.GruppID = k.GruppID
    LEFT JOIN SJ_ObserveradeDagar s
      ON s.Anstnr = k.Anstnr AND s.GruppID = k.GruppID
    GROUP BY k.Anstnr, YEAR(k.KalDag), MONTH(k.KalDag)
),

/* ===== FL-kedja (SE bryggar) – räknas dag-för-dag som tidigare ===== */
FLKedja AS (
    SELECT *,
           LAG(FrånvaroDatum) OVER (PARTITION BY Anstnr ORDER BY FrånvaroDatum) AS PrevDatum
    FROM SenastePerDatum
    WHERE Kortkod IN ('FL','SE')
),
FLKedjaFlaggad AS (
    SELECT *,
           DATEDIFF(DAY, PrevDatum, FrånvaroDatum) AS DagGap,
           SUM(CASE
                 WHEN PrevDatum IS NULL
                   OR DATEDIFF(DAY, PrevDatum, FrånvaroDatum) > @MaxCalendarGapFL
                 THEN 1 ELSE 0
               END) OVER (PARTITION BY Anstnr ORDER BY FrånvaroDatum ROWS UNBOUNDED PRECEDING) AS GruppID
    FROM FLKedja
),
FLBounds AS (
    SELECT
        Anstnr,
        GruppID,
        MIN(CASE WHEN Kortkod='FL' THEN FrånvaroDatum END) AS PeriodStart_FL,
        MAX(FrånvaroDatum)                                   AS KedjeSlut
    FROM FLKedjaFlaggad
    GROUP BY Anstnr, GruppID
),
-- Full kalender även för FL (så helger inkluderas)
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
        YEAR(k.KalDag) AS År,
        MONTH(k.KalDag) AS Månad,
        MIN(b.PeriodStart_FL) AS PeriodStart,
        MAX(b.KedjeSlut)      AS PeriodEnd,
        COUNT(DISTINCT k.KalDag) AS KalenderdagarDennaManad,
        AVG(ABS(f.Procent)) AS GenomsnittligSysselsattningsgrad,
        COUNT(DISTINCT k.KalDag) AS EjBetaldaDagarUtanProcent,
        CAST(COUNT(DISTINCT k.KalDag) AS decimal(18,7)) AS EjBetaldaDagarDennaManad,
        DAY(EOMONTH(MIN(k.KalDag))) AS DagarIMånaden
    FROM FLKalender k
    JOIN FLBounds b ON b.Anstnr=k.Anstnr AND b.GruppID=k.GruppID
    LEFT JOIN SenastePerDatum f ON f.Anstnr=k.Anstnr AND f.FrånvaroDatum=k.KalDag AND f.Kortkod='FL'
    GROUP BY k.Anstnr, YEAR(k.KalDag), MONTH(k.KalDag)
),

/* ===== TJ-kedja (SE bryggar) – helger inkluderas ===== */
TJKedja AS (
    SELECT *,
           LAG(FrånvaroDatum) OVER (PARTITION BY Anstnr ORDER BY FrånvaroDatum) AS PrevDatum
    FROM SenastePerDatum
    WHERE Kortkod IN ('TJ','SE')
),
TJKedjaFlaggad AS (
    SELECT *,
           DATEDIFF(DAY, PrevDatum, FrånvaroDatum) AS DagGap,
           SUM(CASE
                 WHEN PrevDatum IS NULL
                   OR DATEDIFF(DAY, PrevDatum, FrånvaroDatum) > @MaxCalendarGapTJ
                 THEN 1 ELSE 0
               END) OVER (PARTITION BY Anstnr ORDER BY FrånvaroDatum ROWS UNBOUNDED PRECEDING) AS GruppID
    FROM TJKedja
),
TJBounds AS (
    SELECT
        Anstnr,
        GruppID,
        MIN(CASE WHEN Kortkod='TJ' THEN FrånvaroDatum END) AS PeriodStart_TJ,
        MAX(FrånvaroDatum)                                   AS KedjeSlut
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
        YEAR(k.KalDag) AS År,
        MONTH(k.KalDag) AS Månad,
        MIN(b.PeriodStart_TJ) AS PeriodStart,
        MAX(b.KedjeSlut)      AS PeriodEnd,
        COUNT(DISTINCT k.KalDag) AS KalenderdagarDennaManad,
        AVG(ABS(t.Procent)) AS GenomsnittligSysselsattningsgrad,
        COUNT(DISTINCT k.KalDag) AS EjBetaldaDagarUtanProcent,
        CAST(COUNT(DISTINCT k.KalDag) AS decimal(18,7)) AS EjBetaldaDagarDennaManad,
        DAY(EOMONTH(MIN(k.KalDag))) AS DagarIMånaden
    FROM TJKalender k
    JOIN TJBounds b ON b.Anstnr=k.Anstnr AND b.GruppID=k.GruppID
    LEFT JOIN SenastePerDatum t ON t.Anstnr=k.Anstnr AND t.FrånvaroDatum=k.KalDag AND t.Kortkod='TJ'
    GROUP BY k.Anstnr, YEAR(k.KalDag), MONTH(k.KalDag)
)

/* ===== Slutresultat ===== */
SELECT *
FROM(
SELECT * FROM PerManad_SJ
WHERE (@YearMin IS NULL OR År >= @YearMin)
UNION ALL
SELECT * FROM PerManad_FL
WHERE (@YearMin IS NULL OR År >= @YearMin)
UNION ALL
SELECT * FROM PerManad_TJ
WHERE (@YearMin IS NULL OR År >= @YearMin)
--ORDER BY Anstnr, PeriodStart, År, Månad
) X
WHERE X.År in (2024, 2025)
AND X.Anstnr = 1290
and x.PeriodStart = '2024-11-27'
order by x.PeriodStart asc