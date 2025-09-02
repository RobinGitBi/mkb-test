/* ===========================
   Parametrar
   =========================== */
DECLARE @MaxCalendarGapSJ int = 5;     -- Bryt SJ-kedja om glapp > 5 kalenderdagar (observerade SJ/SE-dagar)
DECLARE @MaxCalendarGapFL int = 1;     -- Bryt FL-kedja om glapp > 1 dag (endast FL/FLB; SE bryggar ej)
DECLARE @MaxCalendarGapTJ int = 1;     -- Bryt TJ-kedja om glapp > 1 dag (endast TJ; SE bryggar ej)
DECLARE @SickThresholdDays int = 14;   -- 14-dagarsregeln (kalenderdagar i SJ-kedjan)
DECLARE @YearMin int = NULL;           -- t.ex. 2024 (NULL = ingen filtrering)

/* ===========================
   1) Expandera frånvaro till datum
   - SE behövs i datat för att kunna brygga SJ, men ska inte förlänga slutet.
   =========================== */
WITH UtbrutenFrånvaro AS (
    SELECT 
        F.Ftgnr,
        F.Anstnr,
        F.Fomdatum,
        F.Tomdatum,
        F.Kalenderdagar,
        F.Procent,
        F.[Timestamp],
        F.Kortkod,
        DATEADD(DAY, n.number, F.Fomdatum) AS FrånvaroDatum
    FROM [MKBBIStage].[Agda].[Frånvaro] F
    JOIN master.dbo.spt_values n
      ON n.type = 'P'
     AND n.number BETWEEN 0 AND DATEDIFF(DAY, F.Fomdatum, F.Tomdatum)  -- inklusiv expansion
    WHERE F.Kortkod IN ('SJ','FL','FLB','TJ','SE')
),

/* ===========================
   2) Senaste avläsning per dag & typ (dedup)
   =========================== */
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

/* ===========================
   3) SJ-kedja
   - Använd SJ + SE för att identifiera kedjor (SE bryggar).
   - MEN: PeriodEnd för SJ = sista SJ-dagen (SE förlänger inte slutet).
   =========================== */
SJKedja AS (
    SELECT *,
           LAG(FrånvaroDatum) OVER (PARTITION BY Anstnr ORDER BY FrånvaroDatum) AS PrevDatum
    FROM SenastePerDatum
    WHERE Kortkod IN ('SJ','SE')  -- SE bryggar mellan SJ
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
-- Bounds per kedja: start = första SJ, slut = sista SJ (SE får INTE förlänga)
SJBounds AS (
    SELECT
        Anstnr,
        GruppID,
        MIN(CASE WHEN Kortkod='SJ' THEN FrånvaroDatum END) AS PeriodStart_SJ,
        MAX(CASE WHEN Kortkod='SJ' THEN FrånvaroDatum END) AS PeriodEnd_SJ      -- <-- ändrat: endast SJ
    FROM SJKedjaFlaggad
    GROUP BY Anstnr, GruppID
),
-- Slopa kedjor som saknar någon SJ
SJKedjaValida AS (
    SELECT * 
    FROM SJBounds 
    WHERE PeriodStart_SJ IS NOT NULL AND PeriodEnd_SJ IS NOT NULL
),
-- Full kalender från första SJ till sista SJ (SE i slutet tas alltså inte med)
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
     AND n.number BETWEEN 0 AND DATEDIFF(DAY, b.PeriodStart_SJ, b.PeriodEnd_SJ)  -- <-- till sista SJ
),
-- Observerade SJ-dagar (för procentsats/diagnostik)
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

/* ===========================
   4) FL-kedja (SE bryggar INTE) — FL + FLB
   =========================== */
FLKedja AS (
    SELECT *,
           LAG(FrånvaroDatum) OVER (PARTITION BY Anstnr ORDER BY FrånvaroDatum) AS PrevDatum
    FROM SenastePerDatum
    WHERE Kortkod IN ('FL','FLB')
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
        MIN(FrånvaroDatum) AS PeriodStart_FL,
        MAX(FrånvaroDatum) AS PeriodEnd_FL
    FROM FLKedjaFlaggad
    GROUP BY Anstnr, GruppID
),

