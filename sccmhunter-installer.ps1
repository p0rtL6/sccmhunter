$scriptTitle = 'SCCM Hunter Installer'
$scriptFileName = 'installer.ps1'
$scriptDesc = 'Builds SCCM Hunter to windows compatible binaries'
$version = '1.0.0'

$commands = @{
    'install' = @{
        Description = 'Install SCCM Hunter'
        Arguments   = @{
            'output-dir'  = @{
                Description = 'The output directory for the binaries'
                Order       = 0
                Required    = $false
                Type        = 'PATH'
                Default     = Get-Location
            }
            'source'      = @{
                Description = 'The source to download from (USER/REPO/BRANCh uses Github)'
                Order       = 1
                Required    = $false
                Default     = New-Object System.Uri('https://github.com/p0rtL6/sccmhunter/archive/refs/heads/windows.zip')
                Type        = 'USER/REPO/BRANCH or URL or DIRECTORY'
                CustomType  = @{
                    ReturnType = [Uri]
                    Parser     = {
                        param (
                            [System.Object]$Value
                        )

                        $parsedUri = $null
                        $isURL = [Uri]::TryCreate($value, [UriKind]::RelativeOrAbsolute, [ref]$parsedUri)

                        if (-not $isURL) {
                            $parts = $value -split '/'
                            if ($parts.Length -eq 3) {
                                $stringUri = "https://github.com/$($parts[0])/$($parts[1])/archive/refs/heads/$($parts[2]).zip"
                                [Uri]::TryCreate($stringUri, [UriKind]::RelativeOrAbsolute, [ref]$parsedUri) | Out-Null
                            }
                        }
                        else {
                            if (-not $parsedUri.IsAbsoluteUri) {
                                if (Test-Path $parsedUri) {
                                    try {
                                        $resolvedPath = (Resolve-Path -Path $value).Path
                                        if (Test-Path -Path $resolvedPath -PathType Container) {
                                            $fileUri = "file://$resolvedPath"
                                            [Uri]::TryCreate($fileUri, [UriKind]::RelativeOrAbsolute, [ref]$parsedUri) | Out-Null
                                        }
                                        else {
                                            $parsedUri = $null
                                        }
                                    }
                                    catch {
                                        $parsedUri = $null
                                    }
                                }
                                else {
                                    $parsedUri = $null
                                }
                            }
                        }

                        return $parsedUri
                    }
                }
            }
            'temp-dir'    = @{
                Description = 'The temporary directory that is used for downloading and building'
                Order       = 2
                Required    = $false
                Type        = 'PATH'
                Default     = $env:temp
            }
            'extract-dir' = @{
                Description = 'The directory in which binaries will extract to during runtime'
                Order       = 3
                Required    = $false
                Type        = 'PATH'
            }
        }
        Flags       = @{
            'system-wide' = @{
                Description = 'Install system-wide and add to PATH'
                Order       = 0
            }
        }
    }
}

