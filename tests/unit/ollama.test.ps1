try {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
public class FakePwxWebResponse : WebResponse
{
    public HttpStatusCode StatusCode { get; set; }
    public override long ContentLength { get { return 0; } set { } }
    public override string ContentType { get { return "application/json"; } set { } }
    public override Uri ResponseUri { get { return new Uri("http://127.0.0.1/"); } }
    public override Stream GetResponseStream() { return new MemoryStream(new byte[0]); }
}
'@
}
catch { }

function Reset-PwxRestQueue {
    param([object[]]$Items)
    $global:PwxRestQueue = New-Object System.Collections.ArrayList
    foreach ($it in $Items) { [void]$global:PwxRestQueue.Add($it) }
    $global:PwxRestQueueIndex = 0
}

function Invoke-RestMethod {
    param($Uri, [string]$Method = 'Get', $ContentType, $Body, [int]$TimeoutSec = 100)
    $idx = $global:PwxRestQueueIndex
    $global:PwxRestQueueIndex++
    $item = $global:PwxRestQueue[$idx]
    if ($null -eq $item) { $item = [pscustomobject]@{ kind = 'refused' } }
    switch ($item.kind) {
        'ok' {
            return ($item.body | ConvertFrom-Json)
        }
        'timeout' {
            throw (New-Object System.Net.WebException('The operation has timed out.'))
        }
        'refused' {
            throw (New-Object System.Net.WebException('Unable to connect to the remote server'))
        }
        default {
            $fr = New-Object FakePwxWebResponse
            if ($item.status -ne '') { $fr.StatusCode = [System.Net.HttpStatusCode]$item.status }
            throw (New-Object System.Net.WebException(
                ('HTTP status ' + $item.status), $null, [System.Net.WebExceptionStatus]::ProtocolError, $fr))
        }
    }
}

function Set-PwxOllamaEnv {
    param([string]$Url = 'http://127.0.0.1:0', [int]$RequestTimeout = 5, [int]$ConnectTimeout = 2)
    $env:PWX_OLLAMA_URL = $Url
    $env:PWX_MODEL = 'qwen3:8b'
    $env:PWX_OLLAMA_REQUEST_TIMEOUT = [string]$RequestTimeout
    $env:PWX_OLLAMA_CONNECT_TIMEOUT = [string]$ConnectTimeout
}

Run-PwxTest -Name 'D7: chat 200 valido devuelve contenido' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    Reset-PwxRestQueue -Items @(
        @{ kind = 'ok'; body = '{"models":[{"name":"qwen3:8b"}]}' },
        @{ kind = 'ok'; body = '{"message":{"content":"{\"hola\":1}"}}' }
    )
    Set-PwxOllamaEnv
    $res = Invoke-PwxOllamaChat -Prompt 'hola'
    Assert-PwxTrue $res.ok
    Assert-PwxEqual 'OK' $res.code
    Assert-PwxEqual '{"hola":1}' $res.content
}

Run-PwxTest -Name 'D7: 404 -> MODEL_NOT_FOUND' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    Reset-PwxRestQueue -Items @(
        @{ kind = 'ok'; body = '{"models":[{"name":"qwen3:8b"}]}' },
        @{ kind = 'status'; status = '404' }
    )
    Set-PwxOllamaEnv
    $res = Invoke-PwxOllamaChat -Prompt 'x'
    Assert-PwxTrue (-not $res.ok)
    Assert-PwxEqual 'MODEL_NOT_FOUND' $res.code
}

Run-PwxTest -Name 'D7: 400 -> MODEL_ERROR' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    Reset-PwxRestQueue -Items @(
        @{ kind = 'ok'; body = '{"models":[{"name":"qwen3:8b"}]}' },
        @{ kind = 'status'; status = '400' }
    )
    Set-PwxOllamaEnv
    $res = Invoke-PwxOllamaChat -Prompt 'x'
    Assert-PwxTrue (-not $res.ok)
    Assert-PwxEqual 'MODEL_ERROR' $res.code
}

