WITH calendar AS
(
    SELECT CAST('2020-01-01' AS DATE) AS MonthStartDate
    UNION ALL
    SELECT DATEADD(MONTH, 1, MonthStartDate)
    FROM calendar
    WHERE DATEADD(MONTH, 1, MonthStartDate) <= EOMONTH(GETDATE())
),
trimmed_arbetstider AS
(
    SELECT
        E.ANST_NR,
        C.MonthStartDate,
        -- PeriodStart styrt av kontrakt
        CASE 
            WHEN E.ANSTALLNINGSDATUM > C.MonthStartDate 
                THEN E.ANSTALLNINGSDATUM 
            ELSE C.MonthStartDate 
        END AS PeriodStart,
        -- PeriodEnd styrt av kontrakt
        CASE 
            WHEN ISNULL(E.AVGANGSDATUM,'9999-12-31') < EOMONTH(C.MonthStartDate) 
                THEN ISNULL(E.AVGANGSDATUM,'9999-12-31') 
            ELSE EOMONTH(C.MonthStartDate) 
        END AS PeriodEnd,
        A_ThisMonth.SYSSELSATTNINGSGRAD
    FROM [MKBBIStage].[Agda].[Anställningar] E
    JOIN calendar C
      ON E.ANSTALLNINGSDATUM <= EOMONTH(C.MonthStartDate)
     AND ISNULL(E.AVGANGSDATUM,'9999-12-31') >= C.MonthStartDate
    OUTER APPLY
    (
        SELECT TOP (1)
            A.SYSSELSATTNINGSGRAD
        FROM [MKBBIStage].[Agda].[Arbetstider] A
        WHERE A.ANST_NR = E.ANST_NR
          AND ISNULL(A.ARBETSTIDTOMTID,'9999-12-31') >= C.MonthStartDate
          AND A.ARBETSTIDFRANTID <= EOMONTH(C.MonthStartDate)
        ORDER BY A.ARBETSTIDFRANTID DESC
    ) A_ThisMonth
),
FA AS
(
    SELECT *
    FROM trimmed_arbetstider
    WHERE PeriodStart <= PeriodEnd  -- tillåt 1-dagarsintervall
),
FINAL AS
(
    SELECT
        FA.ANST_NR,
        FA.MonthStartDate,
        MIN(FA.PeriodStart) AS PeriodStart,
        MAX(FA.PeriodEnd)   AS PeriodEnd,
        MAX(FA.SYSSELSATTNINGSGRAD) AS SysselSattningsGrad
    FROM FA
    GROUP BY
        FA.ANST_NR,
        FA.MonthStartDate
)
SELECT *
FROM (
    SELECT 
        F.[AnställdSK],
        F.[AnställningsNummer],
        F.[Datum],
        F.[KostnadsStälle],
        F.[FTE] AS Fte,
        F.[TillTrädesDatum]  AS FrånGällandeKontraktsDatum,
        F.[FrånTrädesDatum]  AS TillGällandeKontraktsDatum,
        T.PeriodStart        AS FrånKontraktsDatumMånad,
        T.PeriodEnd          AS TillKontraktsDatumMånad,
        DATEDIFF(DAY, T.PeriodStart, T.PeriodEnd) + 1 AS DagarMånadEnligtKontrakt,
        F.[AnställningsForm],
        F.[Källa],
        T.SysselSattningsGrad AS SysselSättningsGrad
        --T.PeriodEnd,
        --T.PeriodStart
    FROM [MKBBIDW].[dbo].[ViewFactFte] F
    LEFT JOIN FINAL T
      ON T.ANST_NR = F.AnställningsNummer
     AND T.MonthStartDate = DATEFROMPARTS(YEAR(F.Datum), MONTH(F.Datum), 1)
) X
WHERE YEAR(X.Datum) = 2024
  --AND X.AnställningsNummer = 12183
OPTION (MAXRECURSION 0);
