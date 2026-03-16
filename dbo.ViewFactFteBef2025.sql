USE [MKBBIDW]
GO

/****** Object:  View [dbo].[ViewFactFteBef2025]    Script Date: 2026-03-16 15:41:41 ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO


CREATE VIEW [dbo].[ViewFactFteBef2025]
AS
WITH BeforeFinalTable AS (
    -- Kontraktuell FTE
    SELECT 
        CAST(A.ANST_NR AS INT)                                  AS AnställningsNummer,
        DATEFROMPARTS(A.AR, A.MANDAD_NR, 1)                     AS Datum,
        ROUND(A.FTE / 100.0, 2)                                 AS Fte,
        N'KontraktuellFte'                                      AS Source
    FROM [MKBBIDW].fact.MonthlyFTE A
    WHERE DATEFROMPARTS(A.AR, A.MANDAD_NR, 1) <= CAST(GETDATE() AS DATE)

    UNION ALL

    -- Tim-rapportering
    SELECT 
        CAST(T.Anställningsnummer AS INT)                       AS AnställningsNummer,
        DATEFROMPARTS(YEAR(T.PERIOD), MONTH(T.PERIOD), 1)       AS Datum,
        ROUND(SUM(T.Antal) / 165.0, 2)                          AS Fte,
        N'TimRapportering'                                      AS Source
    FROM [MKBBIDW].fact.Timanställningar T
    WHERE CAST(T.PERIOD AS DATE) <= CAST(GETDATE() AS DATE)
    GROUP BY 
        CAST(T.Anställningsnummer AS INT),
        YEAR(T.PERIOD),
        MONTH(T.PERIOD)
),

scd2_match AS (
    SELECT 
        H.AnställningsNummer,
        H.Datum,
        H.Fte,
        H.Source,
        TA.[AnställdSk],
        TA.[Tilltrade],
        TA.[TilltradeTom],
        TA.[Anställningsform],
        TA.[Kostnadsställe],
        TA.[Slag],
        TA.[Befattning],
        ROW_NUMBER() OVER (
            PARTITION BY H.AnställningsNummer, H.Datum
            ORDER BY 
                CASE 
                    WHEN H.Datum BETWEEN TA.[Tilltrade] AND TA.[TilltradeTom] THEN 0  -- exakt träff i period
                    WHEN H.Datum < TA.[Tilltrade] THEN 1                               -- före nästa period: ta närmast kommande
                    ELSE 2                                                             -- efter period: ta senaste
                END,
                TA.[Tilltrade] DESC
        ) AS rn
    FROM BeforeFinalTable H
    JOIN [MKBBIDW].[dim].[AnställdSCD2] TA
      ON H.AnställningsNummer = TA.[AnstNr]
),

best_match AS (
    SELECT *
    FROM scd2_match
    WHERE rn = 1
)

SELECT 
    H.AnställningsNummer,
    H.Datum,
    H.Fte,
    H.Source,
    bm.[AnställdSk],
    bm.[Kostnadsställe],
    bm.[Tilltrade]    AS TillTrädesDatum,
    bm.[TilltradeTom] AS FrånTrädesDatum,
    bm.[Anställningsform] AS AnställningsForm,
    bm.[Slag],            -- NY: om du vill använda den i rapport
    bm.[Befattning]       -- NY: praktiskt för analys
FROM BeforeFinalTable H
LEFT JOIN best_match bm
  ON H.AnställningsNummer = bm.AnställningsNummer
 AND H.Datum = bm.Datum
WHERE YEAR(H.Datum) < 2025;
GO


