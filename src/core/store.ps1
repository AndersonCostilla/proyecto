function Get-PwxWorkspacePath {
    $cfg = Get-PwxConfig
    New-PwxDirectory -Path $cfg.WorkspacePath | Out-Null
    return $cfg.WorkspacePath
}

function Get-PwxClientsDir {
    $ws = Get-PwxWorkspacePath
    $dir = Join-Path $ws 'clients'
    New-PwxDirectory -Path $dir | Out-Null
    return $dir
}

function Get-PwxClientDir {
    param([string]$ClientId)
    Assert-PwxSafeFileName -Name $ClientId | Out-Null
    return (Join-Path (Get-PwxClientsDir) $ClientId)
}

function Get-PwxClientFile {
    param([string]$ClientId)
    return (Join-Path (Get-PwxClientDir -ClientId $ClientId) 'client.json')
}

function Get-PwxClient {
    param([string]$ClientId)
    $file = Get-PwxClientFile -ClientId $ClientId
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    return Get-PwxJsonFile -Path $file
}

function Get-PwxClients {
    $dir = Get-PwxClientsDir
    $result = @()
    foreach ($sub in (Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue)) {
        $client = Get-PwxClient -ClientId $sub.Name
        if ($client) { $result += $client }
    }
    return $result
}

function New-PwxClient {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Contact = ''
    )
    $id = Get-PwxClientId
    $client = [ordered]@{
        id         = $id
        name       = $Name
        contact    = $Contact
        created_at = Get-PwxTimestamp
        updated_at = Get-PwxTimestamp
        notes      = @()
    }
    Set-PwxJsonFile -Path (Get-PwxClientFile -ClientId $id) -Object $client | Out-Null
    New-PwxDirectory -Path (Join-Path (Get-PwxClientDir -ClientId $id) 'jobs') | Out-Null
    Write-PwxLog -Component 'store' -Message "Cliente creado: $id ($Name)"
    return $client
}

function Get-PwxJobDir {
    param([string]$ClientId, [string]$JobId)
    Assert-PwxSafeFileName -Name $ClientId | Out-Null
    Assert-PwxSafeFileName -Name $JobId | Out-Null
    return (Join-Path (Join-Path (Get-PwxClientDir -ClientId $ClientId) 'jobs') $JobId)
}

function Get-PwxJobFile {
    param([string]$ClientId, [string]$JobId)
    return (Join-Path (Get-PwxJobDir -ClientId $ClientId -JobId $JobId) 'job.json')
}

function Find-PwxJob {
    param([string]$JobId)
    Assert-PwxSafeFileName -Name $JobId | Out-Null
    $clientsDir = Get-PwxClientsDir
    foreach ($clientDir in (Get-ChildItem -LiteralPath $clientsDir -Directory -ErrorAction SilentlyContinue)) {
        $jobFile = Get-PwxJobFile -ClientId $clientDir.Name -JobId $JobId
        if (Test-Path -LiteralPath $jobFile) {
            return [pscustomobject]@{
                ClientId = $clientDir.Name
                JobId    = $JobId
                JobFile  = $jobFile
                JobDir   = Split-Path -Parent $jobFile
            }
        }
    }
    return $null
}

function Get-PwxJob {
    param([string]$JobId)
    $found = Find-PwxJob -JobId $JobId
    if (-not $found) { return $null }
    $job = Get-PwxJsonFile -Path $found.JobFile
    $job | Add-Member -NotePropertyName client_id -NotePropertyValue $found.ClientId -Force
    return $job
}

function Get-PwxJobs {
    param([string]$ClientId)
    $jobsDir = Join-Path (Get-PwxClientDir -ClientId $ClientId) 'jobs'
    $result = @()
    foreach ($sub in (Get-ChildItem -LiteralPath $jobsDir -Directory -ErrorAction SilentlyContinue)) {
        $jobFile = Join-Path $sub.FullName 'job.json'
        if (Test-Path -LiteralPath $jobFile) {
            $job = Get-PwxJsonFile -Path $jobFile
            $job | Add-Member -NotePropertyName client_id -NotePropertyValue $ClientId -Force
            $result += $job
        }
    }
    return $result
}

