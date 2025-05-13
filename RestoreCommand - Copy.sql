USE dbadmin
GO

IF  EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[dbo].[RestoreCommand]') AND type in (N'P', N'PC'))
DROP PROCEDURE [dbo].[RestoreCommand]
GO

SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[dbo].[RestoreCommand]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [dbo].[RestoreCommand] AS'
END
GO

ALTER PROCEDURE [dbo].[RestoreCommand]
AS

/*************************************************************************************************************
Script for creating automated restore scripts based on Ola Hallengren's Maintenance Solution. 
Source: https://ola.hallengren.com

Create RestoreCommand s proc in location of Maintenance Solution procedures 
and CommandLog table along with creating job steps.

At least one full backup for all databases should be logged to CommandLog table (i.e., executed through Maintenance Solution
created FULL backup job) for generated restore scripts to be valid. 
Restore scripts are generated based on CommandLog table, not msdb backup history.

Restore script is created using ouput file. Each backup job creates a date / time stamped restore script file in separate step.
Add a job to manage file retention if desired (I use a modified version of Ola's Output File Cleanup job).
If possible, perform a tail log backup and add to end of restore script 
in order to avoid data loss (also remove any replace options for full backups).

Make sure sql agent has read / write to the directory that you want the restore script created.

Script will read backup file location from @Directory value used in respective DatabaseBackup job (NULL is supported). 
Set @LogToTable = 'Y' for all backup jobs! (This is the defaut).  

Created by Jared Zagelbaum, 4/13/2015, https://jaredzagelbaum.wordpress.com/
For intro / tutorial see: https://jaredzagelbaum.wordpress.com/2015/04/16/automated-restore-script-output-for-ola-hallengrens-maintenance-solution/
Follow me on Twitter!: @JaredZagelbaum

**************************************************************************************************************/

SET NOCOUNT ON

Declare @DatabaseName sysname
Declare @DatabaseNamePartition sysname = 'N/A'
Declare @Command nvarchar(max)
Declare @IncludeCopyOnly nvarchar(max) = 'Y'   -- include copy only backups in restore script? Added for AlwaysOn support
Declare @message nvarchar(max)
Declare restorecursor CURSOR FAST_FORWARD FOR