Run-PwxTest -Name 'D7: 503 -> MODEL_ERROR' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    Reset-PwxRestQueue -Items @(
        @{ kind = 'ok'; body = '{"models":[{"name":"qwen3:8b"}]}' },
        @{ kind = 'status'; status = '503' }
    )
    Set-PwxOllamaEnv
    $res = Invoke-PwxOllamaChat -Prompt 'x'
    Assert-PwxTrue (-not $res.ok)
    Assert-PwxEqual 'MODEL_ERROR' $res.code
}

Run-PwxTest -Name 'D7: timeout -> MODEL_TIMEOUT' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    Reset-PwxRestQueue -Items @(
        @{ kind = 'ok'; body = '{"models":[{"name":"qwen3:8b"}]}' },
        @{ kind = 'timeout' }
    )
    Set-PwxOllamaEnv
    $res = Invoke-PwxOllamaChat -Prompt 'x'
    Assert-PwxTrue (-not $res.ok)
    Assert-PwxEqual 'MODEL_TIMEOUT' $res.code
}

Run-PwxTest -Name 'D7: conexion rechazada -> OLLAMA_OFFLINE' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    Reset-PwxRestQueue -Items @(@{ kind = 'refused' })
    Set-PwxOllamaEnv
    $res = Invoke-PwxOllamaChat -Prompt 'x'
    Assert-PwxTrue (-not $res.ok)
    Assert-PwxEqual 'OLLAMA_OFFLINE' $res.code
}

Run-PwxTest -Name 'D7/T11: JSON invalido por canal real deja BLOCKED' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $client = New-PwxClient -Name 'Cliente LlmBad'
    $job = New-PwxJob -ClientId $client.id -Service 'simulate-service'
    Reset-PwxRestQueue -Items @(
        @{ kind = 'ok'; body = '{"models":[{"name":"qwen3:8b"}]}' },
        @{ kind = 'ok'; body = '{"message":{"content":"esto no es json"}}' }
    )
    Set-PwxOllamaEnv
    $res = Invoke-PwxRequirementsAgent -JobId $job.id -Request 'sim'
    Assert-PwxTrue (-not $res.ok)
    Assert-PwxEqual 'MODEL_INVALID_RESPONSE' $res.code
    Assert-PwxEqual 'BLOCKED' (Get-PwxJob -JobId $job.id).state
}

Remove-Item -Path 'function:Invoke-RestMethod' -ErrorAction SilentlyContinue
Remove-Item -Path 'function:Reset-PwxRestQueue' -ErrorAction SilentlyContinue
# This test is intentionally placed after the original mock helper cleanup so it
# uses a local mock and proves the JSON-format compatibility retry.
function Invoke-RestMethod {
    param($Uri, [string]$Method = 'Get', $ContentType, $Body, [int]$TimeoutSec = 100)
    $idx = $global:PwxRetryQueueIndex
    $global:PwxRetryQueueIndex++
    $item = $global:PwxRetryQueue[$idx]
    if ($item.kind -eq 'ok') { return ($item.body | ConvertFrom-Json) }
    $fr = New-Object FakePwxWebResponse
    $fr.StatusCode = [System.Net.HttpStatusCode]400
    throw (New-Object System.Net.WebException('HTTP status 400', $null, [System.Net.WebExceptionStatus]::ProtocolError, $fr))
}

Run-PwxTest -Name 'D7: format json HTTP 400 reintenta sin format y conserva validacion' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $global:PwxRetryQueue = @(
        @{ kind = 'ok'; body = '{"models":[{"name":"qwen3:8b"}]}' },
        @{ kind = 'status'; status = '400' },
        @{ kind = 'ok'; body = '{"message":{"content":"{\"service\":\"simulate-service\"}"}}' }
    )
    $global:PwxRetryQueueIndex = 0
    Set-PwxOllamaEnv
    $res = Invoke-PwxOllamaChat -Prompt 'devuelve json' -FormatJson $true
    Assert-PwxTrue $res.ok
    Assert-PwxTrue $res.format_fallback 'Debe reportar reintento de compatibilidad'
    Assert-PwxEqual '{"service":"simulate-service"}' $res.content
}

Remove-Item -Path 'function:Invoke-RestMethod' -ErrorAction SilentlyContinue
