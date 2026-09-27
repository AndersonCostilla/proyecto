# E2E de integracion de auth en el panel (PR-5).
# Patron: proceso propio por test (tests/fixtures/start-web-server.ps1),
# HTTP real en loopback y sesiones aisladas por proceso.
# Archivo 100% ASCII a proposito (PS 5.1 rompe no-ASCII sin BOM).

function Get-PwxWebTestFreePort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    $listener.Stop()
    return [int]$port
}

function Start-PwxWebTestServer {
    param(
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$Workspace,
        [Parameter(Mandatory)][string]$Tag,
        [switch]$DevMode
    )
    # Ejecutable del host actual: $PSHOME es mas robusto que Get-Process.Path
    # en Windows (y funciona igual en pwsh y Windows PowerShell 5.1).
    $exeName = 'pwsh'
    if ($PSVersionTable.PSEdition -ne 'Core') { $exeName = 'powershell' }
    if ($env:OS -eq 'Windows_NT') { $exeName = $exeName + '.exe' }
    $hostExe = Join-Path $PSHOME $exeName
    $fixture = Join-Path (Join-Path $global:PwxRoot 'tests') (Join-Path 'fixtures' 'start-web-server.ps1')
    $out = Join-Path $Workspace ('web-{0}.out.log' -f $Tag)
    $err = Join-Path $Workspace ('web-{0}.err.log' -f $Tag)
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $fixture, '-Port', [string]$Port)
    if ($DevMode) { $argList += '-DevMode' }
    $proc = Start-Process -FilePath $hostExe -ArgumentList $argList -PassThru -RedirectStandardOutput $out -RedirectStandardError $err -NoNewWindow
    return [pscustomobject]@{ Process = $proc; Out = $out; Err = $err; Port = $Port }
}

function Read-PwxWebTestServerLog {
    param([Parameter(Mandatory)]$Server)
    $out = ''
    $err = ''
    if (Test-Path -LiteralPath $Server.Out) { $out = [System.IO.File]::ReadAllText($Server.Out) }
    if (Test-Path -LiteralPath $Server.Err) { $err = [System.IO.File]::ReadAllText($Server.Err) }
    return ($out + "`n" + $err)
}

function Wait-PwxWebTestPort {
    param([Parameter(Mandatory)]$Server, [int]$TimeoutSec = 60)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ($Server.Process.HasExited) {
            throw ('El servidor termino antes de escuchar (exit {0}). Log: {1}' -f $Server.Process.ExitCode, (Read-PwxWebTestServerLog -Server $Server))
        }
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $client.Connect([System.Net.IPAddress]::Loopback, $Server.Port)
            $client.Close()
            return
        }
        catch {
            Start-Sleep -Milliseconds 150
        }
        finally {
            $client.Dispose()
        }
    }
    throw ('Timeout esperando el puerto {0}. Log: {1}' -f $Server.Port, (Read-PwxWebTestServerLog -Server $Server))
}

function Wait-PwxWebTestExit {
    param([Parameter(Mandatory)]$Server, [int]$TimeoutSec = 60)
    if (-not $Server.Process.WaitForExit($TimeoutSec * 1000)) {
        throw ('El servidor no salio en {0}s (se esperaba deny-start). Log: {1}' -f $TimeoutSec, (Read-PwxWebTestServerLog -Server $Server))
    }
}

function Stop-PwxWebTestServer {
    param($Server)
    try {
        if ($null -ne $Server -and $null -ne $Server.Process -and -not $Server.Process.HasExited) {
            $Server.Process.Kill()
            $Server.Process.WaitForExit(5000) | Out-Null
        }
    }
    catch {
        # Mejor esfuerzo: el proceso puede haber salido solo.
    }
}

