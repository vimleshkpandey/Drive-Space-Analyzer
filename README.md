# Drive Space Analyzer

`folderexplorer-v2.ps1` scans a Windows folder, calculates recursive folder sizes, and opens a local dashboard for finding disk-space usage.

The dashboard supports deep folder navigation, individual file listings, searching, size sorting, cleanup guidance, and moving selected folders or files to the Windows Recycle Bin.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+
- A modern web browser
- Administrator access is optional but improves access when scanning protected locations

## Run interactively

Open PowerShell in this directory:

```powershell
cd C:\Data\Dev\Project
.\folderexplorer-v2.ps1
```

Choose one of the displayed options:

1. Local AppData
2. Entire `C:\` drive
3. A custom folder path

Scanning the full drive can take significantly longer.

## Help

Display command usage without starting a scan:

```powershell
.\folderexplorer-v2.ps1 -h
```

`-Help` is also supported.

## Pass a path directly

Analyze Local AppData:

```powershell
.\folderexplorer-v2.ps1 -Root "C:\Users\vpandey\AppData\Local"
```

Analyze the entire C: drive:

```powershell
.\folderexplorer-v2.ps1 -Root "C:\"
```

Analyze another folder:

```powershell
.\folderexplorer-v2.ps1 -Root "C:\Data"
```

Optional parameters:

```powershell
.\folderexplorer-v2.ps1 -Root "C:\Data" -MaxDepth 20 -Port 8765
```

| Parameter | Purpose | Default |
|---|---|---|
| `-Root` | Folder to analyze | Interactive selection |
| `-MaxDepth` | Maximum folder depth to scan | `30` |
| `-Port` | Preferred local dashboard port | `8765` |
| `-h`, `-Help` | Display command help and exit | Off |

## Using the dashboard

- Click a folder name to navigate into it.
- Use **Up** or the breadcrumb path to navigate back.
- Files directly inside the current folder are listed together with its child folders.
- Search across all scanned folders and files by name or path.
- Sort folders and files from largest to smallest or smallest to largest.
- Hover over cleanup guidance to understand its meaning.
- Click **Recycle** to move a selected folder or file to the Windows Recycle Bin.

The report is a snapshot. Run the script again after deleting folders to refresh all sizes.

## Deletion safety

Deletion requires browser confirmation and moves folders to the Windows Recycle Bin instead of permanently deleting them.

The script blocks deletion of critical top-level folders such as:

- `C:\Windows`
- `C:\Program Files`
- `C:\Program Files (x86)`
- `C:\ProgramData`
- `C:\Recovery`
- `C:\Users`
- The selected scan root

Cleanup guidance is advisory. Do not delete a folder only because it is marked **Review**. Inspect its contents and close applications that may be using it first.

## Progress and stopping

PowerShell displays the current folder, elapsed time, scanned folder count, file count, and discovered size.

Keep the PowerShell window open while using the dashboard. Press `Ctrl+C` in PowerShell or click **Stop server** in the dashboard when finished.

## Troubleshooting

### Script execution is disabled

Run the script for the current PowerShell session with:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\folderexplorer-v2.ps1
```

### Some folders are missing or show incomplete sizes

Some folders may be inaccessible. Start PowerShell as Administrator and scan again for improved coverage.

### Dashboard does not open

Copy the `Dashboard ready` URL from PowerShell and open it manually. If the preferred port is busy, the script tries the next available ports automatically.

### Deletion fails

The folder may be protected, in use, already deleted, or require elevated permissions. Close applications using it and rerun PowerShell as Administrator if appropriate.
