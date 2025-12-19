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

# ================= GLOBAL VARIABLES =================
$global:baseUrl = "https://api.fabric.microsoft.com/v1"
$global:resourceUrl = "https://api.fabric.microsoft.com"
$global:fabricHeaders = @{}

$connection = $gitHubPATConnection

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
	
    Write-Host "Creating connection with Git provider credentials..."

    $connectionsUrl = "$global:baseUrl/connections"

    $connectionBody = $connection | ConvertTo-Json -Depth 10

    $response = Invoke-RestMethod -Headers $global:fabricHeaders -Uri $connectionsUrl -Method POST -Body $connectionBody

    Write-Host "Connection created successfully! Connection ID: $($response.id)" -ForegroundColor Green

} catch {
    $errorResponse = GetErrorResponse($_.Exception)
    Write-Host "Failed to create connection. . Error reponse: $errorResponse" -ForegroundColor Red
}