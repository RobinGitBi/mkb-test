;WITH
/* 1) Anställningsperioder och kostnadsställe */
EmploymentPeriods AS (
    SELECT 
        ANST_NR,
        TILLTRADE,
        COALESCE(TILLTRADETOM, CONVERT(date,'9999-12-31')) AS TILLTRADETOM,
        ANSTALLNINGSFORM
    FROM [MKBBIStage].[Agda].[Anställningsform]
),
CostCenterChanges AS (
    SELECT 
        ANST_NR,
        KONTERINGFRANTID AS ChangeDate,
        COALESCE(KONTERINGTOMTID, CONVERT(date,'9999-12-31')) AS ChangeEnd,
        DATA AS KostnadsStälle
    FROM [MKBBIStage].[Agda].[Konteringar]
    WHERE KONTERING = N'Kostnadsställe'
),

/* 2) Befattningar (stage only), robust mot kolumnstavning, UTAN BefattningId */
Positions_Base AS (
    SELECT
        CAST(B.ANST_NR AS int)                                AS ANST_NR,
        CAST(B.BEFATTNING AS nvarchar(200))                   AS Befattning,
        CAST(B.BEFATTNINGSYSSELSATTNINGSGRAD AS decimal(9,2)) AS BefattningsGrad,  -- <– kvar tidigt, används ej senare
        -- Start = FOM om finns, annars TOM (endagsperiod om bara TOM finns)
        CAST(COALESCE(B.BEFATTNINGFOMDATUM, B.BEFATTNINGFOMDATUM, B.BEFATTNINGTOMDATUM) AS date) AS StartDt,
        -- Slut = TOM om finns, annars öppet slut
        CAST(COALESCE(B.BEFATTNINGTOMDATUM, B.BEFATTNINGTOMDATUM, CONVERT(date,'9999-12-31')) AS date) AS EndDt
    FROM [MKBBIStage].[Agda].[Befattningar] B
),
Positions_Clean AS (
    SELECT *
    FROM Positions_Base
    WHERE Befattning IS NOT NULL
      AND StartDt IS NOT NULL
      AND StartDt <= EndDt
),

