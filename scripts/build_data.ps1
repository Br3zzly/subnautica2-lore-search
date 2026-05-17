#requires -Version 5.1
# Reads FModel-exported entry JSONs and produces docs/databank.json + copies
# referenced textures into docs/images/.
#
# All inputs live OUTSIDE the repo:
#   -FModelContent <path>  Required. FModel's <Output>/Exports/Subnautica2/Content
#                          directory. Must contain Data/DatabankEntry/*.json.
#                          The script also reads UI/, Utility/, Prototyping/
#                          etc. from here to copy referenced images.
#   -GameRoot <path>       Optional. Subnautica 2 Steam install root. The
#                          script reads version.json from here to stamp the
#                          build CL onto databank.json. Skipped if omitted.
#
# Example:
#   ./scripts/build_data.ps1 `
#     -FModelContent "C:\Users\You\FModel\Output\Exports\Subnautica2\Content" `
#     -GameRoot      "C:\Program Files (x86)\Steam\steamapps\common\Subnautica 2"
param(
    [Parameter(Mandatory=$true)]
    [string]$FModelContent,
    [string]$GameRoot = $null
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $FModelContent)) {
    throw "FModelContent path does not exist: $FModelContent"
}
# Canonical "released" entries live here. Everything else with Type ==
# UWEDatabankEntry found elsewhere in Content is treated as a prototype and
# grouped under a synthetic top-level "Prototypes" category.
$releasedRoot = Join-Path $FModelContent 'Data\DatabankEntry'
if (-not (Test-Path $releasedRoot)) {
    throw "Data\DatabankEntry not found under FModelContent. Expected: $releasedRoot"
}

$repoRoot   = Split-Path -Parent $PSScriptRoot
$docsDir    = Join-Path $repoRoot 'docs'
$outFile    = Join-Path $docsDir  'databank.json'
$imagesDir  = Join-Path $docsDir  'images'
$missingTxt = Join-Path $docsDir  'missing_images.txt'

if (-not (Test-Path $docsDir)) {
    New-Item -ItemType Directory -Path $docsDir | Out-Null
}

# Try to read the game build from <GameRoot>/version.json (best-effort)
$gameBuild = $null
if ($GameRoot) {
    $versionJson = Join-Path $GameRoot 'version.json'
    if (Test-Path $versionJson) {
        try {
            $raw = [System.IO.File]::ReadAllText($versionJson)
            # The file is UTF-16 from the game install; strip NULs.
            $raw = $raw -replace "`0",''
            $v = $raw | ConvertFrom-Json
            if ($v.changelist) { $gameBuild = "CL-$($v.changelist)" }
        } catch {
            Write-Warning "Could not parse ${versionJson}: $_"
        }
    } else {
        Write-Warning "version.json not found under GameRoot ($versionJson). Skipping CL stamp."
    }
}

function Convert-AssetPathToRelative {
    # "/Game/UI/Hud/Art/T_DefaultImage.T_DefaultImage" -> "UI/Hud/Art/T_DefaultImage.png"
    param([string]$assetPath)
    if (-not $assetPath -or -not $assetPath.StartsWith('/Game/')) { return $null }
    $stripped = $assetPath.Substring('/Game/'.Length)
    $lastDot = $stripped.LastIndexOf('.')
    if ($lastDot -gt 0) { $stripped = $stripped.Substring(0, $lastDot) }
    return $stripped + '.png'
}

function Get-Text($field) {
    if ($null -eq $field) { return $null }
    if ($field.PSObject.Properties['SourceString']           -and $field.SourceString)           { return $field.SourceString }
    if ($field.PSObject.Properties['LocalizedString']        -and $field.LocalizedString)        { return $field.LocalizedString }
    if ($field.PSObject.Properties['CultureInvariantString'] -and $field.CultureInvariantString) { return $field.CultureInvariantString }
    return $null
}