function New-PwxJob {
    param(
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$Service,
        [string]$Description = ''
    )
    $client = Get-PwxClient -ClientId $ClientId
    if (-not $client) {
        throw "Cliente inexistente: $ClientId"
    }
    if (-not (Get-PwxService -ServiceId $Service)) {
        throw "Servicio desconocido: $Service"
    }
    $price = $null
    try {
        $priceInfo = Get-PwxPrice -ServiceId $Service
        $price = [ordered]@{
            service_id      = $Service
            base_price      = $priceInfo.base_price
            addons          = @()
            subtotal        = $priceInfo.subtotal
            currency        = $priceInfo.currency
            estimated_hours = $priceInfo.estimated_hours
            computed_at     = Get-PwxTimestamp
            source          = 'catalog'
        }
    }
    catch {
        $price = $null
    }
    $id = Get-PwxJobId
    $jobDir = Get-PwxJobDir -ClientId $ClientId -JobId $id
    New-PwxDirectory -Path (Join-Path $jobDir 'input') | Out-Null
    New-PwxDirectory -Path (Join-Path $jobDir 'working') | Out-Null
    New-PwxDirectory -Path (Join-Path $jobDir 'output') | Out-Null
    New-PwxDirectory -Path (Join-Path $jobDir 'qa') | Out-Null
    New-PwxDirectory -Path (Join-Path $jobDir 'delivery') | Out-Null
    $job = [ordered]@{
        id          = $id
        service     = $Service
        state       = 'NEW'
        description = $Description
        created_at  = Get-PwxTimestamp
        updated_at  = Get-PwxTimestamp
        requirements = $null
        price        = $price
        output_version = 0
        versions     = @()
        files        = [ordered]@{
            input    = @()
            working  = @()
            output   = @()
            delivery = @()
        }
        qa              = $null
        delivery_manifest = $null
        notes           = @()
    }
    Set-PwxJsonFile -Path (Get-PwxJobFile -ClientId $ClientId -JobId $id) -Object $job | Out-Null
    Write-PwxLog -Component 'store' -Message "Trabajo creado: $id (cliente $ClientId, servicio $Service)" -JobId $id
    Add-PwxEvent -JobId $id -Component 'store' -Action 'job.created' -Data @{ client_id = $ClientId; service = $Service }
    return (Get-PwxJob -JobId $id)
}

function Save-PwxJob {
    param([object]$Job)
    $found = Find-PwxJob -JobId $Job.id
    if (-not $found) {
        throw "No se encontro trabajo para guardar: $($Job.id)"
    }
    if (-not (Test-PwxStateValid -State $Job.state)) {
        throw "Estado invalido al guardar: $($Job.state)"
    }
    $persisted = Get-PwxJob -JobId $Job.id
    if ($persisted -and $persisted.state -ne $Job.state) {
        if (-not (Test-PwxTransition -From $persisted.state -To $Job.state)) {
            throw "Transicion de estado invalida al guardar: $($persisted.state) -> $($Job.state)"
        }
    }
    $copy = $Job.PSObject.Copy()
    $copy.PSObject.Properties.Remove('client_id')
    $copy.updated_at = Get-PwxTimestamp
    Set-PwxJsonFile -Path $found.JobFile -Object $copy | Out-Null
    return (Get-PwxJob -JobId $Job.id)
}

function Add-PwxJobNote {
    param([string]$JobId, [string]$Note)
    $job = Get-PwxJob -JobId $JobId
    if (-not $job) { throw "Trabajo inexistente: $JobId" }
    $job.notes = @($job.notes) + $Note
    Save-PwxJob -Job $job | Out-Null
}

function Add-PwxJobFile {
    param([string]$JobId, [string]$Bucket, [string]$Path)
    if ('input','working','output','delivery' -notcontains $Bucket) {
        throw "Bucket invalido: $Bucket"
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Archivo inexistente para registrar: $Path"
    }
    $job = Get-PwxJob -JobId $JobId
    if (-not $job) { throw "Trabajo inexistente: $JobId" }
    $jobDir = (Find-PwxJob -JobId $JobId).JobDir
    $safe = Assert-PwxSafeWorkspacePath -WorkspacePath $jobDir -Path $Path
    $rel = Get-PwxRelativePath -BasePath $jobDir -ChildPath $safe
    $entry = [ordered]@{
        name       = [System.IO.Path]::GetFileName($safe)
        path       = $rel
        size       = (Get-Item -LiteralPath $safe).Length
        sha256     = Get-PwxSha256 -Path $safe
        created_at = Get-PwxTimestamp
    }
    $job.files.$Bucket = @($job.files.$Bucket) + $entry
    Save-PwxJob -Job $job | Out-Null
    return $entry
}

