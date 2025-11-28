USE [MKBBIDW]
GO

/****** Object:  View [dbo].[ViewFactFte]    Script Date: 2025-11-28 08:38:53 ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO



ALTER VIEW [dbo].[ViewFactFte]
AS
WITH JusteradFrånvaro AS (
    SELECT 
        f.AnstNr,
        CAST(CONCAT(YEAR(f.Datum), '-', MONTH(f.Datum), '-', '01') AS DATE) AS Datum,
        SUM(f.ObetaldDagJusterad) AS JusteringFrånvaroDagar
    FROM [MKBBIDW].fact.FteFrånvaroJustering f
	WHERE F.FrånVaroKod IN ('TJ', 'FL', 'SJ')
    GROUP BY f.AnstNr, YEAR(f.Datum), MONTH(f.Datum)
    HAVING SUM(f.ObetaldDagJusterad) <> 0
),

KolumnerInScoope AS (
    SELECT 
        ff.*,
        jf.JusteringFrånvaroDagar,
        DATEDIFF(DAY, ff.Datum, EOMONTH(ff.Datum)) + 1 AS AntalDagarMånad
    FROM [MKBBIDW].fact.FTE ff
    LEFT JOIN JusteradFrånvaro jf 
        ON ff.AnstNr = jf.AnstNr 
       AND ff.Datum = jf.Datum
),

JusteradFte AS (
    SELECT
        kis.*,
        -- Frånvaro -> FTE-justering (negativ kvot av månad)
        - CAST(ROUND(
              CAST(kis.JusteringFrånvaroDagar AS DECIMAL(10,4)) 
            / CAST(kis.AntalDagarMånad       AS DECIMAL(10,4)), 2) AS DECIMAL(10,2)
          ) AS JusteringFte,

        -- ★ NYTT: Effektiv FTE i prognos (ScenarioSk=2) för Intermittent/Särskild visstid
        CASE 
            WHEN kis.ScenarioSk = 2 
             AND kis.[Källa] = N'KontraktuellFte'
             AND (kis.[Anställningsform] LIKE N'Intermittent%' 
               OR kis.[Anställningsform] LIKE N'Särskild visstidsanställning T%')
            THEN 0.0 
            ELSE kis.FTE 
        END AS FTE_Eff
    FROM KolumnerInScoope kis
)

SELECT 
    jf.[AnställdsSk]                          AS 'Anställd SK',
    jf.AnstNr                                  AS Anställningsnummer,
    jf.[KostnadsStälle]                        AS Kostnadsställe,
    jf.[AnställningsForm]                      AS Anställningsform,
    CASE WHEN jf.[RapporteradeTimmar] <> 0 THEN N'Timavlönad' ELSE N'Månadsavlönad' END AS Lönekategori,
    jf.Datum                                   AS Datum,
    jf.[Källa]                                 AS 'FTE Beräkning',
    jf.KontraktStartMånad                      AS 'Kontrakt Start Månad',
    jf.KontraktsSlutMånad                      AS 'Kontrakt Slut Månad',
    jf.[Sysselsättningsgrad]                   AS Sysselsättningsgrad,
    jf.[RapporteradeTimmar]                    AS 'Rapporterade Timmar',
    CASE WHEN jf.[Källa] = N'TimRapportering' THEN jf.NormalArbetsTid END AS 'Normal arbetstid',

    -- ▼ Använd FTE_Eff
    CAST(ROUND(jf.FTE_Eff, 2) AS DECIMAL(10,2)) AS 'FTE före justering',
    COALESCE(ROUND(CAST(jf.JusteringFte AS DECIMAL(10,2)), 2), 0) AS 'Frånvaro justering',
    CASE 
        WHEN CAST(ROUND(jf.FTE_Eff, 2) AS DECIMAL(10,2)) 
           + COALESCE(CAST(jf.JusteringFte AS DECIMAL(10,2)), 0) < 0 
        THEN 0 
        ELSE CAST(ROUND(jf.FTE_Eff, 2) AS DECIMAL(10,2)) 
           + COALESCE(CAST(jf.JusteringFte AS DECIMAL(10,2)), 0) 
    END AS FTE,

    COALESCE(jf.JusteringFrånvaroDagar, 0)     AS 'Dagar frånvaro justering',
    CASE WHEN jf.[RapporteradeTimmar] <> 0 THEN jf.AntalDagarMånad END AS 'Dagar totalt',

    jf.TillTrädesDatum                         AS 'SCD2 ändring datum',
    jf.TillTrädeTomDatum                       AS 'SCD2 ändring tom datum',
    jf.TillträdesDatumJusteradScd2             AS 'SCD2 Justerad Ändring Datum',
    jf.TillträdesTomDatumJusteradScd2          AS 'SCD2 Justerad Ändring t.o.m. Datum',

    jf.Månadslön,
    jf.Lönetillägg,
    jf.MånadsLönPlusTillägg,
    jf.[Lönetillägg Startdatum],
    jf.[Lönetillägg Slutdatum],
    jf.Timlön,
    jf.[Timmar*Timlön],

    -- Snittlön Timanställd (oförändrat)
    CASE 
      WHEN COUNT(CASE WHEN jf.[RapporteradeTimmar] > 0 THEN 1 END)
             OVER (PARTITION BY jf.AnstNr, YEAR(jf.Datum)) = 0
        THEN NULL
      ELSE
        AVG(CASE WHEN jf.[RapporteradeTimmar] > 0 THEN jf.[Timmar*Timlön] END)
          OVER (PARTITION BY jf.AnstNr, YEAR(jf.Datum))
    END AS 'Snittlön Timanställd',

    jf.ScenarioSk AS AktualitetId,
    jf.Scenario   AS Aktualitet
FROM JusteradFte jf
GO


