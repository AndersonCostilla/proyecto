# Tests unitarios del nucleo de auth (PR-4). Sin Pester, runner propio.
# Archivo 100% ASCII a proposito: PS 5.1 rompe el parseo de archivos sin BOM
# que contienen no-ASCII.

function New-PwxAuthFakeHash {
    # Hash con formato valido (16 bytes de salt + 32 de clave en ceros) para
    # reglas de formato de config sin pagar la derivacion PBKDF2.
    return 'pbkdf2-sha256$120000$AAAAAAAAAAAAAAAAAAAAAA==$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
}

Run-PwxTest -Name 'auth: hash pbkdf2 roundtrip OK' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $hash = ConvertTo-PwxPasswordHash -Password 'clave-correcta-123'
    Assert-PwxNotNull $hash 'ConvertTo devuelve un hash'
    $algo = (@($hash -split '\$'))[0]
    Assert-PwxTrue ($algo -eq 'pbkdf2-sha256' -or $algo -eq 'pbkdf2-sha1') ("prefijo pbkdf2 admitido; obtuvo: " + $algo)
    Assert-PwxTrue (Test-PwxPasswordHashFormat -Hash $hash) 'formato del hash generado es valido'
    Assert-PwxTrue (Test-PwxPasswordHash -Password 'clave-correcta-123' -Hash $hash) 'roundtrip verifica la password correcta'
}

Run-PwxTest -Name 'auth: password incorrecta falla' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $hash = ConvertTo-PwxPasswordHash -Password 'la-que-si-es'
    Assert-PwxTrue (-not (Test-PwxPasswordHash -Password 'la-que-no-es' -Hash $hash)) 'password distinta no verifica'
    Assert-PwxTrue (-not (Test-PwxPasswordHash -Password 'la-que-si-es' -Hash ($hash + 'x'))) 'hash alterado no verifica'
}

Run-PwxTest -Name 'auth: formato basura se rechaza sin throw' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    Assert-PwxTrue (-not (Test-PwxPasswordHash -Password 'x' -Hash 'basura')) 'string basura rechazado'
    Assert-PwxTrue (-not (Test-PwxPasswordHash -Password 'x' -Hash '')) 'hash vacio rechazado'
    Assert-PwxTrue (-not (Test-PwxPasswordHash -Password 'x' -Hash 'md5$1$abc$def')) 'algoritmo no admitido rechazado'
    Assert-PwxTrue (-not (Test-PwxPasswordHash -Password 'x' -Hash 'pbkdf2-sha256$10$AAAAAAAAAAAAAAAAAAAAAA==$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=')) 'iteraciones < 1000 rechazadas'
    Assert-PwxTrue (-not (Test-PwxPasswordHash -Password 'x' -Hash 'pbkdf2-sha256$120000$AAAA$AAAA')) 'salt/hash que no son bytes validos rechazados'
    Assert-PwxTrue (-not (Test-PwxPasswordHashFormat -Hash 'pbkdf2-sha256$120000$AAAAAAAAAAAAAAAAAAAAAA==')) 'hash con menos de 4 partes rechazado'
}

