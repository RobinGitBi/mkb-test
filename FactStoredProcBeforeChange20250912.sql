;WITH 
-- ===== MÅNADSKALENDER (ej rekursiv) =====
month_n AS (
  SELECT TOP (240) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS n
  FROM sys.all_objects
),
calendar AS (
  SELECT DATEADD(MONTH, n, CAST('2020-01-01' AS DATE)) AS MonthStartDate
  FROM month_n
  WHERE DATEADD(MONTH, n, '2020-01-01') <= EOMONTH(GETDATE())
),

-- ===== TRIMMA ARBETSTIDER MOT ANSTÄLLNING =====
trimmed_arbetstider AS (
  SELECT
    A.ANST_NR,
    C.MonthStartDate,
    CASE WHEN MAXDATES.StartDate > C.MonthStartDate THEN MAXDATES.StartDate ELSE C.MonthStartDate END AS PeriodStart,
    CASE WHEN MAXDATES.EndDate   < EOMONTH(C.MonthStartDate) THEN MAXDATES.EndDate ELSE EOMONTH(C.MonthStartDate) END AS PeriodEnd,
    TRY_CONVERT(DECIMAL(9,4), REPLACE(REPLACE(A.SYSSELSATTNINGSGRAD, '%', ''), ',', '.')) AS SysselsattningsgradDec
  FROM [MKBBIStage].[Agda].[Arbetstider] A
  JOIN [MKBBIStage].[Agda].[Anställningar] E ON A.ANST_NR = E.ANST_NR
  JOIN calendar C 
    ON COALESCE(A.ARBETSTIDTOMTID, '9999-12-31') >= C.MonthStartDate
   AND A.ARBETSTIDFRANTID <= EOMONTH(C.MonthStartDate)
  CROSS APPLY (
    SELECT
      CASE WHEN A.ARBETSTIDFRANTID > E.ANSTALLNINGSDATUM THEN A.ARBETSTIDFRANTID ELSE E.ANSTALLNINGSDATUM END AS StartDate,
      CASE WHEN COALESCE(A.ARBETSTIDTOMTID, '9999-12-31') < ISNULL(E.AVGANGSDATUM, '9999-12-31')
           THEN COALESCE(A.ARBETSTIDTOMTID, '9999-12-31') ELSE ISNULL(E.AVGANGSDATUM, '9999-12-31') END AS EndDate
  ) AS MAXDATES
),

-- ===== FTE FRÅN KONTRAKT (dag-vägt månadsmedel) =====
facttablefte AS (
  SELECT
    CAST(t.ANST_NR AS int) AS AnstNrInt,
    t.MonthStartDate,
    SUM(
      ROUND(
        CAST(DATEDIFF(DAY, t.PeriodStart, t.PeriodEnd) + 1 AS FLOAT)
        / CAST(DAY(EOMONTH(t.MonthStartDate)) AS FLOAT)
        * (COALESCE(t.SysselsattningsgradDec, 0) / 100.0), 4)
    ) AS FTE,
    MIN(t.PeriodStart) AS PeriodStart,
    MAX(t.PeriodEnd)   AS PeriodEnd,
    CAST(
      SUM(CASE WHEN t.SysselsattningsgradDec IS NOT NULL 
               THEN (DATEDIFF(DAY, t.PeriodStart, t.PeriodEnd) + 1) * t.SysselsattningsgradDec 
               ELSE 0 END) * 1.0
      / NULLIF(SUM(CASE WHEN t.SysselsattningsgradDec IS NOT NULL 
                        THEN (DATEDIFF(DAY, t.PeriodStart, t.PeriodEnd) + 1) 
                        ELSE 0 END), 0)
      AS DECIMAL(6,2)
    ) AS [Sysselsättningsgrad]
  FROM trimmed_arbetstider t
  WHERE DATEDIFF(DAY, t.PeriodStart, t.PeriodEnd) >= 0
  GROUP BY CAST(t.ANST_NR AS int), t.MonthStartDate
),

