# E2E del contrato CLI (v1.0): validacion real de argumentos mediante procesos
# hijo, igual que runner.test.ps1. Cubre: UNKNOWN_FLAG/UNKNOWN_ARGUMENT, flags
# validos existentes, -Attachments de outbox:new y el flujo completo hasta .eml.

$script:PwxCliContractCli = Join-Path (Join-Path $global:PwxRepoRoot 'src') 'bin/pwx.ps1'

function Invoke-PwxCliContractCli {
    param([string[]]$CliArgs)
    $raw = @(& (Get-PwxShellExe) -NoProfile -ExecutionPolicy Bypass -File $script:PwxCliContractCli @CliArgs 2>&1)
    return @{
        exit = [int]$LASTEXITCODE
        out  = (($raw -join "`n") -replace "`r", '')
    }
}

Run-PwxTest -Name 'CLI contrato: typos de flags -> UNKNOWN_FLAG / UNKNOWN_ARGUMENT con exit 1' -File 'e2e' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap

    $r1 = Invoke-PwxCliContractCli -CliArgs @('outbox:send', '-Id', 'M-9999', '-Transprot', 'file')
    Assert-PwxEqual 1 $r1.exit 'outbox:send -Transprot -> exit 1'
    Assert-PwxTrue ($r1.out -match 'UNKNOWN_FLAG') 'mensaje UNKNOWN_FLAG presente'
    Assert-PwxTrue ($r1.out -match 'Transprot') 'el flag con typo se nombra en el error'

    $r2 = Invoke-PwxCliContractCli -CliArgs @('backup:create', '-Labl', 'demo')
    Assert-PwxEqual 1 $r2.exit 'backup:create -Labl -> exit 1'
    Assert-PwxTrue ($r2.out -match 'UNKNOWN_FLAG') 'backup:create UNKNOWN_FLAG'

    $r3 = Invoke-PwxCliContractCli -CliArgs @('client:new', '-Nam', 'Ana')
    Assert-PwxEqual 1 $r3.exit 'client:new -Nam -> exit 1'
    Assert-PwxTrue ($r3.out -match 'UNKNOWN_FLAG') 'client:new UNKNOWN_FLAG'

    $r4 = Invoke-PwxCliContractCli -CliArgs @('client:list', 'token-suelto')
    Assert-PwxEqual 1 $r4.exit 'token posicional suelto -> exit 1'
    Assert-PwxTrue ($r4.out -match 'UNKNOWN_ARGUMENT') 'UNKNOWN_ARGUMENT presente'
}

Run-PwxTest -Name 'CLI contrato: comandos y flags validos siguen funcionando' -File 'e2e' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap

    $r1 = Invoke-PwxCliContractCli -CliArgs @('quote:calc', '-ServiceId', 'excel-service', '-Addons', 'rush', '-Units', '2')
    Assert-PwxEqual 0 $r1.exit 'quote:calc con flags validos -> exit 0'
    Assert-PwxTrue ($r1.out -match '"total"') 'quote:calc devuelve cotizacion'

    $r2 = Invoke-PwxCliContractCli -CliArgs @('client:list')
    Assert-PwxEqual 0 $r2.exit 'client:list sin flags -> exit 0'

    $r3 = Invoke-PwxCliContractCli -CliArgs @('backup:list')
    Assert-PwxEqual 0 $r3.exit 'backup:list -> exit 0'

    $r4 = Invoke-PwxCliContractCli -CliArgs @('web:hash', '-Password', 'democontrato')
    Assert-PwxEqual 0 $r4.exit 'web:hash -Password -> exit 0'
    Assert-PwxTrue ($r4.out -match 'pbkdf2-') 'web:hash devuelve hash pbkdf2'

    $r5 = Invoke-PwxCliContractCli -CliArgs @('backup:restore')
    Assert-PwxEqual 1 $r5.exit 'backup:restore sin -Path -> exit 1 (existe y valida)'
    Assert-PwxTrue ($r5.out -match 'Falta -Path') 'backup:restore exige -Path'
}

