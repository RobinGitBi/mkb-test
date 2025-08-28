   SELECT COUNT(*),
   F.ANSTNR
   FROM [MKBBIStage].[Agda].[Frånvaro] F
   WHERE YEAR(F.Fomdatum ) = 2025
   GROUP BY F.Anstnr
   ORDER BY 1 DESC


      SELECT *
   FROM [MKBBIStage].[Agda].[Frånvaro] F
   WHERE YEAR(F.Fomdatum ) = 2025
   and month(f.Fomdatum) in (2,3)
   AND Anstnr = 2149

   ORDER BY 3 ASC


         SELECT *
   FROM [MKBBIStage].[Agda].[Frånvaro] F
   WHERE YEAR(F.Fomdatum ) in (2024, 2025)
   --and month(f.Fomdatum) in (2,3)
   AND Anstnr = 1290
   and Fomdatum between '2024-12-01' and '2025-01-31'
   order by 3 asc