function Invoke-PwxWebTestHttp {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [string]$Method = 'GET',
        [string]$Body = $null,
        [string]$Cookie = $null,
        [hashtable]$Headers = $null
    )
    $req = [System.Net.HttpWebRequest]::Create($Uri)
    $req.Method = $Method
    $req.Timeout = 20000
    $req.ReadWriteTimeout = 20000
    # Sin proxy: las pruebas van directo a loopback (en Windows el proxy del
    # sistema podria interferir con 127.0.0.1).
    $req.Proxy = $null
    if (-not [string]::IsNullOrEmpty($Cookie)) {
        # CookieContainer es la via documentada; si un runtime la rechaza
        # (cookies sobre IP), se cae a la cabecera cruda.
        try {
            $cc = New-Object System.Net.CookieContainer
            $cc.SetCookies([System.Uri]$Uri, $Cookie)
            $req.CookieContainer = $cc
        }
        catch {
            $req.Headers['Cookie'] = $Cookie
        }
    }
    if ($null -ne $Headers) {
        foreach ($key in $Headers.Keys) {
            $req.Headers[$key] = [string]$Headers[$key]
        }
    }
    if (-not [string]::IsNullOrEmpty($Body)) {
        $req.ContentType = 'application/json; charset=utf-8'
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $req.ContentLength = $bytes.Length
        $stream = $req.GetRequestStream()
        try {
            $stream.Write($bytes, 0, $bytes.Length)
        }
        finally {
            $stream.Close()
        }
    }
    elseif ($Method -eq 'POST' -or $Method -eq 'PUT' -or $Method -eq 'PATCH' -or $Method -eq 'DELETE') {
        $req.ContentLength = 0
    }
    $resp = $null
    try {
        $resp = $req.GetResponse()
    }
    catch [System.Net.WebException] {
        if ($null -ne $_.Exception.Response) {
            $resp = $_.Exception.Response
        }
        else {
            throw
        }
    }
    $status = [int]$resp.StatusCode
    $text = ''
    $responseStream = $resp.GetResponseStream()
    if ($null -ne $responseStream) {
        $reader = New-Object System.IO.StreamReader($responseStream, [System.Text.Encoding]::UTF8)
        try {
            $text = $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }
    }
    $setCookie = [string]$resp.Headers['Set-Cookie']
    $authHeader = [string]$resp.Headers['X-Pwx-Auth']
    $resp.Close()
    return [pscustomobject]@{
        status     = $status
        text       = $text
        setCookie  = $setCookie
        authHeader = $authHeader
    }
}

function Write-PwxWebTestConfig {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Json
    )
    [System.IO.File]::WriteAllText($Path, $Json, (New-Object System.Text.UTF8Encoding($false)))
}

Run-PwxTest -Name 'web auth: deny-start sin config web local (sin -Dev)' -File 'e2e' -Body {
    $ws = New-PwxTestWorkspace
    New-PwxDirectory -Path $ws | Out-Null
    $env:PWX_WORKSPACE = $ws
    $prevCfg = $env:PWX_WEB_CONFIG_FILE
    Invoke-PwxBootstrap
    $server = $null
    try {
        # Regla del test: sin config (env no seteada y web.local.json ausente).
        $env:PWX_WEB_CONFIG_FILE = $null
        $localCfg = Join-Path (Join-Path $global:PwxRoot 'config') 'web.local.json'
        Assert-PwxTrue (-not (Test-Path -LiteralPath $localCfg)) 'config/web.local.json no debe existir para este test (es gitignored)'

        $server = Start-PwxWebTestServer -Port (Get-PwxWebTestFreePort) -Workspace $ws -Tag 'deny'
        Wait-PwxWebTestExit -Server $server -TimeoutSec 60

        Assert-PwxTrue $server.Process.HasExited 'el servidor debe haber salido (deny-start)'
        $log = Read-PwxWebTestServerLog -Server $server
        Assert-PwxTrue ($log -like '*AUTH_NOT_CONFIGURED*') ('el mensaje debe contener AUTH_NOT_CONFIGURED; log: ' + $log)
        Assert-PwxTrue ($log -like '*web.local.json*') ('el mensaje debe ser accionable (menciona web.local.json); log: ' + $log)
        Assert-PwxTrue ($log -like '*web:hash*') ('el mensaje debe mencionar web:hash; log: ' + $log)
    }
    finally {
        $env:PWX_WEB_CONFIG_FILE = $prevCfg
        Stop-PwxWebTestServer -Server $server
    }
}

