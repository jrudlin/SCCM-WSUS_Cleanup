<#
.SYNOPSIS
    Runs a WSUS database cleaup on SCCM Software Update Point servers where WSUS is installed. Runs on top tier (CAS) or lower tier (Primary Site) WSUS servers.
.DESCRIPTION
    Should be deployed/implemented as an SCCM Configuration Baseline/Item to a dynamic Collection containing all SCCM Site Servers.
    Dynamic Collection membership rule:
    - select SMS_R_SYSTEM.ResourceID,SMS_R_SYSTEM.ResourceType,SMS_R_SYSTEM.Name,SMS_R_SYSTEM.SMSUniqueIdentifier,SMS_R_SYSTEM.ResourceDomainORWorkgroup,SMS_R_SYSTEM.Client from SMS_R_System where SMS_R_System.SystemRoles = "SMS Site Server"
.NOTES
    Return Codes:
    - All output including errors are logged to $LogFile

    title     : WSUS Cleanup - SCCM 1806+.ps1
    Author    : Jack Rudlin
    Change History:

     Date           Author           Version   Comments
     25 Sep 2018    Jack Rudlin      1.0       Created Script
     11 Oct 2018    Jack Rudlin      1.1       Updated based on feedback
     12 Oct 2018    Jack Rudlin      1.2       Added IIS Config based on: https://blogs.technet.microsoft.com/meamcs/2018/10/09/resolving-wsus-performance-issues/
     19 Oct 2018    Jack Rudlin      1.3       Two additional Try/Catch added
#>

