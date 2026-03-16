USE [MKBBIDW]
GO

/****** Object:  View [dbo].[TestAnställda]    Script Date: 2026-03-16 15:24:28 ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO


CREATE VIEW [dbo].[TestAnställda]
AS
WITH DistinctFte AS(
SELECT *,
ROW_NUMBER() OVER(PARTITION BY X.ANST_NR ORDER BY X.FRYSDATUM DESC) AS RowNumber
	FROM [MKBBIDW].[fact].[FrystFTE] X)

  SELECT *
  FROM DistinctFte Y
  WHERE Y.RowNumber = 1
GO


