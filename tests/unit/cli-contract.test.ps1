# Contrato CLI <-> ayuda <-> codigo (v1.0).
# Protege contra la deriva entre lo que la ayuda documenta, lo que la tabla de
# flags declara y lo que los handlers leen realmente. Motivacion: en PR-6 se
# perdieron silenciosamente la linea de ayuda de outbox:send y el bloque de
# resolucion de outbox.transport (deriva docs/codigo detectada en la auditoria
# pre-v1.0); estos tests impiden que vuelva a pasar sin fallar la suite.

$script:PwxCliContractSourcePath = Join-Path (Join-Path $global:PwxRepoRoot 'src') 'bin/pwx.ps1'
$script:PwxCliContractSource = [System.IO.File]::ReadAllText($script:PwxCliContractSourcePath)

function Get-PwxCliContractTable {
    # Extrae $PwxCliFlagContracts del fuente: comando -> values/switches
    $table = @{}
    $pattern = "(?m)^\s*'([a-z0-9:-]+)'\s*=\s*@\{\s*values\s*=\s*@\(([^)]*)\)\s*;\s*switches\s*=\s*@\(([^)]*)\)\s*\}"
    foreach ($m in [regex]::Matches($script:PwxCliContractSource, $pattern)) {
        $cmd = $m.Groups[1].Value
        $values = @()
        foreach ($v in [regex]::Matches($m.Groups[2].Value, "'([^']+)'")) { $values += $v.Groups[1].Value }
        $switches = @()
        foreach ($s in [regex]::Matches($m.Groups[3].Value, "'([^']+)'")) { $switches += $s.Groups[1].Value }
        $table[$cmd] = @{ values = $values; switches = $switches }
    }
    return $table
}

function Get-PwxCliContractHandlerFlags {
    # Flags que el case del switch lee realmente (Read-PwxFlag / Test-PwxFlagPresent)
    param([string]$Command)
    $start = $script:PwxCliContractSource.IndexOf(("'{0}' {{" -f $Command))
    if ($start -lt 0) { return $null }
    $next = $script:PwxCliContractSource.Length
    foreach ($m in [regex]::Matches($script:PwxCliContractSource, "(?m)^    '[a-z0-9:-]+' \{|^    default \{")) {
        if ($m.Index -gt $start) { $next = $m.Index; break }
    }
    $block = $script:PwxCliContractSource.Substring($start, $next - $start)
    $values = @()
    # Nota de escapado: "`\`$rest" produce el texto literal \$rest (regex para '$rest')
    foreach ($v in [regex]::Matches($block, "Read-PwxFlag -FlagList `\`$rest -Name '([^']+)'")) { $values += $v.Groups[1].Value }
    $switches = @()
    foreach ($s in [regex]::Matches($block, "Test-PwxFlagPresent -FlagList `\`$rest -Name '([^']+)'")) { $switches += $s.Groups[1].Value }
    return @{ values = $values; switches = $switches }
}

function Get-PwxCliContractHelpText {
    $m = [regex]::Match($script:PwxCliContractSource, "@'\r?\n([\s\S]*?)\r?\n'@")
    if (-not $m.Success) { throw 'No se encontro la ayuda (here-string) en src/bin/pwx.ps1' }
    return $m.Groups[1].Value
}

Run-PwxTest -Name 'contrato CLI: la tabla de flags coincide exactamente con los handlers' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $table = Get-PwxCliContractTable
    Assert-PwxTrue ($table.Count -ge 45) ('la tabla cubre los comandos (hay {0})' -f $table.Count)

    $cases = @([regex]::Matches($script:PwxCliContractSource, "(?m)^    '([a-z0-9:-]+)' \{") | ForEach-Object { $_.Groups[1].Value })
    Assert-PwxTrue ($cases.Count -ge 45) ('hay {0} case de comandos en el switch' -f $cases.Count)

    foreach ($c in $cases) {
        Assert-PwxTrue $table.ContainsKey($c) "la tabla define: $c"
        $h = Get-PwxCliContractHandlerFlags -Command $c
        Assert-PwxNotNull $h "handler localizado: $c"
        $t = $table[$c]
        foreach ($f in @($h.values)) { Assert-PwxTrue (@($t.values) -contains $f) "$c : el handler lee $f y la tabla debe declararlo" }
        foreach ($f in @($t.values)) { Assert-PwxTrue (@($h.values) -contains $f) "$c : la tabla declara $f y el handler debe leerlo" }
        foreach ($f in @($h.switches)) { Assert-PwxTrue (@($t.switches) -contains $f) "$c : el handler usa el switch $f y la tabla debe declararlo" }
        foreach ($f in @($t.switches)) { Assert-PwxTrue (@($h.switches) -contains $f) "$c : la tabla declara el switch $f y el handler debe usarlo" }
    }
}

