# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.

function Main {
    # Create test result
    $currentTestResult = Create-TestResultObject
    $resultArr = @()

    try {
        $noClient = $true
        $noServer = $true
        foreach ($vmData in $allVMData) {
            if ($vmData.RoleName -imatch "client") {
                $clientVMData = $vmData
                $noClient = $false
            }
            elseif ($vmData.RoleName -imatch "server") {
                $noServer = $fase
                $serverVMData = $vmData
            }
        }
        if ($noClient) {
            Throw "No any master VM defined. Be sure that, Client VM role name matches with the pattern `"*master*`". Aborting Test."
        }
        if ($noServer) {
            Throw "No any slave VM defined. Be sure that, Server machine role names matches with pattern `"*slave*`" Aborting Test."
        }
        #region CONFIGURE VM FOR TERASORT TEST
        Write-LogInfo "NFS Client details :"
        Write-LogInfo "  RoleName : $($clientVMData.RoleName)"
        Write-LogInfo "  Public IP : $($clientVMData.PublicIP)"
        Write-LogInfo "  SSH Port : $($clientVMData.SSHPort)"
        Write-LogInfo "NSF SERVER details :"
        Write-LogInfo "  RoleName : $($serverVMData.RoleName)"
        Write-LogInfo "  Public IP : $($serverVMData.PublicIP)"
        Write-LogInfo "  SSH Port : $($serverVMData.SSHPort)"

        $testVMData = $clientVMData

        Provision-VMsForLisa -allVMData $allVMData -installPackagesOnRoleNames "none"

        Write-LogInfo "Generating constansts.sh ..."
        $constantsFile = "$LogDir\constants.sh"
        Set-Content -Value "#Generated by Azure Automation." -Path $constantsFile
        foreach ($param in $currentTestData.TestParameters.param) {
            Add-Content -Value "$param" -Path $constantsFile
            Write-LogInfo "$param added to constants.sh"
            if ($param -imatch "startThread") {
                $startThread = [int]($param.Replace("startThread=",""))
            }
            if ($param -imatch "maxThread") {
                $maxThread = [int]($param.Replace("maxThread=",""))
            }
        }
        Write-LogInfo "constanst.sh created successfully..."
        #endregion

        #region EXECUTE TEST
        $myString = @"
chmod +x perf_fio_nfs.sh
./perf_fio_nfs.sh &> fioConsoleLogs.txt
. utils.sh
collect_VM_properties
"@

        $myString2 = @"
chmod +x *.sh
cp fio_jason_parser.sh gawk JSON.awk utils.sh /root/FIOLog/jsonLog/
cd /root/FIOLog/jsonLog/
./fio_jason_parser.sh
cp perf_fio.csv /root
chmod 666 /root/perf_fio.csv
"@
        Set-Content "$LogDir\StartFioTest.sh" $myString
        Set-Content "$LogDir\ParseFioTestLogs.sh" $myString2
        Copy-RemoteFiles -uploadTo $testVMData.PublicIP -port $testVMData.SSHPort -files $currentTestData.files -username "root" -password $password -upload

        Copy-RemoteFiles -uploadTo $testVMData.PublicIP -port $testVMData.SSHPort -files "$constantsFile,$LogDir\StartFioTest.sh,$LogDir\ParseFioTestLogs.sh" -username "root" -password $password -upload

        $null = Run-LinuxCmd -ip $testVMData.PublicIP -port $testVMData.SSHPort -username "root" -password $password -command "chmod +x *.sh" -runAsSudo
        $testJob = Run-LinuxCmd -ip $testVMData.PublicIP -port $testVMData.SSHPort -username "root" -password $password -command "./StartFioTest.sh" -RunInBackground -runAsSudo
        #endregion

        #region MONITOR TEST
        while ((Get-Job -Id $testJob).State -eq "Running") {
            $currentStatus = Run-LinuxCmd -ip $testVMData.PublicIP -port $testVMData.SSHPort -username "root" -password $password -command "tail -1 runlog.txt"-runAsSudo
            Write-LogInfo "Current Test Status : $currentStatus"
            Wait-Time -seconds 20
        }

        $finalStatus = Run-LinuxCmd -ip $testVMData.PublicIP -port $testVMData.SSHPort -username "root" -password $password -command "cat state.txt"
        Copy-RemoteFiles -downloadFrom $testVMData.PublicIP -port $testVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir -files "FIOTest-*.tar.gz"
        Copy-RemoteFiles -downloadFrom $testVMData.PublicIP -port $testVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir -files "VM_properties.csv"

        $testSummary = $null
        #endregion
        #>

        $finalStatus = "TestCompleted"
        if ($finalStatus -imatch "TestFailed") {
            Write-LogErr "Test failed. Last known status : $currentStatus."
            $testResult = "FAIL"
        }
        elseif ($finalStatus -imatch "TestAborted") {
            Write-LogErr "Test Aborted. Last known status : $currentStatus."
            $testResult = "ABORTED"
        }
        elseif ($finalStatus -imatch "TestCompleted") {
            $null = Run-LinuxCmd -ip $testVMData.PublicIP -port $testVMData.SSHPort -username "root" -password $password -command "/root/ParseFioTestLogs.sh"
            Copy-RemoteFiles -downloadFrom $testVMData.PublicIP -port $testVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir -files "perf_fio.csv"
            Write-LogInfo "Test Completed."
            $testResult = "PASS"
        }
        elseif ($finalStatus -imatch "TestRunning") {
            Write-LogInfo "Powershell backgroud job for test is completed but VM is reporting that test is still running. Please check $LogDir\zkConsoleLogs.txt"
            Write-LogInfo "Contests of summary.log : $testSummary"
            $testResult = "PASS"
        }
        Write-LogInfo "Test result : $testResult"
        Write-LogInfo "Test Completed"
        $currentTestResult.TestSummary += Create-ResultSummary -testResult $testResult -metaData "" -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName

        try {
            foreach ($line in (Get-Content "$LogDir\perf_fio.csv")) {
                if ($line -imatch "Max IOPS of each mode") {
                    $maxIOPSforMode = $true
                    $maxIOPSforBlockSize = $false
                }
                if ($line -imatch "Max IOPS of each BlockSize") {
                    $maxIOPSforMode = $false
                    $maxIOPSforBlockSize = $true
                }
                if ($line -imatch "Iteration,TestType,BlockSize") {
                    $maxIOPSforMode = $false
                    $maxIOPSforBlockSize = $false
                }
                if ($maxIOPSforMode) {
                    Add-Content -Value $line -Path $LogDir\maxIOPSforMode.csv
                }
                if ($maxIOPSforBlockSize) {
                    Add-Content -Value $line -Path $LogDir\maxIOPSforBlockSize.csv
                }
                if ($fioDat) {
                    Add-Content -Value $line -Path $LogDir\fioData.csv
                }
            }
            $fioDataCsv = Import-Csv -Path $LogDir\fioData.csv

            Write-LogInfo "Uploading the test results.."
            $dataSource = $xmlConfig.config.$TestPlatform.database.server
            $DBuser = $xmlConfig.config.$TestPlatform.database.user
            $DBpassword = $xmlConfig.config.$TestPlatform.database.password
            $database = $xmlConfig.config.$TestPlatform.database.dbname
            $dataTableName = $xmlConfig.config.$TestPlatform.database.dbtable
            $TestCaseName = $xmlConfig.config.$TestPlatform.database.testTag
            if ($dataSource -And $DBuser -And $DBpassword -And $database -And $dataTableName) {
                $GuestDistro = cat "$LogDir\VM_properties.csv" | Select-String "OS type"| %{$_ -replace ",OS type,",""}
                $HostType = "Azure"
                $HostBy = ($xmlConfig.config.$TestPlatform.General.Location).Replace('"','')
                $HostOS = cat "$LogDir\VM_properties.csv" | Select-String "Host Version"| %{$_ -replace ",Host Version,",""}
                $GuestOSType = "Linux"
                $GuestDistro = cat "$LogDir\VM_properties.csv" | Select-String "OS type"| %{$_ -replace ",OS type,",""}
                $GuestSize = $testVMData.InstanceSize
                $KernelVersion = cat "$LogDir\VM_properties.csv" | Select-String "Kernel version"| %{$_ -replace ",Kernel version,",""}

                $connectionString = "Server=$dataSource;uid=$DBuser; pwd=$DBpassword;Database=$database;Encrypt=yes;TrustServerCertificate=no;Connection Timeout=30;"

                $SQLQuery = "INSERT INTO $dataTableName (TestCaseName,TestDate,HostType,HostBy,HostOS,GuestOSType,GuestDistro,GuestSize,KernelVersion,DiskSetup,BlockSize_KB,QDepth,seq_read_iops,seq_read_lat_usec,rand_read_iops,rand_read_lat_usec,seq_write_iops,seq_write_lat_usec,rand_write_iops,rand_write_lat_usec) VALUES "

                for ($QDepth = $startThread; $QDepth -le $maxThread; $QDepth *= 2) {
                    $seq_read_iops = ($fioDataCsv |  where { $_.TestType -eq "read" -and  $_.Threads -eq "$QDepth"} | Select ReadIOPS).ReadIOPS
                    $seq_read_lat_usec = ($fioDataCsv |  where { $_.TestType -eq "read" -and  $_.Threads -eq "$QDepth"} | Select MaxOfReadMeanLatency).MaxOfReadMeanLatency

                    $rand_read_iops = ($fioDataCsv |  where { $_.TestType -eq "randread" -and  $_.Threads -eq "$QDepth"} | Select ReadIOPS).ReadIOPS
                    $rand_read_lat_usec = ($fioDataCsv |  where { $_.TestType -eq "randread" -and  $_.Threads -eq "$QDepth"} | Select MaxOfReadMeanLatency).MaxOfReadMeanLatency

                    $seq_write_iops = ($fioDataCsv |  where { $_.TestType -eq "write" -and  $_.Threads -eq "$QDepth"} | Select WriteIOPS).WriteIOPS
                    $seq_write_lat_usec = ($fioDataCsv |  where { $_.TestType -eq "write" -and  $_.Threads -eq "$QDepth"} | Select MaxOfWriteMeanLatency).MaxOfWriteMeanLatency

                    $rand_write_iops = ($fioDataCsv |  where { $_.TestType -eq "randwrite" -and  $_.Threads -eq "$QDepth"} | Select WriteIOPS).WriteIOPS
                    $rand_write_lat_usec= ($fioDataCsv |  where { $_.TestType -eq "randwrite" -and  $_.Threads -eq "$QDepth"} | Select MaxOfWriteMeanLatency).MaxOfWriteMeanLatency

                    $BlockSize_KB= (($fioDataCsv |  where { $_.Threads -eq "$QDepth"} | Select BlockSize)[0].BlockSize).Replace("K","")

                    $SQLQuery += "('$TestCaseName','$(Get-Date -Format yyyy-MM-dd)','$HostType','$HostBy','$HostOS','$GuestOSType','$GuestDistro','$GuestSize','$KernelVersion','RAID0:12xP30','$BlockSize_KB','$QDepth','$seq_read_iops','$seq_read_lat_usec','$rand_read_iops','$rand_read_lat_usec','$seq_write_iops','$seq_write_lat_usec','$rand_write_iops','$rand_write_lat_usec'),"
                    Write-LogInfo "Collected performace data for $QDepth QDepth."
                }

                $SQLQuery = $SQLQuery.TrimEnd(',')
                Write-Host $SQLQuery
                $connection = New-Object System.Data.SqlClient.SqlConnection
                $connection.ConnectionString = $connectionString
                $connection.Open()

                $command = $connection.CreateCommand()
                $command.CommandText = $SQLQuery

                $null = $command.executenonquery()
                $connection.Close()
                Write-LogInfo "Uploading the test results done!!"
            } else {
                Write-LogInfo "Invalid database details. Failed to upload result to database!"
            }
        } catch {
            $ErrorMessage =  $_.Exception.Message
            $ErrorLine = $_.InvocationInfo.ScriptLineNumber
            Write-LogInfo "EXCEPTION : $ErrorMessage at line: $ErrorLine"
        }
    } catch {
        $ErrorMessage =  $_.Exception.Message
        $ErrorLine = $_.InvocationInfo.ScriptLineNumber
        Write-LogInfo "EXCEPTION : $ErrorMessage at line: $ErrorLine"
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