with completed_ola_backups as
(
SELECT  [ID]
      ,[DatabaseName]
      ,[SchemaName]
      ,[ObjectName]
      ,[ObjectType]
      ,[IndexName]
      ,[IndexType]
      ,[StatisticsName]
      ,[PartitionNumber]
      ,[ExtendedInfo]
      ,[Command]
      ,[CommandType]
      ,[StartTime]
      ,[EndTime]
      ,[ErrorNumber]
      ,[ErrorMessage]
	  ,CASE WHEN REPLACE([Command],'/','\') LIKE '%\LOG\%' THEN 'Log'
	  WHEN @IncludeCopyOnly = 'Y' AND REPLACE([Command],'/','\') LIKE '%\LOG_COPY_ONLY\%' THEN 'Log'
	  WHEN REPLACE([Command],'/','\') LIKE '%\DIFF\%' THEN 'Diff'
	  WHEN REPLACE([Command],'/','\') LIKE '%\FULL\%' THEN 'Full'
	  WHEN @IncludeCopyOnly = 'Y' AND REPLACE([Command],'/','\') LIKE '%\FULL_COPY_ONLY\%' THEN 'Full'
	  End BackupType
	  ,CASE WHEN REPLACE([Command],'/','\') LIKE '%\LOG\%' THEN 3
	   WHEN @IncludeCopyOnly = 'Y' AND REPLACE([Command],'/','\') LIKE '%\LOG_COPY_ONLY\%' THEN 3
	  WHEN REPLACE([Command],'/','\') LIKE '%\DIFF\%' THEN 2
	  WHEN REPLACE([Command],'/','\') LIKE '%\FULL\%' THEN 1
	   WHEN @IncludeCopyOnly = 'Y' AND REPLACE([Command],'/','\') LIKE '%\FULL_COPY_ONLY\%' THEN 1
	  End BackupTypeOrder
	  ,CASE CommandType
	WHEN 'BACKUP_LOG'
	THEN CHARINDEX('.trn', Command)
	WHEN 'BACKUP_DATABASE'
	THEN CHARINDEX('.bak', Command)
	END filechar
  FROM [dbo].[CommandLog]
  WHERE CommandType IN ('BACKUP_LOG', 'BACKUP_DATABASE')
  AND EndTime IS NOT NULL -- Completed Backups Only
  AND ErrorNumber = 0
  )
  ,lastfull as
  (
  SELECT MAX( [id]) FullId
  ,DatabaseName
  FROM completed_ola_backups
  WHERE BackupType = 'Full'
  GROUP BY DatabaseName
  )
  ,lastdiff as
 (
  SELECT MAX( [id]) DiffId
  ,cob.DatabaseName
  FROM completed_ola_backups cob
  INNER JOIN lastfull lf
  ON cob.DatabaseName = lf.DatabaseName
  AND cob.[ID] > lf.FullId
  WHERE BackupType = 'Diff'
  GROUP BY cob.DatabaseName
  )
  ,lastnonlog as
  (
  SELECT Max([Id]) LogIdBoundary
  ,DatabaseName
  FROM 
	(
		SELECT Fullid Id, DatabaseName
		FROM lastfull
		UNION ALL
		SELECT DiffId Id, ld.DatabaseName
		FROM lastdiff ld
	) Nonlog
  GROUP BY DatabaseName
  )
  ,lastlogs as
  (
  SELECT cob.[Id] logid
  FROM completed_ola_backups cob
  INNER JOIN lastnonlog lnl
  ON cob.DatabaseName = lnl.DatabaseName
  AND cob.[ID] > lnl.LogIdBoundary
 )
 ,validbackups as
 (
 SELECT FullId backupid
 FROM lastfull
 UNION
 SELECT DiffId backupid
 FROM lastdiff
 UNION
 SELECT logid backupid
 FROM lastlogs
 )

 SELECT cob.DatabaseName
 ,
   REPLACE(
     REPLACE(
       REPLACE(
         REPLACE(
           REPLACE(
             -- Remove backup options at the end
             LEFT(
               Command, 
               CASE 
                 WHEN CHARINDEX('WITH ', Command) > 0 
                   THEN CHARINDEX('WITH ', Command) - 1 
                 ELSE LEN(Command) 
               END
             ),
             'BACKUP LOG', 'RESTORE LOG'
           ),
           'BACKUP DATABASE', 'RESTORE DATABASE'
         ),
         'TO URL = N''', 'FROM URL = N'''
       ),
       ', URL = N''', ', URL = N'''
     ),
     '''', ''''
   )
   + ' WITH NORECOVERY'
   + CASE BackupType
       WHEN 'Full' THEN ', REPLACE;'
       ELSE ';'
     END AS RestoreCommand
 FROM completed_ola_backups cob
 WHERE EXISTS
   (SELECT *
   FROM validbackups vb
   WHERE cob.[ID] = vb.backupid
   )
 ORDER BY cob.DatabaseName, Id, BackupTypeOrder
 ;

RAISERROR( '/*****************************************************************', 10, 1) WITH NOWAIT
 set @message = 'Emergency Script Restore for ' + @@Servername +  CASE @@Servicename WHEN 'MSSQLSERVER' THEN '' ELSE '\' + @@Servicename END 
 RAISERROR(@message,10,1) WITH NOWAIT
 set @message = 'Generated ' + convert(nvarchar, getdate(), 9)  
 RAISERROR(@message,10,1) WITH NOWAIT
 set @message = 'Script does not perform a tail log backup. Dataloss may occur, use only for emergency DR.'
 RAISERROR(@message,10,1) WITH NOWAIT
 RAISERROR( '******************************************************************/', 10, 1) WITH NOWAIT

OPEN RestoreCursor

 FETCH NEXT FROM restorecursor
 INTO @databasename, @command

WHILE @@FETCH_STATUS = 0
 BEGIN

 IF @DatabaseName <> @DatabaseNamePartition AND @DatabaseNamePartition <> 'N/A'
	BEGIN
	set @message = 'RESTORE DATABASE ' + '[' + @DatabaseNamePartition + ']' + ' WITH RECOVERY;'
	RAISERROR(@message,10,1) WITH NOWAIT
	END

	IF @DatabaseName <> @DatabaseNamePartition
		BEGIN
			set @message = char(13) + char(10) + char(13) + char(10) + '--------' + @DatabaseName + '-------------'
			RAISERROR(@message,10,1) WITH NOWAIT
		END
	
	RAISERROR( @Command,10,1) WITH NOWAIT

	SET @DatabaseNamePartition = @DatabaseName
FETCH NEXT FROM restorecursor
INTO @databasename, @command

END

set @message =  'RESTORE DATABASE ' + '[' +  @DatabaseNamePartition + ']' + ' WITH RECOVERY;' 
RAISERROR(@message,10,1) WITH NOWAIT
;

CLOSE restorecursor;
DEALLOCATE restorecursor;

GO


