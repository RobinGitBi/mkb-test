SET NOCOUNT ON;
SET XACT_ABORT ON;

------------------------------------------------------------
-- Parametrar
------------------------------------------------------------
DECLARE @MaxCalendarGapSJ  int = 5;    -- bryt SJ-kedja om glapp > 5 kalenderdagar
DECLARE @MaxCalendarGapFL  int = 1;    -- bryt FL-kedja om glapp > 1 dag
DECLARE @MaxCalendarGapTJ  int = 1;    -- bryt TJ-kedja om glapp > 1 dag
DECLARE @SickThresholdDays int = 14;   -- 14-dagarsregeln (kalenderdagar i SJ-kedjan)

-- >= 2024 och framåt (sätt @ToYear om du vill stänga fönstret)
DECLARE @FromYear int = 2024;
DECLARE @ToYear   int = NULL;          -- NULL = till dagens datum; annars t.ex. 2026

------------------------------------------------------------
-- Datumfönster + lookback för korrekt SJ (14 + max gap)
------------------------------------------------------------
DECLARE @FromDate date = DATEFROMPARTS(@FromYear, 1, 1);
DECLARE @ToDate   date = CASE WHEN @ToYear IS NULL 
                              THEN CAST(GETDATE() AS date)
                              ELSE DATEFROMPARTS(@ToYear, 12, 31) 
                         END;

DECLARE @LookbackSJ  int  = @SickThresholdDays + @MaxCalendarGapSJ;
DECLARE @WindowStart date = DATEADD(DAY, -@LookbackSJ, @FromDate);
DECLARE @WindowEnd   date = @ToDate;

------------------------------------------------------------
-- Rensa temp-tabeller
------------------------------------------------------------
IF OBJECT_ID('tempdb..#Days')  IS NOT NULL DROP TABLE #Days;
IF OBJECT_ID('tempdb..#Tally') IS NOT NULL DROP TABLE #Tally;

------------------------------------------------------------
-- #Tally: exakt så många dagar som fönstret kräver
------------------------------------------------------------
DECLARE @TallyN int = DATEDIFF(DAY, @WindowStart, @WindowEnd) + 1;

;WITH TallySrc AS (
    SELECT TOP (@TallyN) ROW_NUMBER() OVER (ORDER BY (SELECT 1)) - 1 AS n
    FROM sys.all_objects a 
    CROSS JOIN sys.all_objects b
)
SELECT n 
INTO #Tally 
FROM TallySrc;

CREATE UNIQUE CLUSTERED INDEX CIX_Tally ON #Tally(n);

------------------------------------------------------------
-- Bygg #Days: expandera dagar inom fönstret + dedupe på senast [Timestamp]
------------------------------------------------------------
;WITH F AS (
    -- SARG: intervallöverlapp mot fönstret (trimmar källmängd)
    SELECT F.Anstnr, F.Kortkod, F.Fomdatum, F.Tomdatum, F.Procent, F.[Timestamp]
    FROM [MKBBIStage].[Agda].[Frånvaro] F
    WHERE F.Kortkod IN ('SJ','FL','FLB','TJ','SE')
      AND F.Fomdatum <= @WindowEnd
      AND F.Tomdatum >= @WindowStart
),
DaysRaw AS (
    SELECT
        F.Anstnr,
        F.Kortkod,
        DATEADD(DAY, T.n, F.Fomdatum) AS FrånvaroDatum,
        F.Procent,
        F.[Timestamp]
    FROM F
    JOIN #Tally T
      ON T.n BETWEEN 0 AND DATEDIFF(DAY, F.Fomdatum, F.Tomdatum)
     AND DATEADD(DAY, T.n, F.Fomdatum) BETWEEN @WindowStart AND @WindowEnd
),
Dedup AS (
    SELECT *,
           ROW_NUMBER() OVER(
             PARTITION BY Anstnr, Kortkod, FrånvaroDatum
             ORDER BY [Timestamp] DESC
           ) AS rn
    FROM DaysRaw
)
SELECT Anstnr, Kortkod, FrånvaroDatum, Procent
INTO #Days
FROM Dedup
WHERE rn = 1;

CREATE UNIQUE CLUSTERED INDEX CIX_Days 
ON #Days(Anstnr, FrånvaroDatum, Kortkod);

