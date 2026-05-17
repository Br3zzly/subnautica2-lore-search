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

# --- Item descriptions (UWEItemType) pass -----------------------------------
# Items go under a synthetic "Item Descriptions" root. When an item is the
# output of a crafting recipe, we use that recipe's category tree (e.g.
# "Fabricator / Sustenance / Cooked Food") so the in-app tree mirrors the
# in-game fabricator tabs. Items without a recipe (raw resources, creatures,
# deprecated, etc.) fall back to their source subfolder under Data/ItemType.

# Load the crafting category definitions so we can resolve a recipe's
# Category asset → display-name path.
$categoryDefs = @{}
$categoryRoot = Join-Path $FModelContent 'Data\CraftingRecipes\Categories'
if (Test-Path $categoryRoot) {
    foreach ($cf in Get-ChildItem -Path $categoryRoot -Recurse -Filter *.json -File) {
        try {
            $cjson = [System.IO.File]::ReadAllText($cf.FullName) | ConvertFrom-Json
        } catch { continue }
        foreach ($co in $cjson) {
            if ($co.Type -ne 'UWECraftingRecipeCategory') { continue }
            $parent = $null
            if ($co.Properties.PSObject.Properties['ParentCategory'] -and
                $co.Properties.ParentCategory -and
                $co.Properties.ParentCategory.AssetPathName) {
                $parent = ($co.Properties.ParentCategory.AssetPathName -split '\.')[-1]
            }
            $display = Get-Text $co.Properties.Name
            if (-not $display) { $display = $co.Name }
            $categoryDefs[$co.Name] = @{ Display = $display; Parent = $parent }
        }
    }
}

function Get-RecipeCategoryPath($name) {
    if (-not $name -or -not $categoryDefs.ContainsKey($name)) { return @() }
    $path = @($categoryDefs[$name].Display)
    $p = $categoryDefs[$name].Parent
    $guard = 0
    while ($p -and $categoryDefs.ContainsKey($p) -and $guard -lt 16) {
        $path = ,$categoryDefs[$p].Display + $path
        $p = $categoryDefs[$p].Parent
        $guard++
    }
    return ,$path
}

# Build ItemType-asset-name → recipe-category-asset-name. An item that is
# the Output of any recipe inherits that recipe's Category. First match wins.
$itemToRecipeCategory = @{}
$recipeRoot = Join-Path $FModelContent 'Data\CraftingRecipes'
if (Test-Path $recipeRoot) {
    $recipeFiles = Get-ChildItem -Path $recipeRoot -Recurse -Filter *.json -File |
        Where-Object { $_.FullName -notmatch '[\\/]Categories[\\/]' }
    foreach ($rf in $recipeFiles) {
        try {
            $rraw = [System.IO.File]::ReadAllText($rf.FullName)
        } catch { continue }
        if (-not $rraw.Contains('UWECraftingRecipe')) { continue }
        try { $rjson = $rraw | ConvertFrom-Json } catch { continue }
        foreach ($ro in $rjson) {
            if ($ro.Type -ne 'UWECraftingRecipe') { continue }
            $cat = $null
            if ($ro.Properties.PSObject.Properties['Category'] -and
                $ro.Properties.Category -and
                $ro.Properties.Category.AssetPathName) {
                $cat = ($ro.Properties.Category.AssetPathName -split '\.')[-1]
            }
            if (-not $cat) { continue }
            if (-not ($ro.Properties.PSObject.Properties['Output'] -and $ro.Properties.Output)) { continue }
            foreach ($out in $ro.Properties.Output) {
                if (-not ($out.ItemType -and $out.ItemType.AssetPathName)) { continue }
                $itemName = ($out.ItemType.AssetPathName -split '\.')[-1]
                if ($itemName -and -not $itemToRecipeCategory.ContainsKey($itemName)) {
                    $itemToRecipeCategory[$itemName] = $cat
                }
            }
        }
    }
}