function install {
    param (
        [Hashtable]$Arguments,
        [Hashtable]$Flags
    )

    try {
        $tempDir = Join-Path -Path $arguments['temp-dir'] -ChildPath ($scriptTitle -replace ' ', '-').ToLower()
        if (Test-Path -Path $tempDir) {
            Remove-Item -Path $tempDir -Recurse -Force
        }
    
        New-Item -Path $tempDir -ItemType 'Directory' -Force | Out-Null
        
        $startingDirectory = Get-Location

        $targetDirectory

        if ($arguments['source'].IsFile) {
            $targetDirectory = $arguments['source'].AbsolutePath
            $virtualEnvironmentPath = Join-Path -Path $targetDirectory -ChildPath '.venv'
            if (Test-Path -Path $virtualEnvironmentPath) {
                Remove-Item -Path $virtualEnvironmentPath -Recurse -Force
            }
        }
        else {
            Write-Host 'Downloading source...'
            $sourceArchivePath = Join-Path -Path $tempDir -ChildPath 'source.zip'
            $sourceFolderPath = Join-Path -Path $tempDir -ChildPath 'source'

            Invoke-WebRequest -Uri $arguments['source'].AbsoluteUri -OutFile $sourceArchivePath
            Expand-Archive -Path $sourceArchivePath -DestinationPath $sourceFolderPath

            $foldersWithPythonFile = Get-ChildItem -Path $sourceFolderPath -Recurse -File -Filter "sccmhunter.py" | Select-Object DirectoryName
            $targetDirectory = $foldersWithPythonFile.DirectoryName
        }

        Set-Location -Path $targetDirectory

        $pythonBinary = Get-Python -TempDir $tempDir

        & $pythonBinary -m venv .venv
        .\.venv\Scripts\Activate.ps1

        pip install -r requirements.txt
        pip install pyinstaller

        python setup.py install

        $installerArgs = New-Object System.Collections.ArrayList
        $installerArgs.Add('--onefile') | Out-Null

        $installerArgs.Add('--collect-all') | Out-Null
        $installerArgs.Add('lib') | Out-Null

        if ($arguments.ContainsKey('extract-dir')) {
            $installerArgs.Add('--runtime-tmpdir') | Out-Null
            $installerArgs.Add($arguments['extract-dir']) | Out-Null
        }

        pyinstaller $installerArgs 'sccmhunter.py'
        
        $binaryPath = Join-Path -Path $targetDirectory -ChildPath 'dist\sccmhunter.exe'

        if ($flags['system-wide']) {
            Write-Host 'Copying binary to Program Files...'
            New-Item -ItemType Directory -Path 'C:\Program Files\SCCMHunter' -Force
            Copy-Item -Path $binaryPath -Destination 'C:\Program Files\SCCMHunter'

            $currentPath = [System.Environment]::GetEnvironmentVariable('Path', [System.EnvironmentVariableTarget]::Machine)

            if ($currentPath -notlike "*C:\Program Files\SCCMHunter*") {
                $newPath = $currentPath + ';' + 'C:\Program Files\SCCMHunter'

                Write-Host 'Adding SCCMHunter to PATH...'
                [System.Environment]::SetEnvironmentVariable('Path', $newPath, [System.EnvironmentVariableTarget]::Machine)
            }
            else {
                Write-Host 'SCCMHunter is already in PATH.'
            }
        }
        else {
            Copy-Item -Path $binaryPath -Destination $arguments['output-dir']
        }
    }
    finally {
        Write-Host 'Cleaning up...'

        deactivate
        Set-Location -Path $startingDirectory

        Remove-Python -TempDir $tempDir
        if (Test-Path -Path $tempDir) {
            Remove-Item -Path $tempDir -Recurse -Force
        }
    }
}

function Get-Python {
    param (
        [string]$TempDir
    )

    $pythonVersion = '3.13.2'
    $pythonUrl = "https://www.python.org/ftp/python/$pythonVersion/python-$pythonVersion-amd64.exe"

    $pythonOutput = python --version
    if ($pythonOutput -eq "python $pythonVersion") {
        return (Get-Command python).Source
    }

    Write-Host 'Downloading Python...'

    $ProgressPreference = 'SilentlyContinue'
    $pythonDirectory = Join-Path -Path $TempDir -ChildPath 'python'

    if (Test-Path -Path $pythonDirectory) {
        Remove-Item $pythonDirectory -Recurse -Force
    }
    
    New-Item -Path $pythonDirectory -ItemType 'Directory' | Out-Null
    $pythonInstallerPath = Join-Path -Path $pythonDirectory -ChildPath 'python-installer.exe'

    Invoke-WebRequest -Uri $pythonUrl -Outfile $pythonInstallerPath
    Start-Process $pythonInstallerPath -ArgumentList '/quiet', "TargetDir=$($pythonDirectory -replace ' ', '` ')", 'Shortcuts=0', 'Include_doc=0', 'Include_launcher=0' -Wait -Verb RunAs

    $pythonBinary = Join-Path -Path $pythonDirectory -ChildPath 'python.exe'
    return $pythonBinary
}

function Remove-Python {
    param (
        [string]$TempDir
    )

    $pythonDirectory = Join-Path -Path $TempDir -ChildPath 'python'
    $pythonInstallerPath = Join-Path -Path $pythonDirectory -ChildPath 'python-installer.exe'

    if (Test-Path $pythonInstallerPath) {
        Start-Process $pythonInstallerPath -ArgumentList '/quiet', 'uninstall' -Wait -Verb RunAs
    }
}

# !!! Everything below this point does not need to be changed !!!

function Get-FlatArguments {
    param (
        [string]$CommandName
    )

    $flatArguments = @{}

    if ($commands[$commandName].ContainsKey('Arguments')) {
        foreach ($argument in $commands[$commandName]['Arguments'].GetEnumerator()) {
            if ($argument.Value.ContainsKey('Group') -and $argument.Value['Group']) {
                $group = $argument.Value
                if ($group.ContainsKey('Arguments')) {
                    foreach ($groupArgument in $group['Arguments'].GetEnumerator()) {
                        $flatArguments[$groupArgument.Key] = $groupArgument.Value
                    }
                }
            }
            else {
                $flatArguments[$argument.Key] = $argument.Value
            }
        }
    }

    return $flatArguments
}

