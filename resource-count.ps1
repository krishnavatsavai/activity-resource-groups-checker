# Simple Azure Resource Count Checker
# Just checks resource count in each resource group

param(
    [Parameter(Mandatory=$false)]
    [string]$ResourceGroupListFile = "resource-groups.txt"
)

# Check if Azure CLI is installed and logged in
try {
    az account show | Out-Null
} catch {
    Write-Error "Not logged in to Azure CLI. Run 'az login' first."
    exit 1
}

# Read resource groups list
if (Test-Path $ResourceGroupListFile) {
    $resourceGroups = Get-Content $ResourceGroupListFile | Where-Object { $_.Trim() -ne "" }
} else {
    Write-Error "File not found: $ResourceGroupListFile"
    Write-Host "Create a file with resource group names (one per line)"
    exit 1
}

Write-Host "=== Resource Count Checker ===" -ForegroundColor Green
Write-Host ""

$results = @()
$totalResources = 0
$emptyCount = 0

foreach ($rg in $resourceGroups) {
    # Check if resource group exists
    $rgExists = az group show --name $rg 2>$null
    if (-not $rgExists) {
        Write-Host "$rg : NOT FOUND" -ForegroundColor Red
        $results += [PSCustomObject]@{ ResourceGroup = $rg; ResourceCount = 0; Status = "Not Found" }
        continue
    }
    
    # Count resources
    $resourceCount = (az resource list --resource-group $rg --query "length(@)" --output tsv 2>$null)
    if (-not $resourceCount) { $resourceCount = 0 }
    
    $totalResources += $resourceCount
    if ($resourceCount -eq 0) { $emptyCount++ }
    
    $results += [PSCustomObject]@{ 
        ResourceGroup = $rg
        ResourceCount = [int]$resourceCount
        Status = "Found" 
    }
    
    # Display result
    if ($resourceCount -eq 0) {
        Write-Host "$rg : EMPTY (0 resources)" -ForegroundColor Red
    } else {
        Write-Host "$rg : $resourceCount resources" -ForegroundColor Green
    }
}

# Summary
Write-Host ""
Write-Host "=== SUMMARY ===" -ForegroundColor Yellow
Write-Host "Total Resource Groups: $($resourceGroups.Count)"
Write-Host "Empty Resource Groups: $emptyCount"  
Write-Host "Resource Groups with Resources: $(($resourceGroups.Count - $emptyCount))"
Write-Host "Total Resources: $totalResources"

# Export to CSV
$results | Export-Csv -Path $OutputFile -NoTypeInformation
Write-Host ""
Write-Host "Results saved to: $OutputFile" -ForegroundColor Green

# Show empty resource groups for cleanup
$emptyRGs = $results | Where-Object { $_.ResourceCount -eq 0 -and $_.Status -eq "Found" }
if ($emptyRGs.Count -gt 0) {
    Write-Host ""
    Write-Host "Empty resource groups ready for cleanup:" -ForegroundColor Red
    foreach ($rg in $emptyRGs) {
        Write-Host "az group delete --name $($rg.ResourceGroup) --yes --no-wait" -ForegroundColor DarkRed
    }
}
