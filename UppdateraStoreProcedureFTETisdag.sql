;WITH calendar AS (
    -- En rad per månad från 2020-01-01 t.o.m. innevarande månad
    SELECT CAST('2020-01-01' AS DATE) AS MonthStartDate
    UNION ALL
    SELECT DATEADD(MONTH, 1, MonthStartDate)
    FROM calendar
    WHERE DATEADD(MONTH, 1, MonthStartDate) <= EOMONTH(GETDATE())
),
trimmed_arbetstider AS (
    -- Klipper arbetstidsperioder mot anställning + månad
    SELECT
        A.ANST_NR,
        C.MonthStartDate,
        CASE WHEN MAXDATES.StartDate > C.MonthStartDate THEN MAXDATES.StartDate ELSE C.MonthStartDate END AS PeriodStart,
        CASE WHEN MAXDATES.EndDate   < EOMONTH(C.MonthStartDate) THEN MAXDATES.EndDate   ELSE EOMONTH(C.MonthStartDate) END AS PeriodEnd,
        A.SYSSELSATTNINGSGRAD
    FROM [MKBBIStage].[Agda].[Arbetstider] A
    JOIN [MKBBIStage].[Agda].[Anställningar] E 
      ON A.ANST_NR = E.ANST_NR
    JOIN calendar C 
      ON COALESCE(A.ARBETSTIDTOMTID, '9999-12-31') >= C.MonthStartDate
     AND A.ARBETSTIDFRANTID <= EOMONTH(C.MonthStartDate)
    CROSS APPLY (
        SELECT
            CASE WHEN A.ARBETSTIDFRANTID > E.ANSTALLNINGSDATUM 
                 THEN A.ARBETSTIDFRANTID ELSE E.ANSTALLNINGSDATUM END AS StartDate,
            CASE WHEN COALESCE(A.ARBETSTIDTOMTID, '9999-12-31') < ISNULL(E.AVGANGSDATUM, '9999-12-31')
                 THEN COALESCE(A.ARBETSTIDTOMTID, '9999-12-31') ELSE ISNULL(E.AVGANGSDATUM, '9999-12-31') END AS EndDate
    ) AS MAXDATES
),
facttablefte AS (
    -- Aggregerar per månad och ANST_NR samt tar med min/max periodgränser
    SELECT
        t.ANST_NR,
        t.MonthStartDate,
        MIN(t.PeriodStart) AS PeriodStart,
        MAX(t.PeriodEnd)   AS PeriodEnd,
        SUM(
            ROUND(
                CAST(DATEDIFF(DAY, t.PeriodStart, t.PeriodEnd) + 1 AS FLOAT)
                / CAST(DAY(EOMONTH(t.MonthStartDate)) AS FLOAT)
                * (t.SYSSELSATTNINGSGRAD / 100.0), 
                4
            )
        ) AS FTE
    FROM trimmed_arbetstider t
    WHERE DATEDIFF(DAY, t.PeriodStart, t.PeriodEnd) >= 0
    GROUP BY t.ANST_NR, t.MonthStartDate
),
-- Välj EN sysselsättningsgrad från Arbetstider per (ANST_NR, MonthStartDate)
sysse_per_month AS (
    SELECT
        ANST_NR,
        MonthStartDate,
        CAST(SYSSELSATTNINGSGRAD AS DECIMAL(6,2)) AS Sysselsattningsgrad
    FROM (
        SELECT
            t.*,
            ROW_NUMBER() OVER (
                PARTITION BY t.ANST_NR, t.MonthStartDate
                ORDER BY 
                    CASE 
                        WHEN EOMONTH(t.MonthStartDate) BETWEEN t.PeriodStart AND t.PeriodEnd THEN 0 ELSE 1 
                    END,                                   -- 1) täcker EOMONTH först
                    DATEDIFF(DAY, t.PeriodStart, t.PeriodEnd) DESC, -- 2) längst täckning
                    t.PeriodEnd DESC                              -- 3) senast slut
            ) AS rn
        FROM trimmed_arbetstider t
    ) s
    WHERE s.rn = 1
),
facttablefte_enriched AS (
    SELECT 
        f.ANST_NR,
        f.MonthStartDate,
        f.PeriodStart,
        f.PeriodEnd,
        f.FTE,
        s.Sysselsattningsgrad
    FROM facttablefte f
    LEFT JOIN sysse_per_month s
      ON s.ANST_NR = f.ANST_NR
     AND s.MonthStartDate = f.MonthStartDate
),
calendar_days AS (
    -- Dagkalender +-7/+8 år runt innevarande år (för arbetsdagar/helgdagar)
    SELECT CAST(DATEADD(YEAR, -7, DATEFROMPARTS(YEAR(GETDATE()), 1, 1)) AS DATE) AS CalendarDate
    UNION ALL
    SELECT DATEADD(DAY, 1, CalendarDate)
    FROM calendar_days
    WHERE CalendarDate < DATEADD(YEAR, 8, DATEFROMPARTS(YEAR(GETDATE()), 1, 1))
),
workdays AS (
    -- Arbetsdagar (exkl. lör/sön och helgdagar)
    SELECT
        CalendarDate,
        DATEFROMPARTS(YEAR(CalendarDate), MONTH(CalendarDate), 1) AS MonthStart
    FROM calendar_days
    WHERE DATENAME(WEEKDAY, CalendarDate) NOT IN ('Saturday', 'Sunday')
      AND CalendarDate NOT IN (
            SELECT HolidayDate 
            FROM [MKBBIStage].[Agda].[HolidayDateTable] 
            WHERE Holiday = 'Yes'
        )
),
NormalWorkingHours AS (
    -- Normalt antal timmar per månad (8h per arbetsdag)
    SELECT
        MonthStart,
        COUNT(*) * 8 AS NormalWorkingHours
    FROM workdays
    GROUP BY MonthStart
),
hoursreportedfte AS (
    -- Timrapporterad FTE per månad (med fallback 165 före 2025-01-01)
    SELECT 
        TA.[dataANST_NR] AS ANST_NR,
        DATEFROMPARTS(YEAR(TA.[dataFOM_DATUM_AVR]), MONTH(TA.[dataFOM_DATUM_AVR]), 1) AS MonthStartDate,
        SUM(CAST(REPLACE(TA.[dataOMRANTAL], ',', '.') AS DECIMAL(18,4))) / 
        CASE 
            WHEN TA.dataFOM_DATUM_AVR < '2025-01-01' THEN 165 
            ELSE NW.NormalWorkingHours 
        END AS FTE
    FROM [MKBBIStage].[Agda].[timanställda] TA
    LEFT JOIN NormalWorkingHours NW
      ON YEAR(TA.[dataFOM_DATUM_AVR]) = YEAR(NW.MonthStart)
     AND MONTH(TA.[dataFOM_DATUM_AVR]) = MONTH(NW.MonthStart)
    GROUP BY 
        TA.[dataANST_NR],
        TA.[dataFOM_DATUM_AVR],
        NW.NormalWorkingHours
),
final_fte AS (
    -- Union: prioritera HoursReported och fyll på med FactTable där sådan saknas
    SELECT 
        ANST_NR, 
        MonthStartDate, 
        FTE, 
        'TimRapportering' AS Source,
        CAST(NULL AS date) AS PeriodStart,    -- kan bytas till MonthStartDate
        CAST(NULL AS date) AS PeriodEnd,      -- kan bytas till EOMONTH(MonthStartDate)
        CAST(NULL AS DECIMAL(6,2)) AS Sysselsattningsgrad
    FROM hoursreportedfte

    UNION

    SELECT 
        fte.ANST_NR, 
        fte.MonthStartDate, 
        fte.FTE, 
        'KontraktsBaseradFte',
        fte.PeriodStart,
        fte.PeriodEnd,
        fte.Sysselsattningsgrad
    FROM facttablefte_enriched fte
    LEFT JOIN hoursreportedfte hr 
      ON fte.ANST_NR = hr.ANST_NR 
     AND fte.MonthStartDate = hr.MonthStartDate
    WHERE hr.ANST_NR IS NULL
),
scd2_match AS (
    -- Matchar FTE-rad mot bästa SCD2-rad för månaden
    SELECT 
        H.ANST_NR, 
        H.MonthStartDate,
        TA.AnställdSK, 
        TA.TILLTRADE, 
        TA.TILLTRADETOM, 
        TA.ANSTALLNINGSFORM, 
        TA.KostnadsStälle,
        ROW_NUMBER() OVER (
            PARTITION BY H.ANST_NR, H.MonthStartDate
            ORDER BY 
                CASE 
                    WHEN H.MonthStartDate BETWEEN TA.TILLTRADE AND TA.TILLTRADETOM THEN 0
                    WHEN H.MonthStartDate < TA.TILLTRADE THEN 1
                    ELSE 2
                END, 
                TA.TILLTRADE DESC
        ) AS rn
    FROM final_fte H
    INNER JOIN [MKBBIDW].[dbo].[TestAnställdScd2] TA 
      ON H.ANST_NR = TA.ANST_NR
),
best_match AS (
    SELECT * 
    FROM scd2_match 
    WHERE rn = 1
)
SELECT 
    bm.AnställdSK,
    H.ANST_NR as AnställningsNr,
	 bm.KostnadsStälle,
    H.MonthStartDate as Datum,
    CAST(H.FTE AS DECIMAL(10,4)) AS FTE,
    H.Source as Källa,
    H.PeriodStart as KontraktStartMånad,
    H.PeriodEnd as KontraktsSlutMånad,
    H.Sysselsattningsgrad,          -- Hämtad från Arbetstider (ej beräknad)
    bm.TILLTRADE as KontraktStart,
    bm.TILLTRADETOM as KontraktSlut,
    bm.ANSTALLNINGSFORM as AnställningsForm
FROM final_fte H
LEFT JOIN best_match bm 
  ON H.ANST_NR = bm.ANST_NR 
 AND H.MonthStartDate = bm.MonthStartDate
WHERE
YEAR(H.MonthStartDate) = 2024
OPTION (MAXRECURSION 32767);