Run-PwxTest -Name 'web auth: -Dev arranca sin config y responde dev-mode' -File 'e2e' -Body {
    $ws = New-PwxTestWorkspace
    New-PwxDirectory -Path $ws | Out-Null
    $env:PWX_WORKSPACE = $ws
    $prevCfg = $env:PWX_WEB_CONFIG_FILE
    Invoke-PwxBootstrap
    $server = $null
    try {
        $env:PWX_WEB_CONFIG_FILE = $null
        $server = Start-PwxWebTestServer -Port (Get-PwxWebTestFreePort) -Workspace $ws -Tag 'dev' -DevMode
        Wait-PwxWebTestPort -Server $server

        $uri = 'http://127.0.0.1:{0}/api/session' -f $server.Port
        $r = Invoke-PwxWebTestHttp -Uri $uri
        Assert-PwxEqual 200 $r.status 'GET /api/session sin cookie en -Dev => 200'
        Assert-PwxEqual 'dev-mode' $r.authHeader 'header X-Pwx-Auth: dev-mode'
        $body = $r.text | ConvertFrom-Json
        Assert-PwxTrue $body.ok 'body.ok true'
        Assert-PwxTrue $body.devMode 'devMode true'
        Assert-PwxEqual 'admin' ([string]$body.user.role) 'rol dev admin'

        $log = Read-PwxWebTestServerLog -Server $server
        Assert-PwxTrue ($log -like '*AVISO*') ('el arranque en -Dev debe avisar en consola; log: ' + $log)
    }
    finally {
        $env:PWX_WEB_CONFIG_FILE = $prevCfg
        Stop-PwxWebTestServer -Server $server
    }
}

Run-PwxTest -Name 'web auth: login con cookie y whoami /api/session' -File 'e2e' -Body {
    $ws = New-PwxTestWorkspace
    New-PwxDirectory -Path $ws | Out-Null
    $env:PWX_WORKSPACE = $ws
    $prevCfg = $env:PWX_WEB_CONFIG_FILE
    Invoke-PwxBootstrap
    $server = $null
    try {
        $adminHash = ConvertTo-PwxPasswordHash -Password 'admin-pw-1'
        $cfgJson = @"
{
  "schema_version": "1",
  "auth": {
    "enabled": true,
    "users": [
      { "id": "admin", "role": "admin", "passwordHash": "$adminHash" }
    ]
  }
}
"@
        $cfgPath = Join-Path $ws 'web-test.local.json'
        Write-PwxWebTestConfig -Path $cfgPath -Json $cfgJson
        $env:PWX_WEB_CONFIG_FILE = $cfgPath

        $server = Start-PwxWebTestServer -Port (Get-PwxWebTestFreePort) -Workspace $ws -Tag 'login'
        Wait-PwxWebTestPort -Server $server
        $base = 'http://127.0.0.1:{0}' -f $server.Port

        $loginBody = @{ user = 'admin'; password = 'admin-pw-1' } | ConvertTo-Json
        $r = Invoke-PwxWebTestHttp -Uri ($base + '/api/login') -Method 'POST' -Body $loginBody
        Assert-PwxEqual 200 $r.status 'login correcto => 200'
        $body = $r.text | ConvertFrom-Json
        Assert-PwxTrue $body.ok 'login ok true'
        Assert-PwxEqual 'admin' ([string]$body.user.id) 'user.id admin'
        Assert-PwxEqual 'admin' ([string]$body.user.role) 'user.role admin'
        Assert-PwxTrue (-not [string]::IsNullOrEmpty([string]$body.user.expires_at_utc)) 'expires_at_utc presente'
        Assert-PwxTrue ($r.setCookie -like '*pwx_session=*') ('Set-Cookie con pwx_session; obtuvo: ' + $r.setCookie)
        Assert-PwxTrue ($r.setCookie -like '*HttpOnly*') ('Set-Cookie con HttpOnly; obtuvo: ' + $r.setCookie)
        Assert-PwxTrue ($r.setCookie -like '*SameSite=Strict*') ('Set-Cookie con SameSite=Strict; obtuvo: ' + $r.setCookie)

        $m = [regex]::Match($r.setCookie, 'pwx_session=([^;]+)')
        Assert-PwxTrue $m.Success 'token extraido del Set-Cookie'
        $token = $m.Groups[1].Value

        $r2 = Invoke-PwxWebTestHttp -Uri ($base + '/api/session') -Cookie ('pwx_session=' + $token)
        Assert-PwxEqual 200 $r2.status 'GET /api/session con cookie => 200'
        $body2 = $r2.text | ConvertFrom-Json
        Assert-PwxTrue $body2.ok 'session ok true'
        Assert-PwxEqual 'admin' ([string]$body2.user.role) 'rol admin en whoami'
        Assert-PwxTrue (-not $body2.devMode) 'devMode false en modo normal'

        $badBody = @{ user = 'admin'; password = 'mala' } | ConvertTo-Json
        $r3 = Invoke-PwxWebTestHttp -Uri ($base + '/api/login') -Method 'POST' -Body $badBody
        Assert-PwxEqual 401 $r3.status 'password mala => 401'
        $body3 = $r3.text | ConvertFrom-Json
        Assert-PwxEqual 'INVALID_CREDENTIALS' ([string]$body3.error.reason) 'reason INVALID_CREDENTIALS generico'
    }
    finally {
        $env:PWX_WEB_CONFIG_FILE = $prevCfg
        Stop-PwxWebTestServer -Server $server
    }
}

