<#
.Synopsis
   This script promotes PVS Maintenance version to production.
.DESCRIPTION
   This script checks if the update machine is powered off, shuts it down if needed, promotes maintenance version to production, and optionally launches Scheduled Task to
   synchronize PVS servers. The script can be ran interactively without providing paramaters.
   Configuration XML file - InteractivePVSConfig.xml is required for this automation to work. Please specify the file path below the Param block.
.EXAMPLE
    .\Promote-PVSDiskUpdateVersion.ps1 -pvsStoreName "MyStore" -pvsDiskName "myDisk2020"
.NOTES
    If script will not be ran in admin context, make sure Scheduled task has permissions to be executed by users. C:\Windows\System32\Tasks
    At this time Scheduled Task works only if it exists on the same machine that runs this script.

    Author: Dmitry Palchuk
    Creation Date:  12/2020
#>


Param(
    [string]$pvsStoreName,
    [string]$pvsDiskName
)


#Configuration File Path
[xml]$ConfigFile = Get-Content "C:\automation\InteractivePVSConfig.xml"



#vars
$ShutdownTimeout = $ConfigFile.Settings.PVSSettings.ShutdownTimeout
$UpdateCollection = $ConfigFile.Settings.PVSSettings.PVSUpdateCollection
$syncTaskName = $ConfigFile.Settings.PVSSyncTask.syncTaskName
$syncTaskPath = $ConfigFile.Settings.PVSSyncTask.syncTaskPath
$SyncTimeout = $ConfigFile.Settings.PVSSyncTask.SyncTimeout
$PVSScheduledTaskExists = $ConfigFile.Settings.PVSSyncTask.PVSSyncTask
$RemotePVS = $ConfigFile.Settings.BaseSettings.RemotePVS
$RemotePVSServerFQDN = $ConfigFile.Settings.BaseSettings.RemotePVSServerFQDN
$RemotePVSServerPort = $ConfigFile.Settings.BaseSettings.RemotePVSServerPort

#load PVS Snappin
Import-Module $ConfigFile.Settings.BaseSettings.PVSModuleLocation

#connect to pvs server
if ($RemotePVS -eq "true") {
    Set-PvsConnection -Server $RemotePVSServerFQDN -Port $RemotePVSServerPort
}

#get store
If ([string]::IsNullOrEmpty($pvsStoreName)) {
    $PVSStores = Citrix.PVS.SnapIn\Get-PvsStore

    Write-Host "Please select the PVS Store"
    For ($i = 0; $i -lt $PVSStores.Count; $i++) {
        Write-Host "$($i+1): $($PVSStores[$i].Name)"
    }

    [int]$number = Read-Host "Press the number to select store:"
    $pvsstorename = $PVSStores[$number - 1].Name
}
Write-Host "You selected $PVSstorename" -ForegroundColor Green

#get disk
If ([string]::IsNullOrEmpty($pvsDiskName)) {
    #Check if store contains multple disks and prompt
    if (((Citrix.PVS.SnapIn\Get-PvsDiskLocator | Where-Object { $_.StoreName -eq $pvsstorename }).diskLocatorId).count -gt 1) {

        $Disks = Citrix.PVS.SnapIn\Get-PvsDiskLocator | Where-Object { $_.StoreName -eq $pvsstorename }

        Write-Host "The store you selected contains mutliple disks. Please choose the disk"
        For ($i = 0; $i -lt $Disks.Count; $i++) {
            Write-Host "$($i+1): $($Disks[$i].diskLocatorName)"
        }

        [int]$number = Read-Host "Press the number to select disk"
        $disklocator = $Disks[$number - 1]
        $updateDiskLocatorID = (Citrix.PVS.SnapIn\get-pvsdisklocator | Where-Object { $_.DiskLocatorName -eq $($disklocator.name) }).DiskLocatorId.guid


    }
    else {
        $disklocator = Citrix.PVS.SnapIn\Get-PvsDiskLocator | Where-Object { $_.StoreName -eq $pvsstorename }
        $updateDiskLocatorID = $disklocator.disklocatorid.Guid
    }
}

else {
    $disklocator = Citrix.PVS.SnapIn\Get-PvsDiskLocator | Where-Object { $_.Name -eq $pvsDiskName }
    $updateDiskLocatorID = $disklocator.disklocatorid.Guid
}

