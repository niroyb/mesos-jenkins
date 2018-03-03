$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$SERVICE_PATH = Join-Path $here "python-server.json"

Import-Module AzureRM

function Login-AzureRmFromEnv {
    if (Test-Path "$here\env.ps1") {
        . "$here\env.ps1"
    }
    else {
        Write-Error "Could not find $here\env.ps1 file to source credentials, please create it"
        exit 1
    }
    
    $subscription = Get-AzureRmSubscription -ErrorAction SilentlyContinue
    
    if ($subscription -eq $null) {
        $secpasswd = ConvertTo-SecureString $Env:CLIENT_SECRET -AsPlainText -Force
        $cred = New-Object System.Management.Automation.PSCredential -ArgumentList $Env:CLIENT_ID, $secpasswd
        Login-AzureRmAccount -Credential $cred -ServicePrincipal -TenantId $Env:TENANT_ID
    }
}

function getScalesetsVMcount ($RG_NAME) {
    $vmCount = 0

    $scaleSets = Get-AzureRmVmss -ResourceGroupName $RG_NAME
    $scaleSets | ForEach-Object {
        $vms = Get-AzureRmVmssVM -ResourceGroupName $RG_NAME -VMScaleSetName $_.Name
        $vmCount += $vms.Count
    }
    return $vmCount
}

function getMasterFQDN ($RG_NAME) {
    $deployment = Get-AzureRmResourceGroupDeployment -ResourceGroupName $RG_NAME
    $masterFQDN = $deployment.Outputs.masterFQDN.Value
    return $masterFQDN
}

function getDCOSagentCount ($RG_NAME) {
    $masterFQDN = getMasterFQDN($RG_NAME)
    $res = Invoke-WebRequest "http://$masterFQDN/dcos-history-service/history/last" | ConvertFrom-Json | Select-Object slaves
    $agentCount = $res.slaves.Count
    return $agentCount
}

Login-AzureRmFromEnv
$RG_NAME = $Env:RESOURCE_GROUP

Describe "Sanity check" {
    It "Is logged in to Azure" {
        $subscription = Get-AzureRmSubscription
        $subscription | Should not be $null
    }

    It "Has a resource group defined: $RG_NAME" {
        $RG_NAME | Should not be $null
        $RG_NAME | Should be $Env:RESOURCE_GROUP
    }
}

Describe "Getting initial state" {

    It "Can get scalesets" {
        # We get ALL the scalesets from the subscription if resource group is null
        $RG_NAME | Should not be $null
        $scaleSets = Get-AzureRmVmss -ResourceGroupName $RG_NAME
        $scaleSets | Should not be $null
        $scaleSets.Count | Should BeGreaterThan 0
    }

    It "Can get scaleset OS" {
        $scaleSets = Get-AzureRmVmss -ResourceGroupName $RG_NAME
        $scaleSets | Should not be $null
        $scaleSets.Count | Should BeGreaterThan 0
        $scaleSets | ForEach-Object {
            $os = $_.VirtualMachineProfile.OsProfile
            $os.WindowsConfiguration -or $os.LinuxConfiguration | Should not be $null
            if ($os.WindowsConfiguration){
                $os.LinuxConfiguration | Should be $null
            }

            if ($os.LinuxConfiguration){
                $os.WindowsConfiguration | Should be $null
            }
        }
    }

    It "Should have at least one windows scaleset" {
        # We will deploy the marathon test app on Windows so make sure it's possible
        $scaleSets = Get-AzureRmVmss -ResourceGroupName $RG_NAME
        $scaleSets | Should not be $null
        $scaleSets.Count | Should BeGreaterThan 0
        $winCount = 0
        $scaleSets | ForEach-Object {
            $os = $_.VirtualMachineProfile.OsProfile
            if ($os.WindowsConfiguration) {
                $winCount += 1
            }
        }
        $winCount | Should BeGreaterThan 0
    }

    It "Can get scaleset VMs" {
        $scaleSets = Get-AzureRmVmss -ResourceGroupName $RG_NAME
        $scaleSets | Should not be $null
        $scaleSets.Count | Should BeGreaterThan 0
        $scaleSets | ForEach-Object {
            $vms = Get-AzureRmVmssVM -ResourceGroupName $RG_NAME -VMScaleSetName $_.Name
            $vms | Should not be $null
            $vms.Count | Should BeGreaterThan 0
        }
    }

    It "Can get DCOS" {
        # If you want to manage the DCOS master remotely you will need to add an inbound NAT rule to open port 80 for the master load balancer and inbound rule for the master network security group.
        $deployment = Get-AzureRmResourceGroupDeployment -ResourceGroupName $RG_NAME
        $deployment | Should not be $null
        
        $masterFQDN = $deployment.Outputs.masterFQDN.Value
        $masterFQDN | Should not be $null
        
        $res = Invoke-WebRequest "http://$masterFQDN/dcos-history-service/history/last" | ConvertFrom-Json | Select-Object slaves
        $res | Should not be $null
        $res.slaves | Should not be $null
        $res.slaves.Count | Should BeGreaterThan 0
    }

    It "Has the expected number of instances in DCOS" {
        $RG_NAME | Should not be $null
        getScalesetsVMcount($RG_NAME) | Should be $(getDCOSagentCount($RG_NAME))
    }
}