function Add-PwxJobInputFile {
    param(
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$SourcePath,
        [string]$TargetName = ''
    )
    if (-not (Test-Path -LiteralPath $SourcePath)) {
        throw "Archivo de entrada inexistente: $SourcePath"
    }
    if ((Get-Item -LiteralPath $SourcePath).PSIsContainer) {
        throw "La entrada debe ser un archivo, no una carpeta: $SourcePath"
    }
    if (-not $TargetName) {
        $TargetName = [System.IO.Path]::GetFileName($SourcePath)
    }
    if ([string]::IsNullOrWhiteSpace($TargetName)) {
        throw 'Nombre de archivo de entrada vacio'
    }
    if ($TargetName -match '[\\/:*?"<>|]') {
        throw "Nombre de archivo invalido (caracteres no permitidos): $TargetName"
    }
    Assert-PwxSafeFileName -Name $TargetName | Out-Null
    if ([System.IO.Path]::IsPathRooted($TargetName)) {
        throw "Ruta absoluta no permitida en entrada: $TargetName"
    }
    $found = Find-PwxJob -JobId $JobId
    if (-not $found) { throw "Trabajo inexistente: $JobId" }
    $inputDir = Join-Path $found.JobDir 'input'
    New-PwxDirectory -Path $inputDir | Out-Null
    $dest = Join-Path $inputDir $TargetName
    $safeDest = Assert-PwxSafeWorkspacePath -WorkspacePath $found.JobDir -Path $dest
    Copy-Item -LiteralPath $SourcePath -Destination $safeDest -Force
    Write-PwxLog -Component 'store' -Message "Archivo de entrada registrado en $JobId : $TargetName" -JobId $JobId
    return (Add-PwxJobFile -JobId $JobId -Bucket 'input' -Path $safeDest)
}

function Get-PwxJobOutputVersion {
    param([string]$JobId)
    $job = Get-PwxJob -JobId $JobId
    if (-not $job) { throw "Trabajo inexistente: $JobId" }
    if ($null -eq $job.output_version) { return 0 }
    return [int]$job.output_version
}

function Set-PwxJobOutputVersion {
    param([string]$JobId)
    $job = Get-PwxJob -JobId $JobId
    if (-not $job) { throw "Trabajo inexistente: $JobId" }
    $version = Get-PwxJobOutputVersion -JobId $JobId
    $job.output_version = $version + 1
    Save-PwxJob -Job $job | Out-Null
    return $job.output_version
}

function Add-PwxOutputSnapshot {
    param([string]$JobId, [string]$Reason = 'run')
    $job = Get-PwxJob -JobId $JobId
    if (-not $job) { throw "Trabajo inexistente: $JobId" }
    $version = Get-PwxJobOutputVersion -JobId $JobId
    $current = @(Get-PwxOutputSnapshot -JobId $JobId)
    if ($version -le 0 -or $current.Count -eq 0) { return $null }
    if (-not $job.versions) { $job.versions = @() }
    foreach ($v in @($job.versions)) {
        if ([int]$v.version -eq $version) {
            return $v
        }
    }
    $found = Find-PwxJob -JobId $JobId
    $target = Join-Path $found.JobDir ('versions\v' + $version)
    New-PwxDirectory -Path $target | Out-Null
    foreach ($f in $current) {
        $dest = Join-Path $target $f.path
        $destParent = Split-Path -Parent $dest
        New-PwxDirectory -Path $destParent | Out-Null
        Copy-Item -LiteralPath $f.full -Destination $dest -Force
    }
    $snap = [ordered]@{
        version    = $version
        reason     = $Reason
        created_at = Get-PwxTimestamp
        file_count = $current.Count
        path       = ('versions\v' + $version)
    }
    $job.versions = @($job.versions) + $snap
    Save-PwxJob -Job $job | Out-Null
    return $snap
}

function Set-PwxJobState {
    param(
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$To,
        [string]$Reason = '',
        [string]$By = 'system'
    )
    $job = Get-PwxJob -JobId $JobId
    if (-not $job) { throw "Trabajo inexistente: $JobId" }
    $from = $job.state
    Assert-PwxTransition -From $from -To $To | Out-Null
    $job.state = $To
    $job.updated_at = Get-PwxTimestamp
    Save-PwxJob -Job $job | Out-Null
    Add-PwxEvent -JobId $JobId -Component 'state' -Action "state.$To" -Data @{ from = $from; reason = $Reason; by = $By }
    Write-PwxLog -Component 'state' -Message "Trabajo $JobId : $from -> $To ($Reason)" -JobId $JobId
    return (Get-PwxJob -JobId $JobId)
}