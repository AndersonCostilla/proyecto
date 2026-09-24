$PwxStateTransitions = @{
    'NEW'                  = @('REQUIREMENTS', 'BLOCKED', 'CANCELLED')
    'REQUIREMENTS'         = @('READY_FOR_PRODUCTION', 'BLOCKED', 'CANCELLED')
    'READY_FOR_PRODUCTION' = @('IN_PROGRESS', 'BLOCKED', 'CANCELLED')
    'IN_PROGRESS'          = @('QA', 'REWORK', 'BLOCKED', 'CANCELLED')
    'QA'                   = @('READY_FOR_DELIVERY', 'REWORK', 'BLOCKED', 'CANCELLED')
    'REWORK'               = @('IN_PROGRESS', 'BLOCKED', 'CANCELLED')
    'READY_FOR_DELIVERY'   = @('DELIVERED', 'BLOCKED', 'CANCELLED')
    'DELIVERED'            = @('COMPLETED')
    'BLOCKED'              = @('REQUIREMENTS', 'CANCELLED')
    'COMPLETED'            = @()
    'CANCELLED'            = @()
}

function Test-PwxStateValid {
    param([string]$State)
    return $PwxStateTransitions.ContainsKey($State)
}

function Get-PwxAllowedNextStates {
    param([string]$State)
    if (-not (Test-PwxStateValid -State $State)) {
        throw "Estado invalido: $State"
    }
    return $PwxStateTransitions[$State]
}

function Test-PwxTransition {
    param([string]$From, [string]$To)
    if (-not (Test-PwxStateValid -State $From)) { return $false }
    if (-not (Test-PwxStateValid -State $To)) { return $false }
    return ($PwxStateTransitions[$From] -contains $To)
}

function Assert-PwxTransition {
    param([string]$From, [string]$To)
    if (-not (Test-PwxTransition -From $From -To $To)) {
        throw "Transicion de estado invalida: $From -> $To"
    }
}