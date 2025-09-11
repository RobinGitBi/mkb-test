USE [MKBBIDW]
GO

/****** Object:  View [dbo].[ViewFactFteBef2025]    Script Date: 2025-09-11 17:24:48 ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO




CREATE VIEW [dbo].[ViewFactFteBef2025]
AS

WITH BeforeFinalTable AS (
    SELECT 
        A.ANST_NR AS AnställningsNummer,
        DATEFROMPARTS(A.AR, A.MANDAD_NR, 1) AS Datum,
        ROUND(A.FTE / 100.0, 2) AS Fte,
        'KontraktuellFte' AS Source
    FROM [MKBBIDW].fact.MonthlyFTE A
    WHERE DATEFROMPARTS(A.AR, A.MANDAD_NR, 1) <= GETDATE()

    UNION ALL

    SELECT 
        T.Anställningsnummer AS AnställningsNummer,
        DATEFROMPARTS(YEAR(T.PERIOD), MONTH(T.PERIOD), 1) AS Datum,
        ROUND(SUM(T.Antal) / 165.0, 2) AS Fte,
        'TimRapportering' AS Source
    FROM [MKBBIDW].fact.Timanställningar T
    WHERE T.PERIOD <= GETDATE()
    GROUP BY 
        T.Anställningsnummer,
        YEAR(T.PERIOD),
        MONTH(T.PERIOD)
),

scd2_match AS (
    SELECT 
        H.AnställningsNummer,
        H.Datum,
        H.Fte,
        H.Source,
        TA.AnställdSK,
        TA.TILLTRADE,
        TA.TILLTRADETOM,
        TA.ANSTALLNINGSFORM,
        TA.KostnadsStälle,
        ROW_NUMBER() OVER (
            PARTITION BY H.AnställningsNummer, H.Datum
            ORDER BY 
                CASE 
                    WHEN H.Datum BETWEEN TA.TILLTRADE AND COALESCE(TA.TILLTRADETOM, '9999-12-31') THEN 0
                    WHEN H.Datum < TA.TILLTRADE THEN 1
                    ELSE 2
                END,
                TA.TILLTRADE DESC  -- If post-contract, pick latest contract
        ) AS rn
    FROM BeforeFinalTable H
    JOIN [MKBBIDW].dbo.TestAnställdScd2 TA
      ON H.AnställningsNummer = TA.ANST_NR
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
    bm.AnställdSK,
    bm.KostnadsStälle,
    bm.TILLTRADE AS TillTrädesDatum,
    bm.TILLTRADETOM AS FrånTrädesDatum,
    bm.ANSTALLNINGSFORM AS AnställningsForm
FROM BeforeFinalTable H
LEFT JOIN best_match bm
  ON H.AnställningsNummer = bm.AnställningsNummer
 AND H.Datum = bm.Datum
WHERE YEAR(H.Datum) < 2025;




GO