Run-PwxTest -Name 'auth: Test-PwxWebAuthConfigValid reglas (schema/users/role/hash/ids)' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $fake = New-PwxAuthFakeHash

    # Config valida con enabled=true
    $cfgOk = @{
        schema_version = '1'
        auth           = @{
            enabled = $true
            users   = @(@{ id = 'admin'; role = 'admin'; passwordHash = $fake })
        }
    }
    $v = Test-PwxWebAuthConfigValid -Config $cfgOk
    Assert-PwxTrue $v.ok ('config valida deberia pasar; problems: ' + (@($v.problems) -join '; '))
    Assert-PwxEqual 0 @($v.problems).Count 'sin problemas'

    # schema distinto
    $cfgSchema = @{ schema_version = '2'; auth = $cfgOk.auth }
    $v = Test-PwxWebAuthConfigValid -Config $cfgSchema
    Assert-PwxTrue (-not $v.ok) 'schema_version=2 falla'
    Assert-PwxTrue ((@($v.problems) -join ' ') -like '*schema_version*') 'problema menciona schema_version'

    # schema numerico (no string) tambien falla
    $cfgSchemaNum = @{ schema_version = 1; auth = $cfgOk.auth }
    $v = Test-PwxWebAuthConfigValid -Config $cfgSchemaNum
    Assert-PwxTrue (-not $v.ok) 'schema_version numerico falla'

    # enabled=true con users vacios
    $cfgEmpty = @{ schema_version = '1'; auth = @{ enabled = $true; users = @() } }
    $v = Test-PwxWebAuthConfigValid -Config $cfgEmpty
    Assert-PwxTrue (-not $v.ok) 'users vacios con enabled falla'
    Assert-PwxTrue ((@($v.problems) -join ' ') -like '*users*') 'problema menciona users'

    # enabled=true sin users (propiedad ausente)
    $cfgNoUsers = @{ schema_version = '1'; auth = @{ enabled = $true } }
    $v = Test-PwxWebAuthConfigValid -Config $cfgNoUsers
    Assert-PwxTrue (-not $v.ok) 'users ausente con enabled falla'

    # role invalido
    $cfgRole = @{ schema_version = '1'; auth = @{ enabled = $true; users = @(@{ id = 'x'; role = 'superuser'; passwordHash = $fake }) } }
    $v = Test-PwxWebAuthConfigValid -Config $cfgRole
    Assert-PwxTrue (-not $v.ok) 'role invalido falla'
    Assert-PwxTrue ((@($v.problems) -join ' ') -like '*role*') 'problema menciona role'

    # passwordHash invalido
    $cfgHash = @{ schema_version = '1'; auth = @{ enabled = $true; users = @(@{ id = 'x'; role = 'admin'; passwordHash = 'REEMPLAZAR' }) } }
    $v = Test-PwxWebAuthConfigValid -Config $cfgHash
    Assert-PwxTrue (-not $v.ok) 'passwordHash invalido falla'
    Assert-PwxTrue ((@($v.problems) -join ' ') -like '*passwordHash*') 'problema menciona passwordHash'

    # ids duplicados
    $cfgDup = @{ schema_version = '1'; auth = @{ enabled = $true; users = @(
        @{ id = 'ana'; role = 'admin'; passwordHash = $fake },
        @{ id = 'ANA'; role = 'operator'; passwordHash = $fake }
    ) } }
    $v = Test-PwxWebAuthConfigValid -Config $cfgDup
    Assert-PwxTrue (-not $v.ok) 'ids duplicados fallan'
    Assert-PwxTrue ((@($v.problems) -join ' ') -like '*duplicado*') 'problema menciona duplicado'

    # enabled=false: sin users se acepta (solo schema + enabled)
    $cfgOff = @{ schema_version = '1'; auth = @{ enabled = $false } }
    $v = Test-PwxWebAuthConfigValid -Config $cfgOff
    Assert-PwxTrue $v.ok ('enabled=false sin users pasa; problems: ' + (@($v.problems) -join '; '))

    # enabled no booleano
    $cfgBool = @{ schema_version = '1'; auth = @{ enabled = 'yes' } }
    $v = Test-PwxWebAuthConfigValid -Config $cfgBool
    Assert-PwxTrue (-not $v.ok) 'enabled no booleano falla'

    # config ausente
    $v = Test-PwxWebAuthConfigValid -Config $null
    Assert-PwxTrue (-not $v.ok) 'config null falla'
    Assert-PwxTrue ((@($v.problems) -join ' ') -like '*ausente*') 'problema menciona ausente'
}

Run-PwxTest -Name 'auth: Get-PwxWebAuthConfig lee archivo via PWX_WEB_CONFIG_FILE' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $prev = $env:PWX_WEB_CONFIG_FILE
    try {
        $cfgPath = Join-Path $ws 'web-test.local.json'
        New-PwxDirectory -Path $ws | Out-Null
        $obj = @{
            schema_version = '1'
            auth           = @{
                enabled = $true
                users   = @(@{ id = 'admin'; role = 'admin'; passwordHash = (New-PwxAuthFakeHash) })
            }
        }
        $text = $obj | ConvertTo-Json -Depth 5
        [System.IO.File]::WriteAllText($cfgPath, $text, (New-Object System.Text.UTF8Encoding($false)))

        $env:PWX_WEB_CONFIG_FILE = $cfgPath
        $cfg = Get-PwxWebAuthConfig
        Assert-PwxNotNull $cfg 'Get-PwxWebAuthConfig lee el archivo indicado por la env'
        Assert-PwxEqual '1' ([string]$cfg.schema_version) 'schema_version leido'
        $v = Test-PwxWebAuthConfigValid -Config $cfg
        Assert-PwxTrue $v.ok ('archivo de ejemplo valido; problems: ' + (@($v.problems) -join '; '))

        Remove-Item -LiteralPath $cfgPath -Force
        $missing = Get-PwxWebAuthConfig
        Assert-PwxNull $missing 'archivo borrado => $null'
    }
    finally {
        $env:PWX_WEB_CONFIG_FILE = $prev
    }
}