------------------------------------------------------------
-- Kedjelogik + radnivå
------------------------------------------------------------
WITH
-- SJ (SE bryggar)
SJSE AS (
    SELECT Anstnr, Kortkod, FrånvaroDatum
    FROM #Days
    WHERE Kortkod IN ('SJ','SE')
),
SJKedja AS (
    SELECT s.*,
           LAG(s.FrånvaroDatum) OVER (PARTITION BY s.Anstnr ORDER BY s.FrånvaroDatum) AS PrevDatum
    FROM SJSE s
),
SJKedjaGrp AS (
    SELECT *,
           SUM(CASE WHEN PrevDatum IS NULL
                     OR DATEDIFF(DAY, PrevDatum, FrånvaroDatum) > @MaxCalendarGapSJ
                    THEN 1 ELSE 0 END)
             OVER (PARTITION BY Anstnr ORDER BY FrånvaroDatum
                   ROWS UNBOUNDED PRECEDING) AS GruppID
    FROM SJKedja
),
SJBounds AS (
    SELECT
        Anstnr,
        GruppID,
        MIN(CASE WHEN Kortkod='SJ' THEN FrånvaroDatum END) AS PeriodStart_SJ,
        MAX(CASE WHEN Kortkod='SJ' THEN FrånvaroDatum END) AS PeriodEnd_SJ
    FROM SJKedjaGrp
    GROUP BY Anstnr, GruppID
),
SJKedjaValida AS (
    SELECT *
    FROM SJBounds
    WHERE PeriodStart_SJ IS NOT NULL AND PeriodEnd_SJ IS NOT NULL
),
SJKalender AS (
    SELECT
        v.Anstnr,
        v.GruppID,
        DATEADD(DAY, t.n, v.PeriodStart_SJ) AS KalDag,
        ROW_NUMBER() OVER (
            PARTITION BY v.Anstnr, v.GruppID
            ORDER BY DATEADD(DAY, t.n, v.PeriodStart_SJ)
        ) AS CalendarDayNr
    FROM SJKedjaValida v
    JOIN #Tally t
      ON t.n BETWEEN 0 AND DATEDIFF(DAY, v.PeriodStart_SJ, v.PeriodEnd_SJ)
     AND DATEADD(DAY, t.n, v.PeriodStart_SJ) BETWEEN @FromDate AND @ToDate
),
-- FL
FL AS (
    SELECT Anstnr, FrånvaroDatum
    FROM #Days
    WHERE Kortkod IN ('FL','FLB')
),
FLGrp AS (
    SELECT f.*,
           LAG(f.FrånvaroDatum) OVER (PARTITION BY f.Anstnr ORDER BY f.FrånvaroDatum) AS PrevDatum
    FROM FL f
),
FLKedja AS (
    SELECT *,
           SUM(CASE WHEN PrevDatum IS NULL
                     OR DATEDIFF(DAY, PrevDatum, FrånvaroDatum) > @MaxCalendarGapFL
                    THEN 1 ELSE 0 END)
             OVER (PARTITION BY Anstnr ORDER BY FrånvaroDatum
                   ROWS UNBOUNDED PRECEDING) AS GruppID
    FROM FLGrp
),
FLBounds AS (
    SELECT Anstnr, GruppID,
           MIN(FrånvaroDatum) AS PeriodStart_FL,
           MAX(FrånvaroDatum) AS PeriodEnd_FL
    FROM FLKedja
    GROUP BY Anstnr, GruppID
),
FLKalender AS (
    SELECT
        b.Anstnr, b.GruppID,
        DATEADD(DAY, t.n, b.PeriodStart_FL) AS KalDag
    FROM FLBounds b
    JOIN #Tally t
      ON t.n BETWEEN 0 AND DATEDIFF(DAY, b.PeriodStart_FL, b.PeriodEnd_FL)
     AND DATEADD(DAY, t.n, b.PeriodStart_FL) BETWEEN @FromDate AND @ToDate
),
-- TJ
TJ AS (
    SELECT Anstnr, FrånvaroDatum
    FROM #Days
    WHERE Kortkod = 'TJ'
),
TJGrp AS (
    SELECT t.*,
           LAG(t.FrånvaroDatum) OVER (PARTITION BY t.Anstnr ORDER BY t.FrånvaroDatum) AS PrevDatum
    FROM TJ t
),
TJKedja AS (
    SELECT *,
           SUM(CASE WHEN PrevDatum IS NULL
                     OR DATEDIFF(DAY, PrevDatum, FrånvaroDatum) > @MaxCalendarGapTJ
                    THEN 1 ELSE 0 END)
             OVER (PARTITION BY Anstnr ORDER BY FrånvaroDatum
                   ROWS UNBOUNDED PRECEDING) AS GruppID
    FROM TJGrp
),
TJBounds AS (
    SELECT Anstnr, GruppID,
        MIN(FrånvaroDatum) AS PeriodStart_TJ,
        MAX(FrånvaroDatum) AS PeriodEnd_TJ
    FROM TJKedja
    GROUP BY Anstnr, GruppID
),
TJKalender AS (
    SELECT
        b.Anstnr, b.GruppID,
        DATEADD(DAY, t.n, b.PeriodStart_TJ) AS KalDag
    FROM TJBounds b
    JOIN #Tally t
      ON t.n BETWEEN 0 AND DATEDIFF(DAY, b.PeriodStart_TJ, b.PeriodEnd_TJ)
     AND DATEADD(DAY, t.n, b.PeriodStart_TJ) BETWEEN @FromDate AND @ToDate
),

