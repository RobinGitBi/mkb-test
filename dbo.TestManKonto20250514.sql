USE [MKBBIDW]
GO

/****** Object:  View [dbo].[TestManKonto20250514]    Script Date: 2026-03-16 15:14:56 ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO







CREATE VIEW [dbo].[TestManKonto20250514]
AS
SELECT  [KontoNr]
      ,[PNLGroup]
      ,[RRLev1Id]
      ,[RRLev1Namn]
      ,[RRLev2Id]
      ,[RRLev2Namn]
      ,[RRLev3Id]
      ,[RRLev3Namn]
      ,[RRLev4Id]
      ,[RRLev4Namn]
      ,[RRLev5Id]
      ,[RRLev5Namn]
  FROM [MKBBIDW].dim.Konto_ManuellInput
  UNION ALL
  SELECT
  4906 AS [KontoNr],
  'Kostnader för varor, material och vissa köpta tjänster' AS[PNLGroup],
  48 AS [RRLev1Id],
      'Riskkostnader och övriga driftkostnader' AS [RRLev1Namn],
      4800 AS [RRLev2Id],
      'Övriga driftskostnader' AS [RRLev2Namn],
      4906 AS [RRLev3Id],
      '4906 - Omfördelning Kostn.förd PL-tid/debet' AS [RRLev3Namn],
      4906 AS [RRLev4Id],
      '4906 - Omfördelning Kostn.förd PL-tid/debet (Budget)' AS [RRLev4Namn],
      1 AS [RRLev5Id],
      'TB1.1 Driftnetto (DN1)' AS [RRLev5Namn]
UNION ALL
  SELECT
  4907 AS [KontoNr],
  'Kostnader för varor, material och vissa köpta tjänster' AS[PNLGroup],
  48 AS [RRLev1Id],
      'Riskkostnader och övriga driftkostnader' AS [RRLev1Namn],
      4800 AS [RRLev2Id],
      'Övriga driftskostnader' AS [RRLev2Namn],
      4906 AS [RRLev3Id],
      '4906 - Omfördelning Kostn.förd PL-tid/debet' AS [RRLev3Namn],
      4907 AS [RRLev4Id],
      '4907 - Omfördelning Kostn.förd PL-tid/debet (Budget)' AS [RRLev4Namn],
      1 AS [RRLev5Id],
      'TB1.1 Driftnetto (DN1)' AS [RRLev5Namn]
	  UNION ALL
	  SELECT 
	    7298 AS [KontoNr],
  'DN2' AS[PNLGroup],
  999 AS [RRLev1Id],
      'Fastighetsadministration (overhead)' AS [RRLev1Namn],
      4800 AS [RRLev2Id],
      'Fastighetsadministration (overhead)' AS [RRLev2Namn],
      7298 AS [RRLev3Id],
      '7298 - Omfördelning Kostn.förd PL-tid/debet' AS [RRLev3Namn],
      7298 AS [RRLev4Id],
      '7298 - Omfördelning Kostn.förd PL-tid/debet (Budget)' AS [RRLev4Namn],
      999 AS [RRLev5Id],
      'TB1.2 Driftnetto (DN2)' AS [RRLev5Namn]
	  UNION ALL
	 SELECT 
	7299 AS [KontoNr],
  'DN2' AS[PNLGroup],
  999 AS [RRLev1Id],
      'Fastighetsadministration (overhead)' AS [RRLev1Namn],
      4800 AS [RRLev2Id],
      'Fastighetsadministration (overhead)' AS [RRLev2Namn],
      7298 AS [RRLev3Id],
      '7298 - Omfördelning Kostn.förd PL-tid/debet' AS [RRLev3Namn],
      7299 AS [RRLev4Id],
      '7299 - Omfördelning Kostn.förd PL-tid/debet (Budget)' AS [RRLev4Namn],
      999 AS [RRLev5Id],
      'TB1.2 Driftnetto (DN2)' AS [RRLev5Namn]
GO