Run-PwxTest -Name 'auth: sesiones crear/obtener/expirar/sweep/remove' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    Clear-PwxWebSessions | Out-Null

    $a = New-PwxWebSession -UserId 'op1' -Role 'operator' -TtlMinutes 60
    Assert-PwxTrue (-not [string]::IsNullOrEmpty([string]$a.token)) 'token presente'
    Assert-PwxTrue ($a.token.Length -ge 40) 'token con entropia suficiente (>= 40 chars)'
    $got = Get-PwxWebSession -Token $a.token
    Assert-PwxNotNull $got 'obtener sesion creada'
    Assert-PwxEqual 'op1' $got.user_id 'user_id correcto'
    Assert-PwxEqual 'operator' $got.role 'role correcto'

    $b = New-PwxWebSession -UserId 'op2' -Role 'admin' -TtlMinutes 0
    Assert-PwxTrue ($a.token -ne $b.token) 'tokens distintos'

    $removed = Invoke-PwxWebSessionSweep
    Assert-PwxTrue ($removed -ge 1) ('sweep elimino la expirada; obtuvo ' + $removed)
    Assert-PwxNull (Get-PwxWebSession -Token $b.token) 'sesion expirada ya no existe'
    Assert-PwxNotNull (Get-PwxWebSession -Token $a.token) 'la vigente sobrevive al sweep'

    Assert-PwxTrue (Remove-PwxWebSession -Token $a.token) 'remove devuelve true si existia'
    Assert-PwxNull (Get-PwxWebSession -Token $a.token) 'eliminada ya no se obtiene'
    Assert-PwxTrue (-not (Remove-PwxWebSession -Token $a.token)) 'remove devuelve false si no existia'
    Assert-PwxNull (Get-PwxWebSession -Token 'token-inexistente') 'token desconocido => $null'
    Clear-PwxWebSessions | Out-Null
}

Run-PwxTest -Name 'auth: decision rutas publicas, privada y orden 401' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $cfg = @{
        schema_version = '1'
        auth           = @{ enabled = $true; users = @(@{ id = 'admin'; role = 'admin'; passwordHash = (New-PwxAuthFakeHash) }) }
    }

    $d = Get-PwxWebAuthDecision -Path '/' -Method 'GET' -Headers @{} -Config $cfg
    Assert-PwxTrue $d.allowed 'GET / es publica'
    Assert-PwxEqual 200 $d.code 'code 200 en publica'
    Assert-PwxEqual 'PUBLIC' $d.reason 'reason PUBLIC'

    $d = Get-PwxWebAuthDecision -Path '/app.js' -Method 'GET' -Config $cfg
    Assert-PwxTrue $d.allowed 'GET /app.js es publica'
    $d = Get-PwxWebAuthDecision -Path '/styles.css' -Method 'GET' -Config $cfg
    Assert-PwxTrue $d.allowed 'GET /styles.css es publica'
    $d = Get-PwxWebAuthDecision -Path '/app.js?v=3' -Method 'get' -Config $cfg
    Assert-PwxTrue $d.allowed 'query string y minusculas no rompen la ruta publica'

    $d = Get-PwxWebAuthDecision -Path '/api/login' -Method 'POST' -Headers @{} -Config $cfg
    Assert-PwxTrue $d.allowed 'POST /api/login es publica (sin cookie)'

    $d = Get-PwxWebAuthDecision -Path '/api/jobs' -Method 'GET' -Headers @{} -Config $cfg
    Assert-PwxTrue (-not $d.allowed) 'GET privada sin cookie no pasa'
    Assert-PwxEqual 401 $d.code 'code 401'
    Assert-PwxEqual 'AUTH_REQUIRED' $d.reason 'reason AUTH_REQUIRED'

    $d = Get-PwxWebAuthDecision -Path '/api/jobs' -Method 'POST' -Headers @{} -Config $cfg
    Assert-PwxTrue (-not $d.allowed) 'mutacion sin sesion tampoco pasa'
    Assert-PwxEqual 401 $d.code 'la sesion se exige antes que el header CSRF (401 primero)'
    Assert-PwxEqual 'AUTH_REQUIRED' $d.reason 'reason AUTH_REQUIRED en mutacion sin sesion'

    $d = Get-PwxWebAuthDecision -Path '/APP.JS' -Method 'GET' -Config $cfg
    Assert-PwxTrue (-not $d.allowed) 'rutas publicas son case-sensitive'
}