Run-PwxTest -Name 'CLI contrato: outbox:new -Attachments cablea 0, 1 y N adjuntos' -File 'e2e' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $attDir = Join-Path $ws 'entrega'
    New-PwxDirectory -Path $attDir | Out-Null
    $a = Join-Path $attDir 'a.txt'
    $b = Join-Path $attDir 'b.txt'
    [System.IO.File]::WriteAllText($a, 'ADJUNTO A', (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText($b, 'ADJUNTO B', (New-Object System.Text.UTF8Encoding($false)))

    # 0 adjuntos: comportamiento anterior intacto
    $r0 = Invoke-PwxCliContractCli -CliArgs @('outbox:new', '-Recipient', 'x@y.com', '-Subject', 's', '-Body', 'b')
    Assert-PwxEqual 0 $r0.exit 'outbox:new sin adjuntos -> exit 0'
    $id0 = $null
    if ($r0.out -match '"id":\s*"(M-\d+)"') { $id0 = $Matches[1] }
    Assert-PwxNotNull $id0 'id devuelto'
    Assert-PwxEqual 0 @((Get-PwxOutboxItem -Id $id0).attachments).Count 'sin adjuntos'

    # 1 adjunto
    $r1 = Invoke-PwxCliContractCli -CliArgs @('outbox:new', '-Recipient', 'x@y.com', '-Subject', 's', '-Body', 'b', '-Attachments', $a)
    Assert-PwxEqual 0 $r1.exit 'outbox:new con 1 adjunto -> exit 0'
    $id1 = $null
    if ($r1.out -match '"id":\s*"(M-\d+)"') { $id1 = $Matches[1] }
    $item1 = Get-PwxOutboxItem -Id $id1
    Assert-PwxEqual 1 @($item1.attachments).Count 'un adjunto registrado'
    Assert-PwxEqual (Get-PwxSha256 -Path $a) $item1.attachments[0].sha256 'sha256 del adjunto'

    # N adjuntos por coma
    $r2 = Invoke-PwxCliContractCli -CliArgs @('outbox:new', '-Recipient', 'x@y.com', '-Subject', 's', '-Body', 'b', '-Attachments', ($a + ',' + $b))
    Assert-PwxEqual 0 $r2.exit 'outbox:new con 2 adjuntos -> exit 0'
    $id2 = $null
    if ($r2.out -match '"id":\s*"(M-\d+)"') { $id2 = $Matches[1] }
    $item2 = Get-PwxOutboxItem -Id $id2
    Assert-PwxEqual 2 @($item2.attachments).Count 'dos adjuntos registrados'
    $hashes = @($item2.attachments | ForEach-Object { $_.sha256 })
    Assert-PwxTrue ($hashes -contains (Get-PwxSha256 -Path $b)) 'hash del segundo adjunto presente'
}

Run-PwxTest -Name 'CLI contrato: -Attachments rechaza inexistente y fuera del workspace' -File 'e2e' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap

    $r1 = Invoke-PwxCliContractCli -CliArgs @('outbox:new', '-Recipient', 'x@y.com', '-Subject', 's', '-Body', 'b', '-Attachments', (Join-Path $ws 'no-existe.txt'))
    Assert-PwxEqual 1 $r1.exit 'adjunto inexistente -> exit 1'
    Assert-PwxTrue ($r1.out -match 'Adjunto inexistente') 'mensaje de adjunto inexistente'

    $outside = Join-Path ([System.IO.Path]::GetTempPath()) ('pwx-cli-outside-' + [guid]::NewGuid().ToString('N') + '.txt')
    [System.IO.File]::WriteAllText($outside, 'FUERA', (New-Object System.Text.UTF8Encoding($false)))
    try {
        $r2 = Invoke-PwxCliContractCli -CliArgs @('outbox:new', '-Recipient', 'x@y.com', '-Subject', 's', '-Body', 'b', '-Attachments', $outside)
        Assert-PwxEqual 1 $r2.exit 'adjunto fuera del workspace -> exit 1'
        Assert-PwxTrue ($r2.out -match 'Path traversal') 'path traversal bloqueado'
    }
    finally {
        Remove-Item -LiteralPath $outside -Force -ErrorAction SilentlyContinue
    }

    # ningun mensaje debe haberse creado tras los rechazos
    Assert-PwxEqual 0 @(Get-PwxOutboxItems).Count 'sin mensajes creados por llamadas rechazadas'
}

Run-PwxTest -Name 'CLI contrato: flujo outbox:new -Attachments -> approve -> send file (.eml)' -File 'e2e' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $attDir = Join-Path $ws 'entrega'
    New-PwxDirectory -Path $attDir | Out-Null
    $att = Join-Path $attDir 'presupuesto.xlsx'
    [System.IO.File]::WriteAllText($att, 'BYTES-DE-ENTREGA', (New-Object System.Text.UTF8Encoding($false)))
    $expectedHash = (Get-PwxSha256 -Path $att)

    $r1 = Invoke-PwxCliContractCli -CliArgs @('outbox:new', '-Recipient', 'cliente@correo.com', '-Subject', 'Su entrega', '-Body', 'Adjunto el presupuesto.', '-Attachments', $att)
    Assert-PwxEqual 0 $r1.exit 'outbox:new -Attachments -> exit 0'
    $msgId = $null
    if ($r1.out -match '"id":\s*"(M-\d+)"') { $msgId = $Matches[1] }
    Assert-PwxNotNull $msgId 'id del mensaje'

    $r2 = Invoke-PwxCliContractCli -CliArgs @('outbox:approve', '-Id', $msgId, '-By', 'tester')
    Assert-PwxEqual 0 $r2.exit 'outbox:approve -> exit 0'

    $r3 = Invoke-PwxCliContractCli -CliArgs @('outbox:send', '-Id', $msgId, '-Transport', 'file')
    Assert-PwxEqual 0 $r3.exit 'outbox:send -Transport file -> exit 0'
    Assert-PwxTrue ($r3.out -match '"status":\s*"SENT"') 'resultado SENT'

    $emlPath = Join-Path (Get-PwxOutboxEmlDir) ($msgId + '.eml')
    Assert-PwxTrue (Test-Path -LiteralPath $emlPath) '.eml generado'
    $raw = [System.IO.File]::ReadAllText($emlPath)
    Assert-PwxTrue ($raw -match 'multipart/mixed') 'eml multipart'
    Assert-PwxTrue ($raw -match 'filename="presupuesto\.xlsx"') 'adjunto por nombre'
    Assert-PwxTrue ($raw -match ('X-Pwx-Sha256: ' + $expectedHash)) 'sha256 del adjunto en el eml'

    $after = Get-PwxOutboxItem -Id $msgId
    Assert-PwxEqual 'SENT' $after.status 'estado SENT persistido'
    Assert-PwxEqual 1 $after.attempts 'un intento'
    Assert-PwxNull $after.last_error 'sin errores'
}
