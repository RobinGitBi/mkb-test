USE [MKBBIDW]
GO

/****** Object:  View [dbo].[ViewFactFteJusteradPrognos]    Script Date: 2025-09-21 21:19:24 ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

ALTER VIEW  [dbo].[ViewFactFteJusteradPrognos]
AS
WITH src AS (
    SELECT
        vf.[Anställd SK]         AS AnstalldSK,
        vf.[Anställningsnummer]  AS Anstallningsnummer,
        YEAR(vf.[Datum])         AS Ar,
        CAST(vf.[Datum] AS date) AS MonthStart,
        EOMONTH(vf.[Datum])      AS MonthEnd,

        vf.[Anställningsform]    AS Anstallningsform,
        COALESCE(vf.[FTE], 0.0)                      AS FTE,
        COALESCE(vf.[FTE före justering], 0.0)       AS FTE_ForeJustering,
        COALESCE(vf.[Frånvaro justering], 0.0)       AS FTE_FranvaroJustering,

        COALESCE(vf.[Rapporterade Timmar], 0.0)      AS RapporteradeTimmar,
        vf.[Sysselsättningsgrad]                     AS Sysselsattningsgrad,
        vf.[Lönekategori]                            AS Lonekategori,
        vf.[Kostnadsställe]                          AS Kostnadsstalle,  -- kvar

        vf.[Månadslön]            AS Manadslon,
        vf.[Lönetillägg]          AS Lonetillagg,
        vf.[MånadsLönPlusTillägg] AS ManadslonPlusTillagg,
        vf.[Timlön]               AS Timlon,
        vf.[AktualitetId]         AS AktualitetId,

        CAST(COALESCE(vf.[SCD2 Justerad Ändring Datum], vf.[SCD2 ändring datum]) AS date) AS EmpStart,
        CAST(COALESCE(vf.[SCD2 Justerad Ändring t.o.m. Datum], vf.[SCD2 ändring tom datum], '9999-12-31') AS date) AS EmpEnd
    FROM dbo.viewfactfte vf
),
per_month AS (
    SELECT
        s.*,
        CASE
            WHEN GREATEST(s.EmpStart, s.MonthStart) > LEAST(s.EmpEnd, s.MonthEnd) THEN 0.0
            ELSE CAST(
                DATEDIFF(
                    DAY,
                    GREATEST(s.EmpStart, s.MonthStart),
                    LEAST(s.EmpEnd, s.MonthEnd)
                ) + 1 AS decimal(9,4)
            ) / NULLIF(DAY(s.MonthEnd),0)
        END AS FractionMonth,
        CASE WHEN s.RapporteradeTimmar > 0 OR s.FTE > 0 THEN 1.0 ELSE 0.0 END AS WorkedFlag,
        CASE WHEN COALESCE(s.Lonetillagg,0) > 0 THEN 1 ELSE 0 END AS HasLonetillagg
    FROM src s
),
weighted AS (
    SELECT
        AnstalldSK,
        Anstallningsnummer,
        Ar,
        MonthStart,
        Anstallningsform,
        Lonekategori,
        Kostnadsstalle,
        FTE,
        FTE_ForeJustering,
        FTE_FranvaroJustering,
        RapporteradeTimmar,
        Sysselsattningsgrad,
        Manadslon,
        Lonetillagg,
        ManadslonPlusTillagg,
        Timlon,
        AktualitetId,
        EmpStart,
        EmpEnd,
        HasLonetillagg,
        CASE 
            WHEN Lonekategori = N'Timavlönad' OR Timlon IS NOT NULL
                 THEN WorkedFlag
            ELSE FractionMonth
        END AS RowWeight
    FROM per_month
),
last_value AS (
    SELECT *
    FROM (
        SELECT
            w.*,
            ROW_NUMBER() OVER (
                PARTITION BY w.AnstalldSK, w.Ar 
                ORDER BY w.MonthStart DESC
            ) AS rn
        FROM weighted w
    ) x
    WHERE rn = 1
)
SELECT
    w.AnstalldSK as [AnställdSk],
    MAX(lv.Anstallningsnummer) AS [Anställningsnummer],
    /* 🏷️ Kostnadsställe – konstant per AnställdSK (SCD2) */
    MAX(w.Kostnadsstalle) AS [Kostnadsställe],
    w.Ar as [År],
    CAST(CONCAT(w.ar, '01', '01') AS date) AS Datum,

    /* 🔹 FTE (månadsmedel) */
    CAST(SUM(w.FTE_ForeJustering)     / 12.0 AS decimal(14,2)) AS [MedelFTEFöreJustering],
    CAST(SUM(w.FTE_FranvaroJustering) / 12.0 AS decimal(14,2)) AS [MedelFTEFrånvaroJustering],
    CAST(SUM(w.FTE)                   / 12.0 AS decimal(14,2)) AS [MedelFTE],
    CAST(SUM(w.RowWeight) AS decimal(14,2)) AS AntalMånaderEnligtKontrakt,
    CAST(SUM(
        CASE 
            WHEN w.Lonekategori = N'Timavlönad' OR w.Timlon IS NOT NULL
                THEN w.RowWeight * CASE WHEN w.FTE < 0 THEN 0 WHEN w.FTE > 1 THEN 1 ELSE w.FTE END
            ELSE w.RowWeight *
                 CASE 
                    WHEN w.FTE_ForeJustering <= 0 THEN 0
                    WHEN w.FTE < 0 THEN 0
                    WHEN w.FTE > w.FTE_ForeJustering THEN 1
                    ELSE w.FTE / w.FTE_ForeJustering
                 END
        END
    ) AS decimal(14,2)) AS [AntalMånaderEfterFrånvaroJustering],

    /* 📅 SCD2 */
    MIN(w.EmpStart) AS [SCD2Anställningsdatum],
    MAX(w.EmpEnd)   AS [SCD2_AnställningsdatumTom],

    /* 💰 Årsslut */
    MAX(CASE WHEN lv.AnstalldSK IS NOT NULL THEN lv.Manadslon END)           AS [ManådslönÅrsslut],
    MAX(CASE WHEN lv.AnstalldSK IS NOT NULL THEN lv.Lonetillagg END)         AS [LönetilläggÅrsslut],
    MAX(CASE WHEN lv.AnstalldSK IS NOT NULL THEN lv.Timlon END)              AS [TimlönÅrsslut],
    MAX(CASE WHEN lv.AnstalldSK IS NOT NULL THEN lv.Lonekategori END)        AS [LöneKategori],
    MAX(CASE WHEN lv.AnstalldSK IS NOT NULL THEN lv.Sysselsattningsgrad END) AS [SysselsättningsgradÅrsslut],

    /* ✅ Nya: effektiva satser (årsslut om finns, annars årsmedel) + källa */
    CAST(COALESCE(MAX(lv.Manadslon),  AVG(NULLIF(w.Manadslon,0)), 0) AS decimal(14,2)) AS [MånadslönEffektiv],
    CAST(COALESCE(MAX(lv.Timlon),     AVG(NULLIF(w.Timlon,0)),     0) AS decimal(14,2)) AS [TimlönEffektiv],
    CAST(COALESCE(MAX(lv.Lonetillagg),AVG(NULLIF(w.Lonetillagg,0)),0) AS decimal(14,2)) AS [LönetilläggEffektiv],

    CASE
        WHEN MAX(lv.Manadslon) IS NOT NULL THEN N'Årsslut'
        WHEN AVG(NULLIF(w.Manadslon,0)) IS NOT NULL THEN N'Årsmedel'
        ELSE N'Saknas'
    END AS [MånadslönKälla],
    CASE
        WHEN MAX(lv.Timlon) IS NOT NULL THEN N'Årsslut'
        WHEN AVG(NULLIF(w.Timlon,0)) IS NOT NULL THEN N'Årsmedel'
        ELSE N'Saknas'
    END AS [TimlönKälla],
    CASE
        WHEN MAX(lv.Lonetillagg) IS NOT NULL THEN N'Årsslut'
        WHEN AVG(NULLIF(w.Lonetillagg,0)) IS NOT NULL THEN N'Årsmedel'
        ELSE N'Saknas'
    END AS [LönetilläggKälla],

    /* 🕒 Rapporterade timmar & lönetilläggsmånader */
    SUM(w.RapporteradeTimmar) AS [RapporteradeTimmar],
    SUM(w.HasLonetillagg)     AS [LöneTilläggAntalMånader],

    /* ===== Effektiv sysselsättningsgrad (0–1) ===== */
    CAST( COALESCE(MAX(lv.Sysselsattningsgrad), AVG(NULLIF(w.Sysselsattningsgrad,0)), 100.0)/100.0 AS DECIMAL(14,2))
        AS [SysselSättningsGradEff],

    /* ===== Klassning: tim om årsslut ELLER årsmedel visar timlön ===== */
    CASE
        WHEN MAX(CASE WHEN lv.Lonekategori = N'Timavlönad' OR lv.Timlon IS NOT NULL THEN 1 ELSE 0 END) = 1
             OR COALESCE(AVG(NULLIF(w.Timlon,0)),0) > 0
        THEN 1 ELSE 0
    END AS IsHourlyYear,

    /* ===== Prognos bruttolön (robust) ===== */
    CAST(CASE 
        WHEN MAX(CASE WHEN lv.Lonekategori = N'Timavlönad' OR lv.Timlon IS NOT NULL THEN 1 ELSE 0 END) = 1
             OR COALESCE(AVG(NULLIF(w.Timlon,0)),0) > 0
        THEN COALESCE(MAX(lv.Timlon), AVG(NULLIF(w.Timlon,0)), 0) * SUM(w.RapporteradeTimmar)
        ELSE
             (COALESCE(MAX(lv.Manadslon),  AVG(NULLIF(w.Manadslon,0)),  0)
              * (COALESCE(MAX(lv.Sysselsattningsgrad), AVG(NULLIF(w.Sysselsattningsgrad,0)),100.0)/100.0)
              *
              SUM(
                  CASE 
                      WHEN w.Lonekategori = N'Timavlönad' OR w.Timlon IS NOT NULL
                          THEN w.RowWeight * CASE WHEN w.FTE < 0 THEN 0 WHEN w.FTE > 1 THEN 1 ELSE w.FTE END
                      ELSE w.RowWeight *
                           CASE 
                              WHEN w.FTE_ForeJustering <= 0 THEN 0
                              WHEN w.FTE < 0 THEN 0
                              WHEN w.FTE > w.FTE_ForeJustering THEN 1
                              ELSE w.FTE / w.FTE_ForeJustering
                           END
                  END
              )
             )
             +
             (COALESCE(MAX(lv.Lonetillagg),AVG(NULLIF(w.Lonetillagg,0)),0) * SUM(w.HasLonetillagg))
    END AS decimal(14,2)) AS [PrognosBruttolön],

    /* 🏷️ Aktualitet */
    MAX(w.AktualitetId) AS AktualitetId

FROM weighted w
LEFT JOIN last_value lv
    ON lv.AnstalldSK = w.AnstalldSK AND lv.Ar = w.Ar
GROUP BY
    w.AnstalldSK, w.Ar


GO