/* 3) Av-överlappa (“öar” av överlapp) – VINNAREN ÄR SENASTE START */
OverlapBase AS (
    SELECT
        p.*,
        MAX(p.EndDt) OVER (
            PARTITION BY p.ANST_NR
            ORDER BY p.StartDt, p.Befattning
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS RunMaxEnd
    FROM Positions_Clean p
),
OverlapGroups AS (
    SELECT
        o.*,
        LAG(o.RunMaxEnd) OVER (PARTITION BY o.ANST_NR ORDER BY o.StartDt, o.Befattning) AS PrevRunMaxEnd,
        CASE WHEN o.StartDt >
                  ISNULL(LAG(o.RunMaxEnd) OVER (PARTITION BY o.ANST_NR ORDER BY o.StartDt, o.Befattning),
                         CONVERT(date,'1900-01-01'))
             THEN 1 ELSE 0 END AS NewIslandFlag
    FROM OverlapBase o
),
Islands AS (
    SELECT
        g.*,
        SUM(g.NewIslandFlag) OVER (
            PARTITION BY g.ANST_NR
            ORDER BY g.StartDt, g.Befattning
            ROWS UNBOUNDED PRECEDING
        ) AS IslandId
    FROM OverlapGroups g
),
/* winner = MAX(StartDt) */
Winners AS (
    SELECT *
    FROM (
        SELECT
            i.*,
            ROW_NUMBER() OVER (
                PARTITION BY i.ANST_NR, i.IslandId
                ORDER BY i.StartDt DESC, i.EndDt DESC, i.Befattning DESC
            ) AS rn
        FROM Islands i
    ) x
    WHERE rn = 1
),
Deoverlapped AS (
    SELECT
        i.ANST_NR,
        i.Befattning,
        i.BefattningsGrad,  -- <– kvar, men påverkar ej SCD2
        i.StartDt,
        CASE 
            WHEN i.StartDt = w.StartDt AND i.EndDt = w.EndDt AND i.Befattning = w.Befattning
                THEN i.EndDt
            ELSE CASE WHEN i.EndDt <= DATEADD(DAY,-1, w.StartDt) THEN i.EndDt
                      ELSE DATEADD(DAY,-1, w.StartDt) END
        END AS EndDt_Adj
    FROM Islands i
    INNER JOIN Winners w
        ON w.ANST_NR = i.ANST_NR AND w.IslandId = i.IslandId
),
Deoverlapped_Valid AS (
    SELECT *
    FROM Deoverlapped
    WHERE StartDt <= EndDt_Adj
),

/* 4) Trim mot nästa start per anställd (kan aldrig förlänga) */
Trimmed AS (
    SELECT
        d.ANST_NR, d.Befattning, d.BefattningsGrad, d.StartDt,
        CASE 
            WHEN LEAD(d.StartDt) OVER (PARTITION BY d.ANST_NR ORDER BY d.StartDt, d.Befattning) IS NULL 
                THEN d.EndDt_Adj
            ELSE CASE 
                    WHEN d.EndDt_Adj < DATEADD(DAY,-1, LEAD(d.StartDt) OVER (PARTITION BY d.ANST_NR ORDER BY d.StartDt, d.Befattning))
                        THEN d.EndDt_Adj
                    ELSE DATEADD(DAY,-1, LEAD(d.StartDt) OVER (PARTITION BY d.ANST_NR ORDER BY d.StartDt, d.Befattning))
                 END
        END AS EndDt_Final
    FROM Deoverlapped_Valid d
),
Positions_Final AS (
    SELECT *
    FROM Trimmed
    WHERE StartDt <= EndDt_Final
),

/* 5) Brytpunkter – ”dagen efter” på slut, overflow-säkrat */
AllChangePoints AS (
    SELECT ANST_NR, TILLTRADE AS ChangeDate FROM EmploymentPeriods
    UNION ALL
    SELECT ANST_NR,
           CASE WHEN TILLTRADETOM < CONVERT(date,'9999-12-31')
                THEN DATEADD(DAY,1, TILLTRADETOM)
                ELSE CONVERT(date,'9999-12-31') END
    FROM EmploymentPeriods
    UNION ALL
    SELECT ANST_NR, ChangeDate FROM CostCenterChanges
    UNION ALL
    SELECT ANST_NR,
           CASE WHEN ChangeEnd < CONVERT(date,'9999-12-31')
                THEN DATEADD(DAY,1, ChangeEnd)
                ELSE CONVERT(date,'9999-12-31') END
    FROM CostCenterChanges
    UNION ALL
    SELECT ANST_NR, StartDt FROM Positions_Final
    UNION ALL
    SELECT ANST_NR,
           CASE WHEN EndDt_Final < CONVERT(date,'9999-12-31')
                THEN DATEADD(DAY,1, EndDt_Final)
                ELSE CONVERT(date,'9999-12-31') END
    FROM Positions_Final
),
RankedPoints AS (
    SELECT
        acp.ANST_NR,
        acp.ChangeDate,
        LEAD(acp.ChangeDate) OVER (PARTITION BY acp.ANST_NR ORDER BY acp.ChangeDate) AS NextDate
    FROM (SELECT DISTINCT ANST_NR, ChangeDate FROM AllChangePoints) acp
),
ValidSlices AS (
    SELECT
        rp.ANST_NR,
        rp.ChangeDate AS TILLTRADE,
        DATEADD(DAY,-1, rp.NextDate) AS TILLTRADETOM
    FROM RankedPoints rp
    WHERE rp.NextDate IS NOT NULL
),

/* 6) Attribut (befattning frivillig → LEFT JOIN) – Grad tas EJ med */
AddAttributes AS (
    SELECT 
        s.ANST_NR,
        s.TILLTRADE,
        CASE WHEN s.TILLTRADETOM > e.TILLTRADETOM THEN e.TILLTRADETOM ELSE s.TILLTRADETOM END AS TILLTRADETOM,
        e.ANSTALLNINGSFORM,
        k.KostnadsStälle,
        p.Befattning
        -- (ingen BefattningsGrad här)
    FROM ValidSlices s
    INNER JOIN EmploymentPeriods e
        ON s.ANST_NR = e.ANST_NR
       AND s.TILLTRADE BETWEEN e.TILLTRADE AND e.TILLTRADETOM
    LEFT JOIN CostCenterChanges k
        ON s.ANST_NR = k.ANST_NR
       AND s.TILLTRADE BETWEEN k.ChangeDate AND k.ChangeEnd
    LEFT JOIN Positions_Final p
        ON s.ANST_NR = p.ANST_NR
       AND s.TILLTRADE BETWEEN p.StartDt AND p.EndDt_Final
),

/* 7) Komprimera SCD2 – UTAN grad i jämförelsen */
WithLags AS (
    SELECT 
        a.*,
        LAG(a.ANSTALLNINGSFORM) OVER (PARTITION BY a.ANST_NR ORDER BY a.TILLTRADE) AS PrevForm,
        LAG(a.KostnadsStälle)   OVER (PARTITION BY a.ANST_NR ORDER BY a.TILLTRADE) AS PrevKst,
        LAG(a.TILLTRADETOM)     OVER (PARTITION BY a.ANST_NR ORDER BY a.TILLTRADE) AS PrevEnd,
        LAG(a.Befattning)       OVER (PARTITION BY a.ANST_NR ORDER BY a.TILLTRADE) AS PrevBef
        -- (ingen PrevGrad)
    FROM AddAttributes a
),
CollapseGroups AS (
    SELECT
        w.*,
        SUM(CASE 
                WHEN ISNULL(w.PrevForm, N'§') <> ISNULL(w.ANSTALLNINGSFORM, N'§')
                  OR ISNULL(w.PrevKst,  N'§') <> ISNULL(w.KostnadsStälle,  N'§')
                  OR ISNULL(w.PrevBef,  N'§') <> ISNULL(w.Befattning,      N'§')
                  OR w.PrevEnd IS NULL OR DATEDIFF(DAY, w.PrevEnd, w.TILLTRADE) > 1
                THEN 1 ELSE 0 
            END
        ) OVER (PARTITION BY w.ANST_NR ORDER BY w.TILLTRADE ROWS UNBOUNDED PRECEDING) AS GroupId
    FROM WithLags w
),
CollapsedSCD2 AS (
    SELECT
        ANST_NR,
        MIN(TILLTRADE)                    AS TILLTRADE,
        MAX(CAST(TILLTRADETOM AS date))   AS TILLTRADETOM,
        MAX(ANSTALLNINGSFORM)             AS ANSTALLNINGSFORM,
        MAX(KostnadsStälle)               AS KostnadsStälle,
        MAX(Befattning)                   AS Befattning
        -- (ingen BefattningsGrad i resultatet)
    FROM CollapseGroups
    GROUP BY ANST_NR, GroupId
),
FinalSCD2 AS (
    SELECT
        c.*,
        ROW_NUMBER() OVER (ORDER BY TRY_CAST(c.ANST_NR AS int), c.TILLTRADE) AS [AnställdSK]
    FROM CollapsedSCD2 c
)
SELECT
    CAST([ANST_NR] AS int)                  AS [AnstNr],
    CAST([AnställdSK] AS int)               AS [AnställdSk],
    TRY_CAST([KostnadsStälle] AS int)       AS [Kostnadsställe],
    CAST([ANSTALLNINGSFORM] AS varchar(50)) AS [Anställningsform],
    CAST([Befattning] AS nvarchar(200))     AS [Befattning],
    CAST([TILLTRADE] AS date)               AS [Tilltrade],
    CAST([TILLTRADETOM] AS date)            AS [TilltradeTom]
FROM FinalSCD2
where ANST_NR = 8177
ORDER BY [AnstNr], [Tilltrade];