-- Radnivå (faktisk dagsprocent; SJ fallback till SE)
Rad_SJ AS (
    SELECT
        k.Anstnr, k.GruppID, 'SJ' AS SjukKod,
        k.KalDag AS Datum,
        v.PeriodStart_SJ AS PeriodStart,
        v.PeriodEnd_SJ   AS PeriodEnd,
        DAY(EOMONTH(k.KalDag)) AS AntalDagarIMånad,
        CASE WHEN k.CalendarDayNr > @SickThresholdDays THEN 1 ELSE 0 END AS ObetaldDag,
        COALESCE(ABS(dSJ.Procent), ABS(dSE.Procent), 0) AS Sysselsattningsgrad,
        CASE WHEN k.CalendarDayNr > @SickThresholdDays
             THEN COALESCE(ABS(dSJ.Procent), ABS(dSE.Procent), 0) ELSE 0 END AS ObetaldDagJusterad
    FROM SJKalender k
    JOIN SJKedjaValida v
      ON v.Anstnr = k.Anstnr AND v.GruppID = k.GruppID
    LEFT JOIN #Days dSJ
      ON dSJ.Anstnr = k.Anstnr AND dSJ.FrånvaroDatum = k.KalDag AND dSJ.Kortkod = 'SJ'
    LEFT JOIN #Days dSE
      ON dSE.Anstnr = k.Anstnr AND dSE.FrånvaroDatum = k.KalDag AND dSE.Kortkod = 'SE'
),
Rad_FL AS (
    SELECT
        k.Anstnr, k.GruppID, 'FL' AS SjukKod,
        k.KalDag AS Datum,
        b.PeriodStart_FL AS PeriodStart,
        b.PeriodEnd_FL   AS PeriodEnd,
        DAY(EOMONTH(k.KalDag)) AS AntalDagarIMånad,
        1 AS ObetaldDag,
        COALESCE(ABS(d.Procent), 0) AS Sysselsattningsgrad,
        COALESCE(ABS(d.Procent), 0) AS ObetaldDagJusterad
    FROM FLKalender k
    JOIN FLBounds b
      ON b.Anstnr = k.Anstnr AND b.GruppID = k.GruppID
    LEFT JOIN #Days d
      ON d.Anstnr = k.Anstnr AND d.FrånvaroDatum = k.KalDag AND d.Kortkod IN ('FL','FLB')
),
Rad_TJ AS (
    SELECT
        k.Anstnr, k.GruppID, 'TJ' AS SjukKod,
        k.KalDag AS Datum,
        b.PeriodStart_TJ AS PeriodStart,
        b.PeriodEnd_TJ   AS PeriodEnd,
        DAY(EOMONTH(k.KalDag)) AS AntalDagarIMånad,
        1 AS ObetaldDag,
        COALESCE(ABS(d.Procent), 0) AS Sysselsattningsgrad,
        COALESCE(ABS(d.Procent), 0) AS ObetaldDagJusterad
    FROM TJKalender k
    JOIN TJBounds b
      ON b.Anstnr = k.Anstnr AND b.GruppID = k.GruppID
    LEFT JOIN #Days d
      ON d.Anstnr = k.Anstnr AND d.FrånvaroDatum = k.KalDag AND d.Kortkod = 'TJ'
),
RadAlla AS (
    SELECT * FROM Rad_SJ
    UNION ALL
    SELECT * FROM Rad_FL
    UNION ALL
    SELECT * FROM Rad_TJ
)
SELECT
    dBest.[AnställdSk]       AS [AnställdsSk],
    r.[Anstnr]               AS [AnstNr],
    dBest.[Kostnadsställe]   AS [KostnadsStälle],
    dBest.[Anställningsform] AS [AnställningsForm],
    r.[Datum],
    r.[SjukKod] as FrånVaroKod,
	CASE WHEN R.SjukKod = 'SJ' AND CAST(r.ObetaldDag AS int) = 0 THEN '< 15 Dagars Sjukskrivning'   WHEN R.SjukKod = 'SJ' AND CAST(r.ObetaldDag AS int) > 0 then '> 14 Dagars Sjukskrivning' end as SjukSkrivningsPeriod,
	    CAST(CAST(r.ObetaldDagJusterad AS decimal(18,2)) /100 AS decimal(18,2))   AS [ObetaldDagJusterad],
    CAST(r.Sysselsattningsgrad AS decimal(18,2)) AS SysselSättningsGrad
FROM RadAlla r
OUTER APPLY (
    SELECT TOP (1)
           d.[AnställdSk], d.[Kostnadsställe], d.[Anställningsform], d.[Tilltrade], d.[TilltradeTom]
    FROM [MKBBIDW].[dim].[AnställdSCD2] d
    WHERE d.[AnstNr] = r.Anstnr
    ORDER BY CASE 
               WHEN r.Datum BETWEEN d.[Tilltrade] AND d.[TilltradeTom] THEN 0
               WHEN r.Datum < d.[Tilltrade] THEN 1
               ELSE 2
             END,
             d.[Tilltrade] DESC
) dBest
-- returnera bara vald period (>= @FromYear, till @ToYear eller idag)
WHERE r.Datum BETWEEN @FromDate AND @ToDate
ORDER BY r.Anstnr, r.Datum
OPTION (RECOMPILE, MAXDOP 4);