$entries = New-Object System.Collections.Generic.List[object]
# Walk the whole Content tree. Most JSONs (UI, Materials, Blueprints, etc.)
# aren't databank entries, so do a cheap substring check on the raw text
# before paying for ConvertFrom-Json.
$files = Get-ChildItem -Path $FModelContent -Recurse -Filter *.json -File
foreach ($f in $files) {
    try {
        $raw = [System.IO.File]::ReadAllText($f.FullName)
    } catch {
        Write-Warning "Failed to read $($f.FullName): $_"
        continue
    }
    if (-not $raw.Contains('UWEDatabankEntry')) { continue }

    try {
        $json = $raw | ConvertFrom-Json
    } catch {
        Write-Warning "Failed to parse $($f.FullName): $_"
        continue
    }

    $entry = $json | Where-Object { $_.Type -eq 'UWEDatabankEntry' } | Select-Object -First 1
    if (-not $entry) { continue }
    $p = $entry.Properties

    $title = Get-Text $p.EntryTitle
    $body  = Get-Text $p.EntryText
    $cats  = @()
    if ($p.PSObject.Properties['Categories'] -and $p.Categories) {
        foreach ($c in $p.Categories) {
            $ct = Get-Text $c
            if ($ct) { $cats += $ct }
        }
    }

    # Released entries live under Data\DatabankEntry; everything else is a
    # prototype and gets a synthetic "Prototypes" root category prepended so
    # it lands in its own top-level tree branch.
    $isPrototype = -not $f.FullName.StartsWith($releasedRoot, [System.StringComparison]::OrdinalIgnoreCase)
    if ($isPrototype) {
        $cats = @('Prototypes (DEV/WIP Content - not ingame)') + $cats
        $rel = $f.FullName.Substring($FModelContent.Length).TrimStart('\','/')
    } else {
        # Released entries with no Categories[] land in a synthetic "Uncategorized"
        # root so they aren't rendered as bare leaves at the tree root.
        if ($cats.Count -eq 0) { $cats = @('Uncategorized') }
        $rel = $f.FullName.Substring($releasedRoot.Length).TrimStart('\','/')
    }
    $parts = $rel -split '[\\/]'
    # Strip the filename; everything before it is the section path. Join with
    # forward slashes for cross-platform display. Top-level files get "General".
    if ($parts.Count -gt 1) {
        $subfolder = ($parts[0..($parts.Count - 2)]) -join '/'
    } else {
        $subfolder = 'General'
    }
    if ($isPrototype) { $subfolder = "Prototypes/$subfolder" }
    # Immediate parent folder, used to disambiguate ID collisions below.
    $parentFolder = if ($parts.Count -gt 1) { $parts[$parts.Count - 2] } else { '' }

    # EntryImage.AssetPathName → relative texture path (.png) under docs/images/.
    $imageRel = $null
    if ($p.PSObject.Properties['EntryImage'] -and $p.EntryImage -and
        $p.EntryImage.PSObject.Properties['AssetPathName']) {
        $imageRel = Convert-AssetPathToRelative $p.EntryImage.AssetPathName
    }

    $entries.Add([PSCustomObject]@{
        id           = $entry.Name
        subfolder    = $subfolder
        parentFolder = $parentFolder
        title        = if ($title) { $title } else { $entry.Name }
        categories   = $cats
        body         = if ($body)  { $body  } else { '' }
        imageRel     = $imageRel   # internal; resolved to image_url below
    }) | Out-Null
}

# Disambiguate any ID collisions (e.g. Investigations/{Open,Closed}/Singh share
# the same asset name). Append the parent folder so each ID is unique while
# keeping non-colliding IDs clean.
$idCounts = $entries | Group-Object id | Where-Object Count -gt 1
$collidingIds = @{}
foreach ($g in $idCounts) { $collidingIds[$g.Name] = $true }
foreach ($e in $entries) {
    if ($collidingIds.ContainsKey($e.id) -and $e.parentFolder) {
        $e.id = "$($e.id)__$($e.parentFolder)"
    }
}

# --- Image handling ---------------------------------------------------------
# Copy referenced textures from FModel's export tree into docs/images/, and
# emit a list of any that aren't present so the user knows what to export next.

if (-not (Test-Path $imagesDir)) {
    New-Item -ItemType Directory -Path $imagesDir | Out-Null
}

$imgCopied  = 0
$imgPresent = 0
$missing    = New-Object System.Collections.Generic.List[string]
foreach ($e in $entries) {
    if (-not $e.imageRel) { continue }
    $dest = Join-Path $imagesDir $e.imageRel
    $destDir = Split-Path -Parent $dest
    $src = Join-Path $FModelContent $e.imageRel
    if (Test-Path -LiteralPath $src) {
        if (-not (Test-Path -LiteralPath $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }
        Copy-Item -LiteralPath $src -Destination $dest -Force
        $imgCopied++
    }
    if (Test-Path -LiteralPath $dest) {
        $imgPresent++
    } else {
        if (-not ($missing -contains $e.imageRel)) { $missing.Add($e.imageRel) }
    }
}

# Write the missing list (deduped) so the user knows which textures still
# need exporting from FModel.
if ($missing.Count -gt 0) {
    [System.IO.File]::WriteAllLines($missingTxt, ($missing | Sort-Object), [System.Text.UTF8Encoding]::new($false))
} elseif (Test-Path $missingTxt) {
    Remove-Item $missingTxt
}

# Resolve image_url per entry: only set if the file actually exists on disk.
# Frontend then knows to render an <img>; otherwise it shows no image.
foreach ($e in $entries) {
    if ($e.imageRel) {
        $dest = Join-Path $imagesDir $e.imageRel
        if (Test-Path -LiteralPath $dest) {
            $e | Add-Member -NotePropertyName image_url -NotePropertyValue ("images/" + $e.imageRel) -Force
        } else {
            $e | Add-Member -NotePropertyName image_url -NotePropertyValue $null -Force
        }
    } else {
        $e | Add-Member -NotePropertyName image_url -NotePropertyValue $null -Force
    }
}

$sortedEntries = $entries |
    Select-Object id, subfolder, title, categories, body, image_url |
    Sort-Object subfolder, title

$payload = [ordered]@{
    generated_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    game_build   = $gameBuild
    total        = $sortedEntries.Count
    entries      = $sortedEntries
}

$json = $payload | ConvertTo-Json -Depth 10 -Compress:$false
[System.IO.File]::WriteAllText($outFile, $json, [System.Text.UTF8Encoding]::new($false))

$withImage = ($sortedEntries | Where-Object image_url).Count

Write-Output "Wrote $outFile"
Write-Output "  Build:        $gameBuild"
Write-Output "  Total:        $($payload.total)"
Write-Output "  Images:       $withImage entries have a present image"
Write-Output "                $imgCopied copied from $FModelContent"
if ($missing.Count -gt 0) {
    Write-Output "  Missing images: $($missing.Count) (see $missingTxt)"
}
