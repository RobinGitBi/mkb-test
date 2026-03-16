USE [MKBBIDW]
GO

/****** Object:  View [dbo].[TestAnställdScd2]    Script Date: 2026-03-16 14:54:59 ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE VIEW [dbo].[TestAnställdScd2]
AS


-- Step 1: Employment periods (contracts)
WITH EmploymentPeriods AS (
    SELECT 
        ANST_NR,
        TILLTRADE,
        COALESCE(TILLTRADETOM, '9999-12-31') AS TILLTRADETOM,
        ANSTALLNINGSFORM
    FROM [MKBBIStage].[Agda].[Anställningsform]
),

-- Step 2: Cost center changes
CostCenterChanges AS (
    SELECT 
        ANST_NR,
        KONTERINGFRANTID AS ChangeDate,
        COALESCE(KONTERINGTOMTID, '9999-12-31') AS ChangeEnd,
        DATA AS KostnadsStälle
    FROM [MKBBIStage].[Agda].[Konteringar]
    WHERE KONTERING = 'Kostnadsställe'
),

-- Step 3: All relevant change boundaries
AllChangePoints AS (
    SELECT ANST_NR, TILLTRADE AS ChangeDate FROM EmploymentPeriods
    UNION
    SELECT ANST_NR, TILLTRADETOM FROM EmploymentPeriods
    UNION
    SELECT ANST_NR, ChangeDate FROM CostCenterChanges
    UNION
    SELECT ANST_NR, ChangeEnd FROM CostCenterChanges
),

-- Step 4: Rank and slice periods
RankedPoints AS (
    SELECT 
        ANST_NR,
        ChangeDate,
        LEAD(ChangeDate) OVER (PARTITION BY ANST_NR ORDER BY ChangeDate) AS NextDate
    FROM (
        SELECT DISTINCT ANST_NR, ChangeDate FROM AllChangePoints
    ) x
),

ValidSlices AS (
    SELECT 
        R.ANST_NR,
        R.ChangeDate AS TILLTRADE,
        DATEADD(DAY, -1, R.NextDate) AS TILLTRADETOM
    FROM RankedPoints R
    WHERE R.NextDate IS NOT NULL
),

-- Step 5: Join attributes valid during each slice, clip TILLTRADETOM
AddAttributes AS (
    SELECT 
        S.ANST_NR,
        S.TILLTRADE,
        CASE 
            WHEN S.TILLTRADETOM > E.TILLTRADETOM THEN E.TILLTRADETOM 
            ELSE S.TILLTRADETOM 
        END AS TILLTRADETOM,
        E.ANSTALLNINGSFORM,
        K.DATA AS KostnadsStälle
    FROM ValidSlices S
    LEFT JOIN EmploymentPeriods E
        ON S.ANST_NR = E.ANST_NR
        AND S.TILLTRADE BETWEEN E.TILLTRADE AND E.TILLTRADETOM
    LEFT JOIN [MKBBIStage].[Agda].[Konteringar] K
        ON S.ANST_NR = K.ANST_NR
        AND K.KONTERING = 'Kostnadsställe'
        AND S.TILLTRADE BETWEEN K.KONTERINGFRANTID AND COALESCE(K.KONTERINGTOMTID, '9999-12-31')
),

-- Step 6: Keep only valid employment slices
Filtered AS (
    SELECT *
    FROM AddAttributes
    WHERE ANSTALLNINGSFORM IS NOT NULL
),

-- Step 7a: Precompute lag columns
WithLags AS (
    SELECT *,
        LAG(ANSTALLNINGSFORM) OVER (PARTITION BY ANST_NR ORDER BY TILLTRADE) AS PrevForm,
        LAG(KostnadsStälle) OVER (PARTITION BY ANST_NR ORDER BY TILLTRADE) AS PrevKostnad,
        LAG(TILLTRADETOM) OVER (PARTITION BY ANST_NR ORDER BY TILLTRADE) AS PrevEnd
    FROM Filtered
),

-- Step 7b: Compute group based on value changes
CollapseGroups AS (
    SELECT *,
        SUM(CASE 
                WHEN PrevForm IS NULL OR PrevForm != ANSTALLNINGSFORM 
                  OR PrevKostnad IS NULL OR PrevKostnad != KostnadsStälle
                  OR PrevEnd IS NULL OR DATEDIFF(DAY, PrevEnd, TILLTRADE) > 1
                THEN 1 ELSE 0 
            END
        ) OVER (PARTITION BY ANST_NR ORDER BY TILLTRADE ROWS UNBOUNDED PRECEDING) AS GroupId
    FROM WithLags
),

-- Step 8: Aggregate collapsed periods
CollapsedSCD2 AS (
    SELECT
        ANST_NR,
        MIN(TILLTRADE) AS TILLTRADE,
        MAX(CAST(TILLTRADETOM AS DATE)) AS TILLTRADETOM,
        MAX(ANSTALLNINGSFORM) AS ANSTALLNINGSFORM,
        MAX(KostnadsStälle) AS KostnadsStälle
    FROM CollapseGroups
    GROUP BY ANST_NR, GroupId
),

-- Step 9: Assign surrogate key
FinalSCD2 AS (
    SELECT *,
        ROW_NUMBER() OVER( ORDER BY CAST(ANST_NR AS INT) ASC, TILLTRADE ASC) AS AnställdSK
    FROM CollapsedSCD2
)

-- Step 10: Output
SELECT *
FROM FinalSCD2
--WHERE ANST_NR = '1101';  -- Replace or remove this filter for full result

GO


