## Title   : W10-0365-2004-MS
## Version : 1.0.0
## Purpose : This code will run against Azure Image Builder to create a Windows 10 2004 Multi-Session image with
##           Office 365 installed with customizations. 
##
## Author  : Tyler Leverre-Smith 
## Email   : tleverresmith@gmail.com
## GitHub  : https://github.com/tleverresmith

# Collect the credentials from Azure Automation Account Assets
Write-Output "Get auto connection for the AzureRunAsConnection'"
$ConnectionAsset = Get-AutomationConnection -Name 'AzureRunAsConnection'

# Azure auth
$AzContext = $null
try {
    $AzAuth = Connect-AzAccount -ApplicationId $ConnectionAsset.ApplicationId `
                                -CertificateThumbprint $ConnectionAsset.CertificateThumbprint `
                                -TenantId $ConnectionAsset.TenantId `
                                -SubscriptionId $ConnectionAsset.SubscriptionId `
                                -EnvironmentName 'AzureCloud' `
                                -ServicePrincipal

    if (!$AzAuth -or !$AzAuth.Context) {
        throw $AzAuth
    }
    
    $AzContext = $AzAuth.Context
}
catch {
    throw [System.Exception]::new('Failed to authenticate Azure with application ID, tenant ID, subscription ID', $PSItem.Exception)
}

## General Variables
# The postfix to be appended to names for uniqueness between runs
# change as desired but try to keep something that will stay unique as clashing names can cause failures.
$varPostfix = Get-Date -Format yyyyMMddhhmmss

## Temporary Resource Group Variables
$tmpRgRegion = "West US 2"
$tmpRgName = "AzWVD-AIB-$varPostFix"
Write-Output "Temporary Resource Group Name: $tmpRgName"
Write-Output "Temporary Resource Group Region: $tmpRgRegion"

## User Managed Identity Variables
$manIdName = "AzWVD-AIB-ID-$varPostfix"
Write-Output "Managed ID Name: $manIdName"

## Image Template Variables
$templateName = "AzWVD-IMG-$varPostfix"
$templatePublisher = "MicrosoftWindowsDesktop" # Publisher of the base image to use
$templateOffer = "office-365" # Offer of the base image to use
$templateSku = "20h1-evd-o365pp" # SKU of the base image to use
$templateVersion = "latest"  # Version of the base image to use
$templaterunOutputName = "Output-$varPostfix" # The name of the output object during distribution within Azure, you need this to query build status.
Write-Output "Image Template Name: $templateName"
Write-Output "Base Image Publisher: $templatePublisher"
Write-Output "Base Image Offer: $templateOffer"
Write-Output "Base Image Sku: $templateSku"
Write-Output "Base Image Version: $templateVersion"
Write-Output "Image RunOutput Name: $templaterunOutputName"

## Script Execution Starts
$tmpRgCreateResults = New-AzResourceGroup -Name $tmpRgName -Location $tmpRgRegion
If($tmpRgCreateResults.provisioningState -eq "Succeeded") {
    Write-Output "Resource Group Created: $tmpRgName"
} else {
    throw "Resource Group Creation Failed"
    Exit 0xDEAD
}

$manIdCreateResults = New-AzUserAssignedIdentity -ResourceGroupName $tmpRgName -Name $manIdName
If($null -eq $manIdCreateResults) {
    throw "Unable to create the managed identity in Azure"
    Exit 0xDEAD    
} else {
    $manIdClientID = $manIdCreateResults.clientId
    $manIdPid = $manIdCreateResults.PrincipalId
    $manIdArmPath = $manIdCreateResults.Id
    Write-Output "Managed ID Client ID: $manIdClientID"
    Write-Output "Managed ID PID: $manIdPid"
    Write-Output "Managed ID ARM Path: $manIdArmPath"
}

# BUG - Workaround, MS needs to fix the AzRoleAssignment cmndlets in runbooks
Start-Sleep 30 # Allow Azure to catch up, sometimes it moved too fast and the ID is not assigned yet. If we could use Get-AzRoleAssignment this wouldn't be an issue...

Try {
    $tempRgID = (Get-AzResourceGroup -Name $tmpRgName).ResourceId
} catch {
    throw "Error: Unable to resolve the temporary resource group ID"
    exit 0xDEAD
}

# Exception of type 'Microsoft.Rest.Azure.CloudException' is thrown.
New-AzRoleAssignment -ObjectId $manIdPid -Scope $tempRgID -RoleDefinitionName Contributor | Out-Null

# BUG - Workaround, MS needs to fix the AzRoleAssignment cmndlets in runbooks
Start-Sleep 30 # Allow Azure to catch up, sometimes it moved too fast and the ID is not assigned yet. If we could use Get-AzRoleAssignment this wouldn't be an issue...

Write-Output "Building the image template objects"
# Stage the image source
$srcPlatform = New-AzImageBuilderSourceObject `
                -SourceTypePlatformImage `
                -Publisher $templatePublisher  `
                -Offer $templateOffer `
                -Sku $templateSku `
                -Version $templateVersion

# Stage the distributor object
$disSharedImg = New-AzImageBuilderDistributorObject -ManagedImageDistributor `
                -ArtifactTag @{} `
                -ImageID "/subscriptions/$subscriptionID/resourceGroups/$tmpRgName/providers/Microsoft.Compute/images/Image-$varPostfix" `
                -Location "West US 2" `
                -RunOutputName $templaterunOutputName


# Create windows update customzier objects
$custWindowsUpdate = New-AzImageBuilderCustomizerObject `
                           -WindowsUpdateCustomizer -Filter ("BrowseOnly", "IsInstalled") `
                           -SearchCriterion "BrowseOnly=0 and IsInstalled=0"  `
                           -UpdateLimit 100 `
                           -CustomizerName 'WindowsUpdate'

$custRestart = New-AzImageBuilderCustomizerObject `
                -RestartCustomizer `
                -CustomizerName 'PostPatchRestart'

# Stage the template        
Write-Output "Submitting the template to Azure"
New-AzImageBuilderTemplate -ImageTemplateName $templateName `
                           -ResourceGroupName $tmpRgName `
                           -Distribute $disSharedImg `
                           -Source $srcPlatform `
                           -UserAssignedIdentityId $manIdArmPath `
                           -Location $tmpRgRegion `
                           -Customize @($custWindowsUpdate, `
                                        $custRestart) | Out-Null

Write-Output "Verifying the status of the image template"

# Invoke the Azure Image Builder with the created template
$imageTemplate = Get-AzImageBuilderTemplate -ResourceGroupName $tmpRgName -Name $templateName
Write-Output "Template ProvisioningState: $($imageTemplate.ProvisioningState)"

If($imageTemplate.ProvisioningState -ne "Succeeded") {
    Write-Output $imageTemplate.ProvisioningErrorMessage
    Write-Output $imageTemplate.ProvisioningErrorCode
    throw "Image template provisioning failed"
    Exit 0xDEAD
}


Write-Output "Starting the image builder job"
Start-AzImageBuilderTemplate -InputObject $imageTemplate | Out-Null

$buildResults = Get-AzImageBuilderRunOutput -RunOutputName $templaterunOutputName `
                                            -ImageTemplateName $templateName `
                                            -ResourceGroupName $tmpRgName

Write-Output "Build status: $($buildResults.ProvisioningState)"

# If it failed, throw an error and exit
if($buildResults.ProvisioningState -ne "Succeeded") {
    throw "Error: Build job failed"
    Write-Output $buildResults | Select-Object *
    Exit 0xDEAD
}

If($buildResults.ArtifactId -match ".*/versions/(.*)") {
    $artifactID = $Matches[1]
    Write-Output "Build Version: $artifactID"
} else {
    throw "Unable to detect build version, this is probably not fatal but very suspect"
    Write-Output $buildResults | Select-Object *
}

# Clean up the temporary resource group and associated objects
Write-Output "Cleaning up the image template: $templateName"
Remove-AzImageBuilderTemplate -ImageTemplateName $templateName -ResourceGroupName $tmpRgName