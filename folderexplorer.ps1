param(
    [string]$Root,
    [int]$MaxDepth = 30,
    [int]$Port = 8765,
    [Alias("h", "help")]
    [switch]$ShowHelp
)

$ErrorActionPreference = "Stop"
$OutputDir = Join-Path $PSScriptRoot "analyzer"
$HtmlOutput = Join-Path $OutputDir "index.html"
$script:Items = [System.Collections.Generic.List[object]]::new()
$script:FileItems = [System.Collections.Generic.List[object]]::new()
$script:FoldersScanned = 0
$script:FilesScanned = 0L
$script:BytesScanned = 0L
$script:LastProgress = [datetime]::MinValue
$scanStarted = Get-Date

function Show-Usage {
    Write-Host @"
Drive Space Analyzer

Usage:
  .\folderexplorer.ps1
  .\folderexplorer.ps1 -Root <folder>
  .\folderexplorer.ps1 -Root <folder> [-MaxDepth <number>] [-Port <number>]
  .\folderexplorer.ps1 -h

Options:
  -Root       Folder to analyze. If omitted, an interactive menu is shown.
  -MaxDepth   Maximum folder depth to scan. Default: 30.
  -Port       Preferred localhost dashboard port. Default: 8765.
  -h, -Help   Display this help and exit.

Examples:
  .\folderexplorer.ps1 -Root "C:\Users\vpandey\AppData\Local"
  .\folderexplorer.ps1 -Root "C:\"
  .\folderexplorer.ps1 -Root "C:\Data" -MaxDepth 20 -Port 9000
"@
}

if ($ShowHelp) {
    Show-Usage
    return
}

function Select-ScanRoot {
    $defaultPath = Join-Path $env:LOCALAPPDATA ""

    Write-Host ""
    Write-Host "Select a folder to analyze:" -ForegroundColor Cyan
    Write-Host "  1. Local AppData: $defaultPath" -ForegroundColor Green
    Write-Host "  2. Entire C: drive (slower; run as Administrator for better coverage)"
    Write-Host "  3. Enter a custom folder path"
    Write-Host ""

    while ($true) {
        $selection = Read-Host "Choose 1, 2, or 3"

        switch ($selection) {
            "1" { return $defaultPath }
            "2" { return "C:\" }
            "3" {
                $customPath = Read-Host "Enter the full folder path"
                if (-not [string]::IsNullOrWhiteSpace($customPath)) {
                    return $customPath.Trim().Trim('"')
                }
                Write-Host "Please enter a folder path." -ForegroundColor Yellow
            }
            default {
                Write-Host "Invalid choice. Enter 1, 2, or 3." -ForegroundColor Yellow
            }
        }
    }
}

if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Select-ScanRoot
}

if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
    throw "The scan path does not exist or is not a folder: $Root"
}

$Root = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
if ($Root -match '^[A-Za-z]:$') {
    $Root += "\"
}

$excludedNames = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)
[void]$excludedNames.Add('$Recycle.Bin')
[void]$excludedNames.Add('System Volume Information')

