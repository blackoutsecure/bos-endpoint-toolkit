# >>> devbox:configuration-data >>>
throw 'Use npm run build, then run the standalone scripts under output\devbox\windows.'
# <<< devbox:configuration-data <<<

function Test-DevboxConfigurationObject {
    param($Value, [string]$Prefix = '')
    if ($Value -isnot [pscustomobject]) { throw "Expected a configuration object at '$Prefix'." }
    foreach ($Property in $Value.PSObject.Properties) {
        $Path = if ($Prefix) { "$Prefix.$($Property.Name)" } else { $Property.Name }
        $Field = @($DevboxConfigurationFields | Where-Object { $_.path -ceq $Path })
        if ($Field.Count -eq 0) {
            if ($Path -cin @('windows', 'macos')) {
                Test-DevboxConfigurationObject -Value $Property.Value -Prefix $Path
                continue
            }
            throw "Unknown configuration key: $Path"
        }
        $Spec = $Field[0]
        $Item = $Property.Value
        switch ($Spec.type) {
            'integer' {
                if ($null -eq $Item -or $Item -is [bool] -or $Item -is [string] -or
                    $Item -is [array] -or $Item -is [pscustomobject] -or
                    $Item -ne [math]::Floor([double]$Item) -or $Item -lt $Spec.minimum -or $Item -gt $Spec.maximum) {
                    throw "Configuration $Path must be an integer from $($Spec.minimum) through $($Spec.maximum)."
                }
            }
            'boolean' {
                if ($Item -isnot [bool]) { throw "Configuration $Path must be a boolean." }
            }
            'string' {
                if ($Item -isnot [string] -or $Item -cnotmatch $Spec.pattern) { throw "Invalid configuration string: $Path" }
            }
            'array' {
                if ($Item -isnot [array] -or $Item.Count -lt $Spec.minItems) { throw "Invalid configuration array: $Path" }
                $Seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                foreach ($Entry in $Item) {
                    if ($Entry -isnot [string] -or $Entry -cnotmatch $Spec.pattern -or -not $Seen.Add($Entry)) {
                        throw "Configuration $Path requires unique, valid string entries."
                    }
                }
            }
            default { throw "Unsupported configuration type: $($Spec.type)" }
        }
    }
}

function Merge-DevboxConfiguration {
    param($Base, $Override)
    foreach ($Property in $Override.PSObject.Properties) {
        if ($Property.Value -is [pscustomobject]) {
            Merge-DevboxConfiguration -Base $Base.($Property.Name) -Override $Property.Value
        } else {
            $Base.($Property.Name) = $Property.Value
        }
    }
}

function Get-DevboxConfiguration {
    param([string]$Path)
    $Values = $DevboxDefaultsJson | ConvertFrom-Json
    $Source = 'packaged defaults'
    if (-not $Path) {
        $Candidate = Join-Path (Join-Path $env:ProgramData $Values.name) 'desired-config.json'
        if (Test-Path -LiteralPath $Candidate) { $Path = $Candidate }
    }
    if ($Path) {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Desired configuration is missing: $Path" }
        $Override = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        Test-DevboxConfigurationObject -Value $Override
        if ($null -eq $Override.PSObject.Properties['schemaVersion']) { throw 'Desired configuration requires schemaVersion: 1.' }
        Merge-DevboxConfiguration -Base $Values -Override $Override
        $Source = (Get-Item -LiteralPath $Path).FullName
    }
    Test-DevboxConfigurationObject -Value $Values
    [pscustomobject]@{ Values = $Values; Json = ($Values | ConvertTo-Json -Depth 8); Source = $Source }
}

function Get-DevboxWorkerArgument {
    param([string]$WorkerPath, [string]$StateRoot, [ValidateSet('Mount', 'Backup')][string]$Mode)
    if ($WorkerPath -match '["\r\n]' -or $StateRoot -match '["\r\n]') { throw 'Invalid scheduled worker path.' }
    "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$WorkerPath`" -StateRoot `"$StateRoot`" -Mode $Mode"
}