#get writable ver
$diskVersions = Citrix.PVS.SnapIn\Get-PvsDiskVersion -DiskLocatorId $updateDiskLocatorID
$updateversion = $null
#Check if any of the versions are Test or Maintenance
foreach ($version in $diskversions) {
    if (($version.Access -eq 1 -or $version.Access -eq 2 ) -and $version.CanPromote -eq $true) {

        Write-Host "Found the PVS Maintenance Version." -ForegroundColor Green
        $updateversion = $version
    }
}
If ([string]::IsNullOrEmpty($updateversion)) {
    Write-Host "Writable version not found please verify the selected disk" -ForegroundColor Red
    Exit
}


#check if writable version is in use
if ($updateversion.DeviceCount -gt 0) {

    #get machine
    $updatevm = Citrix.PVS.SnapIn\Get-PvsDeviceInfo | Where-Object { $_.DiskLocatorName -eq $($($disklocator.StoreName) + "\" + $($disklocator.DiskLocatorName)) -and $_.Type -ne 0 -and $_.CollectionName -eq $UpdateCollection }
    Write-Host "Found update machine $($updatevm.name)" -ForegroundColor Yellow
    #check for pending reboot?
    #shutdown machine
    write-host "`nStopping" $updatevm.Name -ForegroundColor Yellow
    Citrix.PVS.SnapIn\Start-PvsDeviceShutdown -DeviceName $updatevm.name | Out-Null
    #wait for version to free up
    #Configure and start timer
    $CheckEvery = 10
    $timer = [Diagnostics.Stopwatch]::StartNew()

    #Check ver state
    while ($updateversion.DeviceCount -gt 0) {
        $updateversion = Citrix.PVS.SnapIn\Get-PvsDiskVersion -DiskLocatorId $updateDiskLocatorID | Where-Object { $_.Access -eq 1 }
        ## If the timer has waited greater than or equal to the timeout, throw an exception exiting the loop
        if ($timer.Elapsed.TotalSeconds -ge $ShutdownTimeout) {
            write-host "Timeout exceeded. Giving up on stopping $updateMachine. Please check manually" -ForegroundColor Red
            Exit
        }
        ## Stop the loop every $CheckEvery seconds
        Start-Sleep -Seconds $CheckEvery >$null
    }

    ## When finished, stop the timer
    $timer.Stop()


}
Write-Host $updatevm.Name "is stopped. promoting the version" -ForegroundColor Yellow
#promote version
Citrix.PVS.SnapIn\Get-PvsDiskLocator -Name $disklocator.name -SiteName $updatevm.SiteName -StoreName $disklocator.StoreName -Fields Guid | Citrix.PVS.SnapIn\Invoke-PvsPromoteDiskVersion
Write-Host "`nPromoted $($disklocator.name) on $($disklocator.StoreName) store." -ForegroundColor Green
#sync stores
If ($PVSScheduledTaskExists -eq "True") {
    Write-Host "Synchronizing PVS servers" -ForegroundColor Yellow
    #Configure and start timer
    $CheckEvery = 10
    $timer = [Diagnostics.Stopwatch]::StartNew()

    #Check ver state
    Start-ScheduledTask -TaskName $syncTaskName -TaskPath $syncTaskPath
    while ((Get-ScheduledTask -TaskName $syncTaskName).State -ne 'Ready') {
        ## If the timer has waited greater than or equal to the timeout, throw an exception exiting the loop
        if ($timer.Elapsed.TotalSeconds -ge $SyncTimeout) {
            write-host "Timeout exceeded. Giving up on syncing version. Please check manually" -ForegroundColor Red
            Exit
        }
        ## Stop the loop every $CheckEvery seconds
        Start-Sleep -Seconds $CheckEvery >$null
    }

    ## When finished, stop the timer
    $timer.Stop()

    Write-Host "`nCompleted sync. Verifying replication" -ForegroundColor Yellow
    #Check PVS version replication status
    [array]$problemversions = @()
    $diskVersions = Citrix.PVS.SnapIn\Get-PvsDiskVersion -DiskLocatorId $updateDiskLocatorID
    foreach ($version in $diskversions) {
        if ($version.Access -eq 1 -or $version.Access -eq 2 -or $version.GoodInventoryStatus -ne "True") {

            Write-Host "Found the PVS version that is out of sync or in maintenance. The version is $($version.Name) with number $($version.Version)" -ForegroundColor Red
            [array]$problemversions += $version
        }
    }
    If (![string]::IsNullOrEmpty($problemversions)) {
        Write-Host "`nWritable version not found please verify the selected disk:" -ForegroundColor Red
        $problemversions.name
        Exit
    }
    Elseif ([string]::IsNullOrEmpty($problemversions)) {
        Write-Host "`nAll versions are in sync and not in maintenance" -ForegroundColor Green

    }
}
Else {
    Write-Host "Replication task was not specified in script configuration file. Please ensure that all PVS stores are synchronized" -ForegroundColor Green
}