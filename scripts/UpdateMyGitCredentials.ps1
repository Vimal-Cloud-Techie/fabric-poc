param (
    [Parameter(Mandatory = $true)]
    [string]$workspaceName,

    [Parameter(Mandatory = $true)]
    [ValidateSet("UserPrincipal", "ManagedIdentity", "ServicePrincipal")]
    [string]$principalType,

    [Parameter(Mandatory = $true)]
    [string]$tenantId,

    [Parameter(Mandatory = $true)]
    [string]$subscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$connectionId,

    # Service Principal specific
    [string]$clientId,
    [string]$servicePrincipalSecret
)

# ================= GLOBAL VARIABLES =================
$global:baseUrl = "https://api.fabric.microsoft.com/v1"
$global:resourceUrl = "https://api.fabric.microsoft.com"
$global:fabricHeaders = @{}

$configuredConnectionGitCredentials = @{
    source = "ConfiguredConnection"
    connectionId = $connectionId
}

$myGitCredentials = $configuredConnectionGitCredentials

# ================= AUTH FUNCTIONS =================
function SetFabricHeaders {
    if ($principalType -eq "UserPrincipal") {
        $secureFabricToken = GetSecureTokenForUserPrincipal
    }
    elseif ($principalType -eq "ManagedIdentity") {
        $secureFabricToken = GetSecureTokenForManagedIdentity
    }
    elseif ($principalType -eq "ServicePrincipal") {
        $secureFabricToken = GetSecureTokenForServicePrincipal
    }
    else {
        throw "Invalid principal type."
    }

    $fabricToken = ConvertSecureStringToPlainText $secureFabricToken

    $global:fabricHeaders = @{
        'Content-Type'  = "application/json"
        'Authorization' = "Bearer $fabricToken"
    }
}

function GetSecureTokenForUserPrincipal {
    Connect-AzAccount -TenantId $tenantId -Subscription $subscriptionId | Out-Null
    return (Get-AzAccessToken -AsSecureString -ResourceUrl $global:resourceUrl).Token
}

function GetSecureTokenForManagedIdentity {
    Connect-AzAccount -Identity -TenantId $tenantId | Out-Null
    return (Get-AzAccessToken -AsSecureString -ResourceUrl $global:resourceUrl).Token
}

function GetSecureTokenForServicePrincipal {
    if (-not $clientId -or -not $servicePrincipalSecret) {
        throw "clientId and servicePrincipalSecret are required for ServicePrincipal authentication."
    }

    $secureSecret = ConvertTo-SecureString $servicePrincipalSecret -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential ($clientId, $secureSecret)

    Connect-AzAccount -ServicePrincipal -TenantId $tenantId -Credential $credential | Out-Null
    return (Get-AzAccessToken -AsSecureString -ResourceUrl $global:resourceUrl).Token
}

function ConvertSecureStringToPlainText($secureString) {
    $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureString)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

function GetWorkspaceByName($workspaceName) {
    # Get workspaces    
    $getWorkspacesUrl = "$global:baseUrl/workspaces"
    $workspaces = (Invoke-RestMethod -Headers $global:fabricHeaders -Uri $getWorkspacesUrl -Method GET).value

    # Try to find the workspace by display name
    $workspace = $workspaces | Where-Object {$_.DisplayName -eq $workspaceName}

    return $workspace
}

function GetErrorResponse($exception) {
    # Relevant only for PowerShell Core
    $errorResponse = $_.ErrorDetails.Message
 
    if(!$errorResponse) {
        # This is needed to support Windows PowerShell
        if (!$exception.Response) {
            return $exception.Message
        }
        $result = $exception.Response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($result)
        $reader.BaseStream.Position = 0
        $reader.DiscardBufferedData()
        $errorResponse = $reader.ReadToEnd();
    }
 
    return $errorResponse
}

try {
    SetFabricHeaders

    $workspace = GetWorkspaceByName $workspaceName 
    
    # Verify the existence of the requested workspace
	if(!$workspace) {
	  Write-Host "A workspace with the requested name was not found." -ForegroundColor Red
	  return
	}
	
    # Update Git Credentials
    Write-Host "Updating the Git credentials for the current user in the workspace '$workspaceName'."

    $updateMyGitCredentialsUrl = "$global:baseUrl/workspaces/$($workspace.Id)/git/myGitCredentials"

    $updateMyGitCredentialsBody = $myGitCredentials | ConvertTo-Json

    Invoke-RestMethod -Headers $global:fabricHeaders -Uri $updateMyGitCredentialsUrl -Method PATCH -Body $updateMyGitCredentialsBody

    Write-Host "The Git credentials has been successfully updated for the current user in the workspace '$workspaceName'." -ForegroundColor Green

} catch {
    $errorResponse = GetErrorResponse($_.Exception)
    Write-Host "Failed to update the Git credentials for the current user in the workspace '$workspaceName'. Error reponse: $errorResponse" -ForegroundColor Red
}