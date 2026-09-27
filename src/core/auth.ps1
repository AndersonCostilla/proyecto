# Nucleo de autenticacion del panel web local (PR-4).
# Sin sockets y SIN integracion al server: hashing PBKDF2 de contrasenas,
# carga/validacion de config/web.local.json, sesiones en memoria y la
# decision "pure" que el middleware consumira en PR-5.
# Compatible: pwsh 7.x y Windows PowerShell 5.1. Sin dependencias nuevas.

# ---------------------------------------------------------------------------
# Password hashing (PBKDF2)
# ---------------------------------------------------------------------------

function Get-PwxPbkdf2Bytes {
    # Deriva una clave de 32 bytes con PBKDF2-HMAC.
    # 'sha256' usa Rfc2898DeriveBytes + HashAlgorithmName.SHA256 si el runtime
    # lo soporta; si no, devuelve $null para que el llamador caiga a 'sha1'.
    # 'sha1' intenta el constructor con HashAlgorithmName y, en ultima
    # instancia, el constructor clasico (HMAC-SHA1) que existe en todo runtime.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Password,
        [Parameter(Mandatory)][byte[]]$Salt,
        [Parameter(Mandatory)][int]$Iterations,
        [Parameter(Mandatory)][ValidateSet('sha256', 'sha1')][string]$Algorithm
    )
    if ($Algorithm -eq 'sha256') {
        $k = $null
        try {
            $k = [System.Security.Cryptography.Rfc2898DeriveBytes]::new($Password, $Salt, $Iterations, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
            return $k.GetBytes(32)
        }
        catch {
            # Runtime sin soporte PBKDF2-SHA256 (p. ej. .NET Framework antiguo).
            return $null
        }
        finally {
            if ($null -ne $k) { $k.Dispose() }
        }
    }
    $k = $null
    try {
        $k = [System.Security.Cryptography.Rfc2898DeriveBytes]::new($Password, $Salt, $Iterations, [System.Security.Cryptography.HashAlgorithmName]::SHA1)
        return $k.GetBytes(32)
    }
    catch {
        # Sin HashAlgorithmName: se intenta el constructor clasico abajo.
    }
    finally {
        if ($null -ne $k) { $k.Dispose() }
    }
    $k2 = $null
    try {
        $k2 = [System.Security.Cryptography.Rfc2898DeriveBytes]::new([System.Text.Encoding]::UTF8.GetBytes($Password), $Salt, $Iterations)
        return $k2.GetBytes(32)
    }
    finally {
        if ($null -ne $k2) { $k2.Dispose() }
    }
}

function Test-PwxByteSequenceEqual {
    # Comparacion sin salida temprana (best-effort constante en PowerShell:
    # el interpreter no es constante-time, pero evitamos early-exit por byte).
    [CmdletBinding()]
    param($A, $B)
    if ($null -eq $A -or $null -eq $B) { return $false }
    $lenA = $A.Length
    $lenB = $B.Length
    if ($lenA -ne $lenB) { return $false }
    $diff = 0
    for ($i = 0; $i -lt $lenA; $i++) {
        $diff = $diff -bor ([int]$A[$i] -bxor [int]$B[$i])
    }
    return ($diff -eq 0)
}

function ConvertTo-PwxPasswordHash {
    # Formato de salida: pbkdf2-sha256$<iters>$<saltB64>$<hashB64>
    #   - salt: 16 bytes aleatorios; clave: 32 bytes; password en UTF-8.
    #   - Si el runtime no soporta SHA256, sale pbkdf2-sha1$... (solo compat).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Password,
        [ValidateRange(1000, 10000000)][int]$Iterations = 120000
    )
    $salt = [byte[]]::new(16)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($salt)
    }
    finally {
        $rng.Dispose()
    }
    $algo = 'sha256'
    $key = Get-PwxPbkdf2Bytes -Password $Password -Salt $salt -Iterations $Iterations -Algorithm 'sha256'
    if ($null -eq $key) {
        $algo = 'sha1'
        $key = Get-PwxPbkdf2Bytes -Password $Password -Salt $salt -Iterations $Iterations -Algorithm 'sha1'
    }
    if ($null -eq $key) {
        throw 'PBKDF2 no disponible en este runtime (fallo SHA256 y SHA1).'
    }
    return ('pbkdf2-{0}${1}${2}${3}' -f $algo, $Iterations, [Convert]::ToBase64String($salt), [Convert]::ToBase64String($key))
}

