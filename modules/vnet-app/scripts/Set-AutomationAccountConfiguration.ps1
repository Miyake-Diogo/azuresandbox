#!/usr/bin/env pwsh

#region parameters
param (
    [Parameter(Mandatory = $true)]
    [String]$TenantId,

    [Parameter(Mandatory = $true)]
    [String]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [String]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [String]$AutomationAccountName,

    [Parameter(Mandatory = $true)]
    [String]$VmJumpboxWinName,

    [Parameter(Mandatory = $true)]
    [String]$AppId,

    [Parameter(Mandatory = $true)]
    [string]$AppSecret
)
#endregion

#region functions
function Write-Log {
    param( [string] $msg)
    "$(Get-Date -Format FileDateTimeUniversal) : $msg" | Write-Host
}
function Exit-WithError {
    param( [string]$msg )
    Write-Log "There was an exception during the process, please review..."
    Write-Log $msg
    Exit 2
}

Function Get-Dependency {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ModuleName,
        [Parameter(Mandatory = $false)]
        [int] $Level = 0
    )

    if ($Level -eq 0) {
        $orderedModules = [System.Collections.ArrayList]@()
    }

    # Getting dependencies from the gallery
    Write-Verbose "Checking dependencies for $ModuleName"
    $moduleUri = "https://www.powershellgallery.com/api/v2/Search()?`$filter={1}&searchTerm=%27{0}%27&targetFramework=%27%27&includePrerelease=false&`$skip=0&`$top=40"
    $currentModuleUrl = $moduleUri -f $ModuleName, 'IsLatestVersion'
    $searchResult = Invoke-RestMethod -Method Get -Uri $currentModuleUrl -UseBasicParsing | Where-Object { $_.title.InnerText -eq $ModuleName }

    if ($null -eq $searchResult) {
        Write-Log "Skipping module '$ModuleName' because it cannot be found in PowerShell Gallery..."
        Continue
    }
    
    $moduleInformation = (Invoke-RestMethod -Method Get -UseBasicParsing -Uri $searchResult.id)

    #Creating Variables to get an object
    $moduleVersion = $moduleInformation.entry.properties.version
    $dependencies = $moduleInformation.entry.properties.dependencies
    $dependencyReadable = $dependencies -replace '\:.*', ''

    $moduleObject = [PSCustomObject]@{
        ModuleName    = $ModuleName
        ModuleVersion = $ModuleVersion
    }

    # If no dependencies are found, the module is added to the list
    if ([string]::IsNullOrEmpty($dependencies) ) {
        $orderedModules.Add($moduleObject) | Out-Null
    }

    else {
        # If there are dependencies, they are first checked for dependencies of there own. After that they are added to the list.
        Get-Dependency -ModuleName $dependencyReadable -Level ($Level++)
        $orderedModules.Add($moduleObject) | Out-Null
    }

    return $orderedModules
}

