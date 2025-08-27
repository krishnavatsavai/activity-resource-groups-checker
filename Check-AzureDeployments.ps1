# Azure Resource Group Deployment Checker - Last 30 Days
# Prerequisites: Install Azure PowerShell module and authenticate

param(
    [Parameter(Mandatory=$false)]
    [string]$SubscriptionId,
    
    [Parameter(Mandatory=$false)]
    [string]$ResourceGroupListFile = "resource-groups.txt",
    
    [Parameter(Mandatory=$false)]
    [int]$Days = 30,
    
    [Parameter(Mandatory=$false)]
    [string]$OutputFile = "deployment-report-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
)

# Function to check if Azure PowerShell is installed
function Test-AzureModule {
    if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
        Write-Error "Azure PowerShell module not found. Install with: Install-Module -Name Az -AllowClobber"
        exit 1
    }
}

# Function to authenticate to Azure
function Connect-ToAzure {
    try {
        $context = Get-AzContext
        if (-not $context) {
            Write-Host "Connecting to Azure..." -ForegroundColor Yellow
            Connect-AzAccount
        }
        
        if ($SubscriptionId) {
            Set-AzContext -SubscriptionId $SubscriptionId
            Write-Host "Using subscription: $SubscriptionId" -ForegroundColor Green
        }
        
        $currentSub = (Get-AzContext).Subscription.Name
        Write-Host "Current subscription: $currentSub" -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to connect to Azure: $($_.Exception.Message)"
        exit 1
    }
}

# Function to get resource groups from file or parameter
function Get-ResourceGroupList {
    param([string]$FilePath)
    
    $resourceGroups = @()
    
    if (Test-Path $FilePath) {
        Write-Host "Reading resource groups from file: $FilePath" -ForegroundColor Yellow
        $resourceGroups = Get-Content $FilePath | Where-Object { $_.Trim() -ne "" }
    } else {
        Write-Host "File not found: $FilePath" -ForegroundColor Red
        Write-Host "Please create a file with resource group names (one per line) or provide them interactively."
        
        do {
            $rg = Read-Host "Enter Resource Group name (or 'done' to finish)"
            if ($rg -ne "done" -and $rg.Trim() -ne "") {
                $resourceGroups += $rg.Trim()
            }
        } while ($rg -ne "done")
    }
    
    return $resourceGroups
}

# Function to check deployments for a resource group
function Get-ResourceGroupDeployments {
    param(
        [string]$ResourceGroupName,
        [datetime]$StartDate
    )
    
    try {
        Write-Host "Checking deployments for: $ResourceGroupName" -ForegroundColor Cyan
        
        # Check if resource group exists
        $rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
        if (-not $rg) {
            return @{
                ResourceGroup = $ResourceGroupName
                Status = "Resource Group Not Found"
                DeploymentCount = 0
                Deployments = @()
            }
        }
        
        # Get deployments in the last N days
        $deployments = Get-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName | 
                      Where-Object { $_.Timestamp -gt $StartDate }
        
        $deploymentDetails = @()
        foreach ($deployment in $deployments) {
            $deploymentDetails += [PSCustomObject]@{
                Name = $deployment.DeploymentName
                State = $deployment.ProvisioningState
                Timestamp = $deployment.Timestamp
                Mode = $deployment.Mode
                TemplateLink = $deployment.TemplateLink.Uri
            }
        }
        
        return @{
            ResourceGroup = $ResourceGroupName
            Status = "Success"
            DeploymentCount = $deployments.Count
            Deployments = $deploymentDetails
        }
    }
    catch {
        Write-Warning "Error checking $ResourceGroupName : $($_.Exception.Message)"
        return @{
            ResourceGroup = $ResourceGroupName
            Status = "Error: $($_.Exception.Message)"
            DeploymentCount = 0
            Deployments = @()
        }
    }
}

# Main execution
Write-Host "=== Azure Resource Group Deployment Checker ===" -ForegroundColor Green
Write-Host "Checking for deployments in the last $Days days" -ForegroundColor Yellow

# Prerequisites check
Test-AzureModule
Connect-ToAzure

# Calculate date range
$startDate = (Get-Date).AddDays(-$Days)
Write-Host "Looking for deployments since: $($startDate.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Yellow

# Get resource group list
$resourceGroups = Get-ResourceGroupList -FilePath $ResourceGroupListFile

if ($resourceGroups.Count -eq 0) {
    Write-Error "No resource groups specified. Exiting."
    exit 1
}

Write-Host "Found $($resourceGroups.Count) resource groups to check" -ForegroundColor Yellow

# Check deployments for each resource group
$results = @()
$totalDeployments = 0

foreach ($rgName in $resourceGroups) {
    $result = Get-ResourceGroupDeployments -ResourceGroupName $rgName -StartDate $startDate
    $results += $result
    $totalDeployments += $result.DeploymentCount
    
    # Display summary for this RG
    if ($result.DeploymentCount -gt 0) {
        Write-Host "  checkmark $($result.ResourceGroup): $($result.DeploymentCount) deployments" -ForegroundColor Green
    } else {
        Write-Host "  - $($result.ResourceGroup): No deployments" -ForegroundColor Gray
    }
}

# Generate summary report
Write-Host ""
Write-Host "=== SUMMARY ===" -ForegroundColor Green
Write-Host "Total Resource Groups Checked: $($resourceGroups.Count)"
Write-Host "Total Deployments Found: $totalDeployments"
Write-Host "Resource Groups with Deployments: $(($results | Where-Object { $_.DeploymentCount -gt 0 }).Count)"

# Export detailed results to CSV
$csvData = @()
foreach ($result in $results) {
    if ($result.Deployments.Count -gt 0) {
        foreach ($deployment in $result.Deployments) {
            $csvData += [PSCustomObject]@{
                ResourceGroup = $result.ResourceGroup
                DeploymentName = $deployment.Name
                State = $deployment.State
                Timestamp = $deployment.Timestamp
                Mode = $deployment.Mode
                TemplateLink = $deployment.TemplateLink
            }
        }
    } else {
        $csvData += [PSCustomObject]@{
            ResourceGroup = $result.ResourceGroup
            DeploymentName = "No Deployments"
            State = $result.Status
            Timestamp = ""
            Mode = ""
            TemplateLink = ""
        }
    }
}

$csvData | Export-Csv -Path $OutputFile -NoTypeInformation
Write-Host ""
Write-Host "Detailed report exported to: $OutputFile" -ForegroundColor Green

# Display resource groups with recent activity
$activeRGs = $results | Where-Object { $_.DeploymentCount -gt 0 }
if ($activeRGs.Count -gt 0) {
    Write-Host ""
    Write-Host "=== RESOURCE GROUPS WITH RECENT DEPLOYMENTS ===" -ForegroundColor Yellow
    foreach ($rg in $activeRGs) {
        Write-Host "$($rg.ResourceGroup): $($rg.DeploymentCount) deployments" -ForegroundColor Cyan
    }
}

Write-Host ""
Write-Host "Script completed!" -ForegroundColor Green