function Test-PwxPasswordHashFormat {
    # Valida SOLO el formato de un hash (sin derivar clave): algoritmo admitido,
    # iteraciones 1000..10000000, salt de 16 bytes y hash de 32 bytes en Base64.
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Hash)
    if ([string]::IsNullOrEmpty($Hash)) { return $false }
    $parts = @($Hash -split '\$')
    if ($parts.Count -ne 4) { return $false }
    if ($parts[0] -cne 'pbkdf2-sha256' -and $parts[0] -cne 'pbkdf2-sha1') { return $false }
    $iters = 0
    if (-not [int]::TryParse($parts[1], [ref]$iters)) { return $false }
    if ($iters -lt 1000 -or $iters -gt 10000000) { return $false }
    $salt = $null
    $key = $null
    try { $salt = [Convert]::FromBase64String($parts[2]) } catch { return $false }
    try { $key = [Convert]::FromBase64String($parts[3]) } catch { return $false }
    if ($salt.Length -ne 16 -or $key.Length -ne 32) { return $false }
    return $true
}

function Test-PwxPasswordHash {
    # $false (sin throw) si el formato es invalido o el password no coincide.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Password,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Hash
    )
    if (-not (Test-PwxPasswordHashFormat -Hash $Hash)) { return $false }
    $parts = @($Hash -split '\$')
    $algo = 'sha1'
    if ($parts[0] -ceq 'pbkdf2-sha256') { $algo = 'sha256' }
    $iters = [int]$parts[1]
    $salt = [Convert]::FromBase64String($parts[2])
    $expect = [Convert]::FromBase64String($parts[3])
    $got = Get-PwxPbkdf2Bytes -Password $Password -Salt $salt -Iterations $iters -Algorithm $algo
    if ($null -eq $got) { return $false }
    return (Test-PwxByteSequenceEqual -A $expect -B $got)
}

# ---------------------------------------------------------------------------
# Carga y validacion de config del panel
# ---------------------------------------------------------------------------

function Get-PwxWebAuthConfig {
    # config/web.local.json (gitignored) o la ruta de PWX_WEB_CONFIG_FILE.
    # Archivo inexistente o vacio -> $null. JSON invalido -> throw (loud).
    [CmdletBinding()]
    param()
    $path = $env:PWX_WEB_CONFIG_FILE
    if ([string]::IsNullOrWhiteSpace($path)) {
        $path = Join-Path (Join-Path ([string]$global:PwxRoot) 'config') 'web.local.json'
    }
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return (Get-PwxJsonFile -Path $path)
}

function Test-PwxWebAuthConfigValid {
    # Reglas (no throw; retorna { ok, problems }):
    #   1) schema_version es exactamente "1" (string)
    #   2) auth.enabled es booleano
    #   3) si enabled: auth.users no vacio
    #   4) si enabled: cada user con id texto no vacio, role operator|admin y
    #      passwordHash con formato pbkdf2 valido
    #   5) si enabled: ids unicos (case-insensitive)
    # Con auth.enabled=false solo se validan 1 y 2 (panel abierto sin users).
    [CmdletBinding()]
    param($Config)
    $problems = @()
    try {
        if ($null -eq $Config) {
            $problems += 'config ausente: falta config/web.local.json (o la ruta de PWX_WEB_CONFIG_FILE)'
        }
        else {
            $sv = $Config.schema_version
            if (-not ($sv -is [string]) -or $sv -cne '1') {
                $problems += 'schema_version debe ser "1"'
            }
            $enabled = $Config.auth.enabled
            if ($enabled -isnot [bool]) {
                $problems += 'auth.enabled debe ser booleano'
            }
            elseif ($enabled) {
                $usersRaw = $Config.auth.users
                $users = @()
                if ($null -ne $usersRaw) { $users = @($usersRaw) }
                if ($users.Count -eq 0) {
                    $problems += 'auth.users debe tener al menos un usuario cuando auth.enabled es true'
                }
                else {
                    $seen = @{}
                    for ($i = 0; $i -lt $users.Count; $i++) {
                        $u = $users[$i]
                        $uid = $null
                        $role = $null
                        $hash = $null
                        if ($null -ne $u) {
                            $uid = $u.id
                            $role = $u.role
                            $hash = $u.passwordHash
                        }
                        if (-not ($uid -is [string]) -or [string]::IsNullOrWhiteSpace([string]$uid)) {
                            $problems += ('users[{0}].id debe ser texto no vacio' -f $i)
                        }
                        else {
                            $idKey = [string]$uid
                            if ($seen.ContainsKey($idKey)) {
                                $problems += ('users[{0}].id duplicado: {1}' -f $i, $idKey)
                            }
                            else {
                                $seen[$idKey] = $true
                            }
                        }
                        if ($role -notin @('operator', 'admin')) {
                            $problems += ('users[{0}].role invalido: {1} (esperado operator|admin)' -f $i, $role)
                        }
                        if (-not (Test-PwxPasswordHashFormat -Hash ([string]$hash))) {
                            $problems += ('users[{0}].passwordHash invalido (formato esperado pbkdf2-sha256$iters$salt$hash)' -f $i)
                        }
                    }
                }
            }
        }
    }
    catch {
        $problems += ('validacion fallida: {0}' -f $_.Exception.Message)
    }
    return [ordered]@{
        ok       = ($problems.Count -eq 0)
        problems = @($problems)
    }
}