-- ===== DAGAR & NORMAL ARBETSTID =====
day_n AS (
  SELECT TOP (6000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS n
  FROM sys.all_objects a CROSS JOIN sys.all_objects b
),
bounds AS (
  SELECT 
    DATEADD(YEAR, -7, DATEFROMPARTS(YEAR(GETDATE()), 1, 1)) AS d0,
    DATEADD(YEAR,  8, DATEFROMPARTS(YEAR(GETDATE()), 1, 1)) AS d1
),
calendar_days AS (
  SELECT DATEADD(DAY, n, b.d0) AS CalendarDate
  FROM day_n
  CROSS JOIN bounds b
  WHERE DATEADD(DAY, n, b.d0) <= b.d1
),
workdays AS (
  SELECT
    cd.CalendarDate,
    DATEFROMPARTS(YEAR(cd.CalendarDate), MONTH(cd.CalendarDate), 1) AS MonthStart
  FROM calendar_days cd
  WHERE (DATEDIFF(DAY, '19000101', cd.CalendarDate) % 7) NOT IN (5,6)
    AND NOT EXISTS (
      SELECT 1
      FROM [MKBBIStage].[Agda].[HolidayDateTable] h
      WHERE h.Holiday = 'Yes'
        AND TRY_CONVERT(date, h.HolidayDate) = CAST(cd.CalendarDate AS DATE)
    )
),
NormalWorkingHours AS (
  SELECT MonthStart, COUNT(*) * 8 AS NormalWorkingHours
  FROM workdays
  GROUP BY MonthStart
),

-- ===== TIMRAPPORTERING -> FTE =====
hours_by_month AS (
  SELECT 
    CAST(TA.[dataANST_NR] AS int) AS AnstNrInt,
    DATEFROMPARTS(YEAR(TA.[dataFOM_DATUM_AVR]), MONTH(TA.[dataFOM_DATUM_AVR]), 1) AS MonthStartDate,
    SUM(CAST(REPLACE(TA.[dataOMRANTAL], ',', '.') AS DECIMAL(18,4))) AS Hours
  FROM [MKBBIStage].[Agda].[timanställda] TA
  GROUP BY 
    CAST(TA.[dataANST_NR] AS int),
    DATEFROMPARTS(YEAR(TA.[dataFOM_DATUM_AVR]), MONTH(TA.[dataFOM_DATUM_AVR]), 1)
),
hoursreportedfte AS (
  SELECT 
    h.AnstNrInt,
    h.MonthStartDate,
    h.Hours,
    CASE WHEN h.MonthStartDate < '2025-01-01' THEN 165 ELSE NW.NormalWorkingHours END AS NormalArbetsTid,
    h.Hours / CASE WHEN h.MonthStartDate < '2025-01-01' THEN 165 ELSE NULLIF(NW.NormalWorkingHours,0) END AS FTE
  FROM hours_by_month h
  LEFT JOIN NormalWorkingHours NW ON h.MonthStartDate = NW.MonthStart
),

-- ===== KOMBINERA KÄLLOR =====
final_fte AS (
  SELECT 
    AnstNrInt, MonthStartDate, FTE,
    CAST(NULL AS DATE) AS PeriodStart,
    CAST(NULL AS DATE) AS PeriodEnd,
    CAST(NULL AS DECIMAL(6,2)) AS [Sysselsättningsgrad],
    'TimRapportering' AS Source,
    CAST(ROUND(Hours, 2) AS DECIMAL(18,2)) AS RapporteradeTimmar,
    NormalArbetsTid AS NormalArbetsTid
  FROM hoursreportedfte

  UNION ALL

  SELECT 
    fte.AnstNrInt, fte.MonthStartDate, fte.FTE,
    fte.PeriodStart, fte.PeriodEnd, fte.[Sysselsättningsgrad],
    'KontraktuellFte' AS Source,
    CAST(NULL AS DECIMAL(18,2)) AS RapporteradeTimmar,
    CASE WHEN fte.MonthStartDate < '2025-01-01' THEN 165 ELSE NW.NormalWorkingHours END AS NormalArbetsTid
  FROM facttablefte fte
  LEFT JOIN NormalWorkingHours NW ON fte.MonthStartDate = NW.MonthStart
  LEFT JOIN hoursreportedfte hr  ON fte.AnstNrInt = hr.AnstNrInt AND fte.MonthStartDate = hr.MonthStartDate
  WHERE hr.AnstNrInt IS NULL
),

-- ===== SCD2-match per månad =====
scd2_match AS (
  SELECT 
    H.AnstNrInt, H.MonthStartDate,
    TA.[AnställdSk], TA.[Tilltrade], TA.[TilltradeTom], TA.[Anställningsform], TA.[Kostnadsställe],
    ROW_NUMBER() OVER (
      PARTITION BY H.AnstNrInt, H.MonthStartDate
      ORDER BY 
        CASE 
          WHEN H.MonthStartDate BETWEEN TA.[Tilltrade] AND TA.[TilltradeTom] THEN 0
          WHEN H.MonthStartDate < TA.[Tilltrade] THEN 1
          ELSE 2
        END, TA.[Tilltrade] DESC
    ) AS rn
  FROM final_fte H
  INNER JOIN [MKBBIDW].[dim].[AnställdSCD2] TA ON H.AnstNrInt = TA.[AnstNr]
),
best_match AS ( SELECT * FROM scd2_match WHERE rn = 1 ),

-- ===== Begränsa lönedatasetet till min/max månad som används =====
fte_bounds AS (
  SELECT MIN(MonthStartDate) AS MinMonth, MAX(MonthStartDate) AS MaxMonth
  FROM final_fte
  WHERE YEAR(MonthStartDate) >= 2024
),

/* ===== LÖN: 70 (Månadslön), 10 (Timlön), 230 (Lönetillägg) ===== */
fa_base_70 AS (
  SELECT CAST(FA.ANST_NR AS int) AS AnstNrInt, CAST(FA.DATUM_IN AS date) AS DatumStartDate, CAST(FA.DATUM_UT AS date) AS DatumSlutDate,
         FA.BELOPP, FA.PRIS, FA.ANTAL, FA.FASTAARTER_TYP, FA.FASTAARTER_NOTERING
  FROM [MKBBIStage].[Agda].[FastaArter] FA WHERE FA.LONEART = 70
),
fa_windowed_70 AS (
  SELECT fa.* FROM fa_base_70 fa CROSS JOIN fte_bounds b
  WHERE fa.DatumStartDate <= EOMONTH(b.MaxMonth) AND (fa.DatumSlutDate IS NULL OR fa.DatumSlutDate >= b.MinMonth)
),
fa_match_70 AS (
  SELECT fte.AnstNrInt, fte.MonthStartDate, fa.BELOPP, fa.PRIS, fa.ANTAL, fa.FASTAARTER_TYP, fa.FASTAARTER_NOTERING, fa.DatumStartDate,
         ROW_NUMBER() OVER (PARTITION BY fte.AnstNrInt, fte.MonthStartDate ORDER BY fa.DatumStartDate DESC) AS rn
  FROM final_fte fte
  JOIN fa_windowed_70 fa ON fa.AnstNrInt = fte.AnstNrInt
   AND fa.DatumStartDate < DATEADD(MONTH, 1, fte.MonthStartDate)
   AND (fa.DatumSlutDate IS NULL OR fa.DatumSlutDate >= fte.MonthStartDate)
),
fa_month_70 AS (
  SELECT AnstNrInt, MonthStartDate, BELOPP, PRIS, ANTAL, FASTAARTER_TYP, FASTAARTER_NOTERING, DatumStartDate
  FROM fa_match_70 WHERE rn = 1
),

fa_base_10 AS (
  SELECT CAST(FA.ANST_NR AS int) AS AnstNrInt, CAST(FA.DATUM_IN AS date) AS DatumStartDate, CAST(FA.DATUM_UT AS date) AS DatumSlutDate,
         FA.BELOPP, FA.PRIS, FA.ANTAL, FA.FASTAARTER_TYP, FA.FASTAARTER_NOTERING
  FROM [MKBBIStage].[Agda].[FastaArter] FA WHERE FA.LONEART = 10
),
fa_windowed_10 AS (
  SELECT fa.* FROM fa_base_10 fa CROSS JOIN fte_bounds b
  WHERE fa.DatumStartDate <= EOMONTH(b.MaxMonth) AND (fa.DatumSlutDate IS NULL OR fa.DatumSlutDate >= b.MinMonth)
),
fa_match_10 AS (
  SELECT fte.AnstNrInt, fte.MonthStartDate, fa.BELOPP, fa.PRIS, fa.ANTAL, fa.FASTAARTER_TYP, fa.FASTAARTER_NOTERING, fa.DatumStartDate,
         ROW_NUMBER() OVER (PARTITION BY fte.AnstNrInt, fte.MonthStartDate ORDER BY fa.DatumStartDate DESC) AS rn
  FROM final_fte fte
  JOIN fa_windowed_10 fa ON fa.AnstNrInt = fte.AnstNrInt
   AND fa.DatumStartDate < DATEADD(MONTH, 1, fte.MonthStartDate)
   AND (fa.DatumSlutDate IS NULL OR fa.DatumSlutDate >= fte.MonthStartDate)
),
fa_month_10 AS (
  SELECT AnstNrInt, MonthStartDate, BELOPP, PRIS, ANTAL, FASTAARTER_TYP, FASTAARTER_NOTERING, DatumStartDate
  FROM fa_match_10 WHERE rn = 1
),

fa_base_230 AS (
  SELECT CAST(FA.ANST_NR AS int) AS AnstNrInt, CAST(FA.DATUM_IN AS date) AS DatumStartDate, CAST(FA.DATUM_UT AS date) AS DatumSlutDate,
         FA.BELOPP, FA.PRIS, FA.ANTAL, FA.FASTAARTER_TYP, FA.FASTAARTER_NOTERING
  FROM [MKBBIStage].[Agda].[FastaArter] FA WHERE FA.LONEART = 230
),
fa_windowed_230 AS (
  SELECT fa.* FROM fa_base_230 fa CROSS JOIN fte_bounds b
  WHERE fa.DatumStartDate <= EOMONTH(b.MaxMonth) AND (fa.DatumSlutDate IS NULL OR fa.DatumSlutDate >= b.MinMonth)
),
fa_match_230 AS (
  SELECT fte.AnstNrInt, fte.MonthStartDate, fa.BELOPP, fa.PRIS, fa.ANTAL, fa.FASTAARTER_TYP, fa.FASTAARTER_NOTERING, fa.DatumStartDate, fa.DatumSlutDate,
         ROW_NUMBER() OVER (PARTITION BY fte.AnstNrInt, fte.MonthStartDate ORDER BY fa.DatumStartDate DESC) AS rn
  FROM final_fte fte
  JOIN fa_windowed_230 fa ON fa.AnstNrInt = fte.AnstNrInt
   AND fa.DatumStartDate < DATEADD(MONTH, 1, fte.MonthStartDate)
   AND (fa.DatumSlutDate IS NULL OR fa.DatumSlutDate >= fte.MonthStartDate)
),
fa_month_230 AS (
  SELECT AnstNrInt, MonthStartDate, BELOPP, PRIS, ANTAL, FASTAARTER_TYP, FASTAARTER_NOTERING, DatumStartDate, DatumSlutDate
  FROM fa_match_230 WHERE rn = 1
)


SELECT 
  TRY_CONVERT(INT, bm.[AnställdSk])                                        AS [AnställdSK],
  H.AnstNrInt                                                               AS [Anställningsnummer],
  CAST(COALESCE(TRY_CONVERT(INT, TRY_CONVERT(DECIMAL(18,2), REPLACE(CONVERT(VARCHAR(50), bm.[Kostnadsställe]), ',', '.'))),0) AS INT) AS [Kostnadsställe],
  CAST(bm.[Anställningsform] AS VARCHAR(50))                                AS [Anställningsform],
  CAST(H.[MonthStartDate] AS DATE)                                          AS [Datum],
  CAST(H.[FTE] AS DECIMAL(18,2))                                            AS [FTE],
  CAST(bm.[Tilltrade] AS DATE)                                              AS [SCD2 ändring datum],
  CAST(bm.[TilltradeTom] AS DATE)                                           AS [SCD2 ändring tom datum],
  CAST(H.[Source] AS VARCHAR(30))                                           AS [FTE Beräkning],
  CAST(H.[PeriodStart] AS DATE)                                             AS [Kontrakt Start Månad],
  CAST(H.[PeriodEnd]  AS DATE)                                              AS [Kontrakt Slut Månad],
  CAST(H.[Sysselsättningsgrad] AS DECIMAL(18,2))                            AS [Sysselsättningsgrad],
  CAST(COALESCE(H.[RapporteradeTimmar], CAST(0.0 AS DECIMAL(18,2))) AS DECIMAL(18,2)) AS [Rapporterade Timmar],
  CAST(H.[NormalArbetsTid]   AS INT)                                        AS [Normal arbetstid],
  CASE WHEN COALESCE(H.[RapporteradeTimmar], CAST(0.0 AS DECIMAL(18,2))) = 0 THEN CAST(L70.BELOPP AS DECIMAL(14,2)) ELSE CAST(NULL AS DECIMAL(14,2)) END AS [Månadslön],
  CASE WHEN COALESCE(H.[RapporteradeTimmar], CAST(0.0 AS DECIMAL(18,2))) > 0 THEN CAST(L10.PRIS AS DECIMAL(14,2)) ELSE CAST(NULL AS DECIMAL(14,2)) END AS [Timlön],
  CAST(CAST(COALESCE(H.[RapporteradeTimmar], CAST(0.0 AS DECIMAL(18,2))) AS DECIMAL(14,2)) * CAST(COALESCE(L10.PRIS, CAST(0.0 AS DECIMAL(14,2))) AS DECIMAL(14,2)) AS DECIMAL(14,2)) AS [Timmar*Timlön],
  CAST(COALESCE(L230.BELOPP, CAST(0.0 AS DECIMAL(14,2))) AS DECIMAL(14,2))  AS [Lönetillägg],
  CAST(L230.DatumStartDate AS DATE) AS [Lönetillägg Startdatum],
  CAST(L230.DatumSlutDate AS DATE)                                          AS [Lönetillägg Slutdatum],
  COALESCE(CASE WHEN COALESCE(H.[RapporteradeTimmar], CAST(0.0 AS DECIMAL(18,2))) = 0 THEN CAST(L70.BELOPP AS DECIMAL(14,2)) ELSE CAST(NULL AS DECIMAL(14,2)) END, CAST(0.0 AS DECIMAL(14,2))) + CAST(COALESCE(L230.BELOPP, CAST(0.0 AS DECIMAL(14,2))) AS DECIMAL(14,2)) AS [MånadsLönPlusTillägg]

FROM final_fte H
LEFT JOIN best_match bm 
  ON H.AnstNrInt = bm.AnstNrInt 
 AND H.MonthStartDate = bm.MonthStartDate
LEFT JOIN fa_month_70  L70
  ON L70.AnstNrInt = H.AnstNrInt
 AND L70.MonthStartDate = H.MonthStartDate
LEFT JOIN fa_month_10  L10
  ON L10.AnstNrInt = H.AnstNrInt
 AND L10.MonthStartDate = H.MonthStartDate
LEFT JOIN fa_month_230 L230
  ON L230.AnstNrInt = H.AnstNrInt
 AND L230.MonthStartDate = H.MonthStartDate
WHERE YEAR(H.MonthStartDate) >= 2024
OPTION (RECOMPILE);