Run-PwxTest -Name 'contrato CLI: la ayuda documenta los flags y comandos criticos' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $help = Get-PwxCliContractHelpText
    foreach ($needle in @(
        'backup:restore',
        'backup:verify',
        'web:hash',
        'lead:draft',
        'lead:import-socrata',
        'outbox:export'
    )) {
        Assert-PwxTrue ($help -match [regex]::Escape($needle)) "la ayuda documenta: $needle"
    }
    Assert-PwxTrue ($help -match 'outbox:new.*-Attachments') 'la ayuda documenta -Attachments en outbox:new'
    Assert-PwxTrue ($help -match 'outbox:send.*-Transport') 'la ayuda documenta -Transport en outbox:send'
    Assert-PwxTrue ($help -match 'outbox:send.*-Force') 'la ayuda documenta -Force en outbox:send'
    Assert-PwxTrue ($help -match 'AllowFail') 'la ayuda menciona -AllowFail'
    Assert-PwxTrue ($help -notmatch 'rush,extra') 'la ayuda ya no cita el par de addons invalido rush,extra'
}

Run-PwxTest -Name 'contrato CLI: los addons citados en la ayuda existen en el catalogo' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $catalogPath = (Get-PwxConfig).ServiceCatalogPath
    $catalog = Get-PwxJsonFile -Path $catalogPath
    $allAddons = @()
    foreach ($svc in $catalog.services.PSObject.Properties) {
        if ($svc.Value.addons) {
            foreach ($a in $svc.Value.addons.PSObject.Properties) { $allAddons += $a.Name }
        }
    }
    Assert-PwxTrue ($allAddons.Count -gt 0) 'el catalogo define addons'

    $help = Get-PwxCliContractHelpText
    foreach ($m in [regex]::Matches($help, '\[-Addons ([^\]]*)\]')) {
        foreach ($tok in ($m.Groups[1].Value -split ',')) {
            $t = $tok.Trim()
            if (-not $t) { continue }
            if ($t.StartsWith('<')) { continue } # placeholder <ids>: valido
            Assert-PwxTrue ($allAddons -contains $t) "addon citado en la ayuda existe en el catalogo: $t (reales: $($allAddons -join ','))"
        }
    }
    # Si se citan ids concretos deben ser reales; y la ayuda sigue documentando -Addons
    Assert-PwxTrue ($help -match '-Addons') 'la ayuda sigue documentando -Addons'
}

Run-PwxTest -Name 'contrato CLI: version 1.0.0 y settings.outbox.transport respetado' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    Assert-PwxEqual '1.0.0' (Get-PwxVersion) 'Get-PwxVersion = 1.0.0'
    $boot = [System.IO.File]::ReadAllText((Join-Path (Join-Path $global:PwxRepoRoot 'src') 'bootstrap.ps1'))
    Assert-PwxTrue ($boot -notmatch '0\.1\.0') 'bootstrap sin restos de 0.1.0'
    # Regresion PR-6: el bloque de resolucion de outbox.transport debe existir
    # (si se pierde, settings.json queda silenciosamente ignorado).
    $cfgSrc = [System.IO.File]::ReadAllText((Join-Path (Join-Path $global:PwxRepoRoot 'src') 'core/config.ps1'))
    Assert-PwxTrue ($cfgSrc -match 'cfg\.outbox\.transport') 'config.ps1 lee outbox.transport'
    $raw = Get-PwxJsonFile -Path (Join-Path $global:PwxRepoRoot 'config/settings.json')
    if ($raw.outbox -and $raw.outbox.transport) {
        Assert-PwxEqual ([string]$raw.outbox.transport) ([string](Get-PwxConfig).OutboxTransport) 'settings.outbox.transport llega a Get-PwxConfig'
    }
    else {
        throw 'settings.json debe declarar outbox.transport (contrato v1.0)'
    }
}