# ---------------------------------------------------------------------------
# Sesiones en memoria (solo core; sin cookies ni sockets)
# ---------------------------------------------------------------------------

# Se inicializa al cargar el modulo (bootstrap). Nombre propio para no
# confundirlas con las sesiones del Asistente Word en web/server.ps1.
$script:PwxWebAuthSessions = @{}

function New-PwxWebSession {
    # Token aleatorio de 32 bytes (base64url). Las sesiones viven solo en
    # memoria: al reiniciar el proceso se pierden todas.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$UserId,
        [Parameter(Mandatory)][string]$Role,
        [double]$TtlMinutes = 120
    )
    if ([string]::IsNullOrWhiteSpace($UserId)) { throw 'UserId vacio.' }
    if ($Role -notin @('operator', 'admin')) {
        throw ('Role invalido: {0} (esperado operator|admin)' -f $Role)
    }
    if ($TtlMinutes -lt 0 -or $TtlMinutes -gt 10080) {
        throw ('TtlMinutes fuera de rango 0..10080: {0}' -f $TtlMinutes)
    }
    $bytes = [byte[]]::new(32)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    }
    finally {
        $rng.Dispose()
    }
    $token = ([Convert]::ToBase64String($bytes) -replace '\+', '-' -replace '/', '_' -replace '=', '')
    $now = [DateTime]::UtcNow
    $session = [ordered]@{
        token          = $token
        user_id        = $UserId
        role           = $Role
        created_at_utc = $now.ToString('o')
        expires_at_utc = $now.AddMinutes($TtlMinutes).ToString('o')
    }
    $script:PwxWebAuthSessions[$token] = $session
    return $session
}

function Get-PwxWebSession {
    # Devuelve la sesion vigente o $null (inexistente/expirada). Si esta
    # expirada, la elimina de paso (limpieza perezosa).
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Token)
    if ([string]::IsNullOrEmpty($Token)) { return $null }
    if (-not $script:PwxWebAuthSessions.ContainsKey($Token)) { return $null }
    $session = $script:PwxWebAuthSessions[$Token]
    $expires = [datetime]$session.expires_at_utc
    if ($expires -le [DateTime]::UtcNow) {
        $script:PwxWebAuthSessions.Remove($Token)
        return $null
    }
    return $session
}

function Remove-PwxWebSession {
    # $true si existia y se elimino; $false si no existia.
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Token)
    if ([string]::IsNullOrEmpty($Token)) { return $false }
    if ($script:PwxWebAuthSessions.ContainsKey($Token)) {
        $script:PwxWebAuthSessions.Remove($Token)
        return $true
    }
    return $false
}

function Invoke-PwxWebSessionSweep {
    # Elimina sesiones expiradas y devuelve cuantas quito.
    [CmdletBinding()]
    param()
    $now = [DateTime]::UtcNow
    $removed = 0
    foreach ($token in @($script:PwxWebAuthSessions.Keys)) {
        $session = $script:PwxWebAuthSessions[$token]
        $expires = [datetime]$session.expires_at_utc
        if ($expires -le $now) {
            $script:PwxWebAuthSessions.Remove($token)
            $removed++
        }
    }
    return $removed
}

function Clear-PwxWebSessions {
    # Solo para tests: vacia todas las sesiones y devuelve cuantas habia.
    [CmdletBinding()]
    param()
    $count = $script:PwxWebAuthSessions.Count
    $script:PwxWebAuthSessions.Clear()
    return $count
}

# ---------------------------------------------------------------------------
# Decision "pure" para el middleware (se integra en PR-5)
# ---------------------------------------------------------------------------

function Get-PwxHeaderRawValue {
    # Lee un header sin importar mayusculas; acepta hashtable o PSCustomObject.
    [CmdletBinding()]
    param($Headers, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Headers) { return $null }
    if ($Headers -is [System.Collections.IDictionary]) {
        foreach ($key in @($Headers.Keys)) {
            if ([string]$key -ieq $Name) { return [string]$Headers[$key] }
        }
        return $null
    }
    foreach ($prop in $Headers.PSObject.Properties) {
        if ($prop.Name -ieq $Name) { return [string]$prop.Value }
    }
    return $null
}

