WITH calendar AS (
        SELECT CAST('2020-01-01' AS DATE) AS MonthStartDate
        UNION ALL
        SELECT DATEADD(MONTH, 1, MonthStartDate)
        FROM calendar
        WHERE DATEADD(MONTH, 1, MonthStartDate) <= EOMONTH(GETDATE())
    ),
    trimmed_arbetstider AS (
        SELECT
            A.ANST_NR,
            C.MonthStartDate,
            CASE WHEN MAXDATES.StartDate > C.MonthStartDate THEN MAXDATES.StartDate ELSE C.MonthStartDate END AS PeriodStart,
            CASE WHEN MAXDATES.EndDate < EOMONTH(C.MonthStartDate) THEN MAXDATES.EndDate ELSE EOMONTH(C.MonthStartDate) END AS PeriodEnd,
            A.SYSSELSATTNINGSGRAD
        FROM [MKBBIStage].[Agda].[Arbetstider] A
        JOIN [MKBBIStage].[Agda].[Anställningar] E ON A.ANST_NR = E.ANST_NR
        JOIN calendar C ON COALESCE(A.ARBETSTIDTOMTID, '9999-12-31') >= C.MonthStartDate
                       AND A.ARBETSTIDFRANTID <= EOMONTH(C.MonthStartDate)
        CROSS APPLY (
            SELECT
                CASE WHEN A.ARBETSTIDFRANTID > E.ANSTALLNINGSDATUM THEN A.ARBETSTIDFRANTID ELSE E.ANSTALLNINGSDATUM END AS StartDate,
                CASE WHEN COALESCE(A.ARBETSTIDTOMTID, '9999-12-31') < ISNULL(E.AVGANGSDATUM, '9999-12-31')
                     THEN COALESCE(A.ARBETSTIDTOMTID, '9999-12-31') ELSE ISNULL(E.AVGANGSDATUM, '9999-12-31') END AS EndDate
        ) AS MAXDATES
		)



SELECT  [AnställdSK]
      ,[AnställningsNummer]
      ,[Datum]
      ,[FTE]
      ,[TillTrädesDatum]
      ,[FrånTrädesDatum]
      ,[KostnadsStälle]
      ,[AnställningsForm]
      ,[Källa],
	  T.PeriodStart MonthlyContractualStartDate,
	  T.PeriodEnd MonthlyContractualEndDate,
	  t.SYSSELSATTNINGSGRAD
  FROM [MKBBIDW].[dbo].[ViewFactFte] F
  LEFT JOIN trimmed_arbetstider T ON F.AnställningsNummer = T.ANST_NR AND F.Datum = T.PeriodStart
  WHERE DATEDIFF(DAY, t.PeriodStart, t.PeriodEnd) >= 0
  AND YEAR(DATUM) = 2024


 -- SELECT *
 -- FROM trimmed_arbetstider T 
 --WHERE DATEDIFF(DAY, t.PeriodStart, t.PeriodEnd) >= 0