Try{
    Function Start-WSUSCleanup {

        # Variables
        $SiteServer = $env:COMPUTERNAME # NOTE, This assumes the script has been deployed to a collection which only contains SCCM CAS/Primary Site servers.
        $LogFile = "$env:Temp\Log\WSUS\wsus_cleanup_sccm.log"
        $component = "SCCM WSUS Cleanup Script"
        $CAS_Sleep_Time_Secs = 1800
        $Debug = $false # when running in debug = $true mode, run this script manually as the SYSTEM account (as apposed to in the SCCM CI) on the SCCM Primary Site server as otherwise the SCCM CI that this usually runs under will timeout after 60 seconds

        Function Get-SCCMSiteCode {
            Get-CimInstance -Namespace "root\SMS" -ClassName "SMS_ProviderLocation" -ErrorAction SilentlyContinue | foreach-object -Process {
                if ($_.ProviderForLocalSite -eq $true){
                    $SiteCode = $_.sitecode
                }
            }
            if ($SiteCode) {
                Return $SiteCode
            } else {
                Add-TextToCMLog -LogFile $LogFile -Value "Sitecode of ConfigMgr Site at $SiteServer could not be determined. Could be that SMS Provider is not install on this machine." -Component $component -Severity 3
                exit 1
            }

        }

        Function Add-TextToCMLog {
        <#
        .SYNOPSIS
        Log to a file in a format that can be read by Trace32.exe / CMTrace.exe

        .DESCRIPTION
        Write a line of data to a script log file in a format that can be parsed by Trace32.exe / CMTrace.exe

        The severity of the logged line can be set as:

                1 - Information
                2 - Warning
                3 - Error

        Warnings will be highlighted in yellow. Errors are highlighted in red.

        The tools to view the log:

        SMS Trace - http://www.microsoft.com/en-us/download/details.aspx?id=18153
        CM Trace - Installation directory on Configuration Manager 2012 Site Server - <Install Directory>\tools\

        .EXAMPLE
        Add-TextToCMLog c:\output\update.log "Application of MS15-031 failed" Apply_Patch 3

        This will write a line to the update.log file in c:\output stating that "Application of MS15-031 failed".
        The source component will be Apply_Patch and the line will be highlighted in red as it is an error
        (severity - 3).

        #>

            #Define and validate parameters
            [CmdletBinding()]
            Param(
                #Path to the log file
                [parameter(Mandatory=$True)]
                [String]$LogFile,

                #The information to log
                [parameter(Mandatory=$True)]
                [String]$Value,

                #The source of the error
                [parameter(Mandatory=$True)]
                [String]$Component,

                #The severity (1 - Information, 2- Warning, 3 - Error)
                [parameter(Mandatory=$True)]
                [ValidateRange(1,3)]
                [Single]$Severity
                )


            #Obtain UTC offset
            $DateTime = New-Object -ComObject WbemScripting.SWbemDateTime
            $DateTime.SetVarDate($(Get-Date))
            $UtcValue = $DateTime.Value
            $UtcOffset = $UtcValue.Substring(21, $UtcValue.Length - 21)

            # Delete large log file
            If(test-path -Path $LogFile -ErrorAction SilentlyContinue)
            {
                $LogFileDetails = Get-ChildItem -Path $LogFile
                If ( $LogFileDetails.Length -gt 5mb )
                {
                    Remove-item -Path $LogFile -Force -Confirm:$false
                }
            }

            #Create the line to be logged
            $LogLine =  "<![LOG[$Value]LOG]!>" +`
                        "<time=`"$(Get-Date -Format HH:mm:ss.fff)$($UtcOffset)`" " +`
                        "date=`"$(Get-Date -Format M-d-yyyy)`" " +`
                        "component=`"$Component`" " +`
                        "context=`"$([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)`" " +`
                        "type=`"$Severity`" " +`
                        "thread=`"$($pid)`" " +`
                        "file=`"`">"

            #Write the line to the passed log file
            Out-File -InputObject $LogLine -Append -NoClobber -Encoding Default -FilePath $LogFile -WhatIf:$False

            Switch ($component) {

                1 { Write-Information -MessageData $Value }
                2 { Write-Warning -Message $Value }
                3 { Write-Error -Message $Value }

            }

            write-output -InputObject $Value

        }
        Function Invoke-CMSyncCheck {
        ##########################################################################################################
        <#
        .SYNOPSIS
        Invoke a synchronization check on all software update points.

        .DESCRIPTION
        When ran this function will wait for the software update point synchronization process to complete
        successfully before continuing.

        .EXAMPLE
        Invoke-CMSyncCheck
        Check the ConfigMgr sync status with the default 5 minute lead time.

        #>
        ##########################################################################################################
            [CmdletBinding()]
            Param(
                #The number of minutes to wait after the last sync to run the wizard.
                [int]$SyncLeadTime = 5
            )

            $WaitInterval = 0 #Used to skip the initial wait cycle if it isn't necessary.
            Do{

                #Wait until the loop has iterated once.
                If ($WaitInterval -gt 0){
                    Add-TextToCMLog -LogFile $LogFile -Value "Waiting $TimeToWait minutes for lead time to pass before executing." -Component $component -Severity 1
                    Start-Sleep -Seconds ($WaitInterval)
                }

                #Loop through each SUP and wait until they are all done syncing.
                $LoopCount = 0
                Do {
                    #If syncronizing then wait.
                    If($Syncronizing){
                        Add-TextToCMLog -LogFile $LogFile -Value "Waiting for software update points to stop syncing." -Component $component -Severity 1
                        Start-Sleep -Seconds (300)
                    }

                    $Syncronizing = $False

                    ForEach ($softwareUpdatePointSyncStatus in Get-CMSoftwareUpdateSyncStatus){
                        If($softwareUpdatePointSyncStatus.LastSyncState -eq 6704){$Syncronizing = $True}
                    }

                    $LoopCount++

                } Until((!$Syncronizing) -or ($LoopCount -gt 6 ))

                If($Syncronizing)
                {

                    Add-TextToCMLog -LogFile $LogFile -Value "Failed waiting for WSUS Sync to finish. Exiting." -Component $component -Severity 3
                    Exit

                }
                #Loop through each SUP, calculate the last sync time, and make sure that they all synced successfully.
                $syncTimeStamp = Get-Date -Date "1/1/2001 12:00 AM"
                ForEach ($softwareUpdatePointSyncStatus in Get-CMSoftwareUpdateSyncStatus){
                    If ($softwareUpdatePointSyncStatus.LastSyncErrorCode -ne 0){
                        Add-TextToCMLog -LogFile $LogFile -Value "The software update point $($softwareUpdatePointSyncStatus.WSUSServerName) failed its last synchronization with error code $($softwareUpdatePointSyncStatus.LastSyncErrorCode).  Synchronize successfully before running $component." -Component $component -Severity 2
                        Exit
                    }

                    If ($syncTimeStamp -lt $softwareUpdatePointSyncStatus.LastSyncStateTime) {
                        $syncTimeStamp = $softwareUpdatePointSyncStatus.LastSyncStateTime
                    }
                }


                #Calculate the remaining time to wait for the lead time to expire.
                $TimeToWait = ($syncTimeStamp.AddMinutes($SyncLeadTime) - (Get-Date)).Minutes

                #Set the wait interval in seconds for subsequent loops.
                $WaitInterval = 300
            } Until ($TimeToWait -le 0)

            Add-TextToCMLog -LogFile $LogFile -Value "Software update point synchronization states confirmed." -Component $component -Severity 1
        }

        function Get-Function  {
            param(
                [Parameter(ValueFromPipeline=$true,Mandatory=$true)]
                [String[]]$Name
            )
            begin {
                [string]$functions = ""
            }
            process {
                foreach ($item in $Name)
                {
                    $building = (Get-Item -Path Function:\$item).Definition
                    $functions += "`nfunction $item {
                        $building
                    }"
                }
            }
            end {
                [scriptBlock]::Create($functions)
            }
        }

        #region Load ConfiMgr PoSh module ########################################################################

        # Retrieve the SCCM Site code from WMI on the SCCM Primary Site Server
        $SiteCode = Get-SCCMSiteCode

        # Customizations
        $initParams = @{}

        # Import the ConfigurationManager.psd1 module
        if((Get-Module -Name ConfigurationManager) -eq $null) {
            try{
                Import-Module "$($ENV:SMS_ADMIN_UI_PATH)\..\ConfigurationManager.psd1" @initParams -ErrorAction Stop
            } catch {
                Add-TextToCMLog -LogFile $LogFile -Value "Error importing ConfigMigr PoSh module: $_" -Component $component -Severity 3
                exit 1
            }
        }

        # Connect to the site's drive if it is not already present
        if((Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue) -eq $null) {
            New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $SiteServer @initParams
        }

        # Set the current location to be the site code.
        Set-Location "$($SiteCode):\" @initParams

        #endregion #############################################################################################

        # Check SUP servers in the current site
        Add-TextToCMLog -LogFile $LogFile -Value "Checking SUP servers in the current site: $SiteCode" -Component $component -Severity 1
        $AllWSUSServersInCurrentSiteCode = Get-CMSoftwareUpdateSyncStatus | Where-Object -FilterScript {$_.SiteCode -eq $SiteCode} | Select-Object -Unique -ExpandProperty WSUSServerName
        If($AllWSUSServersInCurrentSiteCode -eq $null){
            Add-TextToCMLog -LogFile $LogFile -Value "Get-CMSoftwareUpdateSyncStatus did not return any SUP servers in site: $SiteCode. Exiting." -Component $component -Severity 3
            return
        }
        Add-TextToCMLog -LogFile $LogFile -Value "$($AllWSUSServersInCurrentSiteCode.Count) SUP servers found in the current site: $SiteCode" -Component $component -Severity 1

        # See if it's the CAS SUP server/Top level WSUS server and add a delay if so (As top level should be processed after lower level WSUS cleanup)
        $TopTierWsus = Get-CMSoftwareUpdateSyncStatus | Where-Object -FilterScript {$_.WSUSSourceServer -like "*Microsoft Update*" -and $_.SiteCode -eq $SiteCode} | Select-Object -Unique -ExpandProperty WSUSServerName

        # Check all SUP servers sync status to see if it's safe to run the cleanup jobs
        Add-TextToCMLog -LogFile $LogFile -Value "Now checking all SUP servers in the current site: $SiteCode to see if they are currently sync'ing" -Component $component -Severity 1
        Invoke-CMSyncCheck

        # Loop each of the WSUS servers in the site and initiate cleanup
        Add-TextToCMLog -LogFile $LogFile -Value "Now starting to invoke cleanup on each of the SUP servers in the site: $SiteCode" -Component $component -Severity 1
        $RemoteFunctions = (Get-Function -Name Add-TextToCMLog)
        $Jobs = @();
        ForEach($RemoteWSUS in $AllWSUSServersInCurrentSiteCode){

                    Add-TextToCMLog -LogFile $LogFile -Value "`nStarting PoSh Job on SUP: $RemoteWSUS" -Component $component -Severity 1

                    # If the SUP is remote from the SiteServer, remind the user that the log file will be written locally on the $RemoteWSUS server
                    If ( -not ( $RemoteWSUS -like "*$SiteServer*" ) )
                    {
                        Add-TextToCMLog -LogFile $LogFile -Value "Please check $LogFile locally on server $RemoteWSUS" -Component $component -Severity 1
                    }

                    # Start the job on the remote or local SUP server
                    Try{
                    $Jobs += Invoke-Command -ArgumentList $CAS_Sleep_Time_Secs,$LogFile,$component,$TopTierWsus,$RemoteWSUS, $RemoteFunctions `
                                                -ComputerName $RemoteWSUS `
                                                -AsJob `
                                                -Verbose `
                                                -ScriptBlock {

                        $LogFile = $Using:LogFile;
                        $TopTierWsus = $Using:TopTierWsus;
                        $component = $Using:component;
                        $RemoteWSUS = $Using:RemoteWSUS;
                        $CAS_Sleep_Time_Secs = $Using:CAS_Sleep_Time_Secs

                        . ([ScriptBlock]::Create($Using:RemoteFunctions))

                        # WSUS IIS AppPool Variables
                        $WSUSSiteNameFilter = "WSUS*"
                        $IISAppPoolQueueMinSize = 2000
                        $IISAppPoolMemoryMinSize = 4194304
                        $ISSWebAdminModuleNAme = "WebAdministration"

                        $IISModule = $true
                        If(-not(get-module -Name $ISSWebAdminModuleNAme)){
                            Try{    
                                Import-Module -Name $ISSWebAdminModuleNAme
                            } Catch {
                                $IISModule = $false
                            }
                        }

                        If($IISModule){

                            $WebSite = Get-Website | Where-Object -FilterScript {$_.Name -like $WSUSSiteNameFilter}
                            If(-not($WebSite)){Add-TextToCMLog -LogFile $LogFile -Value "Could not find IIS website using filter '$WSUSSiteNameFilter'. Skipping IIS config" -Component $component -Severity 3}

                            $WSUSAppPoolName = $WebSite.applicationPool

                            $AppPool = Get-ItemProperty -Path IIS:\AppPools\$WSUSAppPoolName

                            # WSUS App Pool Queue Length
                            $AppPoolQueueLength = $AppPool.queueLength

                            If($AppPoolQueueLength -lt $IISAppPoolQueueMinSize){
                                Add-TextToCMLog -LogFile $LogFile -Value "Setting $WSUSAppPoolName IIS App Pool length to $IISAppPoolQueueMinSize" -Component $component -Severity 1
                                Set-ItemProperty -Path $AppPool.PSPath -Name queueLength -Value $IISAppPoolQueueMinSize
                            } else {
                                Add-TextToCMLog -LogFile $LogFile -Value "$WSUSAppPoolName IIS App Pool length is $AppPoolQueueLength so is already above $IISAppPoolQueueMinSize" -Component $component -Severity 1
                            }

                            # WSUS App Pool Private Memory Size
                            $AppPoolMemorySize = (Get-ItemProperty -Path $AppPool.PSPath -Name recycling.periodicrestart.privateMemory).Value

                            If($AppPoolMemorySize -lt $IISAppPoolMemoryMinSize){
                                Add-TextToCMLog -LogFile $LogFile -Value "Setting $WSUSAppPoolName IIS App Pool memory size to $IISAppPoolMemoryMinSize" -Component $component -Severity 1
                                Set-ItemProperty -Path $AppPool.PSPath -Name recycling.periodicrestart.privateMemory -Value $IISAppPoolMemoryMinSize
                            } else {
                                Add-TextToCMLog -LogFile $LogFile -Value "$WSUSAppPoolName IIS App Pool memory is $AppPoolMemorySize so is already above $IISAppPoolMemoryMinSize" -Component $component -Severity 1
                            }

                        }
                        else
                        {
                            Add-TextToCMLog -LogFile $LogFile -Value "Could not load module $ISSWebAdminModuleNAme. Skipping IIS config" -Component $component -Severity 3
                        }

                        Add-TextToCMLog -LogFile $LogFile -Value "`nWSUS Cleanup Job now running on computer: $($env:COMPUTERNAME)" -Component $component -Severity 1

                        If($TopTierWsus -like "*$env:computername*"){

                            Add-TextToCMLog -LogFile $LogFile -Value "Server: '$TopTierWsus' determined as root/top level WSUS. $CAS_Sleep_Time_Secs seconds sleep starting..." -Component $component -Severity 2

                            For ($i=1; $i -lt $CAS_Sleep_Time_Secs; $i=$i+120){

                                Add-TextToCMLog -LogFile $LogFile -Value "$i seconds passed so far out of $CAS_Sleep_Time_Secs" -Component $component -Severity 2
                                start-sleep -Seconds 120

                            }
                        } else {
                            Add-TextToCMLog -LogFile $LogFile -Value "Server: '$RemoteWSUS' is a lower level WSUS server so starting cleanup now" -Component $component -Severity 1
                        }


                        try{
                            Add-TextToCMLog -LogFile $LogFile -Value "Loading WSUS assemblies..." -Component $component -Severity 1
                            [reflection.assembly]::LoadWithPartialName("Microsoft.UpdateServices.Administration")` | out-null

                            Add-TextToCMLog -LogFile $LogFile -Value "Accessing local WSUS server $RemoteWSUS" -Component $component -Severity 1
                            $WSUS = [Microsoft.UpdateServices.Administration.AdminProxy]::GetUpdateServer()

                            # As per documentation: https://docs.microsoft.com/en-us/sccm/sum/deploy-use/software-updates-maintenance
                            # SCCM 1806 only requires these additional maintenance options be run: 'Unused updates and update revisions', 'Computers not contacting the server' and 'Unneeded update files'

                            $cleanupScope = New-Object -TypeName Microsoft.UpdateServices.Administration.CleanupScope
                            $cleanupScope.CleanupObsoleteUpdates      = $true
                            $cleanupScope.CleanupObsoleteComputers    = $true
                            $cleanupScope.CleanupUnneededContentFiles = $true
                            Write-Information -MessageData "Getting cleanup manager...."
                            $cleanupManager = $WSUS.GetCleanupManager();
                            write-Information -MessageData "Try running cleanup...."

                            Try{
                                $cleanupResults = $cleanupManager.PerformCleanup($cleanupScope);
                            } catch {
                                Add-TextToCMLog -LogFile $LogFile -Value "Oh dear: $($_.Message)" -Component $component -Severity 2
                                Add-TextToCMLog -LogFile $LogFile -Value "Looks like the WSUS service has failed due to the pressures of cleanup. Will restart service and try again" -Component $component -Severity 2
                                Get-Service -Name WSUSService | Start-Service -Confirm:$false
                                start-sleep -Seconds 60
                                Try{
                                    $cleanupResults = $cleanupManager.PerformCleanup($cleanupScope);
                                } catch {
                                    If($($_.Message) -like "*Index was outside the bounds of the array*"){
                                        Add-TextToCMLog -LogFile $LogFile -Value "Error like 'Index was outside the bounds of the array' was received, attempting to recover" -Component $component -Severity 2
                                        If(test-path -Path "$env:programfiles\Update Services\Tools\wsusutil.exe"){
                                            Add-TextToCMLog -LogFile $LogFile -Value "Running WSUS servicing to fix exception error" -Component $component -Severity 1
                                            Start-Process -FilePath "$env:programfiles\Update Services\Tools\wsusutil.exe" -ArgumentList 'postinstall /servicing' -Wait
                                        } else {
                                            Add-TextToCMLog -LogFile $LogFile -Value "Could not find $env:programfiles\Update Services\Tools\wsusutil.exe. Exiting script." -Component $component -Severity 3
                                            return
                                        }
                                    } else {
                                        Add-TextToCMLog -LogFile $LogFile -Value "Unknown WSUS error. Please check Event Viewer and fix error manually. Script will automatically re-run if it is implemented through an SCCM CI. Exiting script." -Component $component -Severity 3
                                        return
                                    }
                                }

                            }

                            Add-TextToCMLog -LogFile $LogFile -Value "Disk Space Freed: $($cleanupResults.DiskSpaceFreed)." -Component $component -Severity 1
                            Add-TextToCMLog -LogFile $LogFile -Value "Obsolete Computers Deleted: $($cleanupResults.ObsoleteComputersDeleted)." -Component $component -Severity 1
                            Add-TextToCMLog -LogFile $LogFile -Value "Obsolete Updates Deleted: $($cleanupResults.ObsoleteUpdatesDeleted)." -Component $component -Severity 1
                            Add-TextToCMLog -LogFile $LogFile -Value "WSUS Cleanup job finished. Now exiting." -Component $component -Severity 1

                        }
                        catch [System.Exception]
                        {
                            Add-TextToCMLog -LogFile $LogFile -Value "Failed to run WSUS cleanup wizard." -Component $component -Severity 3
                            Add-TextToCMLog -LogFile $LogFile -Value "You might need to run the WSUS cleanup wizard multiple times for complete success." -Component $component -Severity 3
                            Add-TextToCMLog -LogFile $LogFile -Value "Error: $($_.Exception.Message)" -Component $component -Severity 3
                            Add-TextToCMLog -LogFile $LogFile -Value "$($_.InvocationInfo.PositionMessage)" -Component $component -Severity 3
                            $WSUS = $null
                        }
                    }

                } catch {
                    Add-TextToCMLog -LogFile $LogFile -Value "An error occured whilst trying to invoke-command on $RemoteWSUS. The error was: $($_.Message)" -Component $component -Severity 3
                }
        }

        If($Debug){
            $SleepSecs = 120
            Do{

                Add-TextToCMLog -LogFile $LogFile -Value "Getting PoSh job output from remaining running jobs..." -Component $component -Severity 1

                ForEach($CurrentJob in ($Jobs | get-job -IncludeChildJob | where-object -FilterScript {$_.State -eq 'Running'})){

                    Add-TextToCMLog -LogFile $LogFile -Value "Information log from job: '$($CurrentJob.Name)' with ID:$($CurrentJob.ID) `n$(
                        If($CurrentJob | get-job -IncludeChildJob | select-object -Property information -ExpandProperty information -ErrorAction SilentlyContinue){
                            $CurrentJob | get-job -IncludeChildJob | select-object -Property information -ExpandProperty information -ErrorAction SilentlyContinue
                        } else {
                            "No output to display right now, still cleaning"
                        })" -Component $component -Severity 1

                    Add-TextToCMLog -LogFile $LogFile -Value "Output log from job: '$($CurrentJob.Name)' with ID:$($CurrentJob.ID) `n$(
                        If($CurrentJob | get-job -IncludeChildJob | select-object -Property output -ExpandProperty output -ErrorAction SilentlyContinue){
                            $CurrentJob | get-job -IncludeChildJob | select-object -Property output -ExpandProperty output -ErrorAction SilentlyContinue
                        } else {
                            "No output to display right now, still cleaning"
                        })" -Component $component -Severity 1

                    Add-TextToCMLog -LogFile $LogFile -Value "Error log from job: '$($CurrentJob.Name)' with ID:$($CurrentJob.ID) `n$(
                        If($CurrentJob | get-job -IncludeChildJob | select-object -Property Error -ExpandProperty Error -ErrorAction SilentlyContinue){
                            $CurrentJob | get-job -IncludeChildJob | select-object -Property Error -ExpandProperty Error -ErrorAction SilentlyContinue
                        } else {
                            "No output to display right now, still cleaning"
                        })" -Component $component -Severity 1
                }

                start-sleep -Seconds $SleepSecs
                $SleepSecs = $SleepSecs + 120
            }

            while

            (

                ($Jobs|get-job -IncludeChildJob).State -eq 'Running'

            )

        }

        # Seems to be a bug if we quit the job really quickly, then the remote 'invoke' job fails
        start-sleep -Seconds 10

    }

    $ScriptFilePath = "$env:Temp\WSUS_CleanUp_SCCM.ps1"

    # Write the file out to the temp folder as SCCM Configuration Items can only run scripts for 60 seconds and this script needs to run for much longer as WSUS is super slow
    ${function:Start-WSUSCleanup} | Out-File -FilePath $ScriptFilePath -Force -Confirm:$false -Width 4096

    # Start the above script that has now been copied out to the temp location
    start-process -FilePath powershell.exe -NoNewWindow -ArgumentList "-file $ScriptFilePath","-NoLogo","-NonInteractive","-NoProfile","-WindowsStyle Hidden"
}
Catch
{
    write-output -InputObject "Error occured whilst trying to run $ScriptFilePath. Error was $($_.Message)"
}