Run-PwxTest -Name 'web auth: logout exige X-Pwx-Panel y borra la sesion' -File 'e2e' -Body {
    $ws = New-PwxTestWorkspace
    New-PwxDirectory -Path $ws | Out-Null
    $env:PWX_WORKSPACE = $ws
    $prevCfg = $env:PWX_WEB_CONFIG_FILE
    Invoke-PwxBootstrap
    $server = $null
    try {
        $adminHash = ConvertTo-PwxPasswordHash -Password 'admin-pw-1'
        $cfgJson = @"
{
  "schema_version": "1",
  "auth": {
    "enabled": true,
    "users": [
      { "id": "admin", "role": "admin", "passwordHash": "$adminHash" }
    ]
  }
}
"@
        $cfgPath = Join-Path $ws 'web-test.local.json'
        Write-PwxWebTestConfig -Path $cfgPath -Json $cfgJson
        $env:PWX_WEB_CONFIG_FILE = $cfgPath

        $server = Start-PwxWebTestServer -Port (Get-PwxWebTestFreePort) -Workspace $ws -Tag 'csrf'
        Wait-PwxWebTestPort -Server $server
        $base = 'http://127.0.0.1:{0}' -f $server.Port

        $loginBody = @{ user = 'admin'; password = 'admin-pw-1' } | ConvertTo-Json
        $r = Invoke-PwxWebTestHttp -Uri ($base + '/api/login') -Method 'POST' -Body $loginBody
        Assert-PwxEqual 200 $r.status 'login para obtener cookie'
        $m = [regex]::Match($r.setCookie, 'pwx_session=([^;]+)')
        Assert-PwxTrue $m.Success 'token extraido'
        $token = $m.Groups[1].Value
        $cookie = 'pwx_session=' + $token

        $r2 = Invoke-PwxWebTestHttp -Uri ($base + '/api/logout') -Method 'POST' -Cookie $cookie
        Assert-PwxEqual 403 $r2.status 'logout sin header => 403'
        $body2 = $r2.text | ConvertFrom-Json
        Assert-PwxEqual 'CSRF_HEADER_MISSING' ([string]$body2.error.reason) 'reason CSRF_HEADER_MISSING'
        Assert-PwxEqual 403 ([int]$body2.error.code) 'code 403 en el body'

        $r3 = Invoke-PwxWebTestHttp -Uri ($base + '/api/logout') -Method 'POST' -Cookie $cookie -Headers @{ 'X-Pwx-Panel' = '1' }
        Assert-PwxEqual 200 $r3.status 'logout con header => 200'
        $body3 = $r3.text | ConvertFrom-Json
        Assert-PwxTrue $body3.ok 'logout ok true'
        Assert-PwxTrue ($r3.setCookie -like '*pwx_session=;*') ('Set-Cookie de borrado; obtuvo: ' + $r3.setCookie)
        Assert-PwxTrue ($r3.setCookie -like '*Max-Age=0*') ('Set-Cookie Max-Age=0; obtuvo: ' + $r3.setCookie)

        $r4 = Invoke-PwxWebTestHttp -Uri ($base + '/api/session') -Cookie $cookie
        Assert-PwxEqual 401 $r4.status 'la sesion ya no valida despues del logout'
        $body4 = $r4.text | ConvertFrom-Json
        Assert-PwxEqual 'AUTH_REQUIRED' ([string]$body4.error.reason) 'reason AUTH_REQUIRED tras logout'
    }
    finally {
        $env:PWX_WEB_CONFIG_FILE = $prevCfg
        Stop-PwxWebTestServer -Server $server
    }
}

