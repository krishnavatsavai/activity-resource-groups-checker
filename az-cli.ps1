# Azure CLI Resource Group Activity Checker - Last 30 Days
# Prerequisites: Install Azure CLI and login with 'az login'

param(
    [Parameter(Mandatory=$false)]
    [string]$ResourceGroupListFile = "resource-groups.txt",
    
    [Parameter(Mandatory=$false)]
    [int]$Days = 30,
    
    [Parameter(Mandatory=$false)]
    [string]$OutputFile = "activity-report-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
)

# Check if Azure CLI is installed
try {
    az version | Out-Null
} catch {
    Write-Error "Azure CLI not found. Install from: https://aka.ms/InstallAzureCLI"
    exit 1
}

# Check if logged in
try {
    $account = az account show | ConvertFrom-Json
    Write-Host "Using subscription: $($account.name)" -ForegroundColor Green
} catch {
    Write-Host "Not logged in to Azure. Running 'az login'..." -ForegroundColor Yellow
    az login
}

Write-Host "=== Azure Resource Group Activity Checker ===" -ForegroundColor Green
Write-Host "Checking for activity in the last $Days days" -ForegroundColor Yellow

# Calculate date range (Azure CLI uses UTC) - Add extra buffer for timezone issues
$startDate = (Get-Date).AddDays(-$Days).AddHours(-24).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
Write-Host "Looking for activity since: $startDate (with 24hr buffer for timezone)" -ForegroundColor Yellow

# Read resource groups
if (Test-Path $ResourceGroupListFile) {
    $resourceGroups = Get-Content $ResourceGroupListFile | Where-Object { $_.Trim() -ne "" }
    Write-Host "Found $($resourceGroups.Count) resource groups to check" -ForegroundColor Yellow
} else {
    Write-Error "File not found: $ResourceGroupListFile"
    Write-Host "Please create a file with resource group names (one per line)"
    exit 1
}

$results = @()
$totalDeployments = 0
$totalActivities = 0

foreach ($rg in $resourceGroups) {
    Write-Host "Checking $rg..." -ForegroundColor Cyan
    
    # Check if resource group exists
    $rgExists = az group show --name $rg 2>$null
    if (-not $rgExists) {
        Write-Host "  Resource group '$rg' not found" -ForegroundColor Red
        $results += [PSCustomObject]@{
            ResourceGroup = $rg
            DeploymentCount = 0
            ActivityCount = 0
            Status = "Not Found"
            HasActivity = $false
        }
        continue
    }
    
    try {
        # Check ARM deployments
        Write-Host "  Checking ARM deployments..." -ForegroundColor Gray
        $deploymentsJson = az deployment group list --resource-group $rg --query "[?timestamp>='$startDate']" 2>$null
        $deployments = if ($deploymentsJson) { $deploymentsJson | ConvertFrom-Json } else { @() }
        $deploymentCount = if ($deployments) { $deployments.Count } else { 0 }
        
        # Debug: Show what deployments exist (without date filter)
        $allDeployments = az deployment group list --resource-group $rg 2>$null | ConvertFrom-Json
        $allDeploymentCount = if ($allDeployments) { $allDeployments.Count } else { 0 }
        Write-Host "    Debug: Found $allDeploymentCount total deployments, $deploymentCount in date range" -ForegroundColor DarkGray
        
        # Check activity logs (Portal activities, manual changes, etc.)
        Write-Host "  Checking activity logs..." -ForegroundColor Gray
        $activitiesJson = az monitor activity-log list --resource-group $rg --start-time $startDate --query "[?status.value=='Succeeded' && (contains(operationName.value, 'write') || contains(operationName.value, 'create') || contains(operationName.value, 'delete') || contains(operationName.value, 'action'))]" 2>$null
        $activities = if ($activitiesJson) { $activitiesJson | ConvertFrom-Json } else { @() }
        $activityCount = if ($activities) { $activities.Count } else { 0 }
        
        $totalActivity = $deploymentCount + $activityCount
        $totalDeployments += $deploymentCount
        $totalActivities += $activityCount
        
        $results += [PSCustomObject]@{
            ResourceGroup = $rg
            DeploymentCount = $deploymentCount
            ActivityCount = $activityCount
            Status = "Success"
            HasActivity = $totalActivity -gt 0
        }
        
        # Display results
        if ($totalActivity -gt 0) {
            Write-Host "  + ${rg}: $deploymentCount deployments, $activityCount activities" -ForegroundColor Green
        } else {
            Write-Host "  - ${rg}: No activity found" -ForegroundColor Gray
        }
        
    } catch {
        Write-Warning "Error checking $rg : $($_.Exception.Message)"
        $results += [PSCustomObject]@{
            ResourceGroup = $rg
            DeploymentCount = 0
            ActivityCount = 0
            Status = "Error: $($_.Exception.Message)"
            HasActivity = $false
        }
    }
}

# Generate summary
Write-Host ""
Write-Host "=== SUMMARY ===" -ForegroundColor Green
Write-Host "Total Resource Groups Checked: $($resourceGroups.Count)"
Write-Host "Total ARM Deployments Found: $totalDeployments"
Write-Host "Total Activity Log Entries: $totalActivities"
Write-Host "Resource Groups with Activity: $(($results | Where-Object { $_.HasActivity }).Count)"

# Export results
$results | Export-Csv -Path $OutputFile -NoTypeInformation
Write-Host ""
Write-Host "Summary report exported to: $OutputFile" -ForegroundColor Green

# Show active resource groups
$activeRGs = $results | Where-Object { $_.HasActivity }
if ($activeRGs.Count -gt 0) {
    Write-Host ""
    Write-Host "=== RESOURCE GROUPS WITH RECENT ACTIVITY ===" -ForegroundColor Yellow
    foreach ($rg in $activeRGs) {
        $total = $rg.DeploymentCount + $rg.ActivityCount
        Write-Host "${rg.ResourceGroup}: $($rg.DeploymentCount) deployments, $($rg.ActivityCount) activities (Total: $total)" -ForegroundColor Cyan
    }
} else {
    Write-Host ""
    Write-Host "No recent activity found in any resource groups." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Script completed!" -ForegroundColor Green

# Optional: Show detailed activity for resource groups with changes
$showDetails = Read-Host "Show detailed activity for active resource groups? (y/N)"
if ($showDetails -eq 'y' -or $showDetails -eq 'Y') {
    foreach ($activeRG in $activeRGs) {
        Write-Host ""
        Write-Host "=== DETAILED ACTIVITY FOR $($activeRG.ResourceGroup) ===" -ForegroundColor Magenta
        
        # Show recent deployments
        if ($activeRG.DeploymentCount -gt 0) {
            Write-Host "ARM Deployments:" -ForegroundColor Yellow
            $deploymentQuery = "[?timestamp>='$startDate'].{Name:name, State:properties.provisioningState, Timestamp:properties.timestamp}"
            $deploymentDetails = az deployment group list --resource-group $activeRG.ResourceGroup --query $deploymentQuery --output table
            Write-Host $deploymentDetails
        }
        
        # Show recent activities (limited to avoid spam)
        if ($activeRG.ActivityCount -gt 0) {
            Write-Host "Recent Activities (Top 10):" -ForegroundColor Yellow
            $activityQuery = "[?status.value=='Succeeded'] | [0:10].{Timestamp:eventTimestamp, Operation:operationName.value, Resource:resourceId, Caller:caller}"
            $activityDetails = az monitor activity-log list --resource-group $activeRG.ResourceGroup --start-time $startDate --query $activityQuery --output table
            Write-Host $activityDetails
        }
    }
}