function Import-Module-Custom {
    param(
        [Parameter(Mandatory = $true)]
        [String]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [String]$AutomationAccountName,

        [Parameter(Mandatory = $true)]
        [String]$ModuleName,

        [Parameter(Mandatory = $true)]
        [String]$ModuleUri
    )

    Write-Log "Importing module '$ModuleName'..."
    $automationModule = Get-AzAutomationModule -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName | Where-Object { $_.Name -eq $ModuleName }

    if ($null -eq $automationModule) {
        try {
            $automationModule = New-AzAutomationModule `
                -Name $ModuleName `
                -ContentLinkUri $ModuleUri `
                -ResourceGroupName $ResourceGroupName `
                -AutomationAccountName $AutomationAccountName `
                -ErrorAction Stop            
        }
        catch {
            Exit-WithError $_
        }
    }

    if ($automationModule.ProvisioningState -ne 'Created') {
        while ($true) {
            $automationModule = Get-AzAutomationModule -Name $ModuleName -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName
        
            if (($automationModule.ProvisioningState -eq 'Succeeded') -or ($automationModule.ProvisioningState -eq 'Failed') -or ($automationModule.ProvisioningState -eq 'Created')) {
                break
            }

            Write-Log "Module '$($automationModule.Name)' provisioning state is '$($automationModule.ProvisioningState)'..."
            Start-Sleep -Seconds 10
        }
    }

    if ($automationModule.ProvisioningState -eq "Failed") {
        Exit-WithError "Module '$($automationModule.Name)' import failed..."
    }

    Write-Log "Module '$($automationModule.Name)' provisioning state is '$($automationModule.ProvisioningState)'..."
}
function Import-DscConfiguration {
    param(
        [Parameter(Mandatory = $true)]
        [String]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [String]$AutomationAccountName,

        [Parameter(Mandatory = $true)]
        [String]$DscConfigurationName,

        [Parameter(Mandatory = $true)]
        [String]$DscConfigurationScript
    )
    
    Write-Log "Importing DSC configuration '$DscConfigurationName' from '$DscConfigurationScript'..."
    $dscConfigurationScriptPath = Join-Path $PSScriptRoot $DscConfigurationScript
    
    try {
        Import-AzAutomationDscConfiguration `
            -SourcePath $dscConfigurationScriptPath `
            -Description $DscConfigurationName `
            -Published `
            -Force `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $AutomationAccountName `
            -ErrorAction Stop `
        | Out-Null
    }
    catch {
        Exit-WithError $_
    }
}
function Start-DscCompilationJob {
    param(
        [Parameter(Mandatory = $true)]
        [String]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [String]$AutomationAccountName,

        [Parameter(Mandatory = $true)]
        [String]$DscConfigurationName,

        [Parameter(Mandatory = $true)]
        [String]$VirtualMachineName
    )

    Write-Log "Compiling DSC Configuration '$DscConfigurationName'..."

    $params = @{
        ComputerName = $VirtualMachineName
    }

    $configurationData = @{
        AllNodes = @(
            @{
                NodeName = "$VirtualMachineName"
                PsDscAllowPlainTextPassword = $true
            }
        )
    }

    try {
        $dscCompilationJob = Start-AzAutomationDscCompilationJob `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $AutomationAccountName `
            -ConfigurationName $DscConfigurationName `
            -ConfigurationData $configurationData `
            -Parameters $params `
            -ErrorAction Stop
    }
    catch {
        Exit-WithError $_
    }
    
    $jobId = $dscCompilationJob.Id
    
    while (-not $dscCompilationJob.Exception) {
        $dscCompilationJob = $dscCompilationJob | Get-AzAutomationDscCompilationJob
        Write-Log "DSC compilation job ID '$jobId' status is '$($dscCompilationJob.Status)'..."

        if ($dscCompilationJob.Status -in @("Queued", "Starting", "Resuming", "Running", "Stopping", "Suspending", "Activating", "New")) {
            Start-Sleep -Seconds 10
            continue
        }

        # Stop looping if status is Completed, Failed, Stopped, Suspended
        if ($dscCompilationJob.Status -in @("Completed", "Failed", "Stopped", "Suspended")) {
            break
        }

        # Anything else is an unexpected status
        Exit-WithError "DSC compilation job ID '$jobId' returned unexpected status '$($dscCompilationJob.Status)'..."
    }
    
    if ($dscCompilationJob.Exception) {
        Exit-WithError "DSC compilation job ID '$jobId' failed with an exception..."
    }

    if ($dscCompilationJob.Status -in @("Failed", "Stopped", "Suspended")) {
        Exit-WithError "DSC compilation job ID '$jobId' failed with status '$($dscCompilationJob.Status)'..."
    }
}

function Update-ExistingModule {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string] $AutomationAccountName,

        [Parameter(Mandatory = $true)]
        [string] $ModuleName
    )

    Write-Log "Getting module '$ModuleName' in automation account '$AutomationAccountName'..."

    try {
        $automationModule = Get-AzAutomationModule `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $AutomationAccountName `
            -Name $ModuleName `
            -ErrorAction Stop
    }
    catch {
        Exit-WithError $_
    }

    if ($null -eq $automationModule) {
        Exit-WithError "Module '$ModuleName' not found in automation account '$AutomationAccountName'..."
    }

    Write-Log "Checking '$ModuleName' in automation account '$AutomationAccountName' for upgrade..."

    # Get latest version from PowerShell Gallery
    $moduleUri = "https://www.powershellgallery.com/api/v2/Search()?`$filter=IsLatestVersion&searchTerm=%27$ModuleName%27&targetFramework=%27%27&includePrerelease=false&`$skip=0&`$top=40"
    $searchResult = Invoke-RestMethod -Method Get -Uri $moduleUri -UseBasicParsing
    $module = $searchResult | Where-Object { $_.title.InnerText -eq $ModuleName }

    if ($null -eq $module) {
        Write-Log "Module '$ModuleName' cannot be found in PowerShell Gallery..."
        return
    }

    $moduleInformation = (Invoke-RestMethod -Method Get -UseBasicParsing -Uri $module.id)
    $latestVersion = $moduleInformation.entry.properties.version

    # Compare versions
    try {
        $existingVersion = [System.Version]::Parse($automationModule.Version)
        $moduleVersion = [System.Version]::Parse($latestVersion)
    }
    catch {
        Exit-WithError "Invalid version format detected for module '$ModuleName'. ExistingVersion: '$($automationModule.Version)', LatestVersion: '$latestVersion'"
    }

    if ($moduleVersion -gt $existingVersion) {
        # Get the module file
        $moduleContentUrl = "https://www.powershellgallery.com/api/v2/package/$ModuleName"
        do {
            # PS Core work-around for issue https://github.com/PowerShell/PowerShell/issues/4534
            try {
                $moduleContentUrl = (Invoke-WebRequest -Uri $moduleContentUrl -MaximumRedirection 0 -UseBasicParsing -ErrorAction Stop).Headers.Location
            }
            catch {
                $moduleContentUrl = $_.Exception.Response.Headers.Location.AbsoluteUri
            }
        } while ($moduleContentUrl -notlike "*.nupkg")

        Write-Log "Updating module '$ModuleName' in automation account '$AutomationAccountName' from '$($automationModule.Version)' to '$latestVersion'..."

        $parameters = @{
            ResourceGroupName     = $ResourceGroupName
            AutomationAccountName = $AutomationAccountName
            Name                  = $ModuleName
            ContentLink           = $moduleContentUrl
        }

        try {
            New-AzAutomationModule @parameters -ErrorAction Stop | Out-Null
        }
        catch {
            Exit-WithError "Module '$ModuleName' could not be updated..."
        }

        # Check provisioning state
        while ($true) {
            $automationModule = Get-AzAutomationModule -Name $ModuleName -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName

            if (($automationModule.ProvisioningState -eq 'Succeeded') -or ($automationModule.ProvisioningState -eq 'Failed')) {
                break
            }

            Write-Log "Module '$($automationModule.Name)' provisioning state is '$($automationModule.ProvisioningState)'..."
            Start-Sleep -Seconds 10
        }

        if ($automationModule.ProvisioningState -eq "Failed") {
            Exit-WithError "Update for module '$ModuleName' has failed..."
        }

        Write-Log "Module '$ModuleName' update succeeded..."
    }
    else {
        Write-Log "Module '$ModuleName' does not need to be updated..."
    }
}
#endregion

#region main
Write-Log "Running '$PSCommandPath'..."

# Log into Azure
Write-Log "Logging into Azure using service principal id '$AppId'..."

$AppSecretSecure = ConvertTo-SecureString $AppSecret -AsPlainText -Force
$spCredential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $AppId, $AppSecretSecure

try {
    Connect-AzAccount -Credential $spCredential -Tenant $TenantId -ServicePrincipal -ErrorAction Stop | Out-Null
}
catch {
    Exit-WithError $_
}

# Set default subscription
Write-Log "Setting default subscription to '$SubscriptionId'..."

try {
    Set-AzContext -Subscription $SubscriptionId | Out-Null
}
catch {
    Exit-WithError $_
}

# Get automation account
$automationAccount = Get-AzAutomationAccount -ResourceGroupName $ResourceGroupName -Name $AutomationAccountName

if ($null -eq $automationAccount) {
    Exit-WithError "Automation account '$AutomationAccountName' was not found..."
}

Write-Log "Located automation account '$AutomationAccountName' in resource group '$ResourceGroupName'"

# Bootstrap automation modules
Update-ExistingModule `
    -ResourceGroupName $ResourceGroupName `
    -AutomationAccountName $automationAccount.AutomationAccountName `
    -ModuleName 'ComputerManagementDsc'

Import-Module-Custom `
    -ResourceGroupName $ResourceGroupName `
    -AutomationAccountName $automationAccount.AutomationAccountName `
    -ModuleName 'cChoco' `
    -ModuleUri 'https://www.powershellgallery.com/api/v2/package/cChoco'

# Import DSC Configurations
Import-DscConfiguration `
    -ResourceGroupName $ResourceGroupName `
    -AutomationAccountName $automationAccount.AutomationAccountName `
    -DscConfigurationName 'JumpBoxConfiguration' `
    -DscConfigurationScript 'JumpBoxConfiguration.ps1'

# Compile DSC Configurations
Start-DscCompilationJob `
    -ResourceGroupName $ResourceGroupName `
    -AutomationAccountName $automationAccount.AutomationAccountName `
    -DscConfigurationName 'JumpBoxConfiguration' `
    -VirtualMachineName $VmJumpboxWinName

Exit 0
#endregion
