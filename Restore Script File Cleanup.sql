USE [msdb]
GO

/******************
This script is not an auto template. It creates a clean up task similar to output file cleanup
used by Ola Hallengren Solution, but uses Powershell commands instead of ForFiles for easier referencing to UNC paths

Created by Jared Zagelbaum, jaredzagelbaum.wordpress.com
Created 5/11/2015
Follow me on twitter: @JaredZagelbaum
*******************/

BEGIN TRANSACTION


Declare @backupdir nvarchar(max) =  'B:\SQLBackup\!restore_scripts' --set root directory here


IF EXISTS (
    SELECT 1 
    FROM msdb.dbo.sysjobs 
    WHERE name = N'Restore Script File Cleanup'
)
BEGIN
    EXEC msdb.dbo.sp_delete_job 
        @job_name = N'Restore Script File Cleanup',
        @delete_unused_schedule = 1;
END


DECLARE @ReturnCode INT
SELECT @ReturnCode = 0
IF NOT EXISTS (SELECT name FROM msdb.dbo.syscategories WHERE name=N'Database Maintenance' AND category_class=1)
BEGIN
EXEC @ReturnCode = msdb.dbo.sp_add_category @class=N'JOB', @type=N'LOCAL', @name=N'Database Maintenance'
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback

END

DECLARE @jobId BINARY(16)
EXEC @ReturnCode =  msdb.dbo.sp_add_job @job_name=N'Restore Script File Cleanup', 
		@enabled=1, 
		@notify_level_eventlog=2, 
		@notify_level_email=2, 
		@notify_level_netsend=0, 
		@notify_level_page=0, 
		@delete_level=0, 
		@description=N'Deletes generated restore script file after indicated number of days', 
		@category_name=N'Database Maintenance', 
		@owner_login_name=N'sa', 
		--@notify_email_operator_name=N'DBAdmins', 
		@job_id = @jobId OUTPUT
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback

Declare @pscommand nvarchar(max) = N'$erroractionpreference = "Stop"
$computer = gc env:computername
Get-ChildItem -path Microsoft.PowerShell.Core\FileSystem::' + @backupdir + ' | where {$_.Lastwritetime -lt (date).
addhours(-48)} | remove-item
'

EXEC @ReturnCode = msdb.dbo.sp_add_jobstep @job_id=@jobId, @step_name=N'Restore Script File Cleanup', 
		@step_id=1, 
		@cmdexec_success_code=0, 
		@on_success_action=1, 
		@on_success_step_id=0, 
		@on_fail_action=2, 
		@on_fail_step_id=0, 
		@retry_attempts=0, 
		@retry_interval=0, 
		@os_run_priority=0, @subsystem=N'PowerShell', 
		@command= @pscommand, 
		--@output_file_name=N'$(ESCAPE_SQUOTE(SQLLOGDIR))\RestoreScriptFileCleanup_$(ESCAPE_SQUOTE(JOBID))_$(ESCAPE_SQUOTE(STEPID))_$(ESCAPE_SQUOTE(STRTDT))_$(ESCAPE_SQUOTE(STRTTM)).txt', 
		@flags=0

DECLARE @schedule_id int
EXEC msdb.dbo.sp_add_jobschedule @job_id=@jobId, @name=N'daily 11 AM', 
		@enabled=1, 
		@freq_type=4, 
		@freq_interval=1, 
		@freq_subday_type=1, 
		@freq_subday_interval=0, 
		@freq_relative_interval=0, 
		@freq_recurrence_factor=1, 
		@active_start_date=20250513, 
		@active_end_date=99991231, 
		@active_start_time=110000, 
		@active_end_time=235959, @schedule_id = @schedule_id OUTPUT
select @schedule_id


IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
EXEC @ReturnCode = msdb.dbo.sp_update_job @job_id = @jobId, @start_step_id = 1
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
EXEC @ReturnCode = msdb.dbo.sp_add_jobserver @job_id = @jobId, @server_name = N'(local)'
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
COMMIT TRANSACTION
GOTO EndSave
QuitWithRollback:
    IF (@@TRANCOUNT > 0) ROLLBACK TRANSACTION
EndSave:

GO