Run-PwxTest -Name 'web auth: roles bloquean /api/admin/* por middleware' -File 'e2e' -Body {
    $ws = New-PwxTestWorkspace
    New-PwxDirectory -Path $ws | Out-Null
    $env:PWX_WORKSPACE = $ws
    $prevCfg = $env:PWX_WEB_CONFIG_FILE
    Invoke-PwxBootstrap
    $server = $null
    try {
        $adminHash = ConvertTo-PwxPasswordHash -Password 'admin-pw-1'
        $opHash = ConvertTo-PwxPasswordHash -Password 'op-pw-2'
        $cfgJson = @"
{
  "schema_version": "1",
  "auth": {
    "enabled": true,
    "users": [
      { "id": "admin", "role": "admin", "passwordHash": "$adminHash" },
      { "id": "operador", "role": "operator", "passwordHash": "$opHash" }
    ]
  }
}
"@
        $cfgPath = Join-Path $ws 'web-test.local.json'
        Write-PwxWebTestConfig -Path $cfgPath -Json $cfgJson
        $env:PWX_WEB_CONFIG_FILE = $cfgPath

        $server = Start-PwxWebTestServer -Port (Get-PwxWebTestFreePort) -Workspace $ws -Tag 'roles'
        Wait-PwxWebTestPort -Server $server
        $base = 'http://127.0.0.1:{0}' -f $server.Port

        $opLogin = @{ user = 'operador'; password = 'op-pw-2' } | ConvertTo-Json
        $r1 = Invoke-PwxWebTestHttp -Uri ($base + '/api/login') -Method 'POST' -Body $opLogin
        Assert-PwxEqual 200 $r1.status 'login operador'
        $opToken = [regex]::Match($r1.setCookie, 'pwx_session=([^;]+)').Groups[1].Value

        $r2 = Invoke-PwxWebTestHttp -Uri ($base + '/api/admin/whatever') -Cookie ('pwx_session=' + $opToken)
        Assert-PwxEqual 403 $r2.status 'operator en /api/admin/* => 403 (antes de routear)'
        $body2 = $r2.text | ConvertFrom-Json
        Assert-PwxEqual 'FORBIDDEN_ROLE' ([string]$body2.error.reason) 'reason FORBIDDEN_ROLE'
        Assert-PwxEqual 403 ([int]$body2.error.code) 'code 403 en el body'

        $adminLogin = @{ user = 'admin'; password = 'admin-pw-1' } | ConvertTo-Json
        $r3 = Invoke-PwxWebTestHttp -Uri ($base + '/api/login') -Method 'POST' -Body $adminLogin
        Assert-PwxEqual 200 $r3.status 'login admin'
        $adminToken = [regex]::Match($r3.setCookie, 'pwx_session=([^;]+)').Groups[1].Value

        $r4 = Invoke-PwxWebTestHttp -Uri ($base + '/api/admin/whatever') -Cookie ('pwx_session=' + $adminToken)
        Assert-PwxTrue ($r4.status -ne 403) ('admin no debe recibir 403; obtuvo ' + $r4.status)
        Assert-PwxEqual 404 $r4.status 'la ruta admin no existe => 404 del router'
    }
    finally {
        $env:PWX_WEB_CONFIG_FILE = $prevCfg
        Stop-PwxWebTestServer -Server $server
    }
}