function Show-Argument {
    param (
        [System.Collections.DictionaryEntry]$Argument,
        [int]$Padding
    )

    $argumentOutputString = "      --$("$($argument.Key) <$($argument.Value['Type'])>".PadRight($padding)) $($argument.Value['Description'])"
    if ($argument.Value.ContainsKey('Default')) {
        if ($argument.Value['Default'] -is [System.Management.Automation.ScriptBlock]) {
            if ($argument.Value.ContainsKey('DefaultDescription')) {
                $argumentOutputString = $argumentOutputString + " (default: $($argument.Value['DefaultDescription']))"
            }
            else {
                $argumentOutputString = $argumentOutputString + " (default: <not specified>)"
            }
        }
        else {
            $argumentOutputString = $argumentOutputString + " (default: $($argument.Value['Default']))"
        }
    }

    Write-Host $argumentOutputString
}

function Show-HelpMenu {
    param (
        [Parameter(Mandatory = $False)]
        [string]$SelectedCommand
    )

    Write-Host "=== $scriptTitle ==="
    Write-Host $scriptDesc
    Write-Host "Version: $version"
    Write-Host ''
    Write-Host "Usage: $scriptFileName [COMMAND] [ARGUMENTS] [FLAGS]"
    Write-Host ''

    $helpMenuCommandPadding = 0
    $helpMenuArgsAndFlagsPadding = 0
    
    foreach ($commandName in $commands.Keys) {
        if ($commandName.Length -gt $helpMenuCommandPadding) {
            $helpMenuCommandPadding = $commandName.Length
        }

        $flatArguments = Get-FlatArguments -CommandName $commandName
    
        foreach ($argument in $flatArguments.GetEnumerator()) {
            $fullArgument = $argument.Key
            if ($argument.Value.ContainsKey('Type')) {
                $fullArgument = "$fullArgument <$($argument.Value['Type'])>"
            }

            if ($fullArgument.Length -gt $helpMenuArgsAndFlagsPadding) {
                $helpMenuArgsAndFlagsPadding = $fullArgument.Length
            }
        }
    
        foreach ($flagName in $commands[$commandName]['Flags'].Keys) {
            if ($flagName.Length -gt $helpMenuArgsAndFlagsPadding) {
                $helpMenuArgsAndFlagsPadding = $flagName.Length
            }
        }
    }
    
    $helpMenuCommandPadding += 2
    $helpMenuArgsAndFlagsPadding += 2

    if (-not $selectedCommand) {
        Write-Host '[COMMANDS]'
    }

    $sortedCommands = $commands.GetEnumerator() | Sort-Object { $_.Value['Order'] }
    foreach ($command in $sortedCommands) {

        if ($selectedCommand -and ($selectedCommand -ne ($command.Key))) {
            continue
        }

        Write-Host "  $($command.Key.PadRight($helpMenuCommandPadding)) $($command.Value['Description'])"
        Write-Host ''

        if ($command.Value.ContainsKey('Arguments')) {
            Write-Host '  [ARGUMENTS]'

            $arguments = $command.Value['Arguments']
            $sortedArguments = $arguments.GetEnumerator() | Sort-Object { $_.Value['Order'] }

            $lastItemWasGroup = $false

            foreach ($argument in $sortedArguments) {
                if ($argument.Value.ContainsKey('Group') -and $argument.Value['Group']) {
                    $lastItemWasGroup = $true
                    Write-Host ''

                    $group = $argument.Value

                    if ($group.ContainsKey('Arguments')) {
                        $groupTitleString = "    {$($argument.Key)}"
                        if ($group.ContainsKey('Required') -and $group['Required']) {
                            $groupTitleString += ' (Required)'
                        }
                        if ($group.ContainsKey('Exclusive') -and $group['Exclusive']) {
                            $groupTitleString += ' (Exclusive)'
                        }
                        Write-Host $groupTitleString

                        $groupArguments = $group['Arguments'].GetEnumerator() | Sort-Object { $_.Value['Order'] }
                        foreach ($groupArgument in $groupArguments) {
                            Show-Argument -Argument $groupArgument -Padding $helpMenuArgsAndFlagsPadding
                        }
                    }
                }
                else {
                    if ($lastItemWasGroup) {
                        Write-Host ''
                    }
                    Show-Argument -Argument $argument -Padding $helpMenuArgsAndFlagsPadding + 2
                }
            }
            Write-Host ''
        }

        if ($command.Value.ContainsKey('Flags')) {
            Write-Host '  [FLAGS]'
            $flags = $command.Value['Flags'].GetEnumerator() | Sort-Object { $_.Value['Order'] }
            foreach ($flagName in $flags.Key) {
                $flagValue = $command.Value['Flags'][$flagName]
                Write-Host "    -$($flagName.PadRight($helpMenuArgsAndFlagsPadding + 1)) $($flagValue['Description'])"
            }
            Write-Host ''
        }
    }
    Write-Host ''
}

