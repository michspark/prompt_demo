# Builds data/demo-data.js for the demo page from the MusicPromptDescription repo.
# Usage (from the prompt_demo folder):
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\build_data.ps1 [-Src ..\MusicPromptDescription]
#
# Only song-level text is exported: Udio URL/title/prompt, prompt categories, similarity rank,
# and the free-text descriptions with their categories. Participant numbers and demographics
# are never written out.

param(
  [string]$Src = (Join-Path $PSScriptRoot '..\..\MusicPromptDescription')
)

$ErrorActionPreference = 'Stop'
$Src = (Resolve-Path $Src).Path
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$OutFile = Join-Path $Root 'data\demo-data.js'

# Category columns in the source CSVs, in the order used throughout the paper and the talk.
$CatCols = [ordered]@{
  g = 'genre'
  s = 'story/narrative/lyrics'
  i = 'instrumentation'
  m = 'mood/emotion'
  t = 'music theory'
  b = 'timbre'
  f = 'function'
}

function Get-Cats($row) {
  $o = [ordered]@{}
  foreach ($k in $CatCols.Keys) {
    $v = $row.($CatCols[$k])
    if ($v -and $v.Trim()) {
      $terms = @($v.Split('|') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
      if ($terms.Count) { $o[$k] = $terms }
    }
  }
  return $o
}

function Get-Uuid([string]$url) {
  if ($url -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') { return $Matches[1] }
  throw "No song UUID in '$url'"
}

function Read-Csv($rel) { Import-Csv -Path (Join-Path $Src $rel) -Encoding UTF8 }

Write-Host "Reading from $Src"
$sample   = Read-Csv 'data\udio_sample_data.csv'
$pcats    = Read-Csv 'data\udio_sample_categories.csv'
$ranked   = Read-Csv 'results\tables\prompt_description_similarity_ranked.csv'
$enRows   = Read-Csv 'data_717\english_717_categories.csv'
$koRows   = Read-Csv 'data_717\korean_717_categories.csv'
$showcase = Get-Content -Raw -Encoding UTF8 (Join-Path $PSScriptRoot 'showcase.json') | ConvertFrom-Json

$pcatById = @{}; foreach ($r in $pcats)  { $pcatById[(Get-Uuid $r.url)] = $r }
$rankById = @{}; foreach ($r in $ranked) { $rankById[$r.song_id] = $r }

function Group-Desc($rows) {
  $h = @{}
  foreach ($r in $rows) {
    $text = ($r.prompt -replace '\s+', ' ').Trim()
    if (-not $text) { continue }
    $d = [ordered]@{ t = $text }
    $c = Get-Cats $r
    if ($c.Count) { $d['c'] = $c }
    if (-not $h.ContainsKey($r.problem_hash)) { $h[$r.problem_hash] = New-Object System.Collections.ArrayList }
    [void]$h[$r.problem_hash].Add($d)
  }
  return $h
}
$enById = Group-Desc $enRows
$koById = Group-Desc $koRows

# Udio creator names, only for the showcase songs; anything that looks like an e-mail is dropped.
$showIds = @($showcase | ForEach-Object { $_.id })
$creatorById = @{}
Import-Csv -Path (Join-Path $Src 'data\casini_udio_data.csv') -Encoding UTF8 | ForEach-Object {
  if ($_.url -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') {
    $id20 = $Matches[1].Substring(0, 20)
    # Some scraped names carry the avatar initial on a first line ("S`nskybroken"); keep the last line.
    $name = @($_.creator -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })[-1]
    if ($showIds -contains $id20 -and $name -and $name -notmatch '@') { $creatorById[$id20] = $name }
  }
}

$songs = New-Object System.Collections.ArrayList
$nEn = 0; $nKo = 0
foreach ($r in $sample) {
  $uuid = Get-Uuid $r.url
  $id = $uuid.Substring(0, 20)
  $rk = $rankById[$id]
  if (-not $rk) { throw "No similarity rank for $id" }
  $en = $enById[$id]; $ko = $koById[$id]
  if (-not $en) { $en = @() }; if (-not $ko) { $ko = @() }
  $nEn += $en.Count; $nKo += $ko.Count
  $song = [ordered]@{
    id     = $id
    url    = "https://www.udio.com/songs/$uuid"
    title  = $r.title.Trim()
    prompt = ($r.prompt -replace '\s+', ' ').Trim()
    pc     = $(if ($pcatById[$uuid]) { Get-Cats $pcatById[$uuid] } else { [ordered]@{} })
    rank   = [int]$rk.rank
    sim    = [math]::Round([double]$rk.mean, 3)
    en     = @($en)
    ko     = @($ko)
  }
  if ($creatorById[$id]) { $song['creator'] = $creatorById[$id] }
  [void]$songs.Add($song)
}

# Validate the hand-written showcase file against the data.
foreach ($s in $showcase) {
  $song = $songs | Where-Object { $_.id -eq $s.id }
  if (-not $song) { throw "Showcase song $($s.id) not found" }
  if ($s.ko_tr.Count -ne $song.ko.Count) { throw "$($s.id): $($s.ko_tr.Count) translations for $($song.ko.Count) Korean descriptions" }
  foreach ($i in $s.en_pick) { if ($i -ge $song.en.Count) { throw "$($s.id): en_pick $i out of range" } }
  foreach ($i in $s.ko_pick) { if ($i -ge $song.ko.Count) { throw "$($s.id): ko_pick $i out of range" } }
  if ($song.rank -ne [int]($s.tag -replace '\D+(\d+).*', '$1')) { Write-Warning "$($s.id): tag '$($s.tag)' but rank is $($song.rank)" }
}

$data = [ordered]@{
  meta = [ordered]@{
    songs = $songs.Count; en = $nEn; ko = $nKo
    source = 'github.com/michspark/MusicPromptDescription (data_717)'
  }
  showcase = @($showcase)
  songs = @($songs)
}

$json = ConvertTo-Json -InputObject $data -Depth 12 -Compress
New-Item -ItemType Directory -Force -Path (Split-Path $OutFile) | Out-Null
$js = "// Generated by tools/build_data.ps1 - do not edit by hand.`nwindow.DEMO_DATA = $json;`n"
[System.IO.File]::WriteAllText($OutFile, $js, (New-Object System.Text.UTF8Encoding $false))

$kb = [math]::Round((Get-Item $OutFile).Length / 1KB)
Write-Host ("songs={0} en={1} ko={2} total={3} showcase={4} creators={5} -> {6} ({7} KB)" -f `
  $songs.Count, $nEn, $nKo, ($nEn + $nKo), $showcase.Count, $creatorById.Count, $OutFile, $kb)
if ($songs.Count -ne 200 -or $nEn -ne 1396 -or $nKo -ne 1228) { Write-Warning 'Counts differ from the camera-ready paper (200 / 1,396 / 1,228).' }