# Released ItemTypes live under Data\ItemType; anything else is a prototype
# (same convention as databank entries).
$itemReleasedRoot = Join-Path $FModelContent 'Data\ItemType'

foreach ($f in $files) {
    try {
        $raw = [System.IO.File]::ReadAllText($f.FullName)
    } catch { continue }
    if (-not $raw.Contains('UWEItemType')) { continue }
    try { $json = $raw | ConvertFrom-Json } catch { continue }

    $entry = $json | Where-Object { $_.Type -eq 'UWEItemType' } | Select-Object -First 1
    if (-not $entry) { continue }
    $p = $entry.Properties
    if (-not $p) { continue }

    $title = $null
    if ($p.PSObject.Properties['Name']) { $title = Get-Text $p.Name }
    if (-not $title) { $title = $entry.Name }

    $body = ''
    if ($p.PSObject.Properties['ItemDescription']) {
        $t = Get-Text $p.ItemDescription
        if ($t) { $body = $t }
    }

    $isReleasedItem = $f.FullName.StartsWith($itemReleasedRoot, [System.StringComparison]::OrdinalIgnoreCase)

    # Path of the file relative to whichever root applies, used both for the
    # subfolder field (UI breadcrumb) and as a fallback category source.
    if ($isReleasedItem) {
        $rel = $f.FullName.Substring($itemReleasedRoot.Length).TrimStart('\','/')
    } else {
        $rel = $f.FullName.Substring($FModelContent.Length).TrimStart('\','/')
    }
    $parts = $rel -split '[\\/]'
    $subfolderParts = @()
    if ($parts.Count -gt 1) { $subfolderParts = @($parts[0..($parts.Count - 2)]) }

    # Categories chain. Starts with "Item Descriptions"; gets either the
    # recipe category path (if this item is crafted) or the source subfolder
    # path. Released-and-not-crafted items at the root of Data/ItemType land
    # in a synthetic "Uncategorized" bucket so they aren't bare leaves.
    $itemCats = @('Item Descriptions')
    $recipeCat = $itemToRecipeCategory[$entry.Name]
    if ($isReleasedItem -and $recipeCat) {
        $itemCats += (Get-RecipeCategoryPath $recipeCat)
    } elseif ($subfolderParts.Count -gt 0) {
        $itemCats += $subfolderParts
    } elseif ($isReleasedItem) {
        $itemCats += 'Uncategorized'
    }
    if (-not $isReleasedItem) {
        $itemCats = @('Prototypes (DEV/WIP Content - not ingame)') + $itemCats
    }

    $subfolder = if ($subfolderParts.Count -gt 0) { $subfolderParts -join '/' } else { 'General' }
    if (-not $isReleasedItem) { $subfolder = "Prototypes/$subfolder" }
    $parentFolder = if ($subfolderParts.Count -gt 0) { $subfolderParts[-1] } else { '' }

    # Thumbnail.AssetPathName → relative texture path under docs/images/.
    $imageRel = $null
    if ($p.PSObject.Properties['Thumbnail'] -and $p.Thumbnail -and
        $p.Thumbnail.PSObject.Properties['AssetPathName']) {
        $imageRel = Convert-AssetPathToRelative $p.Thumbnail.AssetPathName
    }

    $entries.Add([PSCustomObject]@{
        id           = $entry.Name
        subfolder    = $subfolder
        parentFolder = $parentFolder
        title        = $title
        categories   = $itemCats
        body         = $body
        imageRel     = $imageRel
    }) | Out-Null
}

# --- Logs (UWEDialogueSequence audiologs) pass ------------------------------
# Audiolog dialogue files under Data/Narrative/Dialogue/**/Audiolog*_Dialogue
# back the in-game "Log" tab. Each file is a sequence of speaker-attributed
# spoken lines. We flatten the sequence into one entry per file under a
# synthetic "Logs" root, grouped by area (Coral Gardens / Ruins / Other).

# Speaker cache: SpeakingCharacters/DA_Character_<x>.json → display name.
$speakerNames = @{}
$speakerRoot = Join-Path $FModelContent 'Data\Narrative\Dialogue\SpeakingCharacters'
if (Test-Path $speakerRoot) {
    foreach ($sf in Get-ChildItem -Path $speakerRoot -Recurse -Filter *.json -File) {
        try {
            $sjson = [System.IO.File]::ReadAllText($sf.FullName) | ConvertFrom-Json
        } catch { continue }
        foreach ($so in $sjson) {
            if ($so.Type -ne 'UWEDialogueSpeakingCharacter') { continue }
            $displayName = Get-Text $so.Properties.Name
            if (-not $displayName) { $displayName = $so.Name -replace '^DA_Character_','' }
            $speakerNames[$so.Name] = $displayName
        }
    }
}

# StringTable cache. Built per-table because:
#   1) PowerShell's default Hashtable is case-insensitive, but the source data
#      uses BOTH "Audiolog_title" and "Audiolog_Title" (capital T, per-POI
#      tables) as distinct conventions, so we use a case-sensitive Dictionary.
#   2) The generic key "Audiolog_Title" appears in ~11 per-POI tables with a
#      different value in each one. A flat global title index would collide.
# Lookup strategy: first try the audiolog's own primary table (the one its
# first line's TableId points at). Fall back to an "unambiguous global" sweep
# (only used when exactly one table has the key), which handles the few cases
# where titles live in a different table from their lines (e.g. Twins:
# lines in ST_Databank_Audiologs_splits, title in ST_Databank_Audiologs).
$tablesByName = @{}
$strTablesRoot = Join-Path $FModelContent 'StringTables'
if (Test-Path $strTablesRoot) {
    foreach ($tf in Get-ChildItem -Path $strTablesRoot -Recurse -Filter *.json -File) {
        try {
            $tj = [System.IO.File]::ReadAllText($tf.FullName) | ConvertFrom-Json
        } catch { continue }
        foreach ($to in $tj) {
            if ($to.Type -ne 'StringTable') { continue }
            if (-not $to.StringTable -or -not $to.StringTable.KeysToEntries) { continue }
            $d = New-Object 'System.Collections.Generic.Dictionary[String,String]' ([System.StringComparer]::Ordinal)
            foreach ($prop in $to.StringTable.KeysToEntries.PSObject.Properties) {
                $d[$prop.Name] = [string]$prop.Value
            }
            $tablesByName[$to.Name] = $d
        }
    }
}

function Try-TitleInTable {
    param($table, [string]$base)
    if (-not $table -or -not $base) { return $null }
    foreach ($suffix in @('_Title', '_title')) {
        $k = $base + $suffix
        if ($table.ContainsKey($k)) { return $table[$k] }
    }
    return $null
}

# Derive candidate base names from the first line's StringTable key. Observed
# in the wild:
#   "Ruby_TadpoleOps_Line3"  → "Ruby_TadpoleOps"   (+ "_Title" / "_title")
#   "Twins_Line1"            → "Twins"             (title in a sibling table)
#   "Exodus_6_01_Ganz"       → "Exodus_6"
#   "Audiolog_1"             → "Audiolog"          (per-POI tables)
#   "Kurultai8_1_Sophie"     → no title key exists; falls back to humanized name
function Get-AudiologTitle {
    param([string]$lineKey, [string]$lineTableId, [string]$assetName)

    $candidates = New-Object System.Collections.Generic.List[string]
    if ($lineKey) {
        $candidates.Add($lineKey) | Out-Null
        foreach ($v in @(
            ($lineKey -replace '_Line\d+$', ''),
            ($lineKey -replace '_\d+_[A-Za-z]+$', ''),
            ($lineKey -replace '_\d+$', '')
        )) {
            if ($v -and $v -ne $lineKey -and -not $candidates.Contains($v)) {
                $candidates.Add($v) | Out-Null
            }
        }
    }

    # Same-table lookup first. Most reliable; resolves the Audiolog_Title
    # collision case (each per-POI table has its own).
    $primaryTable = $null
    if ($lineTableId) {
        $primaryName = ($lineTableId -split '\.')[-1]
        if ($tablesByName.ContainsKey($primaryName)) {
            $primaryTable = $tablesByName[$primaryName]
        }
    }
    foreach ($c in $candidates) {
        $hit = Try-TitleInTable $primaryTable $c
        if ($hit) { return $hit }
    }

    # Global fallback, but only when exactly one table has the key. Otherwise
    # we can't tell which value to use, and falling back to a humanized name
    # is safer than picking arbitrarily.
    foreach ($c in $candidates) {
        foreach ($suffix in @('_Title', '_title')) {
            $k = $c + $suffix
            $hitVal = $null
            $count = 0
            foreach ($t in $tablesByName.Values) {
                if ($t.ContainsKey($k)) {
                    $hitVal = $t[$k]
                    $count++
                    if ($count -gt 1) { break }
                }
            }
            if ($count -eq 1) { return $hitVal }
        }
    }

    # Humanized fallback: strip wrapper suffixes, area prefix, and underscores.
    $t = $assetName -replace '^DA_', '' `
                    -replace '_Audiolog_Dialogue$', '' `
                    -replace '_Dialogue$', '' `
                    -replace '_Audiolog$', '' `
                    -replace '^CoralGardens_', '' `
                    -replace '^Ruins_', '' `
                    -replace '_', ' '
    return $t
}

# Build a "rendered" view of a dialogue sequence — body (one speaker-prefixed
# paragraph per line) plus the first line's StringTable Key/TableId (used by
# Get-AudiologTitle). Returns $null if the sequence yields no usable lines.
function Get-DialogueRender {
    param($seqProps)
    if (-not $seqProps -or -not $seqProps.Lines) { return $null }
    $bodyLines  = @()
    $firstKey   = $null
    $firstTable = $null
    foreach ($ln in $seqProps.Lines) {
        $text = Get-Text $ln.SpokenText
        if (-not $text) { continue }
        $speakerName = $null
        if ($ln.Speaker -and $ln.Speaker.AssetPathName) {
            $speakerAsset = ($ln.Speaker.AssetPathName -split '\.')[-1]
            if ($speakerNames.ContainsKey($speakerAsset)) {
                $speakerName = $speakerNames[$speakerAsset]
            } else {
                $speakerName = $speakerAsset -replace '^DA_Character_', ''
            }
        }
        if ($speakerName) {
            $bodyLines += "${speakerName}: $text"
        } else {
            $bodyLines += $text
        }
        if (-not $firstKey -and $ln.SpokenText -and $ln.SpokenText.Key) {
            $firstKey   = $ln.SpokenText.Key
            $firstTable = $ln.SpokenText.TableId
        }
    }
    if ($bodyLines.Count -eq 0) { return $null }
    return [PSCustomObject]@{
        Body       = $bodyLines -join "`r`n`r`n"
        FirstKey   = $firstKey
        FirstTable = $firstTable
    }
}

# Pre-parse every UWEDialogueSequence file once and cache (path, name, render).
# Used by both the curated Logs pass and the catch-all Dialogs pass below so
# we don't read+parse the same 700+ files twice.
#
# Identifier note: we use the file's basename (e.g. "DA_Foo_Dialogue") rather
# than the inner $seq.Name as the canonical asset name. For typical hand-named
# sequences they match, but ~15 "Random selector" dialogues have anonymous
# auto-generated names like "UWEDialogueSequence_0" that collide across files.
# The file basename is always unique per file.
$dialogueRoot = Join-Path $FModelContent 'Data\Narrative\Dialogue'
$dataRoot     = Join-Path $FModelContent 'Data'

$parsedDialogues = New-Object System.Collections.Generic.List[object]
foreach ($f in $files) {
    try { $raw = [System.IO.File]::ReadAllText($f.FullName) } catch { continue }
    if (-not $raw.Contains('UWEDialogueSequence')) { continue }
    try { $json = $raw | ConvertFrom-Json } catch { continue }
    $seq = $json | Where-Object { $_.Type -eq 'UWEDialogueSequence' } | Select-Object -First 1
    if (-not $seq) { continue }
    $render = Get-DialogueRender $seq.Properties
    if (-not $render) { continue }
    $parsedDialogues.Add([PSCustomObject]@{
        File     = $f
        AssetId  = $f.BaseName
        Render   = $render
        IsInData = $f.FullName.StartsWith($dataRoot, [System.StringComparison]::OrdinalIgnoreCase)
    }) | Out-Null
}

# --- Logs pass (curated) ----------------------------------------------------
# Two source subsets feed the in-game Log tab:
#   1) Audiologs: `*Audiolog*_Dialogue` under Data/Narrative/Dialogue/. Area
#      sub-bucket is derived from the top-level folder (Coral Gardens / Ruins
#      / Other).
#   2) Blackboxes: `*Blackbox*` files (but NOT *BlackBoxScan* — those are
#      BrokenPDA scan reactions, not actual recordings). Grouped together
#      under "Black Boxes" regardless of source folder.
foreach ($pd in $parsedDialogues) {
    $f = $pd.File
    if (-not $f.FullName.StartsWith($dialogueRoot, [System.StringComparison]::OrdinalIgnoreCase)) { continue }

    $isAudiolog = $f.Name -match 'Audiolog.*_Dialogue.*\.json$'
    $isBlackbox = ($f.Name -match 'Blackbox') -and ($f.Name -notmatch 'BlackBoxScan')
    if (-not ($isAudiolog -or $isBlackbox)) { continue }

    $title = Get-AudiologTitle $pd.Render.FirstKey $pd.Render.FirstTable $pd.AssetId

    if ($isAudiolog) {
        # Area = top-level folder under Data/Narrative/Dialogue.
        $rel   = $f.FullName.Substring($dialogueRoot.Length).TrimStart('\','/')
        $parts = $rel -split '[\\/]'
        if ($parts.Count -gt 1) {
            $top = $parts[0]
            switch ($top) {
                'CoralGardens' { $area = 'Coral Gardens' }
                'Ruins'        { $area = 'Ruins' }
                default        { $area = $top }
            }
        } else {
            $area = 'Other'
        }
        $cats = @('Logs', $area)
        $subfolderParts = @()
        if ($parts.Count -gt 1) { $subfolderParts = @($parts[0..($parts.Count - 2)]) }
        $subfolder    = if ($subfolderParts.Count -gt 0) { 'Logs/' + ($subfolderParts -join '/') } else { 'Logs' }
        $parentFolder = if ($subfolderParts.Count -gt 0) { $subfolderParts[-1] } else { '' }
    } else {
        # Blackboxes: single flat bucket.
        $cats         = @('Logs', 'Black Boxes')
        $subfolder    = 'Logs/Black Boxes'
        $parentFolder = 'Black Boxes'
    }

    $entries.Add([PSCustomObject]@{
        id           = $pd.AssetId
        subfolder    = $subfolder
        parentFolder = $parentFolder
        title        = $title
        categories   = $cats
        body         = $pd.Render.Body
        imageRel     = $null
    }) | Out-Null
}

# Title collision pass for Logs only. A handful of stub audiologs reuse a
# single line from another audiolog's content (e.g. Jubilee0/Jubilee1 only
# contain one line borrowed from Exodus_2), which means they legitimately
# resolve to the same _Title in the source data. Disambiguate by suffixing
# the humanized asset name so each tree leaf is distinguishable.
$logEntries = $entries | Where-Object { $_.categories -and $_.categories[0] -eq 'Logs' }
$titleGroups = $logEntries | Group-Object title | Where-Object { $_.Count -gt 1 }
foreach ($g in $titleGroups) {
    foreach ($e in $g.Group) {
        $shortName = $e.id -replace '^DA_', '' `
                           -replace '_Audiolog_Dialogue$', '' `
                           -replace '_Dialogue$', '' `
                           -replace '^CoralGardens_', '' `
                           -replace '^Ruins_', '' `
                           -replace '_', ' '
        $e.title = "$($e.title) ($shortName)"
    }
}

# --- Dialogs pass (catch-all) -----------------------------------------------
# Every UWEDialogueSequence in the entire Content tree gets an entry under a
# "Dialogs" root, so the site is a complete reference for every spoken line —
# not just the curated Logs set. Anything outside Data/ is grouped under the
# Prototypes root the same way Databank and Item entries are.
#
# Sub-tree derivation:
#   - Under Data/Narrative/Dialogue/: use the relative folder path after the
#     dialogue root. Root-level files (no subfolder) are bucketed by filename
#     prefix to avoid 287 flat leaves — DA_Dialogue_<X>_* → "Dialogue / <X>",
#     DA_<X>_* → "<X>", with X taken from the asset name.
#   - Under Data/ but outside Dialogue/: relative path from Data/.
#   - Outside Data/: relative path from Content/, under the Prototypes root.
#
# IDs are prefixed with "dlg_" so the same audiolog file can live in both
# Logs and Dialogs without the ID dedup logic mangling either copy.
function Get-RootDialogBucket {
    param([string]$assetName)
    $n = $assetName -replace '^DA_', ''
    $parts = $n -split '_'
    if ($parts.Count -eq 0 -or -not $parts[0]) { return @() }
    # DA_Dialogue_<X>_* → ["Dialogue", "<X>"], else just first segment.
    if ($parts[0] -eq 'Dialogue' -and $parts.Count -ge 2 -and $parts[1]) {
        return @('Dialogue', $parts[1])
    }
    return @($parts[0])
}

foreach ($pd in $parsedDialogues) {
    $f = $pd.File
    $rel = $f.FullName.Substring($FModelContent.Length).TrimStart('\','/')
    $parts = $rel -split '[\\/]'

    if ($pd.IsInData) {
        $cats = @('Dialogs')
        if ($f.FullName.StartsWith($dialogueRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            # Strip "Data\Narrative\Dialogue\" prefix.
            $dialogRel   = $f.FullName.Substring($dialogueRoot.Length).TrimStart('\','/')
            $dialogParts = $dialogRel -split '[\\/]'
            if ($dialogParts.Count -gt 1) {
                $cats += @($dialogParts[0..($dialogParts.Count - 2)])
            } else {
                # Root-level: bucket by filename prefix.
                $cats += (Get-RootDialogBucket $pd.AssetId)
            }
        } else {
            # Other Data/ subtree — use everything after "Data\".
            if ($parts.Count -gt 2) { $cats += @($parts[1..($parts.Count - 2)]) }
        }
    } else {
        # Prototype: outside Data/. Tag with the Prototypes root then folder chain.
        $cats = @('Prototypes (DEV/WIP Content - not ingame)', 'Dialogs')
        if ($parts.Count -gt 1) { $cats += @($parts[0..($parts.Count - 2)]) }
    }

    $subfolderParts = if ($parts.Count -gt 1) { @($parts[0..($parts.Count - 2)]) } else { @() }
    $subfolder = if ($subfolderParts.Count -gt 0) { 'Dialogs/' + ($subfolderParts -join '/') } else { 'Dialogs' }
    $parentFolder = if ($subfolderParts.Count -gt 0) { $subfolderParts[-1] } else { '' }

    # Title: try the StringTable _Title/_title machinery; fallback humanizes
    # the asset name (the same fallback Get-AudiologTitle uses).
    $title = Get-AudiologTitle $pd.Render.FirstKey $pd.Render.FirstTable $pd.AssetId

    $entries.Add([PSCustomObject]@{
        id           = 'dlg_' + $pd.AssetId
        subfolder    = $subfolder
        parentFolder = $parentFolder
        title        = $title
        categories   = $cats
        body         = $pd.Render.Body
        imageRel     = $null
    }) | Out-Null
}

# --- Axum Glyphs (SN2AxumGlyphDataAsset) pass -------------------------------
# Each file is a single logogram from the in-game Axum script: a Word FText
# (the glyph's meaning, e.g. "joy", "Karakorum"), a GlyphTexture (the actual
# rendered glyph PNG), and an UnlockRule (usually "scan the Rosetta Stone").
# Released glyphs live under Data/Narrative/AxumGlyphs/; the three Test/
# files use placeholder textures and get a "Test" subcategory. Anything
# outside Data/ goes under the Prototypes root (currently none, but the
# branch is here for forward-compat).
$glyphReleasedRoot = Join-Path $FModelContent 'Data\Narrative\AxumGlyphs'
$glyphTestRoot     = Join-Path $glyphReleasedRoot 'Test'

foreach ($f in $files) {
    try { $raw = [System.IO.File]::ReadAllText($f.FullName) } catch { continue }
    if (-not $raw.Contains('SN2AxumGlyphDataAsset')) { continue }
    try { $json = $raw | ConvertFrom-Json } catch { continue }

    $glyph = $json | Where-Object { $_.Type -eq 'SN2AxumGlyphDataAsset' } | Select-Object -First 1
    if (-not $glyph -or -not $glyph.Properties) { continue }
    $p = $glyph.Properties

    $word = Get-Text $p.Word
    if (-not $word) { $word = $glyph.Name }

    # Body: unlock requirement. Most glyphs unlock when you fully scan the
    # Observatory Rosetta Stone, so noting that is small but useful.
    $body = ''
    if ($p.UnlockRule -and $p.UnlockRule.EventAsset -and $p.UnlockRule.EventAsset.ObjectName) {
        $eventType  = if ($p.UnlockRule.EventType) {
            ($p.UnlockRule.EventType -replace '^ERecipeEventTypes::', '')
        } else { 'Unknown' }
        # ObjectName format: "UWEScanData'DA_Observatory_RosettaStone_ScanData'"
        $eventAsset = $p.UnlockRule.EventAsset.ObjectName -replace "^[^']+'", '' -replace "'$", ''
        $body = "Unlock: $eventType of $eventAsset"
    }

    $imageRel = $null
    if ($p.GlyphTexture -and $p.GlyphTexture.AssetPathName) {
        $imageRel = Convert-AssetPathToRelative $p.GlyphTexture.AssetPathName
    }

    # NOTE: assign $cats with explicit statements, not an `if`-expression.
    # PowerShell unwraps a single-element array when it's the value of a
    # conditional expression — `$x = if (…) { @('one') }` yields a string,
    # which then ConvertTo-Json serialises as a scalar instead of a 1-element
    # array. Same trap applies anywhere else we build a categories list.
    $isReleased = $f.FullName.StartsWith($dataRoot, [System.StringComparison]::OrdinalIgnoreCase)
    $isTest     = $f.FullName.StartsWith($glyphTestRoot, [System.StringComparison]::OrdinalIgnoreCase)
    if ($isReleased -and $isTest) {
        $cats = @('Axum Glyphs', 'Test')
    } elseif ($isReleased) {
        $cats = @('Axum Glyphs')
    } else {
        $cats = @('Prototypes (DEV/WIP Content - not ingame)', 'Axum Glyphs')
    }

    $rel   = $f.FullName.Substring($FModelContent.Length).TrimStart('\','/')
    $parts = $rel -split '[\\/]'
    $subfolderParts = if ($parts.Count -gt 1) { @($parts[0..($parts.Count - 2)]) } else { @() }
    $subfolder    = if ($subfolderParts.Count -gt 0) { 'Axum Glyphs/' + ($subfolderParts -join '/') } else { 'Axum Glyphs' }
    $parentFolder = if ($subfolderParts.Count -gt 0) { $subfolderParts[-1] } else { '' }

    $entries.Add([PSCustomObject]@{
        id           = $f.BaseName
        subfolder    = $subfolder
        parentFolder = $parentFolder
        title        = $word
        categories   = $cats
        body         = $body
        imageRel     = $imageRel
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
