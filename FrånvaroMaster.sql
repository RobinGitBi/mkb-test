/* ===========================
   Parametrar
   =========================== */
DECLARE @MaxCalendarGapSJ int = 5;     -- Bryt SJ-kedja om glapp > 5 kalenderdagar (mellan observerade SJ/SE-dagar)
DECLARE @MaxCalendarGapFL int = 1;     -- Bryt FL-kedja om glapp > 1 dag
DECLARE @MaxCalendarGapTJ int = 1;     -- Bryt TJ-kedja om glapp > 1 dag
DECLARE @SickThresholdDays int = 14;   -- 14-dagarsregeln (kalenderdagar i kedjan)
DECLARE @YearMin int = NULL;           -- t.ex. 2024 (NULL = ingen filtrering)

/* ===========================
   1) Expandera fr�nvaro till datum (inkl. SE som brygga)
   =========================== */
WITH UtbrutenFr�nvaro AS (
    SELECT 
        F.Ftgnr,
        F.Anstnr,
        F.Fomdatum,
        F.Tomdatum,
        F.Kalenderdagar,
        F.Procent,
        F.[Timestamp],
        F.Kortkod,
        DATEADD(DAY, n.number, F.Fomdatum) AS Fr�nvaroDatum
    FROM [MKBBIStage].[Agda].[Fr�nvaro] F
    JOIN master.dbo.spt_values n
      ON n.type = 'P'
     AND n.number BETWEEN 0 AND DATEDIFF(DAY, F.Fomdatum, F.Tomdatum)  -- inklusiv expansion
    WHERE F.Kortkod IN ('SJ','FL','TJ','SE') -- SE anv�nds endast f�r bryggning/avslut
),

/* ===========================
   2) Senaste avl�sning per dag & typ
   =========================== */
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

