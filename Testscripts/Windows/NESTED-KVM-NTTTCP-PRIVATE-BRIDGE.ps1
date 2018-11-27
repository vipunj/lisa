# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.

$testScript = "nested_kvm_ntttcp_private_bridge.sh"

function New-ConstantsFile ($filePath) {
    Write-LogInfo "Generating constants.sh ..."
    Set-Content -Value "#Generated by Azure Automation." -Path $filePath

    foreach ($param in $currentTestData.TestParameters.param) {
        Add-Content -Value "$param" -Path $filePath
    }
    Write-LogInfo "constants.sh created successfully..."
    Write-LogInfo (Get-Content -Path $filePath)
}

function Start-TestExecution ($ip, $port) {
    Copy-RemoteFiles -uploadTo $ip -port $port -files $currentTestData.files -username $user -password $password -upload

    Run-LinuxCmd -username $user -password $password -ip $ip -port $port -command "chmod +x *" -runAsSudo

    Write-LogInfo "Executing : ${testScript}"
    $cmd = "/home/$user/${testScript} -logFolder /home/$user > /home/$user/TestExecutionConsole.log"
    $testJob = Run-LinuxCmd -username $user -password $password -ip $ip -port $port -command $cmd -runAsSudo -RunInBackground

    while ((Get-Job -Id $testJob).State -eq "Running" ) {
        $currentStatus = Run-LinuxCmd -username $user -password $password -ip $ip -port $port -command "cat /home/$user/state.txt"
        Write-LogInfo "Current Test Status : $currentStatus"
        Wait-Time -seconds 20
    }
}

function Send-ResultToDatabase ($xmlConfig, $logDir) {
    Write-LogInfo "Uploading the test results.."
    $dataSource = $xmlConfig.config.Azure.database.server
    $user = $xmlConfig.config.Azure.database.user
    $password = $xmlConfig.config.Azure.database.password
    $database = $xmlConfig.config.Azure.database.dbname
    $dataTableName = $xmlConfig.config.Azure.database.dbtable
    $testCaseName = $xmlConfig.config.Azure.database.testTag
    if ($dataSource -And $user -And $password -And $database -And $dataTableName) {
        # Get host info
        $hostType    = "Azure"
        $hostBy    = ($xmlConfig.config.Azure.General.Location).Replace('"','')
        $hostOS    = Get-Content "$logDir\VM_properties.csv" | Select-String "Host Version"| ForEach-Object{$_ -replace ",Host Version,",""}

        # Get L1 guest info
        $l1GuestDistro    = Get-Content "$logDir\VM_properties.csv" | Select-String "OS type"| ForEach-Object{$_ -replace ",OS type,",""}
        $l1GuestOSType    = "Linux"
        $l1GuestSize = $AllVMData.InstanceSize
        $l1GuestKernelVersion    = Get-Content "$logDir\VM_properties.csv" | Select-String "Kernel version"| ForEach-Object{$_ -replace ",Kernel version,",""}
        $imageInfo = $xmlConfig.config.Azure.Deployment.Data.Distro.ARMImage
        $imageName = "$($imageInfo.Publisher) $($imageInfo.Offer) $($imageInfo.Sku) $($imageInfo.Version)"

        # Get L2 guest info
        $l2GuestDistro    = Get-Content "$logDir\nested_properties.csv" | Select-String "OS type"| ForEach-Object{$_ -replace ",OS type,",""}
        $l2GuestKernelVersion    = Get-Content "$logDir\nested_properties.csv" | Select-String "Kernel version"| ForEach-Object{$_ -replace ",Kernel version,",""}

        foreach ($param in $currentTestData.TestParameters.param) {
            if ($param -match "NestedCpuNum") {
                $L2GuestCpuNum = [int]($param.split("=")[1])
            }
            if ($param -match "NestedMemMB") {
                $L2GuestMemMB = [int]($param.split("=")[1])
            }
            if ($param -match "NestedNetDevice") {
                $KvmNetDevice = $param.split("=")[1]
            }
        }

        $ipVersion = "IPv4"
        $protocolType = "TCP"
        $connectionString = "Server=$dataSource;uid=$user; pwd=$password;Database=$database;Encrypt=yes;TrustServerCertificate=no;Connection Timeout=30;"
        $logContents = Get-Content -Path "$logDir\report.log"
        $sqlQuery = "INSERT INTO $dataTableName (TestCaseName,TestDate,HostType,HostBy,HostOS,ImageName,L1GuestOSType,
            L1GuestDistro,L1GuestSize,L1GuestKernelVersion,L2GuestDistro,L2GuestKernelVersion,L2GuestMemMB,L2GuestCpuNum,
            KvmNetDevice,IPVersion,ProtocolType,NumberOfConnections,Throughput_Gbps,Latency_ms) VALUES "

        for ($i = 1; $i -lt $logContents.Count; $i++) {
            $line = $logContents[$i].Trim() -split '\s+'
            $sqlQuery += "('$testCaseName','$(Get-Date -Format yyyy-MM-dd)','$hostType','$hostBy','$hostOS','$imageName','$l1GuestOSType',
                '$l1GuestDistro','$l1GuestSize','$l1GuestKernelVersion','$l2GuestDistro','$l2GuestKernelVersion','$L2GuestMemMB','$L2GuestCpuNum',
                '$KvmNetDevice','$ipVersion','$protocolType',$($line[0]),$($line[1]),$($line[2])),"
        }
        $sqlQuery = $sqlQuery.TrimEnd(',')
        Write-LogInfo $sqlQuery

        $connection = New-Object System.Data.SqlClient.SqlConnection
        $connection.ConnectionString = $connectionString
        $connection.Open()

        $command = $connection.CreateCommand()
        $command.CommandText = $sqlQuery
        $null = $command.executenonquery()
        $connection.Close()
        Write-LogInfo "Uploading the test results done!!"
    } else {
        Write-LogInfo "Database details are not provided. Results will not be uploaded to database!"
    }
}