function Format-Size {
    param([long]$Bytes)

    if ($Bytes -ge 1TB) { return "{0:N2} TB" -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N1} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N1} KB" -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Show-ScanProgress {
    param([string]$Path)

    $now = Get-Date
    if (($now - $script:LastProgress).TotalMilliseconds -lt 250) {
        return
    }

    $script:LastProgress = $now
    $elapsed = $now - $scanStarted
    $status = "Folders: {0:N0} | Files: {1:N0} | Found: {2} | Time: {3:hh\:mm\:ss}" -f `
        $script:FoldersScanned, $script:FilesScanned, (Format-Size $script:BytesScanned), $elapsed

    Write-Progress -Activity "Analyzing $Root" -Status $status -CurrentOperation $Path
}

function Scan-Folder {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [int]$Depth
    )

    $directSize = 0L
    $directFiles = 0L
    $totalSize = 0L
    $totalFiles = 0L
    $accessDenied = $false

    Show-ScanProgress -Path $Path

    try {
        $children = Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop
    }
    catch {
        $children = @()
        $accessDenied = $true
    }

    foreach ($child in $children) {
        if ($child.PSIsContainer) {
            if ($Depth -ge $MaxDepth -or
                $excludedNames.Contains($child.Name) -or
                ($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                continue
            }

            $childTotal = Scan-Folder -Path $child.FullName -Depth ($Depth + 1)
            $totalSize += $childTotal.Size
            $totalFiles += $childTotal.Files
        }
        else {
            $directSize += [long]$child.Length
            $directFiles++
            $script:FileItems.Add([pscustomobject]@{
                Kind         = "File"
                Path         = $child.FullName
                Parent       = $Path
                Name         = $child.Name
                Size         = [long]$child.Length
                Files        = 0
                LastModified = $child.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
            })
        }
    }

    $totalSize += $directSize
    $totalFiles += $directFiles
    $script:FoldersScanned++
    $script:FilesScanned += $directFiles
    $script:BytesScanned += $directSize

    $name = Split-Path -Path $Path -Leaf
    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = $Path
    }

    $parent = Split-Path -Path $Path -Parent
    if ([string]::IsNullOrWhiteSpace($parent) -and $Path -ne $Root) {
        $parent = $Root
    }

    $script:Items.Add([pscustomobject]@{
        Kind         = "Folder"
        Path         = $Path
        Parent       = $parent
        Name         = $name
        Size         = $totalSize
        Files        = $totalFiles
        DirectSize   = $directSize
        DirectFiles  = $directFiles
        Depth        = $Depth
        AccessDenied = $accessDenied
    })

    return [pscustomobject]@{
        Size  = $totalSize
        Files = $totalFiles
    }
}

function Test-ProtectedPath {
    param([string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $rootPath = $Root.TrimEnd('\')

    if ($fullPath.Equals($rootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    $protectedRoots = @(
        "$env:SystemDrive\Windows",
        "$env:SystemDrive\Program Files",
        "$env:SystemDrive\Program Files (x86)",
        "$env:SystemDrive\ProgramData",
        "$env:SystemDrive\Recovery",
        "$env:SystemDrive\Users"
    )

    foreach ($protected in $protectedRoots) {
        $protectedPrefix = $protected.TrimEnd('\') + "\"
        if ($fullPath.Equals($protected, [System.StringComparison]::OrdinalIgnoreCase) -or
            $fullPath.StartsWith($protectedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Send-JsonResponse {
    param(
        [Parameter(Mandatory)]$Context,
        [int]$StatusCode,
        [Parameter(Mandatory)]$Body
    )

    $json = $Body | ConvertTo-Json -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $Context.Response.StatusCode = $StatusCode
    $Context.Response.ContentType = "application/json; charset=utf-8"
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.Close()
}

Write-Host ""
Write-Host "C: Drive Analyzer" -ForegroundColor Cyan
Write-Host "Scanning $Root. Press Ctrl+C to stop." -ForegroundColor Yellow
Write-Host ""

$rootTotal = Scan-Folder -Path $Root -Depth 0
Write-Progress -Activity "Analyzing $Root" -Completed

$scanElapsed = (Get-Date) - $scanStarted
Write-Host ("Scan complete: {0:N0} folders, {1:N0} files, {2}, {3:hh\:mm\:ss}" -f `
    $script:FoldersScanned, $script:FilesScanned, (Format-Size $rootTotal.Size), $scanElapsed) -ForegroundColor Green
Write-Host "Building dashboard..." -ForegroundColor Cyan

function ConvertTo-JsonArray {
    param([System.Collections.ICollection]$Collection)

    if ($Collection.Count -eq 0) {
        return "[]"
    }

    $serialized = $Collection | ConvertTo-Json -Depth 5 -Compress
    if ($Collection.Count -eq 1) {
        return "[$serialized]"
    }
    return $serialized
}

$json = ConvertTo-JsonArray -Collection $script:Items
$filesJson = ConvertTo-JsonArray -Collection $script:FileItems
$rootJson = $Root | ConvertTo-Json -Compress

