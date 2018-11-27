# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.

function Main {
    # Create test result
    $superUser = "root"
    $resultArr = @()

    try {
        #region CONFIGURE VM FOR DPDK TEST
        Write-LogInfo "VM details :"
        Write-LogInfo "  RoleName : $($allVMData.RoleName)"
        Write-LogInfo "  Public IP : $($allVMData.PublicIP)"
        Write-LogInfo "  SSH Port : $($allVMData.SSHPort)"
        Write-LogInfo "  Internal IP : $($allVMData.InternalIP)"

        # PROVISION VMS FOR LISA WILL ENABLE ROOT USER AND
        #   WILL MAKE ENABLE PASSWORDLESS AUTHENTICATION ACROSS ALL VMS IN SAME HOSTED SERVICE.
        Provision-VMsForLisa -allVMData $allVMData -installPackagesOnRoleNames "none"
        #endregion

        Write-LogInfo "Getting Active NIC Name."
        $getNicCmd = ". ./utils.sh &> /dev/null && get_active_nic_name"
        $vmNicName = (Run-LinuxCmd -ip $allVMData.PublicIP -port $allVMData.SSHPort -username $superUser -password $password -command $getNicCmd).Trim()

        if($EnableAcceleratedNetworking -or ($currentTestData.AdditionalHWConfig.Networking -imatch "SRIOV")) {
            $DataPath = "SRIOV"
        } else {
            $DataPath = "Synthetic"
        }
        Write-LogInfo "VM $DataPath NIC: $vmNicName"

        Write-LogInfo "Generating constants.sh ..."
        $constantsFile = "$LogDir\constants.sh"
        Set-Content -Value "#Generated by Azure Automation." -Path $constantsFile
        Add-Content -Value "vms=$($allVMData.RoleName)" -Path $constantsFile
        Add-Content -Value "client=$($allVMData.InternalIP)" -Path $constantsFile
        Add-Content -Value "server=$($allVMData.InternalIP)" -Path $constantsFile
        foreach ($param in $currentTestData.TestParameters.param) {
            Add-Content -Value "$param" -Path $constantsFile
        }
        Write-LogInfo "constanst.sh created successfully..."
        Write-LogInfo (Get-Content -Path $constantsFile)
        #endregion

        #region EXECUTE TEST
        $myString = @"
cd /root/
./dpdkSetup.sh 2>&1 > dpdkConsoleLogs.txt
. utils.sh
collect_VM_properties
"@
        Set-Content "$LogDir\StartDpdkSetup.sh" $myString
        Copy-RemoteFiles -uploadTo $allVMData.PublicIP -port $allVMData.SSHPort -files "$constantsFile,$LogDir\StartDpdkSetup.sh" -username $superUser -password $password -upload

        $null = Run-LinuxCmd -ip $allVMData.PublicIP -port $allVMData.SSHPort -username $superUser -password $password -command "chmod +x *.sh" | Out-Null
        $testJob = Run-LinuxCmd -ip $allVMData.PublicIP -port $allVMData.SSHPort -username $superUser -password $password -command "./StartDpdkSetup.sh" -RunInBackground
        #endregion

        #region MONITOR TEST
        while ((Get-Job -Id $testJob).State -eq "Running") {
            $currentStatus = Run-LinuxCmd -ip $allVMData.PublicIP -port $allVMData.SSHPort -username $superUser -password $password -command "tail -2 dpdkConsoleLogs.txt | head -1"
            Write-LogInfo "Current Test Status : $currentStatus"
            Wait-Time -seconds 20
        }
        $finalStatus = Run-LinuxCmd -ip $allVMData.PublicIP -port $allVMData.SSHPort -username $superUser -password $password -command "cat /root/state.txt"
        Copy-RemoteFiles -downloadFrom $allVMData.PublicIP -port $allVMData.SSHPort -username $superUser -password $password -download -downloadTo $LogDir -files "*.csv, *.txt, *.log"

        if ($finalStatus -imatch "TestFailed") {
            Write-LogErr "Test failed. Last known status : $currentStatus."
            $testResult = "FAIL"
        }
        elseif ($finalStatus -imatch "TestAborted") {
            Write-LogErr "Test Aborted. Last known status : $currentStatus."
            $testResult = "ABORTED"
        }
        elseif ($finalStatus -imatch "TestCompleted") {
            Write-LogInfo "Test Completed."
            Write-LogInfo "DPDK build is Success"
            $testResult = "PASS"
        }
        else {
            Write-LogErr "Test execution is not successful, Check test logs in VM."
            $testResult = "ABORTED"
        }
        Write-LogInfo "Test result : $testResult"
    } catch {
        $ErrorMessage =  $_.Exception.Message
        $ErrorLine = $_.InvocationInfo.ScriptLineNumber
        Write-LogErr "EXCEPTION : $ErrorMessage at line: $ErrorLine"
        $testResult = "FAIL"
    } finally {
        if (!$testResult) {
            $testResult = "Aborted"
        }
        $resultArr += $testResult
    }
    $currentTestResult.TestResult = Get-FinalResultHeader -resultarr $resultArr
    return $currentTestResult.TestResult
}

Main