function Main {
    $currentTestResult = Create-TestResultObject
    $resultArr = @()
    $testResult = $resultAborted

    try {
        $hs1VIP = $AllVMData.PublicIP
        $hs1vm1sshport = $AllVMData.SSHPort

        $constantsFile = "$LogDir\constants.sh"
        New-ConstantsFile -filePath $constantsFile
        Copy-RemoteFiles -uploadTo $hs1VIP -port $hs1vm1sshport -files "$constantsFile" -username $user -password $password -upload

        Start-TestExecution -ip $hs1VIP -port $hs1vm1sshport

        # Download test logs
        $files = "/home/$user/state.txt, /home/$user/${testScript}.log, /home/$user/TestExecutionConsole.log"
        Copy-RemoteFiles -download -downloadFrom $hs1VIP -files $files -downloadTo $LogDir -port $hs1vm1sshport -username $user -password $password
        $finalStatus = Get-Content $LogDir\state.txt
        if ($finalStatus -imatch "TestFailed") {
            Write-LogErr "Test failed. Last known status : $currentStatus."
            $testResult = $resultFail
        }
        elseif ($finalStatus -imatch "TestAborted") {
            Write-LogErr "Test Aborted. Last known status : $currentStatus."
            $testResult = $resultAborted
        }
        elseif ($finalStatus -imatch "TestCompleted") {
            $testResult = $resultPass
        }
        elseif ($finalStatus -imatch "TestRunning") {
            Write-LogInfo "Powershell backgroud job for test is completed but VM is reporting that test is still running. Please check $LogDir\zkConsoleLogs.txt"
            $testResult = $resultAborted
        }

        # Collect L1 VM properties
        Run-LinuxCmd -username $user -password $password -ip $hs1VIP -port $hs1vm1sshport -command ". utils.sh && collect_VM_properties" -runAsSudo
        Copy-RemoteFiles -download -downloadFrom $hs1VIP -files "/home/$user/VM_properties.csv" -downloadTo $LogDir -port $hs1vm1sshport -username $user -password $password

        if ($testResult -imatch $resultPass) {
            $files = "/home/$user/ntttcpConsoleLogs, /home/$user/ntttcpTest.log, /home/$user/report.log, /home/$user/nested_properties.csv"
            Copy-RemoteFiles -download -downloadFrom $hs1VIP -files $files -downloadTo $LogDir -port $hs1vm1sshport -username $user -password $password
            $files = "/home/$user/ntttcp-test-logs-receiver.tar, /home/$user/ntttcp-test-logs-sender.tar"
            Copy-RemoteFiles -download -downloadFrom $hs1VIP -files $files -downloadTo $LogDir -port $hs1vm1sshport -username $user -password $password

            $ntttcpReportLog = Get-Content -Path "$LogDir\report.log"
            if (!$ntttcpReportLog) {
                $testResult = $resultFail
                throw "Invalid NTTTCP report file"
            }
            $uploadResults = $true
            $checkValues = "$resultPass,$resultFail,$resultAborted"
            foreach ($line in $ntttcpReportLog) {
                if ($line -imatch "test_connections") {
                    continue;
                }
                try {
                    $splits = $line.Trim() -split '\s+'
                    $testConnections = $splits[0]
                    $throughputGbps = $splits[1]
                    $cyclePerByte = $splits[2]
                    $averageTcpLatency = $splits[3]
                    $metadata = "Connections=$testConnections"
                    $connResult = "throughput=$throughputGbps`Gbps cyclePerBytet=$cyclePerByte Avg_TCP_lat=$averageTcpLatency"
                    $currentTestResult.TestSummary +=  Create-ResultSummary -testResult $connResult -metaData $metaData -checkValues $checkValues -testName $currentTestData.testName
                    if ([string]$throughputGbps -imatch "0.00") {
                        $testResult = $resultFail
                        $uploadResults = $false
                    }
                } catch {
                    $currentTestResult.TestSummary +=  Create-ResultSummary -testResult "Error in parsing logs." -metaData "NTTTCP" -checkValues $checkValues -testName $currentTestData.testName
                }
            }

            Write-LogInfo $currentTestResult.TestSummary
            if (!$uploadResults) {
                Write-LogInfo "Zero throughput for some connections, results will not be uploaded to database!"
            }
            else {
                Send-ResultToDatabase -xmlConfig $xmlConfig -logDir $LogDir
            }
        }
    } catch {
        $errorMessage =  $_.Exception.Message
        $ErrorLine = $_.InvocationInfo.ScriptLineNumber
        Write-LogInfo "EXCEPTION : $errorMessage at line: $ErrorLine"
    }

    $resultArr += $testResult
    Write-LogInfo "Test result : $testResult"
    $currentTestResult.TestResult = Get-FinalResultHeader -resultarr $resultArr
    return $currentTestResult.TestResult
}

# Global Variables
# $xmlConfig
# $AllVMData
# $currentTestData
# $Distro
# $user
# $password
# $resultPass
# $resultFail
# $resultAborted

Main