/* ===========================
   5) TJ-kedja (SE bryggar INTE)
   =========================== */
TJKedja AS (
    SELECT *,
           LAG(FrånvaroDatum) OVER (PARTITION BY Anstnr ORDER BY FrånvaroDatum) AS PrevDatum
    FROM SenastePerDatum
    WHERE Kortkod = 'TJ'
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
        MIN(FrånvaroDatum) AS PeriodStart_TJ,
        MAX(FrånvaroDatum) AS PeriodEnd_TJ
    FROM TJKedjaFlaggad
    GROUP BY Anstnr, GruppID
),

/* ===========================
   6) Månadsaggregering per kedja (GruppID)
      - SJ: räkna på kedjans kalender från första till sista SJ (SE i slutet räknas ej).
      - FL/TJ: som tidigare, enbart egna dagar.
   =========================== */
PerManad_SJ AS (
    SELECT
        k.Anstnr,
        k.GruppID,
        'SJ' AS Kortkod,
        YEAR(k.KalDag)  AS År,
        MONTH(k.KalDag) AS Månad,
        MIN(b.PeriodStart_SJ) AS PeriodStart,
        MAX(b.PeriodEnd_SJ)   AS PeriodEnd,     -- <-- sista SJ, ej SE
        COUNT(DISTINCT k.KalDag) AS KalenderdagarDennaManad,
        AVG(CASE WHEN YEAR(s.FrånvaroDatum)=YEAR(k.KalDag) AND MONTH(s.FrånvaroDatum)=MONTH(k.KalDag)
                 THEN s.Procent END) AS GenomsnittligSysselsattningsgrad,
        COUNT(DISTINCT CASE WHEN k.CalendarDayNr > @SickThresholdDays THEN k.KalDag END) AS EjBetaldaDagarUtanProcent,
        CAST(COUNT(DISTINCT CASE WHEN k.CalendarDayNr > @SickThresholdDays THEN k.KalDag END) AS decimal(18,7)) AS EjBetaldaDagarDennaManad,
        DAY(EOMONTH(MIN(k.KalDag))) AS DagarIMånaden
    FROM SJKalender k
    JOIN SJKedjaValida b
      ON b.Anstnr = k.Anstnr AND b.GruppID = k.GruppID
    LEFT JOIN SJ_ObserveradeDagar s
      ON s.Anstnr = k.Anstnr AND s.GruppID = k.GruppID
    GROUP BY k.Anstnr, k.GruppID, YEAR(k.KalDag), MONTH(k.KalDag)
),

-- FL: enkel kalender per FL/FLB-kedja (SE påverkar ej)
FLKalender AS (
    SELECT
        b.Anstnr,
        b.GruppID,
        DATEADD(DAY, n.number, b.PeriodStart_FL) AS KalDag
    FROM FLBounds b
    JOIN master.dbo.spt_values n
      ON n.type = 'P'
     AND b.PeriodStart_FL IS NOT NULL
     AND n.number BETWEEN 0 AND DATEDIFF(DAY, b.PeriodStart_FL, b.PeriodEnd_FL)
),
PerManad_FL AS (
    SELECT
        k.Anstnr,
        k.GruppID,
        'FL' AS Kortkod,  -- rapportera samlat som FL
        YEAR(k.KalDag)  AS År,
        MONTH(k.KalDag) AS Månad,
        MIN(b.PeriodStart_FL) AS PeriodStart,
        MAX(b.PeriodEnd_FL)   AS PeriodEnd,
        COUNT(DISTINCT k.KalDag) AS KalenderdagarDennaManad,
        AVG(ABS(f.Procent)) AS GenomsnittligSysselsattningsgrad,
        COUNT(DISTINCT k.KalDag) AS EjBetaldaDagarUtanProcent,
        CAST(COUNT(DISTINCT k.KalDag) AS decimal(18,7)) AS EjBetaldaDagarDennaManad,
        DAY(EOMONTH(MIN(k.KalDag))) AS DagarIMånaden
    FROM FLKalender k
    JOIN FLBounds b ON b.Anstnr = k.Anstnr AND b.GruppID = k.GruppID
    LEFT JOIN SenastePerDatum f 
      ON f.Anstnr = k.Anstnr 
     AND f.FrånvaroDatum = k.KalDag 
     AND f.Kortkod IN ('FL','FLB')
    GROUP BY k.Anstnr, k.GruppID, YEAR(k.KalDag), MONTH(k.KalDag)
),

