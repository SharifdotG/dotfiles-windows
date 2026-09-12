# Reading and comparing the JSON config files that other programs own.
# Dot-sourced by scripts\doctor.ps1.
#
# Why this exists: Windows Terminal and Docker Desktop rewrite their own
# settings file whenever a setting is changed in their UI. They reformat it,
# reorder the keys, drop every comment and - in Terminal's case - add the profiles
# they generate themselves. A byte-for-byte comparison against the repo copy then
# reports drift forever, on a file that is semantically identical.
#
# So the question doctor asks about those files is not "is this file identical?"
# but "are the settings this repo manages still in force?". That is a subset test:
# every key the repo sets must be present and equal in the live file, and anything
# the app added on its own is none of our business. Files no program rewrites
# (the PowerShell profile, starship.toml, .wslconfig) keep the strict hash check,
# because for those equality really is the right question.

# Parse JSON with comments and trailing commas - "JSONC", which is what all three
# of those files are. ConvertFrom-Json rejects both, so they are stripped first.
# One pass, tracking string literals, so a // inside "https://aka.ms/..." and a
# comma inside "a, b" both survive.
function ConvertFrom-Jsonc {
    param([Parameter(Mandatory)][string]$Path)

    $text = Get-Content -LiteralPath $Path -Raw
    $out  = [System.Text.StringBuilder]::new($text.Length)
    # Index in $out of the last non-whitespace character emitted, so a comma can
    # be found again once the closing brace that makes it trailing shows up.
    $last = -1
    $i = 0

    while ($i -lt $text.Length) {
        $c = $text[$i]

        # A string literal is copied whole, backslash escapes included, so that
        # nothing inside it is ever mistaken for syntax.
        if ($c -eq '"') {
            $null = $out.Append($c)
            $i++
            while ($i -lt $text.Length) {
                $ch = $text[$i]
                $null = $out.Append($ch)
                $i++
                if ($ch -eq '\') {
                    if ($i -lt $text.Length) { $null = $out.Append($text[$i]); $i++ }
                    continue
                }
                if ($ch -eq '"') { break }
            }
            $last = $out.Length - 1
            continue
        }

        if ($c -eq '/' -and $i + 1 -lt $text.Length) {
            if ($text[$i + 1] -eq '/') {
                while ($i -lt $text.Length -and $text[$i] -ne "`n") { $i++ }
                continue
            }
            if ($text[$i + 1] -eq '*') {
                $end = $text.IndexOf('*/', $i + 2)
                $i = if ($end -lt 0) { $text.Length } else { $end + 2 }
                continue
            }
        }

        # A closing brace or bracket right after a comma makes that comma trailing.
        if (($c -eq '}' -or $c -eq ']') -and $last -ge 0 -and $out[$last] -eq ',') {
            $null = $out.Remove($last, 1)
        }

        $null = $out.Append($c)
        if (-not [char]::IsWhiteSpace($c)) { $last = $out.Length - 1 }
        $i++
    }

    $out.ToString() | ConvertFrom-Json
}

# Which of the four shapes ConvertFrom-Json produces this is. A string is not
# treated as a list even though it is enumerable.
function Get-JsonKind($Value) {
    if ($null -eq $Value)                                       { return 'null' }
    if ($Value -is [string])                                    { return 'scalar' }
    if ($Value -is [System.Collections.IList])                  { return 'array' }
    if ($Value -is [System.Management.Automation.PSCustomObject]) { return 'object' }
    'scalar'
}

# Is everything in $Expected also in $Actual, with the same value? Extra keys in
# $Actual are fine; that is the whole point.
function Test-JsonContains($Expected, $Actual) {
    $kind = Get-JsonKind $Expected
    if ($kind -ne (Get-JsonKind $Actual)) { return $false }

    switch ($kind) {
        'null'  { return $true }
        'object' {
            foreach ($property in $Expected.PSObject.Properties) {
                if ($property.Name -notin $Actual.PSObject.Properties.Name) { return $false }
                if (-not (Test-JsonContains $property.Value $Actual.$($property.Name))) { return $false }
            }
            return $true
        }
        'array' {
            # An empty expected array means "whatever the app generates here is
            # fine" - Terminal's profiles.list is the case this is for.
            foreach ($item in $Expected) {
                $found = $false
                foreach ($candidate in $Actual) {
                    if (Test-JsonContains $item $candidate) { $found = $true; break }
                }
                if (-not $found) { return $false }
            }
            return $true
        }
    }

    # Scalars. Booleans and strings must stay their own type, so `true` never
    # matches "true"; -eq on the strings is case-insensitive on purpose, because
    # "#EFF1F5" and "#eff1f5" are the same colour to every one of these programs.
    if ($Expected -is [bool] -or $Actual -is [bool]) {
        return ($Expected -is [bool]) -and ($Actual -is [bool]) -and ($Expected -eq $Actual)
    }
    if ($Expected -is [string] -or $Actual -is [string]) {
        return ($Expected -is [string]) -and ($Actual -is [string]) -and ($Expected -eq $Actual)
    }
    # Numbers arrive as Int64 or Double depending on how they were written.
    [double]$Expected -eq [double]$Actual
}

# The same walk as Test-JsonContains, but it returns the dotted path of everything
# that does not match instead of a single $false - so doctor can say WHICH setting
# drifted. Returns an empty array when the file is in order.
function Compare-JsonSubset {
    param($Expected, $Actual, [string[]]$Ignore = @(), [string]$Path = '')

    $kind = Get-JsonKind $Expected
    if ($kind -ne (Get-JsonKind $Actual)) {
        return @($(if ($Path) { $Path } else { '<root>' }))
    }

    $drift = [System.Collections.Generic.List[string]]::new()

    switch ($kind) {
        'object' {
            foreach ($property in $Expected.PSObject.Properties) {
                $child = if ($Path) { "$Path.$($property.Name)" } else { $property.Name }
                if ($child -in $Ignore) { continue }
                if ($property.Name -notin $Actual.PSObject.Properties.Name) {
                    $drift.Add("$child (missing)")
                    continue
                }
                $drift.AddRange([string[]]@(
                    Compare-JsonSubset $property.Value $Actual.$($property.Name) -Ignore $Ignore -Path $child
                ))
            }
        }
        'array' {
            # Report the element, not the whole array: "keybindings[3]" points at
            # the one binding that went missing.
            for ($i = 0; $i -lt $Expected.Count; $i++) {
                $found = $false
                foreach ($candidate in $Actual) {
                    if (Test-JsonContains $Expected[$i] $candidate) { $found = $true; break }
                }
                if (-not $found) { $drift.Add("$Path[$i]") }
            }
        }
        default {
            if (-not (Test-JsonContains $Expected $Actual)) {
                $drift.Add($(if ($Path) { $Path } else { '<root>' }))
            }
        }
    }

    $drift.ToArray()
}
