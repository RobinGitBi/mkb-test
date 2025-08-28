WITH calendar AS
  (SELECT CAST('2020-01-01' AS DATE) AS MonthStartDate
   UNION ALL SELECT DATEADD(MONTH, 1, MonthStartDate)
   FROM calendar
   WHERE DATEADD(MONTH, 1, MonthStartDate) <= EOMONTH(GETDATE())),
     trimmed_arbetstider AS
  (SELECT A.ANST_NR,
          C.MonthStartDate,
          CASE
              WHEN MAXDATES.StartDate > C.MonthStartDate THEN MAXDATES.StartDate
              ELSE C.MonthStartDate
          END AS PeriodStart,
          CASE
              WHEN MAXDATES.EndDate < EOMONTH(C.MonthStartDate) THEN MAXDATES.EndDate
              ELSE EOMONTH(C.MonthStartDate)
          END AS PeriodEnd,
          A.SYSSELSATTNINGSGRAD
   FROM [MKBBIStage].[Agda].[Arbetstider] A
   JOIN [MKBBIStage].[Agda].[Anställningar] E ON A.ANST_NR = E.ANST_NR
   JOIN calendar C ON COALESCE(A.ARBETSTIDTOMTID, '9999-12-31') >= C.MonthStartDate
   AND A.ARBETSTIDFRANTID <= EOMONTH(C.MonthStartDate) CROSS APPLY
     (SELECT CASE
                 WHEN A.ARBETSTIDFRANTID > E.ANSTALLNINGSDATUM THEN A.ARBETSTIDFRANTID
                 ELSE E.ANSTALLNINGSDATUM
             END AS StartDate, CASE
                                   WHEN COALESCE(A.ARBETSTIDTOMTID, '9999-12-31') < ISNULL(E.AVGANGSDATUM, '9999-12-31') THEN COALESCE(A.ARBETSTIDTOMTID, '9999-12-31')
                                   ELSE ISNULL(E.AVGANGSDATUM, '9999-12-31')
                               END AS EndDate) AS MAXDATES),
     FA AS
  (SELECT *
   FROM trimmed_arbetstider
   WHERE PeriodStart < PeriodEnd),
     FINAL AS
  (SELECT FA.ANST_NR,
          MIN(FA.PeriodStart) AS PeriodStart,
          MAX(FA.PERIODEND) AS PeriodEnd,
          MAX(FA.SYSSELSATTNINGSGRAD) SysselSattningsGrad
   FROM FA
   GROUP BY FA.ANST_NR,
            YEAR(FA.MONTHSTARTDATE),
            MONTH(FA.MonthStartDate))--SELECT *
--FROM FA

SELECT [AnställdSK] ,
       [AnställningsNummer] ,
       [Datum] ,
       [KostnadsStälle] ,
       [FTE] AS Fte ,
       [TillTrädesDatum] AS FrånGällandeKontraktsDatum ,
       [FrånTrädesDatum] AS TillGällandeKontraktsDatum,
       T.PeriodStart FrånKontraktsDatumMånad,
       T.PeriodEnd TillKontraktsDatumMånad ,
       [AnställningsForm] ,
       [Källa],
       t.SYSSELSATTNINGSGRAD AS SysselSättningsGrad
FROM [MKBBIDW].[dbo].[ViewFactFte] F
LEFT JOIN FINAL T ON F.AnställningsNummer = T.ANST_NR
AND year(F.Datum) = year(t.PeriodEnd)
AND MONTH(f.datum) = month(t.PeriodEnd)