-- TJ: kalender per TJ-kedja (SE påverkar ej)
TJKalender AS (
    SELECT
        b.Anstnr,
        b.GruppID,
        DATEADD(DAY, n.number, b.PeriodStart_TJ) AS KalDag
    FROM TJBounds b
    JOIN master.dbo.spt_values n
      ON n.type = 'P'
     AND b.PeriodStart_TJ IS NOT NULL
     AND n.number BETWEEN 0 AND DATEDIFF(DAY, b.PeriodStart_TJ, b.PeriodEnd_TJ)
),
PerManad_TJ AS (
    SELECT
        k.Anstnr,
        k.GruppID,
        'TJ' AS Kortkod,
        YEAR(k.KalDag)  AS År,
        MONTH(k.KalDag) AS Månad,
        MIN(b.PeriodStart_TJ) AS PeriodStart,
        MAX(b.PeriodEnd_TJ)   AS PeriodEnd,
        COUNT(DISTINCT k.KalDag) AS KalenderdagarDennaManad,
        AVG(ABS(t.Procent)) AS GenomsnittligSysselsattningsgrad,
        COUNT(DISTINCT k.KalDag) AS EjBetaldaDagarUtanProcent,
        CAST(COUNT(DISTINCT k.KalDag) AS decimal(18,7)) AS EjBetaldaDagarDennaManad,
        DAY(EOMONTH(MIN(k.KalDag))) AS DagarIMånaden
    FROM TJKalender k
    JOIN TJBounds b ON b.Anstnr = k.Anstnr AND b.GruppID = k.GruppID
    LEFT JOIN SenastePerDatum t ON t.Anstnr = k.Anstnr AND t.FrånvaroDatum = k.KalDag AND t.Kortkod = 'TJ'
    GROUP BY k.Anstnr, k.GruppID, YEAR(k.KalDag), MONTH(k.KalDag)
)

-- ===========================
-- 7) Slutresultat – en rad per MÅNAD och KEDJA (GruppID)
-- ===========================
SELECT
x.Anstnr,
cast(concat(x.år,'-',x.Månad,'-','01') as date) as Datum,
x.Kortkod as SjukKod,
x.PeriodStart as FrånVaroStart,
x.PeriodEnd AS FrånVaroSlut,
x.KalenderdagarDennaManad as FrånvaroAntalDagar,
x.EjBetaldaDagarUtanProcent as FrånVaroAntalObetaldaDagar,
x.DagarIMånaden as AntalDagarIMånad
FROM (

SELECT 
    Anstnr, GruppID, Kortkod, År, Månad,
    PeriodStart, PeriodEnd,
    KalenderdagarDennaManad,
    GenomsnittligSysselsattningsgrad,
    EjBetaldaDagarUtanProcent,
    EjBetaldaDagarDennaManad,
    DagarIMånaden
FROM PerManad_SJ
WHERE (@YearMin IS NULL OR År >= @YearMin)

UNION ALL

SELECT 
    Anstnr, GruppID, Kortkod, År, Månad,
    PeriodStart, PeriodEnd,
    KalenderdagarDennaManad,
    GenomsnittligSysselsattningsgrad,
    EjBetaldaDagarUtanProcent,
    EjBetaldaDagarDennaManad,
    DagarIMånaden
FROM PerManad_FL
WHERE (@YearMin IS NULL OR År >= @YearMin)

UNION ALL

SELECT 
    Anstnr, GruppID, Kortkod, År, Månad,
    PeriodStart, PeriodEnd,
    KalenderdagarDennaManad,
    GenomsnittligSysselsattningsgrad,
    EjBetaldaDagarUtanProcent,
    EjBetaldaDagarDennaManad,
    DagarIMånaden
FROM PerManad_TJ
WHERE (@YearMin IS NULL OR År >= @YearMin)

) X
where X.År  >= 2024 -- Startår 2024 för relevant data för uppföljning av justerad FTE --
ORDER BY 1 asc