$html = @'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Drive Space Analyzer</title>
<style>
:root{color-scheme:dark;--bg:#0d1117;--panel:#161b22;--line:#30363d;--muted:#8b949e;--text:#e6edf3;--blue:#58a6ff;--red:#f85149;--amber:#d29922;--green:#3fb950}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:14px system-ui,Segoe UI,sans-serif}
header{padding:22px 28px;background:var(--panel);border-bottom:1px solid var(--line)}h1{margin:0 0 5px;font-size:25px}.muted{color:var(--muted)}
.toolbar{position:sticky;top:0;z-index:2;display:flex;gap:9px;flex-wrap:wrap;padding:14px 28px;background:#0d1117ee;border-bottom:1px solid var(--line);backdrop-filter:blur(8px)}
input,button{border:1px solid var(--line);border-radius:7px;background:#21262d;color:var(--text);padding:9px 12px}input{flex:1;min-width:260px}button{cursor:pointer}button:hover{border-color:var(--blue)}button.danger{color:#ffb3ad;border-color:#6e2b28}button.danger:hover{background:#3d1d1b}
main{max-width:1500px;margin:auto;padding:22px 28px}.crumbs{margin:0 0 16px}.crumbs button{padding:3px 7px;background:transparent;border:0;color:var(--blue)}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(175px,1fr));gap:12px;margin-bottom:18px}.card{padding:16px;background:var(--panel);border:1px solid var(--line);border-radius:8px}.label{font-size:12px;color:var(--muted);text-transform:uppercase}.value{font-size:23px;font-weight:650;margin-top:5px}
.notice{padding:12px 14px;margin-bottom:16px;border-left:3px solid var(--amber);background:#2b2111}.table-wrap{overflow:auto;border:1px solid var(--line);border-radius:8px}
table{width:100%;border-collapse:collapse;background:var(--panel)}th,td{padding:11px 12px;border-bottom:1px solid #252b33;text-align:left;white-space:nowrap}th{position:sticky;top:0;background:#1c2128;color:var(--muted);font-size:12px;text-transform:uppercase}tr:hover{background:#1c2128}
.folder{color:var(--blue);font-weight:600;cursor:pointer}.file{color:var(--text)}.item-icon{display:inline-block;width:22px;text-align:center}.path{max-width:470px;overflow:hidden;text-overflow:ellipsis;color:var(--muted)}.bar-bg{width:160px;height:8px;background:#30363d;border-radius:5px;overflow:hidden}.bar{height:100%;background:var(--blue)}
.badge{padding:3px 7px;border-radius:20px;font-size:11px}.safe{color:#7ee787;background:#16351f}.caution{color:#e3b341;background:#3b2e12}.protected{color:#ff7b72;background:#3d1d1b}.empty{text-align:center;padding:35px;color:var(--muted)}
.toast{position:fixed;right:22px;bottom:22px;max-width:430px;padding:13px 16px;border:1px solid var(--line);border-radius:8px;background:#21262d;box-shadow:0 8px 30px #0008;display:none}
@media(max-width:800px){header,.toolbar,main{padding-left:14px;padding-right:14px}.optional{display:none}}
</style>
</head>
<body>
<header><h1>Drive Space Analyzer</h1><div class="muted">Navigate folders, identify cleanup candidates, and move unwanted folders to the Recycle Bin.</div></header>
<div class="toolbar">
  <input id="search" type="search" placeholder="Search all scanned folders and files..." autocomplete="off">
  <button id="home">Root</button>
  <button id="up">Up</button>
  <button id="sort">Size: largest first</button>
  <button id="stopServer" class="danger">Stop server</button>
</div>
<main>
  <div id="crumbs" class="crumbs"></div>
  <div id="cards" class="cards"></div>
  <div class="notice"><strong>Deletion safety:</strong> deletion moves a folder or file to the Windows Recycle Bin. Windows and other critical locations are blocked. Review every path before confirming.</div>
  <div class="table-wrap"><table>
    <thead><tr><th>Folder / File</th><th>Size</th><th>Relative</th><th>Files below</th><th class="optional">Modified</th><th>Guidance</th><th class="optional">Path</th><th>Action</th></tr></thead>
    <tbody id="rows"></tbody>
  </table></div>
</main>
<div id="toast" class="toast"></div>
<script>
const DATA = __DATA__;
const FILES = __FILES__;
const ROOT = __ROOT__;
let current = ROOT;
let descending = true;

const byPath = new Map(DATA.map(x => [key(x.Path), x]));
const fileByPath = new Map(FILES.map(x => [key(x.Path), x]));
const children = new Map();
const filesByParent = new Map();
for (const item of DATA) {
  const parentKey = key(item.Parent || "");
  if (!children.has(parentKey)) children.set(parentKey, []);
  children.get(parentKey).push(item);
}
for (const item of FILES) {
  const parentKey = key(item.Parent || "");
  if (!filesByParent.has(parentKey)) filesByParent.set(parentKey, []);
  filesByParent.get(parentKey).push(item);
}

function key(path){return String(path || "").replace(/[\\]+$/,"").toLowerCase()}
function formatSize(bytes){
  const units=["B","KB","MB","GB","TB"]; let value=Number(bytes)||0, unit=0;
  while(value>=1024&&unit<units.length-1){value/=1024;unit++}
  return `${value.toFixed(unit<2?1:2)} ${units[unit]}`;
}
function escapeHtml(value){return String(value).replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]))}
function guidance(path){
  const p=path.toLowerCase();
  if (/\\windows(?:\\|$)|\\program files(?: \(x86\))?(?:\\|$)|\\programdata(?:\\|$)|\\recovery(?:\\|$)/.test(p))
    return {label:"Protected",className:"protected",text:"Application or Windows data. Do not delete manually."};
  if (/\\(temp|tmp|cache|caches|logs?|crashdumps?|node_modules|\.gradle|\.m2\\repository)(?:\\|$)/.test(p))
    return {label:"Review",className:"safe",text:"Often reclaimable, but verify the folder contents first."};
  return {label:"Caution",className:"caution",text:"Purpose is unknown. Open and inspect before deleting."};
}
function isBlocked(path){
  const p=key(path), root=key(ROOT);
  if(p===root) return true;
  return [/^[a-z]:\\windows(?:\\|$)/,/^[a-z]:\\program files(?: \(x86\))?(?:\\|$)/,/^[a-z]:\\programdata(?:\\|$)/,/^[a-z]:\\recovery(?:\\|$)/,/^[a-z]:\\users$/].some(r=>r.test(p));
}
function visibleItems(){
  const query=document.getElementById("search").value.trim().toLowerCase();
  const list=query
    ? [...DATA,...FILES].filter(x=>x.Path.toLowerCase().includes(query))
    : [...(children.get(key(current))||[]),...(filesByParent.get(key(current))||[])];
  return list.sort((a,b)=>descending?b.Size-a.Size:a.Size-b.Size);
}
function renderCrumbs(){
  const parts=current.replace(/[\\]+$/,"").split("\\");
  let html="", built=parts[0]+"\\";
  html+=`<button data-path="${escapeHtml(built)}">${escapeHtml(parts[0])}\\</button>`;
  for(let i=1;i<parts.length;i++){built+=(built.endsWith("\\")?"":"\\")+parts[i];html+=` / <button data-path="${escapeHtml(built)}">${escapeHtml(parts[i])}</button>`}
  document.getElementById("crumbs").innerHTML=html;
}
function render(){
  const list=visibleItems(), currentItem=byPath.get(key(current));
  const displayedSize=list.reduce((n,x)=>n+x.Size,0);
  const shownFolders=list.filter(x=>x.Kind==="Folder").length;
  const shownFiles=list.filter(x=>x.Kind==="File").length;
  document.getElementById("cards").innerHTML=`
    <div class="card"><div class="label">Current folder</div><div class="value">${formatSize(currentItem?.Size||displayedSize)}</div></div>
    <div class="card"><div class="label">Folders shown</div><div class="value">${shownFolders.toLocaleString()}</div></div>
    <div class="card"><div class="label">Files shown</div><div class="value">${shownFiles.toLocaleString()}</div></div>
    <div class="card"><div class="label">Files below current folder</div><div class="value">${(currentItem?.Files||0).toLocaleString()}</div></div>
    <div class="card"><div class="label">Direct files here</div><div class="value">${formatSize(currentItem?.DirectSize||0)}</div></div>`;
  renderCrumbs();
  const max=Math.max(1,...list.map(x=>x.Size));
  document.getElementById("rows").innerHTML=list.length?list.map(item=>{
    const guide=guidance(item.Path), blocked=isBlocked(item.Path), pct=Math.max(1,item.Size/max*100);
    const isFolder=item.Kind==="Folder";
    const name=isFolder
      ? `<span class="folder" data-path="${escapeHtml(item.Path)}"><span class="item-icon">&#128193;</span>${escapeHtml(item.Name)}</span>${item.AccessDenied?' <span title="Some content could not be read">!</span>':''}`
      : `<span class="file"><span class="item-icon">&#128196;</span>${escapeHtml(item.Name)}</span>`;
    return `<tr>
      <td>${name}</td>
      <td>${formatSize(item.Size)}</td><td><div class="bar-bg"><div class="bar" style="width:${pct}%"></div></div></td>
      <td>${isFolder?item.Files.toLocaleString():"-"}</td>
      <td class="optional">${escapeHtml(item.LastModified||"-")}</td>
      <td title="${escapeHtml(guide.text)}"><span class="badge ${guide.className}">${guide.label}</span></td>
      <td class="path optional" title="${escapeHtml(item.Path)}">${escapeHtml(item.Path)}</td>
      <td>${blocked?'<span class="muted">Blocked</span>':`<button class="danger" data-delete="${escapeHtml(item.Path)}" data-kind="${item.Kind}">Recycle</button>`}</td>
    </tr>`}).join(""):'<tr><td colspan="8" class="empty">No folders or files found.</td></tr>';
}
function showToast(message,error=false){const el=document.getElementById("toast");el.textContent=message;el.style.display="block";el.style.borderColor=error?"var(--red)":"var(--green)";setTimeout(()=>el.style.display="none",5000)}
async function recycle(path,kind){
  const item=kind==="File"?fileByPath.get(key(path)):byPath.get(key(path));
  const answer=confirm(`Move this ${kind.toLowerCase()} to the Recycle Bin?\n\n${path}\n\nReported size: ${formatSize(item?.Size||0)}\n\nThe dashboard data is a snapshot; rescan afterward for exact totals.`);
  if(!answer)return;
  try{
    const response=await fetch("/recycle",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({path,kind})});
    const result=await response.json();
    if(!response.ok)throw new Error(result.error||"Deletion failed");
    if(kind==="File")removeFile(path);else removeSubtree(path);
    render();
    showToast(result.message);
  }catch(error){showToast(error.message,true)}
}
function removeSubtree(path){
  const prefix=key(path)+"\\", removed=byPath.get(key(path));
  for(let i=DATA.length-1;i>=0;i--){const p=key(DATA[i].Path);if(p===key(path)||p.startsWith(prefix)){byPath.delete(p);DATA.splice(i,1)}}
  for(let i=FILES.length-1;i>=0;i--){const p=key(FILES[i].Path);if(p.startsWith(prefix)){fileByPath.delete(p);FILES.splice(i,1)}}
  for(const [parent,list] of children)children.set(parent,list.filter(x=>key(x.Path)!==key(path)&&!key(x.Path).startsWith(prefix)));
  for(const [parent,list] of filesByParent)filesByParent.set(parent,list.filter(x=>!key(x.Path).startsWith(prefix)));
  if(removed){let parent=removed.Parent;while(parent&&byPath.has(key(parent))){const node=byPath.get(key(parent));node.Size=Math.max(0,node.Size-removed.Size);node.Files=Math.max(0,node.Files-removed.Files);parent=node.Parent}}
}
function removeFile(path){
  const removed=fileByPath.get(key(path));if(!removed)return;
  fileByPath.delete(key(path));
  const index=FILES.findIndex(x=>key(x.Path)===key(path));if(index>=0)FILES.splice(index,1);
  const parentKey=key(removed.Parent);filesByParent.set(parentKey,(filesByParent.get(parentKey)||[]).filter(x=>key(x.Path)!==key(path)));
  let parent=removed.Parent;while(parent&&byPath.has(key(parent))){const node=byPath.get(key(parent));node.Size=Math.max(0,node.Size-removed.Size);node.Files=Math.max(0,node.Files-1);if(key(parent)===parentKey){node.DirectSize=Math.max(0,node.DirectSize-removed.Size);node.DirectFiles=Math.max(0,node.DirectFiles-1)}parent=node.Parent}
}
document.addEventListener("click",event=>{
  const folder=event.target.closest("[data-path]"); if(folder){current=folder.dataset.path;document.getElementById("search").value="";render();return}
  const button=event.target.closest("[data-delete]"); if(button)recycle(button.dataset.delete,button.dataset.kind);
});
document.getElementById("search").addEventListener("input",render);
document.getElementById("home").addEventListener("click",()=>{current=ROOT;document.getElementById("search").value="";render()});
document.getElementById("up").addEventListener("click",()=>{const item=byPath.get(key(current));if(item?.Parent){current=item.Parent;render()}});
document.getElementById("sort").addEventListener("click",event=>{descending=!descending;event.target.textContent=descending?"Size: largest first":"Size: smallest first";render()});
document.getElementById("stopServer").addEventListener("click",async()=>{
  if(!confirm("Stop the local dashboard server?"))return;
  try{
    await fetch("/shutdown",{method:"POST"});
    document.body.innerHTML='<main><div class="card"><h2>Dashboard server stopped</h2><p>You can close this browser tab.</p></div></main>';
  }catch(error){showToast("The server has stopped. You can close this browser tab.")}
});
render();
</script>
</body>
</html>
'@

$html = $html.Replace("__DATA__", $json).Replace("__FILES__", $filesJson).Replace("__ROOT__", $rootJson)
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
Set-Content -LiteralPath $HtmlOutput -Value $html -Encoding UTF8

$listener = [System.Net.HttpListener]::new()
$started = $false
for ($candidatePort = $Port; $candidatePort -lt ($Port + 10); $candidatePort++) {
    try {
        $listener.Prefixes.Clear()
        $url = "http://localhost:$candidatePort/"
        $listener.Prefixes.Add($url)
        $listener.Start()
        $started = $true
        break
    }
    catch {
        if ($listener.IsListening) {
            $listener.Stop()
        }
    }
}

if (-not $started) {
    throw "Could not start the local dashboard server on ports $Port-$($Port + 9). Try running PowerShell as Administrator."
}

Add-Type -AssemblyName Microsoft.VisualBasic
Write-Host ""
Write-Host "Dashboard ready: $url" -ForegroundColor Green
Write-Host "Keep this PowerShell window open while using the dashboard." -ForegroundColor Yellow
Write-Host "Press Ctrl+C here when finished." -ForegroundColor Yellow
Start-Process $url

try {
    $keepRunning = $true
    while ($listener.IsListening -and $keepRunning) {
        $contextTask = $listener.GetContextAsync()
        while (-not $contextTask.IsCompleted) {
            Start-Sleep -Milliseconds 200
        }
        $context = $contextTask.GetAwaiter().GetResult()
        try {
            if ($context.Request.HttpMethod -eq "GET" -and $context.Request.Url.AbsolutePath -eq "/") {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($html)
                $context.Response.ContentType = "text/html; charset=utf-8"
                $context.Response.ContentLength64 = $bytes.Length
                $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                $context.Response.Close()
                continue
            }

            if ($context.Request.HttpMethod -eq "POST" -and $context.Request.Url.AbsolutePath -eq "/recycle") {
                $reader = [System.IO.StreamReader]::new($context.Request.InputStream, $context.Request.ContentEncoding)
                $requestBody = $reader.ReadToEnd() | ConvertFrom-Json
                $reader.Dispose()

                $target = [System.IO.Path]::GetFullPath([string]$requestBody.path).TrimEnd('\')
                $rootPrefix = $Root.TrimEnd('\') + "\"
                if (-not $target.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                    Send-JsonResponse -Context $context -StatusCode 400 -Body @{ error = "The selected path is outside the scanned root." }
                    continue
                }
                if (Test-ProtectedPath -Path $target) {
                    Send-JsonResponse -Context $context -StatusCode 403 -Body @{ error = "Deletion of this protected folder is blocked." }
                    continue
                }
                $isFile = [string]$requestBody.kind -eq "File"
                if ($isFile -and -not [System.IO.File]::Exists($target)) {
                    Send-JsonResponse -Context $context -StatusCode 404 -Body @{ error = "The file no longer exists." }
                    continue
                }
                if (-not $isFile -and -not [System.IO.Directory]::Exists($target)) {
                    Send-JsonResponse -Context $context -StatusCode 404 -Body @{ error = "The folder no longer exists." }
                    continue
                }

                if ($isFile) {
                    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
                        $target,
                        [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                        [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin,
                        [Microsoft.VisualBasic.FileIO.UICancelOption]::ThrowException
                    )
                }
                else {
                    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(
                        $target,
                        [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                        [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin,
                        [Microsoft.VisualBasic.FileIO.UICancelOption]::ThrowException
                    )
                }
                Send-JsonResponse -Context $context -StatusCode 200 -Body @{ message = "Moved to Recycle Bin: $target" }
                continue
            }

            if ($context.Request.HttpMethod -eq "POST" -and $context.Request.Url.AbsolutePath -eq "/shutdown") {
                Send-JsonResponse -Context $context -StatusCode 200 -Body @{ message = "Dashboard server stopped." }
                $keepRunning = $false
                continue
            }

            Send-JsonResponse -Context $context -StatusCode 404 -Body @{ error = "Not found." }
        }
        catch {
            if ($context.Response.OutputStream.CanWrite) {
                Send-JsonResponse -Context $context -StatusCode 500 -Body @{ error = $_.Exception.Message }
            }
        }
    }
}
finally {
    $listener.Stop()
    $listener.Close()
}
