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
    [string]$key,

    [Parameter(Mandatory = $true)]
    [string]$displayName,

    # Service Principal specific
    [string]$clientId,
    [string]$servicePrincipalSecret
)

# Connection with personal access token for GitHubSourceControl
$gitHubPATConnection = @{
    connectivityType = "ShareableCloud"
    displayName = $displayName
    connectionDetails = @{
        type = "GitHubSourceControl"
        creationMethod = "GitHubSourceControl.Contents"
    }
    credentialDetails = @{
        credentials = @{
            credentialType = "Key"
            key = $key
        }
    }
}
$connection = $gitHubPATConnection

# ================= GLOBAL VARIABLES =================
$global:baseUrl = "https://api.fabric.microsoft.com/v1"
$global:resourceUrl = "https://api.fabric.microsoft.com"
$global:fabricHeaders = @{}

# ================ AUTH FUNCTIONS =================
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
    write-Host "Fabric headers set successfully $($global:fabricHeaders)." -ForegroundColor Green
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
    # $credential = New-Object System.Management.Automation.PSCredential ($clientId, $secureSecret)
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

# ================= ERROR RESPONSE HANDLING =================
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

# ================ SET HEADERS =================
SetFabricHeaders

# ================ GET WORKSPACE =================
function GetWorkspaceByName($workspaceName) {
    # Get workspaces    
    $getWorkspacesUrl = "$global:baseUrl/workspaces"
    $workspaces = (Invoke-RestMethod -Headers $global:fabricHeaders -Uri $getWorkspacesUrl -Method GET).value

    # Try to find the workspace by display name
    $workspace = $workspaces | Where-Object {$_.DisplayName -eq $workspaceName}

    return $workspace
}

# ================ STORE GIT PROVIDER CREDENTIALS =================
function storegitprovidercredentials {
    try {	
        Write-Host "Creating connection with Git provider credentials..."

        $connectionsUrl = "$global:baseUrl/connections"

        $connectionBody = $connection | ConvertTo-Json -Depth 10

        $response = Invoke-RestMethod -Headers $global:fabricHeaders -Uri $connectionsUrl -Method POST -Body $connectionBody

        Write-Host "Connection created successfully! Connection ID: $($response.id)" -ForegroundColor Green

    } catch {
        $errorResponse = GetErrorResponse($_.Exception)
        Write-Host "Failed to create connection. . Error reponse: $errorResponse" -ForegroundColor Red
        Write-Error $_
        exit 1
    }
    $connection=$response.id
    return $connection
}

$connectionId=storegitprovidercredentials $connection

$configuredConnectionGitCredentials = @{
    source = "ConfiguredConnection"
    connectionId = $connectionId
}

$myGitCredentials = $configuredConnectionGitCredentials

# ================ PREPARE GIT CREDENTIALS =================
function updategitcredential{
    try {
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

    }catch {
        $errorResponse = GetErrorResponse($_.Exception)
        Write-Host "Failed to update the Git credentials for the current user in the workspace '$workspaceName'. Error reponse: $errorResponse" -ForegroundColor Red
        Write-Error $_
        exit 1
    }
}
# ================ MAIN SCRIPT =================
try {
    updategitcredential

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
    Write-Error $_
    exit 1
}