function New-PwxWebAuthResult {
    # Objeto uniforme de decision: { allowed, code, userId, role, reason }.
    [CmdletBinding()]
    param([bool]$Allowed, [int]$Code, $UserId, $Role, [string]$Reason)
    return [ordered]@{
        allowed = $Allowed
        code    = $Code
        userId  = $UserId
        role    = $Role
        reason  = $Reason
    }
}

function Get-PwxWebAuthDecision {
    # Funcion pura (sin efectos salvo la lectura/limpieza de sesiones):
    #   -DevMode            -> todo permitido (reason DEV_MODE, role admin)
    #   -Config auth.enabled=false -> todo permitido (reason AUTH_DISABLED)
    #   publicas: GET|HEAD /, /app.js, /styles.css y POST /api/login (reason PUBLIC)
    #   el resto requiere cookie pwx_session valida -> 401 AUTH_REQUIRED
    #   mutaciones POST/PUT/PATCH/DELETE exigen header X-Pwx-Panel: 1
    #       -> 403 CSRF_HEADER_MISSING
    #   /api/admin/* exige rol admin (el server lo aplicara en PR-5)
    #       -> 403 FORBIDDEN_ROLE
    #   permitido -> 200 con PUBLIC | DEV_MODE | AUTH_DISABLED | SESSION_OK
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Method,
        $Headers,
        $Config,
        [switch]$DevMode
    )
    $method = ([string]$Method).ToUpperInvariant()
    $path = [string]$Path
    $q = $path.IndexOf([char]'?')
    if ($q -ge 0) { $path = $path.Substring(0, $q) }
    if ($path -eq '') { $path = '/' }

    if ($DevMode) {
        return New-PwxWebAuthResult -Allowed $true -Code 200 -UserId 'dev' -Role 'admin' -Reason 'DEV_MODE'
    }

    if ($null -ne $Config -and ($Config.auth.enabled -is [bool]) -and -not $Config.auth.enabled) {
        return New-PwxWebAuthResult -Allowed $true -Code 200 -UserId $null -Role $null -Reason 'AUTH_DISABLED'
    }

    $isPublicRead = ($method -eq 'GET' -or $method -eq 'HEAD') -and ($path -ceq '/' -or $path -ceq '/app.js' -or $path -ceq '/styles.css')
    if ($isPublicRead) {
        return New-PwxWebAuthResult -Allowed $true -Code 200 -UserId $null -Role $null -Reason 'PUBLIC'
    }
    if ($method -eq 'POST' -and $path -ceq '/api/login') {
        return New-PwxWebAuthResult -Allowed $true -Code 200 -UserId $null -Role $null -Reason 'PUBLIC'
    }

    $token = $null
    $cookie = Get-PwxHeaderRawValue -Headers $Headers -Name 'Cookie'
    if (-not [string]::IsNullOrEmpty($cookie)) {
        foreach ($pair in ($cookie -split ';')) {
            $eq = $pair.IndexOf([char]'=')
            if ($eq -lt 1) { continue }
            $name = $pair.Substring(0, $eq).Trim()
            if ($name -ieq 'pwx_session') {
                $value = $pair.Substring($eq + 1).Trim()
                if ($value.Length -ge 2 -and $value.StartsWith('"') -and $value.EndsWith('"')) {
                    $value = $value.Substring(1, $value.Length - 2)
                }
                $token = $value
            }
        }
    }

    $session = $null
    if (-not [string]::IsNullOrEmpty($token)) {
        $session = Get-PwxWebSession -Token $token
    }
    if ($null -eq $session) {
        return New-PwxWebAuthResult -Allowed $false -Code 401 -UserId $null -Role $null -Reason 'AUTH_REQUIRED'
    }

    if ($method -eq 'POST' -or $method -eq 'PUT' -or $method -eq 'PATCH' -or $method -eq 'DELETE') {
        $panelHeader = Get-PwxHeaderRawValue -Headers $Headers -Name 'X-Pwx-Panel'
        if ($panelHeader -ne '1') {
            return New-PwxWebAuthResult -Allowed $false -Code 403 -UserId $session.user_id -Role $session.role -Reason 'CSRF_HEADER_MISSING'
        }
    }

    if ($path.StartsWith('/api/admin/', [System.StringComparison]::Ordinal) -and [string]$session.role -ine 'admin') {
        return New-PwxWebAuthResult -Allowed $false -Code 403 -UserId $session.user_id -Role $session.role -Reason 'FORBIDDEN_ROLE'
    }

    return New-PwxWebAuthResult -Allowed $true -Code 200 -UserId $session.user_id -Role $session.role -Reason 'SESSION_OK'
}
