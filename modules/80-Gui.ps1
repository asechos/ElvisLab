# ============================================================================
# ElvisLab - Interfaz grafica principal
# ============================================================================

function Show-Gui {
    param($Config)

    Initialize-UiTypes
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $colors = @{
        window      = [System.Drawing.Color]::FromArgb(30, 31, 34)
        topBar      = [System.Drawing.Color]::FromArgb(24, 25, 28)
        sideBar     = [System.Drawing.Color]::FromArgb(36, 37, 40)
        panel       = [System.Drawing.Color]::FromArgb(43, 45, 49)
        border      = [System.Drawing.Color]::FromArgb(47, 49, 54)
        text        = [System.Drawing.Color]::FromArgb(227, 229, 232)
        muted       = [System.Drawing.Color]::FromArgb(154, 160, 166)
        accent      = [System.Drawing.Color]::FromArgb(47, 111, 208)
        accentHover = [System.Drawing.Color]::FromArgb(59, 127, 224)
        green       = [System.Drawing.Color]::FromArgb(59, 165, 93)
        red         = [System.Drawing.Color]::FromArgb(179, 59, 59)
    }

    $script:IsInstalling = $false
    $script:InstalledOnly = $false
    $script:Backend = 'direct'
    $script:InstallProcess = $null
    $script:ProgramStatus = @{}
    $script:TweakChecks = @{}
    $script:TweakModels = @{}

    function New-FlatButton {
        param(
            [string]$Text,
            [int]$X,
            [int]$Y,
            [int]$Width = 190,
            [int]$Height = 34,
            [switch]$Primary
        )

        $button = New-Object System.Windows.Forms.Button
        $button.Text = $Text
        $button.Location = New-Object System.Drawing.Point($X, $Y)
        $button.Size = New-Object System.Drawing.Size($Width, $Height)
        $button.FlatStyle = 'Flat'
        $button.FlatAppearance.BorderSize = 0
        $button.Cursor = 'Hand'

        if ($Primary) {
            $button.BackColor = $colors.accent
            $button.ForeColor = [System.Drawing.Color]::White
            $button.Font = New-Object System.Drawing.Font('Segoe UI', 11.5, [System.Drawing.FontStyle]::Bold)
            $button.FlatAppearance.MouseOverBackColor = $colors.accentHover
            $button.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(37, 90, 168)
        } else {
            $button.BackColor = $colors.panel
            $button.ForeColor = $colors.text
            $button.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(53, 55, 60)
            $button.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(58, 60, 66)
        }

        return $button
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = '{0} {1}' -f $Config.appName, $Config.version
    $form.AutoScaleMode = 'Font'
    $form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'Sizable'
    $form.MaximizeBox = $true
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 11)
    $form.BackColor = $colors.window

    $workArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $clientWidth = [int][Math]::Min(1180, [Math]::Max(1000, $workArea.Width - 40))
    $clientHeight = [int][Math]::Min(740, [Math]::Max(640, $workArea.Height - 60))
    $form.ClientSize = New-Object System.Drawing.Size($clientWidth, $clientHeight)
    $form.MinimumSize = New-Object System.Drawing.Size(1016, 679)

    $iconPath = Join-Path $script:ScriptDir 'Resources\ElvisLab.ico'
    if (Test-Path -LiteralPath $iconPath) {
        try { $form.Icon = New-Object System.Drawing.Icon($iconPath) } catch { }
    }

    $rootLayout = New-Object System.Windows.Forms.TableLayoutPanel
    $rootLayout.Dock = 'Fill'
    $rootLayout.ColumnCount = 2
    $rootLayout.RowCount = 3
    $rootLayout.Margin = New-Object System.Windows.Forms.Padding(0)
    $rootLayout.Padding = New-Object System.Windows.Forms.Padding(0)
    $rootLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 204))) | Out-Null
    $rootLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
    $rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 50))) | Out-Null
    $rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
    $rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 44))) | Out-Null
    $form.Controls.Add($rootLayout)

    $mainHost = New-Object System.Windows.Forms.Panel
    $mainHost.Dock = 'Fill'
    $mainHost.BackColor = $colors.window
    $rootLayout.Controls.Add($mainHost, 1, 1)

    # --- Barra superior ------------------------------------------------------
    $topBar = New-Object System.Windows.Forms.Panel
    $topBar.Size = New-Object System.Drawing.Size(1000, 50)
    $topBar.BackColor = $colors.topBar

    $topBorder = New-Object System.Windows.Forms.Panel
    $topBorder.Dock = 'Bottom'
    $topBorder.Height = 1
    $topBorder.BackColor = $colors.border
    $topBar.Controls.Add($topBorder)

    $lblBrand = New-Object System.Windows.Forms.Label
    $lblBrand.Text = $Config.appName
    $lblBrand.Font = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
    $lblBrand.ForeColor = $colors.text
    $lblBrand.Location = New-Object System.Drawing.Point(16, 10)
    $lblBrand.Size = New-Object System.Drawing.Size(130, 28)
    $topBar.Controls.Add($lblBrand)

    $brandLine = New-Object System.Windows.Forms.Panel
    $brandLine.Location = New-Object System.Drawing.Point(18, 37)
    $brandLine.Size = New-Object System.Drawing.Size(112, 3)
    $brandLine.BackColor = $colors.accent
    $topBar.Controls.Add($brandLine)

    $txtSearch = New-Object System.Windows.Forms.TextBox
    $txtSearch.Location = New-Object System.Drawing.Point(740, 13)
    $txtSearch.Size = New-Object System.Drawing.Size(244, 24)
    $txtSearch.BackColor = $colors.panel
    $txtSearch.ForeColor = $colors.muted
    $txtSearch.BorderStyle = 'FixedSingle'
    $txtSearch.Text = 'Buscar programas...'
    $txtSearch.Anchor = 'Top,Right'
    $topBar.Controls.Add($txtSearch)

    $btnBackendDirect = New-Object System.Windows.Forms.Button
    $btnBackendDirect.Text = 'Directo'
    $btnBackendDirect.Location = New-Object System.Drawing.Point(620, 10)
    $btnBackendDirect.Size = New-Object System.Drawing.Size(58, 30)
    $btnBackendDirect.FlatStyle = 'Flat'
    $btnBackendDirect.FlatAppearance.BorderSize = 0
    $btnBackendDirect.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $btnBackendDirect.Cursor = 'Hand'
    $btnBackendDirect.Anchor = 'Top,Right'
    $topBar.Controls.Add($btnBackendDirect)

    $btnBackendWinget = New-Object System.Windows.Forms.Button
    $btnBackendWinget.Text = 'Winget'
    $btnBackendWinget.Location = New-Object System.Drawing.Point(680, 10)
    $btnBackendWinget.Size = New-Object System.Drawing.Size(56, 30)
    $btnBackendWinget.FlatStyle = 'Flat'
    $btnBackendWinget.FlatAppearance.BorderSize = 0
    $btnBackendWinget.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $btnBackendWinget.Cursor = 'Hand'
    $btnBackendWinget.Anchor = 'Top,Right'
    $topBar.Controls.Add($btnBackendWinget)

    $backendTip = New-Object System.Windows.Forms.ToolTip
    $backendTip.SetToolTip($btnBackendDirect, 'Instaladores oficiales verificados con SHA256 y/o firma digital.')
    $backendTip.SetToolTip($btnBackendWinget, 'Windows Package Manager: instala y actualiza desde el catalogo de winget.')

    $topBar.Dock = 'Fill'
    $rootLayout.Controls.Add($topBar, 0, 0)
    $rootLayout.SetColumnSpan($topBar, 2)

    # --- Panel lateral -------------------------------------------------------
    $sideBar = New-Object System.Windows.Forms.Panel
    $sideBar.Size = New-Object System.Drawing.Size(204, 546)
    $sideBar.BackColor = $colors.sideBar

    $sideBorder = New-Object System.Windows.Forms.Panel
    $sideBorder.Dock = 'Right'
    $sideBorder.Width = 1
    $sideBorder.BackColor = $colors.border
    $sideBar.Controls.Add($sideBorder)

    # --- Barra de estado -----------------------------------------------------
    $statusBar = New-Object System.Windows.Forms.Panel
    $statusBar.Size = New-Object System.Drawing.Size(1000, 44)
    $statusBar.BackColor = $colors.topBar

    $statusBorder = New-Object System.Windows.Forms.Panel
    $statusBorder.Dock = 'Top'
    $statusBorder.Height = 1
    $statusBorder.BackColor = $colors.border
    $statusBar.Controls.Add($statusBorder)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Location = New-Object System.Drawing.Point(16, 13)
    $lblStatus.Size = New-Object System.Drawing.Size(424, 20)
    $lblStatus.ForeColor = $colors.text
    $lblStatus.AutoEllipsis = $true
    $lblStatus.Text = 'Listo.'
    $statusBar.Controls.Add($lblStatus)

    $progressTrack = New-Object System.Windows.Forms.Panel
    $progressTrack.Location = New-Object System.Drawing.Point(452, 18)
    $progressTrack.Size = New-Object System.Drawing.Size(300, 8)
    $progressTrack.BackColor = $colors.panel
    $statusBar.Controls.Add($progressTrack)

    $progressFill = New-Object System.Windows.Forms.Panel
    $progressFill.Location = New-Object System.Drawing.Point(0, 0)
    $progressFill.Size = New-Object System.Drawing.Size(0, 8)
    $progressFill.BackColor = $colors.green
    $progressTrack.Controls.Add($progressFill)

    $lblPercent = New-Object System.Windows.Forms.Label
    $lblPercent.Location = New-Object System.Drawing.Point(760, 12)
    $lblPercent.Size = New-Object System.Drawing.Size(52, 20)
    $lblPercent.ForeColor = $colors.muted
    $lblPercent.Text = '0%'
    $statusBar.Controls.Add($lblPercent)

    $lblVersion = New-Object System.Windows.Forms.Label
    $lblVersion.Text = 'v' + $Config.version
    $lblVersion.Location = New-Object System.Drawing.Point(916, 13)
    $lblVersion.Size = New-Object System.Drawing.Size(68, 20)
    $lblVersion.TextAlign = 'MiddleRight'
    $lblVersion.ForeColor = $colors.muted
    $lblVersion.Anchor = 'Top,Right'
    $statusBar.Controls.Add($lblVersion)

    $statusBar.Dock = 'Fill'
    $rootLayout.Controls.Add($statusBar, 0, 2)
    $rootLayout.SetColumnSpan($statusBar, 2)

    # --- Contenido por pestanas ----------------------------------------------
    $tabPanels = @{}
    foreach ($tabId in @('install', 'tweaks', 'updates', 'log', 'config')) {
        $panel = New-Object System.Windows.Forms.Panel
        $panel.Dock = 'Fill'
        $panel.BackColor = $colors.window
        $panel.Visible = $false
        $mainHost.Controls.Add($panel)
        $tabPanels[$tabId] = $panel
    }

    $tabInstall = $tabPanels['install']
    $tabTweaks = $tabPanels['tweaks']
    $tabUpdates = $tabPanels['updates']
    $tabLog = $tabPanels['log']
    $tabConfig = $tabPanels['config']
    $tabTweaks.AutoScroll = $true
    $tabConfig.AutoScroll = $true

    # Pestana Instalar
    $cardsView = New-Object ElvisCardsView
    $cardsView.Dock = 'Fill'
    $tabInstall.Controls.Add($cardsView)

    # Pestana Actualizar
    $lblUpdatesTitle = New-Object System.Windows.Forms.Label
    $lblUpdatesTitle.Text = 'Actualizaciones'
    $lblUpdatesTitle.Font = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
    $lblUpdatesTitle.ForeColor = $colors.text
    $lblUpdatesTitle.Location = New-Object System.Drawing.Point(24, 20)
    $lblUpdatesTitle.Size = New-Object System.Drawing.Size(500, 30)
    $tabUpdates.Controls.Add($lblUpdatesTitle)

    $lblUpdatesHint = New-Object System.Windows.Forms.Label
    $lblUpdatesHint.Text = 'Actualiza los programas gestionados, todas las apps con winget o Windows Update.'
    $lblUpdatesHint.ForeColor = $colors.muted
    $lblUpdatesHint.Location = New-Object System.Drawing.Point(24, 50)
    $lblUpdatesHint.Size = New-Object System.Drawing.Size(740, 20)
    $tabUpdates.Controls.Add($lblUpdatesHint)

    $lblUpdatesApps = New-Object System.Windows.Forms.Label
    $lblUpdatesApps.Text = 'APLICACIONES GESTIONADAS'
    $lblUpdatesApps.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $lblUpdatesApps.ForeColor = [System.Drawing.Color]::FromArgb(127, 131, 138)
    $lblUpdatesApps.Location = New-Object System.Drawing.Point(24, 86)
    $lblUpdatesApps.Size = New-Object System.Drawing.Size(400, 18)
    $tabUpdates.Controls.Add($lblUpdatesApps)

    $updatesLines = @()
    foreach ($file in @($Config.files)) {
        $state = if (Resolve-InstalledPath -File $file) { 'instalado' } else { 'no instalado' }
        $updatesLines += ('- {0}: {1}' -f $file.name, $state)
    }

    $lblUpdatesList = New-Object System.Windows.Forms.Label
    $lblUpdatesList.Text = ($updatesLines -join "`r`n")
    $lblUpdatesList.ForeColor = $colors.text
    $lblUpdatesList.Location = New-Object System.Drawing.Point(36, 112)
    $lblUpdatesList.Size = New-Object System.Drawing.Size(720, 112)
    $tabUpdates.Controls.Add($lblUpdatesList)

    $btnUpdatesAll = New-FlatButton -Text 'Actualizar todos los instalados' -X 24 -Y 238 -Width 240 -Height 40 -Primary
    $tabUpdates.Controls.Add($btnUpdatesAll)

    $btnRefreshState = New-FlatButton -Text 'Refrescar estado' -X 276 -Y 238 -Width 160 -Height 40
    $tabUpdates.Controls.Add($btnRefreshState)

    $btnWingetAll = New-FlatButton -Text 'Actualizar todo (winget)' -X 448 -Y 238 -Width 290 -Height 40
    $tabUpdates.Controls.Add($btnWingetAll)

    $script:WingetVersion = ''
    if (Test-WingetAvailable) {
        try { $script:WingetVersion = ((& winget --version 2>&1 | Out-String).Trim()) } catch { }
    }

    $lblWingetState = New-Object System.Windows.Forms.Label
    if (Test-WingetAvailable) {
        $lblWingetState.Text = "winget disponible ($script:WingetVersion). Las actualizaciones usan el catalogo oficial de winget."
        $lblWingetState.ForeColor = $colors.green
    } else {
        $lblWingetState.Text = 'winget no esta disponible. Instala App Installer desde Microsoft Store para actualizar y desinstalar.'
        $lblWingetState.ForeColor = [System.Drawing.Color]::FromArgb(230, 160, 40)
    }
    $lblWingetState.Location = New-Object System.Drawing.Point(24, 292)
    $lblWingetState.Size = New-Object System.Drawing.Size(740, 40)
    $tabUpdates.Controls.Add($lblWingetState)

    $lblWindowsUpdate = New-Object System.Windows.Forms.Label
    $lblWindowsUpdate.Text = 'WINDOWS UPDATE'
    $lblWindowsUpdate.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $lblWindowsUpdate.ForeColor = [System.Drawing.Color]::FromArgb(127, 131, 138)
    $lblWindowsUpdate.Location = New-Object System.Drawing.Point(24, 356)
    $lblWindowsUpdate.Size = New-Object System.Drawing.Size(400, 18)
    $tabUpdates.Controls.Add($lblWindowsUpdate)

    $btnOpenWindowsUpdate = New-FlatButton -Text 'Abrir Windows Update' -X 24 -Y 382 -Width 210 -Height 40
    $tabUpdates.Controls.Add($btnOpenWindowsUpdate)

    $btnOpenUpdateHistory = New-FlatButton -Text 'Ver historial' -X 246 -Y 382 -Width 150 -Height 40
    $tabUpdates.Controls.Add($btnOpenUpdateHistory)

    $btnWindowsUpdate = New-FlatButton -Text 'Instalar actualizaciones pendientes' -X 408 -Y 382 -Width 330 -Height 40
    $tabUpdates.Controls.Add($btnWindowsUpdate)

    $lblUpdatesNote = New-Object System.Windows.Forms.Label
    $lblUpdatesNote.Text = 'WinUtil tambien modifica las politicas de Windows Update. Aqui no se desactivan actualizaciones por seguridad.'
    $lblUpdatesNote.ForeColor = $colors.muted
    $lblUpdatesNote.Location = New-Object System.Drawing.Point(24, 440)
    $lblUpdatesNote.Size = New-Object System.Drawing.Size(740, 40)
    $tabUpdates.Controls.Add($lblUpdatesNote)


    # Pestana Ajustes
    $lblTweaksTitle = New-Object System.Windows.Forms.Label
    $lblTweaksTitle.Text = 'Ajustes del sistema'
    $lblTweaksTitle.Font = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
    $lblTweaksTitle.ForeColor = $colors.text
    $lblTweaksTitle.Location = New-Object System.Drawing.Point(24, 20)
    $lblTweaksTitle.Size = New-Object System.Drawing.Size(500, 30)
    $tabTweaks.Controls.Add($lblTweaksTitle)

    $lblTweaksHint = New-Object System.Windows.Forms.Label
    $lblTweaksHint.Text = 'Los ajustes se aplican antes de instalar. Usa un preset o marca los que quieras.'
    $lblTweaksHint.ForeColor = $colors.muted
    $lblTweaksHint.Location = New-Object System.Drawing.Point(24, 50)
    $lblTweaksHint.Size = New-Object System.Drawing.Size(720, 20)
    $tabTweaks.Controls.Add($lblTweaksHint)

    $btnPresetRecommended = New-FlatButton -Text 'Recomendado' -X 18 -Y 78 -Width 136 -Height 32 -Primary
    $btnPresetMinimal = New-FlatButton -Text 'Minimo' -X 162 -Y 78 -Width 120 -Height 32
    $btnPresetAdvanced = New-FlatButton -Text 'Avanzados' -X 290 -Y 78 -Width 136 -Height 32
    $btnPresetAll = New-FlatButton -Text 'Todo' -X 434 -Y 78 -Width 100 -Height 32
    $btnPresetClear = New-FlatButton -Text 'Limpiar' -X 542 -Y 78 -Width 120 -Height 32
    $tabTweaks.Controls.Add($btnPresetRecommended)
    $tabTweaks.Controls.Add($btnPresetMinimal)
    $tabTweaks.Controls.Add($btnPresetAdvanced)
    $tabTweaks.Controls.Add($btnPresetAll)
    $tabTweaks.Controls.Add($btnPresetClear)

    $flowTweaks = New-Object System.Windows.Forms.FlowLayoutPanel
    $flowTweaks.Location = New-Object System.Drawing.Point(18, 120)
    $flowTweaks.Size = New-Object System.Drawing.Size(760, 310)
    $flowTweaks.FlowDirection = 'TopDown'
    $flowTweaks.WrapContents = $false
    $flowTweaks.AutoScroll = $true
    $flowTweaks.BackColor = $colors.window
    $tabTweaks.Controls.Add($flowTweaks)

    $tweakCategories = @($Config.tweaks | ForEach-Object { $_.category } | Select-Object -Unique)
    foreach ($category in $tweakCategories) {
        $header = New-Object System.Windows.Forms.Label
        $header.Text = [string]$category
        $header.Font = New-Object System.Drawing.Font('Segoe UI', 10.5, [System.Drawing.FontStyle]::Bold)
        $header.ForeColor = [System.Drawing.Color]::FromArgb(90, 169, 230)
        $header.Size = New-Object System.Drawing.Size(736, 24)
        $header.Margin = New-Object System.Windows.Forms.Padding(0, 10, 0, 4)
        $flowTweaks.Controls.Add($header)

        foreach ($tweak in @($Config.tweaks | Where-Object { $_.category -eq $category })) {
            $row = New-Object System.Windows.Forms.Panel
            $row.Size = New-Object System.Drawing.Size(736, 54)
            $row.BackColor = $colors.panel
            $row.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)

            $check = New-Object ElvisToggle
            $check.Text = $tweak.name
            $check.Tag = $tweak.id
            $check.Checked = [bool]$tweak.enabled
            $check.Location = New-Object System.Drawing.Point(12, 7)
            $check.Size = New-Object System.Drawing.Size(708, 24)
            $check.Font = New-Object System.Drawing.Font('Segoe UI', 11)
            $check.ForeColor = $colors.text
            $check.BackColor = $colors.panel
            $check.Add_CheckedChanged({ Update-TweakSelectionCount })
            $row.Controls.Add($check)

            if ($tweak.description) {
                $description = New-Object System.Windows.Forms.Label
                $description.Text = $tweak.description
                $description.ForeColor = $colors.muted
                $description.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
                $description.Location = New-Object System.Drawing.Point(48, 30)
                $description.Size = New-Object System.Drawing.Size(676, 18)
                $row.Controls.Add($description)
            }

            $row.Add_Resize({
                param($sender, $eventArgs)
                $rowWidth = $sender.Width
                foreach ($child in $sender.Controls) {
                    if ($child -is [ElvisToggle]) {
                        $child.Width = [Math]::Max(200, $rowWidth - 28)
                    } elseif ($child -is [System.Windows.Forms.Label]) {
                        $child.Width = [Math]::Max(150, $rowWidth - 60)
                    }
                }
            })

            $flowTweaks.Controls.Add($row)
            $script:TweakChecks[$tweak.id] = $check
            $script:TweakModels[$tweak.id] = $tweak
        }
    }

    if ($flowTweaks.Controls.Count -eq 0) {
        $lblNoTweaks = New-Object System.Windows.Forms.Label
        $lblNoTweaks.Text = 'No hay ajustes configurados.'
        $lblNoTweaks.ForeColor = $colors.muted
        $lblNoTweaks.AutoSize = $true
        $lblNoTweaks.Location = New-Object System.Drawing.Point(24, 130)
        $tabTweaks.Controls.Add($lblNoTweaks)
    }

    $flowTweaks.AutoScrollPosition = New-Object System.Drawing.Point(0, 0)

    $flowTweaks.Add_Resize({
        param($sender, $eventArgs)
        $flowWidth = [Math]::Max(300, $sender.ClientSize.Width - 24)
        foreach ($control in $sender.Controls) {
            if ($control -is [System.Windows.Forms.Panel] -or $control -is [System.Windows.Forms.Label]) {
                $control.Width = $flowWidth
            }
        }
    })

    $btnApplyTweaks = New-FlatButton -Text 'Ejecutar ajustes marcados' -X 18 -Y 448 -Width 240 -Height 40 -Primary
    $tabTweaks.Controls.Add($btnApplyTweaks)

    $btnUndoTweaks = New-FlatButton -Text 'Deshacer seleccionados' -X 270 -Y 448 -Width 220 -Height 40
    $tabTweaks.Controls.Add($btnUndoTweaks)

    $lblTweakCount = New-Object System.Windows.Forms.Label
    $lblTweakCount.Location = New-Object System.Drawing.Point(18, 492)
    $lblTweakCount.Size = New-Object System.Drawing.Size(400, 20)
    $lblTweakCount.ForeColor = $colors.text
    $lblTweakCount.Font = New-Object System.Drawing.Font('Segoe UI', 11)
    $lblTweakCount.Text = 'Ajustes seleccionados: 0'
    $tabTweaks.Controls.Add($lblTweakCount)

    $lblTweaksFooter = New-Object System.Windows.Forms.Label
    $lblTweaksFooter.Text = 'Ejecutar ajustes no instala programas. El punto de restauracion se ejecuta primero.'
    $lblTweaksFooter.ForeColor = $colors.muted
    $lblTweaksFooter.Location = New-Object System.Drawing.Point(18, 514)
    $lblTweaksFooter.Size = New-Object System.Drawing.Size(740, 20)
    $tabTweaks.Controls.Add($lblTweaksFooter)

    $tabTweaks.Add_Resize({
        $tabHeight = $tabTweaks.ClientSize.Height
        $tabWidth = $tabTweaks.ClientSize.Width
        $buttonsTop = [Math]::Max(448, $tabHeight - 98)
        $countTop = $buttonsTop + 44
        $footerTop = $countTop + 22
        $flowHeight = [Math]::Max(120, $buttonsTop - 12 - 120)
        $contentWidth = [Math]::Max(400, $tabWidth - 36)

        $flowTweaks.Location = New-Object System.Drawing.Point(18, 120)
        $flowTweaks.Size = New-Object System.Drawing.Size($contentWidth, $flowHeight)
        $btnApplyTweaks.Location = New-Object System.Drawing.Point(18, $buttonsTop)
        $btnUndoTweaks.Location = New-Object System.Drawing.Point(270, $buttonsTop)
        $lblTweakCount.Location = New-Object System.Drawing.Point(18, $countTop)
        $lblTweaksFooter.Location = New-Object System.Drawing.Point(18, $footerTop)
        $lblTweaksFooter.Width = $contentWidth
    })

    # Pestana Registro
    $lblLogTitle = New-Object System.Windows.Forms.Label
    $lblLogTitle.Text = 'Registro de actividades'
    $lblLogTitle.Font = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
    $lblLogTitle.ForeColor = $colors.text
    $lblLogTitle.Location = New-Object System.Drawing.Point(24, 20)
    $lblLogTitle.Size = New-Object System.Drawing.Size(500, 30)
    $tabLog.Controls.Add($lblLogTitle)

    $txtLog = New-Object System.Windows.Forms.RichTextBox
    $txtLog.Dock = 'Fill'
    $txtLog.ReadOnly = $true
    $txtLog.BackColor = [System.Drawing.Color]::FromArgb(24, 25, 28)
    $txtLog.ForeColor = $colors.text
    $txtLog.BorderStyle = 'FixedSingle'
    $txtLog.Font = New-Object System.Drawing.Font('Consolas', 11)
    $txtLog.ScrollBars = 'Vertical'
    $txtLog.WordWrap = $true
    $txtLog.DetectUrls = $false
    $txtLog.HideSelection = $false
    $tabLog.Padding = New-Object System.Windows.Forms.Padding(24, 54, 24, 24)
    $tabLog.Controls.Add($txtLog)

    # Pestana Config
    $lblConfigTitle = New-Object System.Windows.Forms.Label
    $lblConfigTitle.Text = 'Configuracion'
    $lblConfigTitle.Font = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
    $lblConfigTitle.ForeColor = $colors.text
    $lblConfigTitle.Location = New-Object System.Drawing.Point(24, 20)
    $lblConfigTitle.Size = New-Object System.Drawing.Size(500, 30)
    $tabConfig.Controls.Add($lblConfigTitle)

    $installedCount = 0
    foreach ($file in @($Config.files)) {
        if (Resolve-InstalledPath -File $file) { $installedCount++ }
    }

    $lblConfigInfo = New-Object System.Windows.Forms.Label
    $lblConfigInfo.Location = New-Object System.Drawing.Point(24, 58)
    $lblConfigInfo.Size = New-Object System.Drawing.Size(748, 180)
    $lblConfigInfo.ForeColor = $colors.text
    $lblConfigInfo.Font = New-Object System.Drawing.Font('Segoe UI', 11)
    $lblConfigInfo.Text = @"