if ($Args.Count -eq 0 -or $Args[0] -eq '-h' -or $Args[0] -eq '--help') {
    Show-HelpMenu
    exit 0
}

if (-not $commands.ContainsKey($Args[0])) {
    throw 'Invalid command selected (Use -h or --help for help)'
}

$selectedCommand = $null
$flattenedCommandArguments = $null
$selectedArguments = @{}
$selectedFlags = @{}

for ($i = 0; $i -lt $Args.Count; $i++) {
    if ($i -eq 0) {
        $selectedCommand = $Args[0]
        $flattenedCommandArguments = Get-FlatArguments -CommandName $Args[0]
    }
    elseif ($Args -contains '-h' -or $Args -contains '--help') {
        if ($selectedCommand) {
            Show-HelpMenu -SelectedCommand $selectedCommand
        }
        else {
            Show-HelpMenu
        }
        exit 0
    }
    elseif ($Args[$i].StartsWith('--')) {
        $arg = $Args[$i].Substring(2)
        $argParts = $arg -split '='
        $keyword = $argParts[0]
        $value = $null

        if (-not $flattenedCommandArguments.ContainsKey($keyword)) {
            throw 'Invalid argument (Use -h or --help for help)'
        }

        if ($argParts.Count -eq 2) {
            $value = $argParts[1]
        }
        elseif ($argParts.Count -gt 2 -or $argParts -lt 1) {
            throw 'Malformed argument (Use -h or --help for help)'
        }

        if (-not $value) {
            $i++
            $value = $Args[$i]
        }

        if (-not $value) {
            throw "No value provided for argument `"$keyword`" (Use -h or --help for help)"
        }

        $argumentTypeString = $flattenedCommandArguments[$keyword]['Type']

        $targetType = [System.Object]
        $parser = { param([System.Object]$Value) return $value }

        if ($flattenedCommandArguments[$keyword].ContainsKey('CustomType')) {
            if ($flattenedCommandArguments[$keyword].ContainsKey('ReturnType')) {
                $targetType = $flattenedCommandArguments[$keyword]['CustomType']['ReturnType']
            }

            $parser = $flattenedCommandArguments[$keyword]['CustomType']['Parser']
        }
        else {
            switch ($argumentTypeString) {
                'STRING' {
                    $targetType = [string]
                    $parser = { param([System.Object]$Value) return $value -as [string] }
                }
                'NUMBER' {
                    $targetType = [int32]
                    $parser = { param([System.Object]$Value) return $value -as [int32] }
                }
                'BOOLEAN' {
                    $targetType = [bool]
                    $parser = { param([System.Object]$Value) return $value -as [bool] }
                }
                'PATH' {
                    $targetType = [string]
                    $parser = {
                        param(
                            [System.Object]$Value
                        )

                        if ((-not ($value -match '\\')) -and (-not ($value -match '/'))) {
                            $value = Join-Path -Path (Get-Location) -ChildPath $value
                        }
            
                        $parentDir = Split-Path -Path $value -Parent
            
                        if ((-not $parentDir) -or ($parentDir -and (Test-Path -Path $parentDir))) {
                            return (Resolve-Path -Path $value).Path -as [string]
                        }
                    }
                }
            }
        }

        $targetArrayType = $targetType.MakeArrayType()
        $shouldBeList = $flattenedCommandArguments[$keyword].ContainsKey('List') -and $flattenedCommandArguments[$keyword]['List']

        $parsedValue = $null

        if ($value -is [System.Object[]]) {
            if (-not $shouldBeList) {
                throw "Argument value for `"$keyword`" cannot be a list (Use -h or --help for help)"
            }

            for ($j = 0; $j -lt $value.Length; $j++) {
                $parsedListItem = & $parser -Value $value[$j]
                if ($null -ne $parsedListItem) {
                    $value[$j] = $parsedListItem
                }
                else {
                    throw "Argument value `"$($value[$j])`" is not a valid $($argumentTypeString.ToLower()) (Use -h or --help for help)"
                }
            }

            $parsedValue = $value -as $targetArrayType
        }
        else {
            if ($shouldBeList) {
                $parsedValue = @(& $parser -Value $value) -as $targetArrayType
            }
            else {
                $parsedValue = & $parser -Value $value
            }
        }
        
        if ($null -eq $parsedValue) {
            if ($shouldBeList) {
                throw "Argument value `"$value`" for `"$keyword`" is not a valid $($argumentTypeString.ToLower()) list (Use -h or --help for help)"
            }
            else {
                throw "Argument value `"$value`" for `"$keyword`" is not a valid $($argumentTypeString.ToLower()) (Use -h or --help for help)"
            }
        }
        
        $selectedArguments[$keyword] = $parsedValue
    }
    elseif ($Args[$i].StartsWith('-')) {
        $flag = $Args[$i].Substring(1)
        if (-not $commands[$selectedCommand]['Flags'].ContainsKey($flag)) {
            throw 'Invalid flag (Use -h or --help for help)'
        }

        $selectedFlags[$flag] = $True
    }
    else {
        throw 'Invalid input (Use -h or --help for help)'
    }
}

