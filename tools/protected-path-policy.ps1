Set-StrictMode -Version Latest

function Get-ProtectedPathReason {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [switch]$AllowDocumentationExamples
    )

    $normalized = $Path -replace "\\", "/"
    $leaf = Split-Path -Leaf $normalized

    if (($leaf -match '(?i)^\.env(\..+)?$') -and ($leaf -notmatch '(?i)^\.env\.example$')) {
        return "env file"
    }

    if ($normalized -match '(?i)(^|/)(id_rsa|id_dsa|id_ecdsa|id_ed25519)(?![.]pub(?:$|/))(\.|$)') {
        return "SSH private key"
    }

    if ($leaf -match '(?i)\.(pem|p12|pfx|key|keystore|jks|asc|ppk|pgpass)$') {
        return "key/certificate file"
    }

    if ($leaf -match '(?i)(^|[._-])(secret|secrets|credential|credentials)([._-]|$)') {
        if ($AllowDocumentationExamples -and
            $leaf -match '(?i)[.](md|txt|example|sample|template|rst|adoc)$') {
            return $null
        }
        return "credential-looking name"
    }

    return $null
}