Archivo de configuracion:
$ConfigPath

Registro de esta sesion:
$($script:LogFile)

Programas: $(@($Config.files).Count) (instalados: $installedCount)
Ajustes: $(@($Config.tweaks).Count)
Accesos directos: $(@($Config.shortcuts).Count)
"@
    $tabConfig.Controls.Add($lblConfigInfo)

    $lblBackendInfo = New-Object System.Windows.Forms.Label
    $lblBackendInfo.Location = New-Object System.Drawing.Point(24, 248)
    $lblBackendInfo.Size = New-Object System.Drawing.Size(748, 24)
    $lblBackendInfo.ForeColor = $colors.muted
    $lblBackendInfo.Font = New-Object System.Drawing.Font('Segoe UI', 11)
    $lblBackendInfo.Text = 'Motor actual: Directo (instaladores verificados).'
    $tabConfig.Controls.Add($lblBackendInfo)

    $lblConfigTools = New-Object System.Windows.Forms.Label
    $lblConfigTools.Text = 'HERRAMIENTAS'
    $lblConfigTools.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $lblConfigTools.ForeColor = [System.Drawing.Color]::FromArgb(127, 131, 138)
    $lblConfigTools.Location = New-Object System.Drawing.Point(24, 282)
    $lblConfigTools.Size = New-Object System.Drawing.Size(400, 18)
    $tabConfig.Controls.Add($lblConfigTools)

    $btnOpenConfig = New-FlatButton -Text 'Abrir config.json' -X 24 -Y 306 -Width 230
    $btnOpenLogs = New-FlatButton -Text 'Abrir carpeta de registros' -X 264 -Y 306 -Width 230
    $btnConfigRefresh = New-FlatButton -Text 'Refrescar estado' -X 504 -Y 306 -Width 230
    $tabConfig.Controls.Add($btnOpenConfig)
    $tabConfig.Controls.Add($btnOpenLogs)
    $tabConfig.Controls.Add($btnConfigRefresh)

    $btnControlPanel = New-FlatButton -Text 'Panel de control' -X 24 -Y 346 -Width 230
    $btnNetworkPanel = New-FlatButton -Text 'Conexiones de red' -X 264 -Y 346 -Width 230
    $btnSoundPanel = New-FlatButton -Text 'Sonido' -X 504 -Y 346 -Width 230
    $tabConfig.Controls.Add($btnControlPanel)
    $tabConfig.Controls.Add($btnNetworkPanel)
    $tabConfig.Controls.Add($btnSoundPanel)

    $btnPrinterPanel = New-FlatButton -Text 'Impresoras' -X 24 -Y 386 -Width 230
    $btnProgramsPanel = New-FlatButton -Text 'Programas y caracteristicas' -X 264 -Y 386 -Width 230
    $btnRepairWinget = New-FlatButton -Text 'Reparar winget' -X 504 -Y 386 -Width 230
    $tabConfig.Controls.Add($btnPrinterPanel)
    $tabConfig.Controls.Add($btnProgramsPanel)
    $tabConfig.Controls.Add($btnRepairWinget)

    $btnResetNetwork = New-FlatButton -Text 'Reset de red' -X 24 -Y 426 -Width 230
    $btnScanCorruption = New-FlatButton -Text 'Escanear corrupcion' -X 264 -Y 426 -Width 230
    $btnCleanTempWindows = New-FlatButton -Text 'Limpiar temporales' -X 504 -Y 426 -Width 230
    $tabConfig.Controls.Add($btnResetNetwork)
    $tabConfig.Controls.Add($btnScanCorruption)
    $tabConfig.Controls.Add($btnCleanTempWindows)

    $lblConfigEnergy = New-Object System.Windows.Forms.Label
    $lblConfigEnergy.Text = 'ENERGIA'
    $lblConfigEnergy.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $lblConfigEnergy.ForeColor = [System.Drawing.Color]::FromArgb(127, 131, 138)
    $lblConfigEnergy.Location = New-Object System.Drawing.Point(24, 474)
    $lblConfigEnergy.Size = New-Object System.Drawing.Size(400, 18)
    $tabConfig.Controls.Add($lblConfigEnergy)

    $btnUltimateOn = New-FlatButton -Text 'Ultimate Performance' -X 24 -Y 496 -Width 230
    $btnUltimateOff = New-FlatButton -Text 'Quitar plan' -X 264 -Y 496 -Width 150
    $tabConfig.Controls.Add($btnUltimateOn)
    $tabConfig.Controls.Add($btnUltimateOff)

    $lblConfigNetwork = New-Object System.Windows.Forms.Label
    $lblConfigNetwork.Text = 'RED / DNS'
    $lblConfigNetwork.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $lblConfigNetwork.ForeColor = [System.Drawing.Color]::FromArgb(127, 131, 138)
    $lblConfigNetwork.Location = New-Object System.Drawing.Point(24, 542)
    $lblConfigNetwork.Size = New-Object System.Drawing.Size(400, 18)
    $tabConfig.Controls.Add($lblConfigNetwork)

    $lblDns = New-Object System.Windows.Forms.Label
    $lblDns.Text = 'DNS'
    $lblDns.ForeColor = $colors.text
    $lblDns.Location = New-Object System.Drawing.Point(24, 570)
    $lblDns.Size = New-Object System.Drawing.Size(40, 20)
    $tabConfig.Controls.Add($lblDns)

    $cmbDns = New-Object System.Windows.Forms.ComboBox
    $cmbDns.Location = New-Object System.Drawing.Point(70, 566)
    $cmbDns.Size = New-Object System.Drawing.Size(220, 26)
    $cmbDns.DropDownStyle = 'DropDownList'
    $cmbDns.FlatStyle = 'Flat'
    $cmbDns.BackColor = $colors.panel
    $cmbDns.ForeColor = $colors.text
    foreach ($item in @('Predeterminado (DHCP)', 'Google', 'Cloudflare', 'Cloudflare (malware)', 'Quad9', 'AdGuard')) {
        $cmbDns.Items.Add($item) | Out-Null
    }
    $cmbDns.SelectedIndex = 0
    $tabConfig.Controls.Add($cmbDns)

    $btnApplyDns = New-FlatButton -Text 'Aplicar DNS' -X 300 -Y 564 -Width 110 -Height 30
    $btnDnsDhcp = New-FlatButton -Text 'Restablecer DHCP' -X 418 -Y 564 -Width 140 -Height 30
    $tabConfig.Controls.Add($btnApplyDns)
    $tabConfig.Controls.Add($btnDnsDhcp)

    $lblConfigNote = New-Object System.Windows.Forms.Label
    $lblConfigNote.Text = 'DNS se aplica a los adaptadores fisicos activos. Ultimate Performance no se recomienda en laptops.'
    $lblConfigNote.ForeColor = $colors.muted
    $lblConfigNote.Location = New-Object System.Drawing.Point(24, 604)
    $lblConfigNote.Size = New-Object System.Drawing.Size(740, 20)
    $tabConfig.Controls.Add($lblConfigNote)

    $configTip = New-Object System.Windows.Forms.ToolTip
    $configTip.SetToolTip($btnScanCorruption, 'SFC + DISM abre una consola aparte y puede tardar varios minutos.')
    $configTip.SetToolTip($btnResetNetwork, 'Restablece la pila IP y Winsock. Requiere reiniciar.')
    $configTip.SetToolTip($btnCleanTempWindows, 'Elimina archivos temporales del usuario y del sistema.')
    $configTip.SetToolTip($btnUltimateOn, 'Activa el plan de energia Ultimate Performance. No recomendado para laptops.')
    $configTip.SetToolTip($cmbDns, 'Cambia el DNS de todos los adaptadores fisicos activos.')

    # --- Botones laterales ---------------------------------------------------
    $lblActions = New-Object System.Windows.Forms.Label
    $lblActions.Text = 'ACCIONES'
    $lblActions.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $lblActions.ForeColor = [System.Drawing.Color]::FromArgb(127, 131, 138)
    $lblActions.Location = New-Object System.Drawing.Point(14, 16)
    $lblActions.Size = New-Object System.Drawing.Size(172, 18)
    $sideBar.Controls.Add($lblActions)

    function New-SidebarButton {
        param([string]$Text, [int]$Y, [switch]$Primary)

        $button = New-Object System.Windows.Forms.Button
        $button.Text = $Text
        $button.Location = New-Object System.Drawing.Point(14, $Y)
        $button.Size = New-Object System.Drawing.Size(176, 34)
        $button.FlatStyle = 'Flat'
        $button.FlatAppearance.BorderSize = 0
        $button.TextAlign = 'MiddleLeft'
        $button.Padding = New-Object System.Windows.Forms.Padding(8, 0, 0, 0)
        $button.Cursor = 'Hand'

        if ($Primary) {
            $button.BackColor = $colors.accent
            $button.ForeColor = [System.Drawing.Color]::White
            $button.Font = New-Object System.Drawing.Font('Segoe UI', 11.5, [System.Drawing.FontStyle]::Bold)
            $button.FlatAppearance.MouseOverBackColor = $colors.accentHover
            $button.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(37, 90, 168)
        } else {
            $button.BackColor = $colors.sideBar
            $button.ForeColor = [System.Drawing.Color]::FromArgb(220, 221, 222)
            $button.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(49, 51, 56)
            $button.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(58, 60, 66)
        }

        $sideBar.Controls.Add($button)
        return $button
    }

    $btnPrimary = New-SidebarButton -Text 'Instalar seleccionados' -Y 40 -Primary
    $btnUninstall = New-SidebarButton -Text 'Desinstalar' -Y 78
    $btnUpgradeAll = New-SidebarButton -Text 'Actualizar instalados' -Y 114
    $btnShortcuts = New-SidebarButton -Text 'Crear accesos directos' -Y 150
    $btnClean = New-SidebarButton -Text 'Limpiar descargas' -Y 186
    $btnLog = New-SidebarButton -Text 'Abrir registro' -Y 222

    $lblSelection = New-Object System.Windows.Forms.Label
    $lblSelection.Text = 'SELECCION'
    $lblSelection.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $lblSelection.ForeColor = [System.Drawing.Color]::FromArgb(127, 131, 138)
    $lblSelection.Location = New-Object System.Drawing.Point(14, 262)
    $lblSelection.Size = New-Object System.Drawing.Size(172, 18)
    $sideBar.Controls.Add($lblSelection)

    $btnAll = New-SidebarButton -Text 'Seleccionar todo' -Y 284
    $btnNone = New-SidebarButton -Text 'Quitar seleccion' -Y 320
    $btnExpand = New-SidebarButton -Text 'Expandir categorias' -Y 356
    $btnCollapse = New-SidebarButton -Text 'Contraer categorias' -Y 392
    $btnInstalledOnly = New-SidebarButton -Text 'Solo instalados' -Y 428

    $lblSummary = New-Object System.Windows.Forms.Label
    $lblSummary.Location = New-Object System.Drawing.Point(16, 470)
    $lblSummary.Size = New-Object System.Drawing.Size(174, 64)
    $lblSummary.ForeColor = $colors.muted
    $lblSummary.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
    $lblSummary.Anchor = 'Bottom,Left'
    $sideBar.Controls.Add($lblSummary)

    $sideBar.Dock = 'Fill'
    $rootLayout.Controls.Add($sideBar, 0, 1)

    # --- Logica de la interfaz ----------------------------------------------
    function Set-UiProgress {
        param([int]$Value)
        if ($Value -lt 0) { $Value = 0 }
        if ($Value -gt 100) { $Value = 100 }
        $progressFill.Width = [int]($progressTrack.Width * $Value / 100)
        $lblPercent.Text = "$Value%"
    }

    function Append-UiLog {
        param([string]$Line)

        $color = [System.Drawing.Color]::FromArgb(200, 202, 205)
        if ($Line -match '\[OK\]') { $color = [System.Drawing.Color]::FromArgb(87, 200, 120) }
        elseif ($Line -match '\[WARN\]') { $color = [System.Drawing.Color]::FromArgb(230, 180, 80) }
        elseif ($Line -match '\[ERROR\]') { $color = [System.Drawing.Color]::FromArgb(240, 110, 110) }

        $txtLog.SelectionStart = $txtLog.TextLength
        $txtLog.SelectionLength = 0
        $txtLog.SelectionColor = $color
        $txtLog.AppendText($Line + "`r`n")
        $txtLog.SelectionStart = $txtLog.TextLength
        $txtLog.ScrollToCaret()
    }

    function Add-UiMessage {
        param([string]$Message, [string]$Level = 'INFO')

        Write-LogLine $Message $Level
        Append-UiLog ('[{0}] [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message)

        try {
            if (Test-Path -LiteralPath $script:LogFile) {
                $script:LogPos = (Get-Item -LiteralPath $script:LogFile).Length
            }
        } catch { }
    }

    function Read-NewLogLines {
        if (-not $script:LogFile -or -not (Test-Path -LiteralPath $script:LogFile)) { return @() }

        $lines = @()
        try {
            $stream = [System.IO.File]::Open($script:LogFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try {
                if ($stream.Length -lt $script:LogPos) { $script:LogPos = 0 }
                $stream.Position = $script:LogPos
                $remaining = [int]($stream.Length - $stream.Position)
                if ($remaining -gt 0) {
                    $buffer = New-Object byte[] $remaining
                    $read = $stream.Read($buffer, 0, $remaining)
                    $lastNewLine = -1
                    for ($i = $read - 1; $i -ge 0; $i--) {
                        if ($buffer[$i] -eq 10) { $lastNewLine = $i; break }
                    }
                    if ($lastNewLine -ge 0) {
                        $text = $script:Utf8NoBom.GetString($buffer, 0, $lastNewLine + 1)
                        $script:LogPos = $script:LogPos + $lastNewLine + 1
                        $lines = @($text -split "`r?`n" | Where-Object { $_ -ne '' })
                    }
                }
            } finally {
                $stream.Dispose()
            }
        } catch { }
        return $lines
    }

    function Read-ProgressFile {
        if (-not $script:ProgressFile -or -not (Test-Path -LiteralPath $script:ProgressFile)) { return $null }
        try {
            $json = [System.IO.File]::ReadAllText($script:ProgressFile, $script:Utf8NoBom)
            if ([string]::IsNullOrWhiteSpace($json)) { return $null }
            return ($json | ConvertFrom-Json)
        } catch {
            return $null
        }
    }

    function Update-InstallButton {
        if ($script:IsInstalling) { return }
        $count = $cardsView.SelectedCount
        if ($count -gt 0) {
            $btnPrimary.Text = "Instalar ($count)"
        } else {
            $btnPrimary.Text = 'Instalar'
        }
    }

    function Update-SidebarSummary {
        $installed = 0
        foreach ($file in @($Config.files)) {
            if (Resolve-InstalledPath -File $file) { $installed++ }
        }
        $lblSummary.Text = "{0} programas`n{1} instalados`n{2} ajustes" -f @($Config.files).Count, $installed, @($Config.tweaks).Count
    }

    function Update-UpdatesSummary {
        if (-not $lblUpdatesList) { return }

        $lines = @()
        foreach ($file in @($Config.files)) {
            $state = if (Resolve-InstalledPath -File $file) { 'instalado' } else { 'no instalado' }
            $lines += ('- {0}: {1}' -f $file.name, $state)
        }
        $lblUpdatesList.Text = ($lines -join "`r`n")

        if (Test-WingetAvailable) {
            $lblWingetState.Text = "winget disponible ($($script:WingetVersion)). Las actualizaciones usan el catalogo oficial de winget."
            $lblWingetState.ForeColor = $colors.green
        } else {
            $lblWingetState.Text = 'winget no esta disponible. Instala App Installer desde Microsoft Store para actualizar y desinstalar.'
            $lblWingetState.ForeColor = [System.Drawing.Color]::FromArgb(230, 160, 40)
        }
    }

    function Rebuild-ProgramCards {
        $selection = @($cardsView.GetSelectedIds())
        $models = Build-ProgramModels -Config $Config -SelectedIds $selection -StatusMap $script:ProgramStatus
        $cardsView.SetPrograms($models)
        Update-InstallButton
        Update-SidebarSummary
        Update-UpdatesSummary
    }

    function Update-UiProgress {
        $state = Read-ProgressFile
        if ($null -eq $state) { return }

        $value = 0
        if ($null -ne $state.percent) { $value = [int]$state.percent }
        Set-UiProgress -Value $value

        if ($state.status) { $lblStatus.Text = [string]$state.status }

        $statusMap = @{
            'pending'      = @{ Text = 'En espera'; Kind = 0 }
            'downloading'  = @{ Text = 'Descargando'; Kind = 0 }
            'verifying'    = @{ Text = 'Verificando'; Kind = 0 }
            'installing'   = @{ Text = 'Instalando'; Kind = 0 }
            'upgrading'    = @{ Text = 'Actualizando'; Kind = 0 }
            'uninstalling' = @{ Text = 'Desinstalando'; Kind = 0 }
            'ok'           = @{ Text = 'Instalado'; Kind = 1 }
            'downloaded'   = @{ Text = 'Descargado'; Kind = 1 }
            'updated'      = @{ Text = 'Actualizado'; Kind = 1 }
            'uptodate'     = @{ Text = 'Al dia'; Kind = 1 }
            'uninstalled'  = @{ Text = 'Desinstalado'; Kind = 0 }
            'skipped'      = @{ Text = 'Omitido'; Kind = 3 }
            'warn'         = @{ Text = 'Advertencia'; Kind = 3 }
            'error'        = @{ Text = 'Error'; Kind = 2 }
            'cancelled'    = @{ Text = 'Cancelado'; Kind = 3 }
        }

        foreach ($entry in @($state.items)) {
            $mapped = $statusMap[[string]$entry.status]
            if (-not $mapped) { $mapped = @{ Text = [string]$entry.status; Kind = 0 } }
            $script:ProgramStatus[[string]$entry.id] = @{ Text = $mapped.Text; Kind = $mapped.Kind }
            $cardsView.SetStatus([string]$entry.id, $mapped.Text, $mapped.Kind)
        }
    }

    function Set-RunningState {
        param([bool]$Running)

        $script:IsInstalling = $Running
        $wingetOk = Test-WingetAvailable
        $btnUninstall.Enabled = (-not $Running) -and $wingetOk
        $btnUpgradeAll.Enabled = (-not $Running) -and $wingetOk
        $btnShortcuts.Enabled = -not $Running
        $btnClean.Enabled = -not $Running
        $btnAll.Enabled = -not $Running
        $btnNone.Enabled = -not $Running
        $btnExpand.Enabled = -not $Running
        $btnCollapse.Enabled = -not $Running
        $btnInstalledOnly.Enabled = -not $Running
        $btnApplyTweaks.Enabled = -not $Running
        $btnUndoTweaks.Enabled = -not $Running
        $btnPresetRecommended.Enabled = -not $Running
        $btnPresetMinimal.Enabled = -not $Running
        $btnPresetAdvanced.Enabled = -not $Running
        $btnPresetAll.Enabled = -not $Running
        $btnPresetClear.Enabled = -not $Running
        $btnUpdatesAll.Enabled = (-not $Running) -and $wingetOk
        $btnWingetAll.Enabled = (-not $Running) -and $wingetOk
        $btnWindowsUpdate.Enabled = -not $Running
        $btnRefreshState.Enabled = -not $Running
        $btnConfigRefresh.Enabled = -not $Running
        $btnRepairWinget.Enabled = (-not $Running) -and $wingetOk
        $btnResetNetwork.Enabled = -not $Running
        $btnScanCorruption.Enabled = -not $Running
        $btnCleanTempWindows.Enabled = -not $Running
        $btnUltimateOn.Enabled = -not $Running
        $btnUltimateOff.Enabled = -not $Running
        $btnApplyDns.Enabled = -not $Running
        $btnDnsDhcp.Enabled = -not $Running
        $cmbDns.Enabled = -not $Running
        $btnBackendWinget.Enabled = (-not $Running) -and $wingetOk
        $btnBackendDirect.Enabled = -not $Running
        $cardsView.Enabled = -not $Running
        $flowTweaks.Enabled = -not $Running

        if ($Running) {
            $btnPrimary.Text = 'Cancelar operacion'
            $btnPrimary.BackColor = $colors.red
            $btnPrimary.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(200, 70, 70)
            $btnPrimary.Enabled = $true
        } else {
            $btnPrimary.BackColor = $colors.accent
            $btnPrimary.FlatAppearance.MouseOverBackColor = $colors.accentHover
            $btnPrimary.Enabled = $true
            Update-InstallButton
        }
    }

    function Show-Tab {
        param([string]$Name)

        foreach ($key in $tabPanels.Keys) {
            $tabPanels[$key].Visible = ($key -eq $Name)
        }
        foreach ($key in $tabButtons.Keys) {
            $button = $tabButtons[$key]
            if ($key -eq $Name) {
                $button.BackColor = $colors.accent
                $button.ForeColor = [System.Drawing.Color]::White
            } else {
                $button.BackColor = $colors.topBar
                $button.ForeColor = $colors.muted
            }
        }

        $txtSearch.Enabled = ($Name -eq 'install')

        if ($Name -eq 'tweaks') {
            $flowTweaks.AutoScrollPosition = New-Object System.Drawing.Point(0, 0)
        }
    }

    function Update-BackendUi {
        $direct = ($script:Backend -eq 'direct')

        if ($direct) {
            $btnBackendDirect.BackColor = $colors.accent
            $btnBackendDirect.ForeColor = [System.Drawing.Color]::White
            $btnBackendWinget.BackColor = $colors.topBar
            $btnBackendWinget.ForeColor = $colors.muted
            $lblBackendInfo.Text = 'Motor actual: Directo (instaladores oficiales verificados con SHA256 y/o firma).'
        } else {
            $btnBackendDirect.BackColor = $colors.topBar
            $btnBackendDirect.ForeColor = $colors.muted
            $btnBackendWinget.BackColor = $colors.accent
            $btnBackendWinget.ForeColor = [System.Drawing.Color]::White
            $lblBackendInfo.Text = 'Motor actual: Winget (instala y actualiza desde el catalogo de Windows Package Manager).'
        }
    }

    function Set-UiBackend {
        param([string]$Name)

        if ($Name -eq 'winget' -and -not (Test-WingetAvailable)) {
            [System.Windows.Forms.MessageBox]::Show('winget no esta disponible en este equipo. Instala App Installer desde Microsoft Store.', 'ElvisLab', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }

        $script:Backend = $Name
        Update-BackendUi
    }

    function Get-SelectedTweakIds {
        $ids = @()
        foreach ($key in $script:TweakChecks.Keys) {
            if ($script:TweakChecks[$key].Checked) { $ids += $key }
        }
        return $ids
    }

    function Set-TweakPreset {
        param([string]$Name)

        foreach ($key in $script:TweakChecks.Keys) {
            $model = $script:TweakModels[$key]
            $checked = switch ($Name) {
                'recommended' { $model.category -eq 'Esenciales' }
                'minimal' { $key -in @('restorepoint', 'telemetry') }
                'advanced' { $model.category -eq 'Avanzados' }
                'all' { $true }
                'clear' { $false }
                default { $false }
            }
            $script:TweakChecks[$key].Checked = [bool]$checked
        }

        Update-TweakSelectionCount
    }

    function Update-TweakSelectionCount {
        $count = @($script:TweakChecks.Values | Where-Object { $_.Checked }).Count
        $lblTweakCount.Text = "Ajustes seleccionados: $count"
    }

    function Start-ElvisJob {
        param(
            [string[]]$ExtraArguments,
            [string]$InitialStatus,
            [switch]$OpenLogTab
        )

        if ($script:InstallProcess -and -not $script:InstallProcess.HasExited) { return $false }

        $runId = [guid]::NewGuid().ToString('N')
        $runDir = Join-Path $env:TEMP "ElvisLab\run_$runId"
        New-Item -ItemType Directory -Path $runDir -Force | Out-Null

        $script:ProgressFile = Join-Path $runDir 'progress.json'
        $script:CancelFile = Join-Path $runDir 'cancel.flag'

        try {
            $launch = Get-HostLaunchCommand
            $arguments = New-Object System.Collections.Generic.List[string]
            foreach ($part in $launch.Prefix) { $arguments.Add([string]$part) }
            $arguments.Add('-Headless')
            $arguments.Add('-ConfigPath'); $arguments.Add(('"{0}"' -f $ConfigPath))
            $arguments.Add('-ProgressFile'); $arguments.Add(('"{0}"' -f $script:ProgressFile))
            $arguments.Add('-CancelFile'); $arguments.Add(('"{0}"' -f $script:CancelFile))
            if ($script:LogFile) {
                $arguments.Add('-LogFile'); $arguments.Add(('"{0}"' -f $script:LogFile))
            }
            foreach ($arg in $ExtraArguments) { $arguments.Add([string]$arg) }

            $script:InstallProcess = Start-Process -FilePath $launch.FileName -ArgumentList ($arguments -join ' ') -PassThru -WindowStyle Hidden
        } catch {
            Add-UiMessage "No se pudo iniciar el proceso: $($_.Exception.Message)" 'ERROR'
            return $false
        }

        Set-RunningState -Running $true
        Set-UiProgress -Value 0
        $lblStatus.Text = $InitialStatus
        if ($OpenLogTab) { Show-Tab -Name 'log' }
        $timer.Start()
        return $true
    }

    # --- Pestanas ------------------------------------------------------------
    $tabButtons = @{}
    $tabDefinitions = @(
        @{ id = 'install'; text = 'Instalar' },
        @{ id = 'tweaks'; text = 'Ajustes' },
        @{ id = 'updates'; text = 'Actualizar' },
        @{ id = 'log'; text = 'Registro' },
        @{ id = 'config'; text = 'Config' }
    )

    $tabX = 152
    foreach ($tab in $tabDefinitions) {
        $button = New-Object System.Windows.Forms.Button
        $button.Text = $tab.text
        $button.Location = New-Object System.Drawing.Point($tabX, 10)
        $button.Size = New-Object System.Drawing.Size(88, 30)
        $button.FlatStyle = 'Flat'
        $button.FlatAppearance.BorderSize = 0
        $button.BackColor = $colors.topBar
        $button.ForeColor = $colors.muted
        $button.Cursor = 'Hand'
        $button.Tag = $tab.id
        $button.Add_Click({
            param($sender, $eventArgs)
            Show-Tab -Name ([string]$sender.Tag)
        })
        $topBar.Controls.Add($button)
        $tabButtons[$tab.id] = $button
        $tabX += 92
    }

    # --- Datos iniciales -----------------------------------------------------
    $cardsView.SetPrograms((Build-ProgramModels -Config $Config -SelectedIds @() -StatusMap $script:ProgramStatus))
    Update-InstallButton
    Update-SidebarSummary
    Update-TweakSelectionCount

    $script:SearchPlaceholder = 'Buscar programas...'
    $txtSearch.Add_GotFocus({
        if ($txtSearch.Text -eq $script:SearchPlaceholder) {
            $txtSearch.Text = ''
            $txtSearch.ForeColor = [System.Drawing.Color]::FromArgb(227, 229, 232)
        }
    })
    $txtSearch.Add_LostFocus({
        if ([string]::IsNullOrWhiteSpace($txtSearch.Text)) {
            $txtSearch.Text = $script:SearchPlaceholder
            $txtSearch.ForeColor = [System.Drawing.Color]::FromArgb(154, 160, 166)
        }
    })
    $txtSearch.Add_TextChanged({
        if ($txtSearch.Text -eq $script:SearchPlaceholder) {
            $cardsView.SetFilter('')
        } else {
            $cardsView.SetFilter($txtSearch.Text)
        }
    })

    $cardsView.Add_SelectionChanged({
        Update-InstallButton
    })

    # --- Timer ---------------------------------------------------------------
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 250
    $timer.Add_Tick({
        foreach ($line in (Read-NewLogLines)) { Append-UiLog $line }
        Update-UiProgress

        if (-not $script:InstallProcess) { return }
        if (-not $script:InstallProcess.HasExited) { return }

        [System.Threading.Thread]::Sleep(150)
        foreach ($line in (Read-NewLogLines)) { Append-UiLog $line }
        Update-UiProgress

        $process = $script:InstallProcess
        $exitCode = $process.ExitCode
        $script:InstallProcess = $null
        $timer.Stop()
        $process.Dispose()

        $final = Read-ProgressFile
        $finalStatus = ''
        if ($final -and $final.status) { $finalStatus = [string]$final.status }

        if ($exitCode -eq 0) {
            if (-not $finalStatus) { $finalStatus = 'Operacion completada.' }
            $lblStatus.Text = $finalStatus
            if (-not $final) { Add-UiMessage $finalStatus 'OK' }
        } elseif ($exitCode -eq 3) {
            if (-not $finalStatus) { $finalStatus = 'Operacion cancelada.' }
            $lblStatus.Text = $finalStatus
            if (-not $final) { Add-UiMessage $finalStatus 'WARN' }
        } else {
            if (-not $finalStatus) { $finalStatus = "La operacion termino con codigo $exitCode. Revisa el registro." }
            $lblStatus.Text = $finalStatus
            if (-not $final) { Add-UiMessage $finalStatus 'ERROR' }
        }

        Set-RunningState -Running $false
        Rebuild-ProgramCards
    })

    # --- Acciones ------------------------------------------------------------
    $btnPrimary.Add_Click({
        if ($script:InstallProcess -and -not $script:InstallProcess.HasExited) {
            try {
                [System.IO.File]::WriteAllText($script:CancelFile, 'cancel', $script:Utf8NoBom)
            } catch { }
            $btnPrimary.Enabled = $false
            $lblStatus.Text = 'Cancelando... (se detiene al terminar el paso actual)'
            Add-UiMessage 'Cancelacion solicitada. Se detendra al terminar el paso actual.' 'WARN'
            return
        }

        $selectedIds = @($cardsView.GetSelectedIds())
        if ($selectedIds.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('Selecciona al menos un programa.', 'ElvisLab', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }

        $tweakIds = @(Get-SelectedTweakIds)
        $extra = @('-Backend', $script:Backend, '-Install', ('"{0}"' -f ($selectedIds -join ',')))
        if ($tweakIds.Count -gt 0) {
            $extra += @('-Tweaks', ('"{0}"' -f ($tweakIds -join ',')))
        } else {
            $extra += '-NoTweaks'
        }

        if (Start-ElvisJob -ExtraArguments $extra -InitialStatus 'Iniciando instalacion...' -OpenLogTab) {
            Add-UiMessage ("Instalando {0} programa(s) y {1} ajuste(s) con motor {2}." -f $selectedIds.Count, $tweakIds.Count, $script:Backend) 'INFO'
        }
    })

    function Start-UpgradeAll {
        if (-not (Test-WingetAvailable)) {
            [System.Windows.Forms.MessageBox]::Show('winget no esta disponible. Instala App Installer desde Microsoft Store.', 'ElvisLab', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        if ($script:InstallProcess -and -not $script:InstallProcess.HasExited) { return }

        $answer = [System.Windows.Forms.MessageBox]::Show('Se actualizaran con winget los programas gestionados que esten instalados. Continuar?', 'ElvisLab', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        if (Start-ElvisJob -ExtraArguments @('-Upgrade') -InitialStatus 'Buscando actualizaciones...' -OpenLogTab) {
            Add-UiMessage 'Actualizando programas gestionados con winget...' 'INFO'
        }
    }

    function Start-WingetUpgradeAll {
        if (-not (Test-WingetAvailable)) {
            [System.Windows.Forms.MessageBox]::Show('winget no esta disponible. Instala App Installer desde Microsoft Store.', 'ElvisLab', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        if ($script:InstallProcess -and -not $script:InstallProcess.HasExited) { return }

        $answer = [System.Windows.Forms.MessageBox]::Show('Se actualizaran con winget TODOS los programas del sistema que tengan actualizacion disponible. Puede tardar varios minutos. Continuar?', 'ElvisLab', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        if (Start-ElvisJob -ExtraArguments @('-UpgradeAll') -InitialStatus 'Buscando actualizaciones con winget...' -OpenLogTab) {
            Add-UiMessage 'Actualizando todas las aplicaciones con winget...' 'INFO'
        }
    }

    function Start-WindowsUpdateInstall {
        if ($script:InstallProcess -and -not $script:InstallProcess.HasExited) { return }

        $answer = [System.Windows.Forms.MessageBox]::Show('Se buscaran, descargaran e instalaran las actualizaciones pendientes de Windows Update. Puede tardar mucho tiempo y requerir reinicio. Continuar?', 'ElvisLab', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        if (Start-ElvisJob -ExtraArguments @('-WindowsUpdate') -InitialStatus 'Buscando actualizaciones de Windows...' -OpenLogTab) {
            Add-UiMessage 'Instalando actualizaciones de Windows...' 'INFO'
        }
    }

    $btnUninstall.Add_Click({
        if (-not (Test-WingetAvailable)) {
            [System.Windows.Forms.MessageBox]::Show('winget no esta disponible. Instala App Installer desde Microsoft Store.', 'ElvisLab', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        if ($script:InstallProcess -and -not $script:InstallProcess.HasExited) { return }

        $selectedIds = @($cardsView.GetSelectedIds())
        if ($selectedIds.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('Selecciona al menos un programa.', 'ElvisLab', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }

        $answer = [System.Windows.Forms.MessageBox]::Show(("Se desinstalaran {0} programa(s) con winget:`r`n`r`n{1}`r`n`r`nContinuar?" -f $selectedIds.Count, ($selectedIds -join ', ')), 'ElvisLab', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        $extra = @('-Uninstall', '-Install', ('"{0}"' -f ($selectedIds -join ',')))
        if (Start-ElvisJob -ExtraArguments $extra -InitialStatus 'Desinstalando programas...' -OpenLogTab) {
            Add-UiMessage ("Desinstalando {0} programa(s) con winget..." -f $selectedIds.Count) 'INFO'
        }
    })

    $btnUpgradeAll.Add_Click({ Start-UpgradeAll })

    $btnPresetRecommended.Add_Click({ Set-TweakPreset -Name 'recommended' })
    $btnPresetMinimal.Add_Click({ Set-TweakPreset -Name 'minimal' })
    $btnPresetAdvanced.Add_Click({ Set-TweakPreset -Name 'advanced' })
    $btnPresetAll.Add_Click({ Set-TweakPreset -Name 'all' })
    $btnPresetClear.Add_Click({ Set-TweakPreset -Name 'clear' })

    $btnApplyTweaks.Add_Click({
        if ($script:InstallProcess -and -not $script:InstallProcess.HasExited) { return }

        $tweakIds = @(Get-SelectedTweakIds)
        if ($tweakIds.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('Marca al menos un ajuste.', 'ElvisLab', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }

        $extra = @('-ApplyOnly', '-Tweaks', ('"{0}"' -f ($tweakIds -join ',')))
        if (Start-ElvisJob -ExtraArguments $extra -InitialStatus 'Aplicando ajustes...') {
            Add-UiMessage ("Aplicando {0} ajuste(s)..." -f $tweakIds.Count) 'INFO'
        }
    })

    $btnUndoTweaks.Add_Click({
        if ($script:InstallProcess -and -not $script:InstallProcess.HasExited) { return }

        $tweakIds = @(Get-SelectedTweakIds)
        if ($tweakIds.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('Marca al menos un ajuste.', 'ElvisLab', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }

        $answer = [System.Windows.Forms.MessageBox]::Show('Se desharan los ajustes seleccionados que lo permitan. Continuar?', 'ElvisLab', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        $extra = @('-UndoTweaks', '-Tweaks', ('"{0}"' -f ($tweakIds -join ',')))
        if (Start-ElvisJob -ExtraArguments $extra -InitialStatus 'Restaurando ajustes...') {
            Add-UiMessage ("Restaurando {0} ajuste(s)..." -f $tweakIds.Count) 'INFO'
        }
    })

    $btnInstalledOnly.Add_Click({
        $script:InstalledOnly = -not $script:InstalledOnly
        $cardsView.SetInstalledOnly($script:InstalledOnly)
        if ($script:InstalledOnly) {
            $btnInstalledOnly.BackColor = $colors.accent
            $btnInstalledOnly.ForeColor = [System.Drawing.Color]::White
        } else {
            $btnInstalledOnly.BackColor = $colors.sideBar
            $btnInstalledOnly.ForeColor = [System.Drawing.Color]::FromArgb(220, 221, 222)
        }
    })

    $btnUpdatesAll.Add_Click({ Start-UpgradeAll })
    $btnWingetAll.Add_Click({ Start-WingetUpgradeAll })
    $btnWindowsUpdate.Add_Click({ Start-WindowsUpdateInstall })

    $btnRefreshState.Add_Click({
        Rebuild-ProgramCards
        Add-UiMessage 'Estado de instalacion actualizado.' 'INFO'
    })

    $btnOpenWindowsUpdate.Add_Click({
        try {
            Start-Process -FilePath 'ms-settings:windowsupdate'
        } catch {
            Add-UiMessage "No se pudo abrir Windows Update: $($_.Exception.Message)" 'ERROR'
        }
    })

    $btnOpenUpdateHistory.Add_Click({
        try {
            Start-Process -FilePath 'ms-settings:windowsupdate-history'
        } catch {
            Add-UiMessage "No se pudo abrir el historial de actualizaciones: $($_.Exception.Message)" 'ERROR'
        }
    })

    $btnShortcuts.Add_Click({
        Add-UiMessage 'Creando accesos directos...' 'INFO'
        $created = 0
        $skipped = 0
        foreach ($shortcut in @($Config.shortcuts)) {
            try {
                if (New-ShortcutItem -Shortcut $shortcut -Config $Config) { $created++ } else { $skipped++ }
            } catch {
                Add-UiMessage "ERROR al crear '$($shortcut.name)': $($_.Exception.Message)" 'ERROR'
            }
        }
        if ($created -gt 0) {
            Add-UiMessage "OK: $created acceso(s) directo(s) creado(s)." 'OK'
        } else {
            Add-UiMessage 'No se creo ningun acceso directo. Instala primero los programas.' 'WARN'
        }
        if ($skipped -gt 0) {
            Add-UiMessage "$skipped acceso(s) omitido(s) porque el programa no esta instalado." 'WARN'
        }
        Update-SidebarSummary
    })

    $btnClean.Add_Click({
        if ($script:InstallProcess -and -not $script:InstallProcess.HasExited) {
            [System.Windows.Forms.MessageBox]::Show('Hay una instalacion en curso. Espera a que termine.', 'ElvisLab', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        $tempRoot = Join-Path $env:TEMP 'ElvisLab'
        try {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
            Add-UiMessage 'Descargas temporales de ElvisLab limpiadas. Los accesos directos no dependen de ellas.' 'OK'
        } catch {
            Add-UiMessage "No se pudo limpiar la carpeta temporal: $($_.Exception.Message)" 'ERROR'
        }
    })

    $btnLog.Add_Click({
        if ($script:LogFile -and (Test-Path -LiteralPath $script:LogFile)) {
            try {
                Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $script:LogFile)
            } catch {
                Add-UiMessage "No se pudo abrir el registro: $($_.Exception.Message)" 'ERROR'
            }
        } else {
            Add-UiMessage 'Todavia no hay un archivo de registro.' 'WARN'
        }
    })

    $btnAll.Add_Click({ $cardsView.SelectAll() })
    $btnNone.Add_Click({ $cardsView.ClearSelection() })
    $btnExpand.Add_Click({ $cardsView.ExpandAll() })
    $btnCollapse.Add_Click({ $cardsView.CollapseAll() })

    $btnOpenConfig.Add_Click({
        try {
            Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $ConfigPath)
        } catch {
            Add-UiMessage "No se pudo abrir config.json: $($_.Exception.Message)" 'ERROR'
        }
    })

    $btnOpenLogs.Add_Click({
        try {
            $folder = Split-Path -Parent $script:LogFile
            Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $folder)
        } catch {
            Add-UiMessage "No se pudo abrir la carpeta de registros: $($_.Exception.Message)" 'ERROR'
        }
    })

    $btnConfigRefresh.Add_Click({
        Rebuild-ProgramCards
        Add-UiMessage 'Estado de instalacion actualizado.' 'INFO'
    })

    $btnControlPanel.Add_Click({
        try { Start-Process -FilePath 'control.exe' } catch { Add-UiMessage "No se pudo abrir el Panel de control: $($_.Exception.Message)" 'ERROR' }
    })

    $btnNetworkPanel.Add_Click({
        try { Start-Process -FilePath 'ncpa.cpl' } catch { Add-UiMessage "No se pudieron abrir las conexiones de red: $($_.Exception.Message)" 'ERROR' }
    })

    $btnSoundPanel.Add_Click({
        try { Start-Process -FilePath 'mmsys.cpl' } catch { Add-UiMessage "No se pudieron abrir los ajustes de sonido: $($_.Exception.Message)" 'ERROR' }
    })

    $btnPrinterPanel.Add_Click({
        try { Start-Process -FilePath 'control.exe' -ArgumentList 'printers' } catch { Add-UiMessage "No se pudieron abrir las impresoras: $($_.Exception.Message)" 'ERROR' }
    })

    $btnProgramsPanel.Add_Click({
        try { Start-Process -FilePath 'appwiz.cpl' } catch { Add-UiMessage "No se pudo abrir Programas y caracteristicas: $($_.Exception.Message)" 'ERROR' }
    })

    $btnRepairWinget.Add_Click({
        if (-not (Test-WingetAvailable)) {
            [System.Windows.Forms.MessageBox]::Show('winget no esta disponible en este equipo.', 'ElvisLab', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        try {
            $result = Invoke-WingetCommand -Arguments @('source', 'update') -Quiet
            if ($result.ExitCode -eq 0) {
                Add-UiMessage 'Fuentes de winget actualizadas correctamente.' 'OK'
            } else {
                Add-UiMessage "winget source update termino con codigo $($result.ExitCode)." 'WARN'
            }
        } catch {
            Add-UiMessage "No se pudo reparar winget: $($_.Exception.Message)" 'ERROR'
        }
    })

    $btnResetNetwork.Add_Click({
        $answer = [System.Windows.Forms.MessageBox]::Show('Se restableceran la pila IP y Winsock. Necesitaras reiniciar. Continuar?', 'ElvisLab', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        try {
            $ipOutput = (& netsh int ip reset 2>&1 | Out-String)
            $ipCode = $LASTEXITCODE
            $winsockOutput = (& netsh winsock reset 2>&1 | Out-String)
            $winsockCode = $LASTEXITCODE
            Add-UiMessage ("Reset de red: IP codigo {0}, Winsock codigo {1}. Reinicia el equipo." -f $ipCode, $winsockCode) $(if ($ipCode -eq 0 -and $winsockCode -eq 0) { 'OK' } else { 'WARN' })
        } catch {
            Add-UiMessage "No se pudo restablecer la red: $($_.Exception.Message)" 'ERROR'
        }
    })

    $btnScanCorruption.Add_Click({
        $answer = [System.Windows.Forms.MessageBox]::Show('SFC + DISM puede tardar mucho tiempo. Se abrira una consola aparte. Continuar?', 'ElvisLab', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        try {
            $command = 'sfc /scannow; DISM /Online /Cleanup-Image /RestoreHealth'
            Start-Process -FilePath 'powershell.exe' -ArgumentList ("-NoExit -ExecutionPolicy Bypass -Command `"$command`"")
            Add-UiMessage 'Se abrio una consola con SFC + DISM.' 'INFO'
        } catch {
            Add-UiMessage "No se pudo iniciar el escaneo: $($_.Exception.Message)" 'ERROR'
        }
    })

    $btnCleanTempWindows.Add_Click({
        $answer = [System.Windows.Forms.MessageBox]::Show('Se eliminaran archivos temporales del usuario y del sistema. Algunos archivos en uso se omitiran. Continuar?', 'ElvisLab', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        try {
            $result = Clear-ElvisTempFiles
            Add-UiMessage ("Temporales: {0} eliminado(s), {1} en uso/omitido(s)." -f $result.Removed, $result.Failed) $(if ($result.Failed -gt 0) { 'WARN' } else { 'OK' })
        } catch {
            Add-UiMessage "No se pudieron limpiar los temporales: $($_.Exception.Message)" 'ERROR'
        }
    })

    $btnUltimateOn.Add_Click({
        $answer = [System.Windows.Forms.MessageBox]::Show('Ultimate Performance esta pensado para equipos de escritorio; no se recomienda en laptops. Deseas activarlo?', 'ElvisLab', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        try {
            $guid = Enable-UltimatePerformance
            Add-UiMessage ("Plan Ultimate Performance activado ({0})." -f $guid) 'OK'
        } catch {
            Add-UiMessage "No se pudo activar Ultimate Performance: $($_.Exception.Message)" 'ERROR'
        }
    })

    $btnUltimateOff.Add_Click({
        $answer = [System.Windows.Forms.MessageBox]::Show('Se activara el plan Equilibrado y se eliminaran los planes Ultimate Performance. Continuar?', 'ElvisLab', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        try {
            $count = Disable-UltimatePerformance
            Add-UiMessage ("Planes Ultimate Performance eliminados: {0}." -f $count) 'OK'
        } catch {
            Add-UiMessage "No se pudo quitar Ultimate Performance: $($_.Exception.Message)" 'ERROR'
        }
    })

    $dnsMap = @{
        'Predeterminado (DHCP)' = 'dhcp'
        'Google' = 'google'
        'Cloudflare' = 'cloudflare'
        'Cloudflare (malware)' = 'cloudflare-malware'
        'Quad9' = 'quad9'
        'AdGuard' = 'adguard'
    }

    $btnApplyDns.Add_Click({
        $selected = [string]$cmbDns.SelectedItem
        $provider = $dnsMap[$selected]
        if (-not $provider) { $provider = 'dhcp' }

        $answer = [System.Windows.Forms.MessageBox]::Show(("Se cambiara el DNS a '{0}' en todos los adaptadores fisicos activos. Continuar?" -f $selected), 'ElvisLab', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        try {
            $count = Set-ElvisDns -Provider $provider
            Add-UiMessage ("DNS '{0}' aplicado en {1} adaptador(es)." -f $selected, $count) 'OK'
        } catch {
            Add-UiMessage "No se pudo aplicar el DNS: $($_.Exception.Message)" 'ERROR'
        }
    })

    $btnDnsDhcp.Add_Click({
        $answer = [System.Windows.Forms.MessageBox]::Show('Se restablecera el DNS a DHCP en todos los adaptadores fisicos activos. Continuar?', 'ElvisLab', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        try {
            $count = Set-ElvisDns -Provider 'dhcp'
            Add-UiMessage ("DNS restablecido a DHCP en {0} adaptador(es)." -f $count) 'OK'
        } catch {
            Add-UiMessage "No se pudo restablecer el DNS: $($_.Exception.Message)" 'ERROR'
        }
    })

    $btnBackendDirect.Add_Click({ Set-UiBackend -Name 'direct' })
    $btnBackendWinget.Add_Click({ Set-UiBackend -Name 'winget' })

    if (-not (Test-WingetAvailable)) {
        $btnBackendWinget.Enabled = $false
        $btnUninstall.Enabled = $false
        $btnUpgradeAll.Enabled = $false
        $btnUpdatesAll.Enabled = $false
        $btnWingetAll.Enabled = $false
        $btnRepairWinget.Enabled = $false
    }

    Update-BackendUi
    Update-UpdatesSummary

    $form.Add_FormClosing({
        param($sender, $eventArgs)

        if ($script:InstallProcess -and -not $script:InstallProcess.HasExited) {
            $answer = [System.Windows.Forms.MessageBox]::Show('Hay una operacion en curso. Si sales, el proceso continuara en segundo plano. Deseas salir?', 'ElvisLab', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
                $eventArgs.Cancel = $true
                return
            }
            try { [System.IO.File]::WriteAllText($script:CancelFile, 'cancel', $script:Utf8NoBom) } catch { }
        }
    })

    Show-Tab -Name 'install'
    $lblStatus.Text = 'Listo. Selecciona los programas y pulsa Instalar.'
    Add-UiMessage ('Listo. Configuracion: {0}' -f $ConfigPath) 'INFO'

    $form.Add_Shown({
        $form.Activate()
        $flowTweaks.AutoScrollPosition = New-Object System.Drawing.Point(0, 0)
    })
    [void]$form.ShowDialog()
}
