<#
.Synopsis
   Reboots machines in desktop group by placing them into maintenance in predefined bacthes.
.DESCRIPTION
   The script reboots all machines in a given desktop delivery group. This is done by placing a user defined number of
   machines into maintenance, waiting for sessions to logoff and rebooting machines. Once the batch is verfied, the script
   moves to the next batch. The parameters available are DesktopGroupName, PercentToRemain (percentage of machines in the desktop group
   to reamin available), Retryinterval (how often in seconds the script checks for sessions on the given batch), WaitForRegisterInterval (expected
   reboot and registration timeout - if lapses script errors), and MaxRecords (number of machine objects in site, required by powershell.
   Default is 10000, increase if you have more).
   The script is meant to run on the Delivery Controller.
.EXAMPLE
    .\start-desktopgroupreboot.ps1 -DesktopGroupName "My Desktops" -PercentToRemain 80 -WaitForRegisterInterval 180
.NOTES
  Author: Dmitry Palchuk
  Creation Date:  12/2020
#>


Param (
    #Name of Desktop Delivery Group
    [Parameter(Mandatory = $true)]
    $DesktopGroupName,
    #Percent of machines in Desktop Delivery Group to remain available
    [Parameter(Mandatory = $true)]
    [int]$PercentToRemain,
    #Time it takes for machines to reboot and register
    [int]$WaitForRegisterInterval = 120,
    #Retry interval seconds between session count checks
    [int]$RetryInterval = 120,
    # Maximum Records paramater for PS quieries
    [int]$MaxRecords = 10000
)

#Load Citrix snappin
Add-PSSnapIn citrix*

#Functions

function Wait-RebootMaintenance ($machines, $retryinterval, $waitforregisterinterval) {
    #main
    write-host "Working on rebooting $machines" -ForegroundColor Yellow
    #while there are machines that are in maintenance mode
    $verifymachines = $machines
    while ($machines.count -gt 0) {
        write-host $machines.count "machines remaining. machines are `n$machines `n" -ForegroundColor Yellow
        #for each machine check if session count is less then one
        foreach ($machine in $machines) {
            if ((Get-BrokerMachine -MachineName $machine).SessionCount -lt 1) {
                Write-Host $machine "has" (Get-BrokerMachine -MachineName $machine).sessioncount "sessions rebooting"
                #if true reboot and turn off maintenance mode
                Get-BrokerMachine -MachineName $machine | New-BrokerHostingPowerAction -Action Restart | Set-BrokerMachine -InMaintenanceMode $false
                #remove machine from array
                $machines = $machines | Where-Object { $_ -ne $machine }
            }
        }
        write-host "waiting $retryinterval seconds"
        Start-Sleep $retryinterval
    }
    #verify that machines registered
    Start-Sleep $waitforregisterinterval
    foreach ($machine in $verifymachines) {
        if ((Get-BrokerMachine $machine).RegistrationState -ne "Registered") { Throw "One or more of rebooted machines did not register. Stopping" }
    }
    write-host "ending the batch" -foregroundcolor green
}



#Main

#calculate reboot count
[int]$totalcount = (Get-BrokerMachine -MaxRecordCount $maxrecords -DesktopGroupName $desktopgroupname).count
[int]$machinestoremainup = [System.Math]::Round(($totalcount / 100) * $percenttoremain)
[int]$placeinmaintcount = $totalcount - $machinestoremainup
write-host "`nBatches of $placeinmaintcount machines will be placed in maintenance at one time `n" -ForegroundColor Yellow


#get machines with zero sessions first and reboot
$zerosessionmachines = Get-BrokerMachine -MaxRecordCount $maxrecords -DesktopGroupName $desktopgroupname | Where-Object { $_.SessionCount -lt 1 }

if ($zerosessionmachines.count -gt 0) {
    Write-Host "`nThe following machines do not have sessions. rebooting. $($zerosessionmachines.MachineName) `n" -ForegroundColor Yellow
    #reboot
    Wait-RebootMaintenance -machines $zerosessionmachines.machinename -retryinterval $retryinterval -waitforregisterinterval $waitforregisterinterval
    #build remaining array
    write-host "`nBuilding remaining arrays"
    $allmachines = (Get-BrokerMachine -MaxRecordCount $maxrecords -DesktopGroupName $desktopgroupname).MachineName | Where-Object { $_ -notin $zerosessionmachines.machinename }
    if ($allmachines.Count -lt 1) {
        write-host "all machines have been rebooted" -ForegroundColor Green
        break
    }
}

else {
    #Get list of machines in delivery group
    $allmachines = (Get-BrokerMachine -MaxRecordCount $maxrecords -DesktopGroupName $desktopgroupname).MachineName
}


#Cycle through remaining machines in specified batches
while ($allmachines -gt 0) {
    #subtract the placeinmaintenancecount from remaining machines
    $newremainingmachines = $allmachines | Select-Object -first $placeinmaintcount
    #put in maintenance and reboot
    Write-Host "The following machines will be placed into maint" $placeinmaintmachines
    foreach ($box in $newremainingmachines) {
        Write-Host "Placing $box into maintenance"
        set-brokermachine -machinename $box -inmaintenancemode $true
    }
    Wait-RebootMaintenance -machines $newremainingmachines -retryinterval $retryinterval -waitforregisterinterval $waitforregisterinterval
    #update array
    $allmachines = $allmachines | Where-Object { $_ -notin $newremainingmachines }
}

Write-Host "All machines have been rebooted" -ForegroundColor Green