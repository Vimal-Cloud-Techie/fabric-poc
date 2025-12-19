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

    # Service Principal specific
    [string]$clientId,
    [string]$servicePrincipalSecret
)

# ================= GLOBAL VARIABLES =================
$global:baseUrl = "https://api.fabric.microsoft.com/v1"
$global:resourceUrl = "https://api.fabric.microsoft.com"
$global:fabricHeaders = @{}

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

# ================= FABRIC FUNCTIONS =================
function GetWorkspaceByName($workspaceName) {
    $url = "$global:baseUrl/workspaces"
    $workspaces = (Invoke-RestMethod -Headers $global:fabricHeaders -Uri $url -Method GET).value
    return $workspaces | Where-Object { $_.DisplayName -eq $workspaceName }
}

# ================= MAIN =================
try {
    SetFabricHeaders

    $workspace = GetWorkspaceByName $workspaceName 
    
    # Verify the existence of the requested workspace
	if(!$workspace) {
	  Write-Host "A workspace with the requested name was not found." -ForegroundColor Red
	  return
	}
	
    # Get Status
    Write-Host "Calling GET Status REST API to construct the request body for UpdateFromGit REST API."

    $gitStatusUrl = "$global:baseUrl/workspaces/$($workspace.Id)/git/status"
    $gitStatusResponse = Invoke-RestMethod -Headers $global:fabricHeaders -Uri $gitStatusUrl -Method GET

    # Update from Git
    Write-Host "Updating the workspace '$workspaceName' from Git."

    $updateFromGitUrl = "$global:baseUrl/workspaces/$($workspace.Id)/git/updateFromGit"

    $updateFromGitBody = @{ 
        remoteCommitHash = $gitStatusResponse.RemoteCommitHash
		workspaceHead = $gitStatusResponse.WorkspaceHead
        options = @{
            # Allows overwriting existing items if needed
            allowOverrideItems = $TRUE
        }
    } | ConvertTo-Json

    $updateFromGitResponse = Invoke-WebRequest -Headers $global:fabricHeaders -Uri $updateFromGitUrl -Method POST -Body $updateFromGitBody

    $operationId = $updateFromGitResponse.Headers['x-ms-operation-id']
    $retryAfter = $updateFromGitResponse.Headers['Retry-After']
    Write-Host "Long Running Operation ID: '$operationId' has been scheduled for updating the workspace '$workspaceName' from Git with a retry-after time of '$retryAfter' seconds." -ForegroundColor Green

} catch {
    $errorResponse = GetErrorResponse($_.Exception)
    Write-Host "Failed to update the workspace '$workspaceName' from Git. Error reponse: $errorResponse" -ForegroundColor Red
}