foreach ($flagName in $commands[$selectedCommand]['Flags'].Keys) {
    if (-not $selectedFlags.ContainsKey($flagName)) {
        $selectedFlags[$flagName] = $False
    }
}

$defaultArguments = @{}
foreach ($argument in $flattenedCommandArguments.GetEnumerator()) {
    if ($argument.Value.ContainsKey('Default')) {
        if ($argument.Value['Default'] -is [System.Management.Automation.ScriptBlock]) {
            $defaultArguments[$argument.Key] = & $argument.Value['Default'] -Arguments $selectedArguments -Flags $selectedFlags
        }
        else {
            $defaultArguments[$argument.Key] = $argument.Value['Default']
        }
    }
}

foreach ($defaultArgument in $defaultArguments.GetEnumerator()) {
    if (-not $selectedArguments.ContainsKey($defaultArgument.Key)) {
        $selectedArguments[$defaultArgument.Key] = $defaultArgument.Value
    }
}

foreach ($argument in $flattenedCommandArguments.GetEnumerator()) {
    if ($argument.Value.ContainsKey('Group') -and $argument.Value['Group']) {
        $group = $argument.Value

        if ($group.ContainsKey('Required')) {
            if ($group['Required'] -is [bool]) {
                $required = $false
                if ($group.ContainsKey('Required') -and $group['Required']) {
                    $required = $true 
                }
        
                $exclusive = $false
                if ($group.ContainsKey('Exclusive') -and $group['Exclusive']) {
                    $exclusive = $true 
                }
        
                if ($group.ContainsKey('Arguments')) {
                    $numberOfArgumentsSelected = 0
                    foreach ($groupArgument in $group['Arguments'].GetEnumerator()) {
                        $selectedArguments
                        if ($selectedArguments.ContainsKey($groupArgument.Key)) {
                            $numberOfArgumentsSelected++
                        }
                    }
        
                    if (($numberOfArgumentsSelected -eq 0) -and $required) {
                        throw "Missing required argument for required group `"$($argument.Key)`" (Use -h or --help for help)"
                    }
        
                    if (($numberOfArgumentsSelected -gt 1) -and $exclusive) {
                        throw "Multiple arguments specified for exclusive group `"$($argument.Key)`" (Use -h or --help for help)"
                    }
                }
            }
            elseif ($group['Required'] -is [System.Management.Automation.ScriptBlock]) {
                if (-not (& $group['Required'] -Arguments $selectedArguments -Flags $selectedFlags)) {
                    if ($group.ContainsKey('RequiredDescription')) {
                        throw "Group `"$($argument.Key)`" did not meet the requirements: $($group['RequiredDescription'])"
                    }
                    else {
                        throw "Group `"$($argument.Key)`" did not meet the requirements, no description was provided."
                    }
                }
            }
        }
    }
    else {
        if ($argument.Value.ContainsKey('Required')) {
            if ($argument.Value['Required'] -is [bool] -and $argument.Value['Required'] -and (-not $selectedArguments.ContainsKey($argument.Key))) {
                throw "Missing required argument `"$($argument.Key)`" (Use -h or --help for help)"
            }

            if ($argument.Value['Required'] -is [System.Management.Automation.ScriptBlock]) {
                if (-not (& $argument.Value['Required'] -Arguments $selectedArguments -Flags $selectedFlags)) {
                    if ($argument.Value.ContainsKey('RequiredDescription')) {
                        throw "Argument `"$($argument.Key)`" did not meet the requirements: $($argument.Value['RequiredDescription'])"
                    }
                    else {
                        throw "Argument `"$($argument.Key)`" did not meet the requirements, no description was provided."
                    }
                }
            }
        }
    }
}

& (Get-Command $selectedCommand) -Arguments $selectedArguments -Flags $selectedFlags