Describe "ScaleUp" {
    
    $TestCases = @()
    $scaleSets = Get-AzureRmVmss -ResourceGroupName $RG_NAME
    $scaleSets | Foreach-Object {$TestCases += @{scaleset = $_}}

    It "Can increase the scaleset capacity" -TestCases $TestCases {
        param($scaleset)
        Write-Host $scaleset.Name
        $initial_capacity = $scaleset.Sku.Capacity
        
        # Make sure we are initially scaled down (1 or 2 vms)
        $initial_capacity | Should BeLessThan 3

        # Scale up
        $scaleset.Sku.capacity = 4
        $res = Update-AzureRmVmss -ResourceGroupName $RG_NAME -Name $scaleset.Name -VirtualMachineScaleSet $scaleset
        $res | Should not be $null
        $res.Sku.Capacity | Should be 4

        # Sanity check
        $updated_vmss = Get-AzureRmVmss -ResourceGroupName $RG_NAME -VMScaleSetName $scaleset.Name
        $updated_vmss.Sku.Capacity | Should be 4
    }
}

Describe "DCOS UI" {
    It "Reports the same amount of agents as the number of VMs in the scalesets" {
        $RG_NAME | Should not be $null
        $vmCount = getScalesetsVMcount($RG_NAME)
        $agentCount = 0

        $retryCount = 15

        while ($retryCount -gt 0) {

            $agentCount = getDCOSagentCount($RG_NAME)
            Write-Host "Retry count=$retryCount  VMs=$vmCount  agents=$agentCount"
            if ($vmCount -eq $agentCount){
                break
            }

            $retryCount -= 1
        }

        $agentCount | Should Be $vmCount
    }
}

Describe "DCOS cli cluster" {

    It "Can list the clusters" {
        $clusters = $(dcos cluster list --json | ConvertFrom-Json)
        $? | Should be $True

        $masterFQDN = getMasterFQDN($RG_NAME)
        $thisCluster = $clusters | Where-Object {$_.url -eq "http://$masterFQDN"}

        # Only setup cluster if it not already setup or cli returns an error
        if ($thisCluster -eq $null){
            Write-Host "Adding DCOS cluster: $masterFQDN"
            dcos cluster setup "http://$masterFQDN"
            $? | Should be $True
        }
    }
}

Describe "DCOS service add" {
    It "Has service definition file" {
        Test-Path $SERVICE_PATH -PathType Leaf | Should be $True
    }

    It "Can schedule a service" {
        # This will fail if the service already exists
        dcos marathon app add "$SERVICE_PATH"
        $? | Should be $true
    }

}

Describe "DCOS service deployment progress" {

    It "Can complete the deployment" {
        
        $retryCount = 1

        while ($retryCount -gt 0) {

            $deployments = dcos marathon deployment list --json | ConvertFrom-Json
            Write-Host "Retry count=$retryCount  deployments=$deployments.Count"
            if ($deployments.Count -eq 0){
                break
            }

            $retryCount -= 1
        }
        # No deployments left after successful deploy
        $deployments.Count | Should be 0
    }

    It "Can see the service" {
        # Get service definition from file
        Test-Path $SERVICE_PATH -PathType Leaf | Should be $True
        $service = Get-Content -Raw -Path $SERVICE_PATH | ConvertFrom-Json
        

        $app = dcos marathon app list --json | ConvertFrom-Json | Where-Object {$_.id -eq "/" + $service.id}
        $app.Count | Should be 1
    }

    It "Has a task Running" {
        $service = Get-Content -Raw -Path $SERVICE_PATH | ConvertFrom-Json
        $app = dcos marathon app list --json | ConvertFrom-Json | Where-Object {$_.id -eq "/" + $service.id}
        $app.tasksRunning | Should be 1
    }
}

Describe "DCOS service invocation" {
    It "Can invoke the deployed web server" {
        
    }
}

Describe "DCOS service removal" {
    It "Can remove the deployed service" {
        dcos marathon app remove "/pythonserver"
        $? | Should be $true
    }
}

Describe "ScaleDown" {
    $TestCases = @()
    $scaleSets = Get-AzureRmVmss -ResourceGroupName $RG_NAME
    $scaleSets | Foreach-Object {$TestCases += @{scaleset = $_}}

    It "Can reduce the scaleset capacity" -TestCases $TestCases {
        param($scaleset)
        Write-Host $scaleset.Name
        $initial_capacity = $scaleset.Sku.Capacity
        
        # Make sure we are initially scaled up 3 or more
        $initial_capacity | Should BeGreaterThan 2

        # Scale down to 2
        $scaleset.Sku.capacity = 2
        $res = Update-AzureRmVmss -ResourceGroupName $RG_NAME -Name $scaleset.Name -VirtualMachineScaleSet $scaleset
        $res | Should not be $null
        $res.Sku.Capacity | Should be 2

        # Sanity check
        $updated_vmss = Get-AzureRmVmss -ResourceGroupName $RG_NAME -VMScaleSetName $scaleset.Name
        $updated_vmss.Sku.Capacity | Should be 2
    }

}