Run-PwxTest -Name 'auth: decision CSRF, roles, DevMode y auth deshabilitado' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $cfg = @{
        schema_version = '1'
        auth           = @{ enabled = $true; users = @(@{ id = 'admin'; role = 'admin'; passwordHash = (New-PwxAuthFakeHash) }) }
    }
    $op = New-PwxWebSession -UserId 'op1' -Role 'operator' -TtlMinutes 60
    $ad = New-PwxWebSession -UserId 'root' -Role 'admin' -TtlMinutes 60
    $cookieOp = 'tema=uno; pwx_session=' + $op.token + '; otra=1'
    $cookieAd = 'pwx_session=' + $ad.token

    # Mutacion con sesion pero sin X-Pwx-Panel
    $d = Get-PwxWebAuthDecision -Path '/api/jobs' -Method 'POST' -Headers @{ Cookie = $cookieOp } -Config $cfg
    Assert-PwxTrue (-not $d.allowed) 'mutacion sin header CSRF no pasa'
    Assert-PwxEqual 403 $d.code 'code 403'
    Assert-PwxEqual 'CSRF_HEADER_MISSING' $d.reason 'reason CSRF_HEADER_MISSING'
    Assert-PwxEqual 'op1' $d.userId 'la decision expone el userId de la sesion'

    # Mutacion con sesion Y header correcto
    $d = Get-PwxWebAuthDecision -Path '/api/jobs' -Method 'POST' -Headers @{ Cookie = $cookieOp; 'X-Pwx-Panel' = '1' } -Config $cfg
    Assert-PwxTrue $d.allowed 'mutacion con sesion + header pasa'
    Assert-PwxEqual 'SESSION_OK' $d.reason 'reason SESSION_OK'

    # DELETE tambien es mutacion
    $d = Get-PwxWebAuthDecision -Path '/api/jobs/1' -Method 'DELETE' -Headers @{ Cookie = $cookieOp } -Config $cfg
    Assert-PwxEqual 'CSRF_HEADER_MISSING' $d.reason 'DELETE tambien exige el header'

    # /api/admin/* con rol operator => FORBIDDEN_ROLE
    $d = Get-PwxWebAuthDecision -Path '/api/admin/users' -Method 'GET' -Headers @{ Cookie = $cookieOp } -Config $cfg
    Assert-PwxTrue (-not $d.allowed) 'operator no entra a /api/admin/*'
    Assert-PwxEqual 403 $d.code 'code 403 en rol insuficiente'
    Assert-PwxEqual 'FORBIDDEN_ROLE' $d.reason 'reason FORBIDDEN_ROLE'

    # /api/admin/* con rol admin => pasa
    $d = Get-PwxWebAuthDecision -Path '/api/admin/users' -Method 'GET' -Headers @{ Cookie = $cookieAd } -Config $cfg
    Assert-PwxTrue $d.allowed 'admin si entra a /api/admin/*'
    Assert-PwxEqual 'SESSION_OK' $d.reason 'reason SESSION_OK con admin'

    # Cookie con comillas y minusculas en el nombre
    $d = Get-PwxWebAuthDecision -Path '/api/jobs' -Method 'GET' -Headers @{ Cookie = ('pwx_session="' + $op.token + '"') } -Config $cfg
    Assert-PwxTrue $d.allowed 'cookie pwx_session con comillas se interpreta'

    # DevMode abre todo aunque no haya sesion
    $d = Get-PwxWebAuthDecision -Path '/api/cualquier-cosa' -Method 'DELETE' -Headers @{} -Config $cfg -DevMode
    Assert-PwxTrue $d.allowed 'DevMode permite todo'
    Assert-PwxEqual 'DEV_MODE' $d.reason 'reason DEV_MODE'
    Assert-PwxEqual 'admin' $d.role 'DevMode con role admin'

    # auth.enabled=false => panel abierto
    $cfgOff = @{ schema_version = '1'; auth = @{ enabled = $false } }
    $d = Get-PwxWebAuthDecision -Path '/api/jobs' -Method 'POST' -Headers @{} -Config $cfgOff
    Assert-PwxTrue $d.allowed 'auth deshabilitado permite mutacion sin sesion'
    Assert-PwxEqual 'AUTH_DISABLED' $d.reason 'reason AUTH_DISABLED'
}