/* ===========================
   3) SJ-kedja (SE bryggar + kan avsluta)
   =========================== */
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
-- Kedjegr�nser per GruppID och slopa kedjor som saknar SJ helt
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
-- Full kalender per kedja (alla datum fr�n f�rsta SJ till kedjeslut, inkl. SE/helger)
SJKalender AS (
    SELECT
        b.Anstnr,
        b.GruppID,
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
-- Endast observerade SJ-dagar (f�r procentsats/diagnostik)
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

/* ===========================
   4) FL-kedja (SE bryggar)
   =========================== */
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

/* ===========================
   5) TJ-kedja (SE bryggar)
   =========================== */
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

/* ===========================
   6) M�nadsaggregering per kedja (GruppID)
      - SJ: r�kna p� kedjans KALENDER (inkl. helger/SE)
      - FL/TJ: r�kna kalenderdagar i kedjan (ingen 14-dagarsregel)
   =========================== */
PerManad_SJ AS (
    SELECT
        k.Anstnr,
        k.GruppID,                -- beh�ll kedje-ID
        'SJ' AS Kortkod,
        YEAR(k.KalDag)  AS �r,
        MONTH(k.KalDag) AS M�nad,
        MIN(b.PeriodStart_SJ) AS PeriodStart,
        MAX(b.KedjeSlut)      AS PeriodEnd,
        COUNT(DISTINCT k.KalDag) AS KalenderdagarDennaManad,  -- antal kalenderdatum i m�naden inom kedjan
        -- Genomsnittlig syssels.grad fr�n observerade SJ-dagar i m�naden (kan bli NULL om inga SJ-dagar samma m�nad)
        AVG(CASE WHEN YEAR(s.Fr�nvaroDatum)=YEAR(k.KalDag) AND MONTH(s.Fr�nvaroDatum)=MONTH(k.KalDag)
                 THEN s.Procent END) AS GenomsnittligSysselsattningsgrad,
        COUNT(DISTINCT CASE WHEN k.CalendarDayNr > @SickThresholdDays THEN k.KalDag END) AS EjBetaldaDagarUtanProcent,
        CAST(COUNT(DISTINCT CASE WHEN k.CalendarDayNr > @SickThresholdDays THEN k.KalDag END) AS decimal(18,7)) AS EjBetaldaDagarDennaManad,
        DAY(EOMONTH(MIN(k.KalDag))) AS DagarIM�naden
    FROM SJKalender k
    JOIN SJKedjaValida b
      ON b.Anstnr = k.Anstnr AND b.GruppID = k.GruppID
    LEFT JOIN SJ_ObserveradeDagar s
      ON s.Anstnr = k.Anstnr AND s.GruppID = k.GruppID
    GROUP BY k.Anstnr, k.GruppID, YEAR(k.KalDag), MONTH(k.KalDag)
),
-- FL: bygg en enkel kalender per kedja (helger ing�r)
FLKalender AS (
    SELECT
        b.Anstnr,
        b.GruppID,
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
        k.GruppID,
        'FL' AS Kortkod,
        YEAR(k.KalDag)  AS �r,
        MONTH(k.KalDag) AS M�nad,
        MIN(b.PeriodStart_FL) AS PeriodStart,
        MAX(b.KedjeSlut)      AS PeriodEnd,
        COUNT(DISTINCT k.KalDag) AS KalenderdagarDennaManad,
        AVG(ABS(f.Procent)) AS GenomsnittligSysselsattningsgrad,
        COUNT(DISTINCT k.KalDag) AS EjBetaldaDagarUtanProcent,
        CAST(COUNT(DISTINCT k.KalDag) AS decimal(18,7)) AS EjBetaldaDagarDennaManad,
        DAY(EOMONTH(MIN(k.KalDag))) AS DagarIM�naden
    FROM FLKalender k
    JOIN FLBounds b ON b.Anstnr = k.Anstnr AND b.GruppID = k.GruppID
    LEFT JOIN SenastePerDatum f ON f.Anstnr = k.Anstnr AND f.Fr�nvaroDatum = k.KalDag AND f.Kortkod = 'FL'
    GROUP BY k.Anstnr, k.GruppID, YEAR(k.KalDag), MONTH(k.KalDag)
),
-- TJ: kalender per kedja
TJKalender AS (
    SELECT
        b.Anstnr,
        b.GruppID,
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
        k.GruppID,
        'TJ' AS Kortkod,
        YEAR(k.KalDag)  AS �r,
        MONTH(k.KalDag) AS M�nad,
        MIN(b.PeriodStart_TJ) AS PeriodStart,
        MAX(b.KedjeSlut)      AS PeriodEnd,
        COUNT(DISTINCT k.KalDag) AS KalenderdagarDennaManad,
        AVG(ABS(t.Procent)) AS GenomsnittligSysselsattningsgrad,
        COUNT(DISTINCT k.KalDag) AS EjBetaldaDagarUtanProcent,
        CAST(COUNT(DISTINCT k.KalDag) AS decimal(18,7)) AS EjBetaldaDagarDennaManad,
        DAY(EOMONTH(MIN(k.KalDag))) AS DagarIM�naden
    FROM TJKalender k
    JOIN TJBounds b ON b.Anstnr = k.Anstnr AND b.GruppID = k.GruppID
    LEFT JOIN SenastePerDatum t ON t.Anstnr = k.Anstnr AND t.Fr�nvaroDatum = k.KalDag AND t.Kortkod = 'TJ'
    GROUP BY k.Anstnr, k.GruppID, YEAR(k.KalDag), MONTH(k.KalDag)
)
SELECT *
FROM(
/* ===========================
   7) Slutresultat � en rad per M�NAD och KEDJA (GruppID)
   =========================== */
SELECT 
    Anstnr,
    GruppID,                              -- kedje-ID f�r tydlighet/diagnostik
    Kortkod,
    �r,
    M�nad,
    PeriodStart,
    PeriodEnd,
    KalenderdagarDennaManad,
    GenomsnittligSysselsattningsgrad,
    EjBetaldaDagarUtanProcent,
    EjBetaldaDagarDennaManad,
    DagarIM�naden
FROM PerManad_SJ
WHERE (@YearMin IS NULL OR �r >= @YearMin)

UNION ALL

SELECT 
    Anstnr,
    GruppID,
    Kortkod,
    �r,
    M�nad,
    PeriodStart,
    PeriodEnd,
    KalenderdagarDennaManad,
    GenomsnittligSysselsattningsgrad,
    EjBetaldaDagarUtanProcent,
    EjBetaldaDagarDennaManad,
    DagarIM�naden
FROM PerManad_FL
WHERE (@YearMin IS NULL OR �r >= @YearMin)

UNION ALL

SELECT 
    Anstnr,
    GruppID,
    Kortkod,
    �r,
    M�nad,
    PeriodStart,
    PeriodEnd,
    KalenderdagarDennaManad,
    GenomsnittligSysselsattningsgrad,
    EjBetaldaDagarUtanProcent,
    EjBetaldaDagarDennaManad,
    DagarIM�naden
FROM PerManad_TJ
WHERE (@YearMin IS NULL OR �r >= @YearMin)

--ORDER BY Anstnr, PeriodStart, �r, M�nad, Kortkod
) X
WHERE X.Anstnr = 1290
AND X.PeriodStart = '2024-11-27'
ORDER BY 6 ASC