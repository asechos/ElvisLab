# ============================================================================
# ElvisLab - Controles WinForms personalizados y modelos de UI
# ============================================================================

function Initialize-UiTypes {
    if ('ElvisCardsView' -as [type]) { return }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $code = @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Linq;
using System.Windows.Forms;

public class ElvisProgram
{
    public string Id;
    public string Name;
    public string Category;
    public string BadgeText;
    public Color BadgeColor = Color.FromArgb(88, 101, 242);
    public Image Icon;
    public bool Selected;
    public bool Installed;
    public string Status;
    public int StatusKind;
}

public class ElvisCardsView : ScrollableControl
{
    private List<ElvisProgram> programs = new List<ElvisProgram>();
    private Dictionary<string, Rectangle> cardRects = new Dictionary<string, Rectangle>();
    private Dictionary<string, Rectangle> headerRects = new Dictionary<string, Rectangle>();
    private HashSet<string> collapsed = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    private bool layoutDirty = true;
    private string hoverCard = null;
    private string hoverHeader = null;
    private string filterText = "";
    private bool installedOnly = false;
    private Font titleFont;
    private Font detailFont;
    private Font headerFont;
    private Font badgeFont;

    public event EventHandler SelectionChanged;

    public ElvisCardsView()
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        BackColor = Color.FromArgb(30, 31, 34);
        AutoScroll = true;
        titleFont = new Font("Segoe UI", 11f, FontStyle.Regular);
        detailFont = new Font("Segoe UI", 9.5f, FontStyle.Regular);
        headerFont = new Font("Segoe UI", 11.5f, FontStyle.Bold);
        badgeFont = new Font("Segoe UI", 9.5f, FontStyle.Bold);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            if (titleFont != null) { titleFont.Dispose(); }
            if (detailFont != null) { detailFont.Dispose(); }
            if (headerFont != null) { headerFont.Dispose(); }
            if (badgeFont != null) { badgeFont.Dispose(); }
        }
        base.Dispose(disposing);
    }

    public int SelectedCount
    {
        get
        {
            int count = 0;
            for (int i = 0; i < programs.Count; i++)
            {
                if (programs[i].Selected) { count++; }
            }
            return count;
        }
    }

    public void SetPrograms(List<ElvisProgram> items)
    {
        programs = items == null ? new List<ElvisProgram>() : items;
        layoutDirty = true;
        Invalidate();
    }

    public void SetFilter(string text)
    {
        filterText = text == null ? "" : text.Trim();
        layoutDirty = true;
        Invalidate();
    }

    public void SetInstalledOnly(bool value)
    {
        installedOnly = value;
        layoutDirty = true;
        Invalidate();
    }

    public string[] GetSelectedIds()
    {
        return programs.Where(p => p.Selected).Select(p => p.Id).ToArray();
    }

    public void SelectAll()
    {
        for (int i = 0; i < programs.Count; i++) { programs[i].Selected = true; }
        Invalidate();
        RaiseSelectionChanged();
    }

    public void ClearSelection()
    {
        for (int i = 0; i < programs.Count; i++) { programs[i].Selected = false; }
        Invalidate();
        RaiseSelectionChanged();
    }

    public void ExpandAll()
    {
        collapsed.Clear();
        layoutDirty = true;
        Invalidate();
    }

    public void CollapseAll()
    {
        collapsed.Clear();
        foreach (var group in programs.GroupBy(p => CategoryOf(p))) { collapsed.Add(group.Key); }
        layoutDirty = true;
        Invalidate();
    }

    public void SetStatus(string id, string status, int kind)
    {
        ElvisProgram target = programs.FirstOrDefault(p => string.Equals(p.Id, id, StringComparison.OrdinalIgnoreCase));
        if (target == null) { return; }
        target.Status = status;
        target.StatusKind = kind;
        Invalidate();
    }

    private void RaiseSelectionChanged()
    {
        if (SelectionChanged != null) { SelectionChanged(this, EventArgs.Empty); }
    }

    private static string CategoryOf(ElvisProgram p)
    {
        return string.IsNullOrEmpty(p.Category) ? "Programas" : p.Category;
    }

    private bool Matches(ElvisProgram p)
    {
        if (installedOnly && !p.Installed) { return false; }
        if (string.IsNullOrEmpty(filterText)) { return true; }
        string needle = filterText.ToLowerInvariant();
        if (p.Name != null && p.Name.ToLowerInvariant().Contains(needle)) { return true; }
        if (p.Category != null && p.Category.ToLowerInvariant().Contains(needle)) { return true; }
        return false;
    }

    protected override void OnResize(EventArgs e)
    {
        base.OnResize(e);
        layoutDirty = true;
        Invalidate();
    }

    private void EnsureLayout()
    {
        if (!layoutDirty) { return; }
        layoutDirty = false;
        cardRects.Clear();
        headerRects.Clear();

        int pad = 18;
        int cardW = 180;
        int cardH = 50;
        int gap = 10;
        int headerH = 34;
        int sectionGap = 14;

        int available = ClientSize.Width - (pad * 2);
        int columns = Math.Max(1, (available + gap) / (cardW + gap));
        int y = pad;

        foreach (var group in programs.Where(p => Matches(p)).GroupBy(p => CategoryOf(p)))
        {
            headerRects[group.Key] = new Rectangle(pad, y, available, 28);
            y += headerH;

            if (!collapsed.Contains(group.Key))
            {
                int col = 0;
                foreach (var p in group)
                {
                    int x = pad + (col * (cardW + gap));
                    cardRects[p.Id] = new Rectangle(x, y, cardW, cardH);
                    col++;
                    if (col >= columns)
                    {
                        col = 0;
                        y += cardH + gap;
                    }
                }
                if (col != 0) { y += cardH + gap; }
            }
            y += sectionGap;
        }

        Size desired = new Size(0, y + pad);
        if (AutoScrollMinSize != desired) { AutoScrollMinSize = desired; }
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        EnsureLayout();
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
        g.Clear(BackColor);

        int scroll = AutoScrollPosition.Y;

        foreach (var entry in headerRects)
        {
            Rectangle rect = entry.Value;
            rect.Offset(0, scroll);
            DrawHeader(g, entry.Key, rect);
        }

        foreach (var entry in cardRects)
        {
            ElvisProgram program = programs.FirstOrDefault(p => p.Id == entry.Key);
            if (program == null) { continue; }
            Rectangle rect = entry.Value;
            rect.Offset(0, scroll);
            DrawCard(g, program, rect);
        }
    }

    private void DrawHeader(Graphics g, string text, Rectangle rect)
    {
        bool isCollapsed = collapsed.Contains(text);
        Color accent = Color.FromArgb(90, 169, 230);

        using (SolidBrush brush = new SolidBrush(accent))
        {
            g.DrawString(text, headerFont, brush, rect.X, rect.Y + 2);
        }

        SizeF size = g.MeasureString(text, headerFont);
        int lineX = rect.X + (int)size.Width + 10;
        using (Pen pen = new Pen(Color.FromArgb(58, 60, 65)))
        {
            g.DrawLine(pen, lineX, rect.Y + 14, rect.Right - 24, rect.Y + 14);
        }

        using (Pen pen = new Pen(Color.FromArgb(140, 143, 148), 1.6f))
        {
            PointF[] points;
            if (isCollapsed)
            {
                points = new PointF[]
                {
                    new PointF(rect.Right - 17, rect.Y + 7),
                    new PointF(rect.Right - 11, rect.Y + 13),
                    new PointF(rect.Right - 17, rect.Y + 19)
                };
            }
            else
            {
                points = new PointF[]
                {
                    new PointF(rect.Right - 20, rect.Y + 9),
                    new PointF(rect.Right - 13, rect.Y + 16),
                    new PointF(rect.Right - 6, rect.Y + 9)
                };
            }
            g.DrawLines(pen, points);
        }
    }

    private void DrawCard(Graphics g, ElvisProgram program, Rectangle rect)
    {
        bool hover = string.Equals(hoverCard, program.Id, StringComparison.OrdinalIgnoreCase);

        Color background = hover ? Color.FromArgb(53, 55, 60) : Color.FromArgb(43, 45, 49);
        Color border = program.Selected
            ? Color.FromArgb(59, 165, 93)
            : (hover ? Color.FromArgb(74, 76, 82) : Color.FromArgb(58, 59, 64));

        using (GraphicsPath path = RoundedRect(rect, 6))
        {
            using (SolidBrush brush = new SolidBrush(background))
            {
                g.FillPath(brush, path);
            }
            using (Pen pen = new Pen(border, program.Selected ? 1.6f : 1f))
            {
                g.DrawPath(pen, path);
            }
        }

        Rectangle badge = new Rectangle(rect.X + 8, rect.Y + ((rect.Height - 30) / 2), 30, 30);
        if (program.Icon != null)
        {
            g.DrawImage(program.Icon, badge);
        }
        else
        {
            using (GraphicsPath path = RoundedRect(badge, 5))
            {
                using (SolidBrush brush = new SolidBrush(program.BadgeColor))
                {
                    g.FillPath(brush, path);
                }
            }
            string badgeText = string.IsNullOrEmpty(program.BadgeText) ? "?" : program.BadgeText;
            using (SolidBrush brush = new SolidBrush(Color.White))
            using (StringFormat format = new StringFormat())
            {
                format.Alignment = StringAlignment.Center;
                format.LineAlignment = StringAlignment.Center;
                g.DrawString(badgeText, badgeFont, brush, badge, format);
            }
        }

        int textX = rect.X + 46;
        int textRight = rect.Right - 28;

        Rectangle titleRect = new Rectangle(textX, rect.Y + 5, textRight - textX, 22);
        TextRenderer.DrawText(
            g,
            program.Name,
            titleFont,
            titleRect,
            Color.FromArgb(227, 229, 232),
            TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPadding);

        string status = program.Status;
        if (string.IsNullOrEmpty(status)) { status = program.Installed ? "Instalado" : "No instalado"; }

        Color statusColor = Color.FromArgb(154, 160, 166);
        if (program.StatusKind == 1) { statusColor = Color.FromArgb(59, 165, 93); }
        else if (program.StatusKind == 2) { statusColor = Color.FromArgb(237, 66, 69); }
        else if (program.StatusKind == 3) { statusColor = Color.FromArgb(230, 160, 40); }
        else if (program.Installed) { statusColor = Color.FromArgb(59, 165, 93); }

        Rectangle detailRect = new Rectangle(textX, rect.Y + 27, textRight - textX, 18);
        TextRenderer.DrawText(
            g,
            status,
            detailFont,
            detailRect,
            statusColor,
            TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPadding);

        int cx = rect.Right - 15;
        int cy = rect.Y + (rect.Height / 2);
        int radius = 9;

        if (program.Selected)
        {
            using (SolidBrush brush = new SolidBrush(Color.FromArgb(59, 165, 93)))
            {
                g.FillEllipse(brush, cx - radius, cy - radius, radius * 2, radius * 2);
            }
            using (Pen pen = new Pen(Color.White, 1.8f))
            {
                pen.StartCap = LineCap.Round;
                pen.EndCap = LineCap.Round;
                g.DrawLines(pen, new PointF[]
                {
                    new PointF(cx - 4, cy),
                    new PointF(cx - 1, cy + 3),
                    new PointF(cx + 4, cy - 3)
                });
            }
        }
        else
        {
            Color ring = hover ? Color.FromArgb(120, 124, 130) : Color.FromArgb(92, 95, 102);
            using (Pen pen = new Pen(ring, 1.4f))
            {
                g.DrawEllipse(pen, cx - radius, cy - radius, radius * 2, radius * 2);
            }
        }
    }

    private static GraphicsPath RoundedRect(Rectangle rect, int radius)
    {
        GraphicsPath path = new GraphicsPath();
        int d = radius * 2;
        path.AddArc(rect.X, rect.Y, d, d, 180, 90);
        path.AddArc(rect.Right - d, rect.Y, d, d, 270, 90);
        path.AddArc(rect.Right - d, rect.Bottom - d, d, d, 0, 90);
        path.AddArc(rect.X, rect.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        EnsureLayout();

        Point content = new Point(e.X - AutoScrollPosition.X, e.Y - AutoScrollPosition.Y);
        string newCard = null;
        string newHeader = null;

        foreach (var entry in cardRects)
        {
            if (entry.Value.Contains(content)) { newCard = entry.Key; break; }
        }
        if (newCard == null)
        {
            foreach (var entry in headerRects)
            {
                if (entry.Value.Contains(content)) { newHeader = entry.Key; break; }
            }
        }

        if (newCard != hoverCard || newHeader != hoverHeader)
        {
            hoverCard = newCard;
            hoverHeader = newHeader;
            Cursor = (newCard != null || newHeader != null) ? Cursors.Hand : Cursors.Default;
            Invalidate();
        }
    }

    protected override void OnMouseLeave(EventArgs e)
    {
        base.OnMouseLeave(e);
        if (hoverCard != null || hoverHeader != null)
        {
            hoverCard = null;
            hoverHeader = null;
            Cursor = Cursors.Default;
            Invalidate();
        }
    }

    protected override void OnMouseClick(MouseEventArgs e)
    {
        base.OnMouseClick(e);
        EnsureLayout();

        Point content = new Point(e.X - AutoScrollPosition.X, e.Y - AutoScrollPosition.Y);

        foreach (var entry in cardRects)
        {
            if (entry.Value.Contains(content))
            {
                ElvisProgram program = programs.FirstOrDefault(p => p.Id == entry.Key);
                if (program != null)
                {
                    program.Selected = !program.Selected;
                    Invalidate();
                    RaiseSelectionChanged();
                }
                return;
            }
        }

        foreach (var entry in headerRects)
        {
            if (entry.Value.Contains(content))
            {
                if (collapsed.Contains(entry.Key)) { collapsed.Remove(entry.Key); }
                else { collapsed.Add(entry.Key); }
                layoutDirty = true;
                Invalidate();
                return;
            }
        }
    }
}

public class ElvisToggle : Control
{
    private bool isChecked;
    public event EventHandler CheckedChanged;

    public ElvisToggle()
    {
        SetStyle(
            ControlStyles.UserPaint |
            ControlStyles.AllPaintingInWmPaint |
            ControlStyles.OptimizedDoubleBuffer |
            ControlStyles.ResizeRedraw |
            ControlStyles.Selectable,
            true);
        BackColor = Color.FromArgb(43, 45, 49);
        ForeColor = Color.FromArgb(227, 229, 232);
        Cursor = Cursors.Hand;
        Size = new Size(200, 24);
    }

    public bool Checked
    {
        get { return isChecked; }
        set
        {
            if (isChecked == value) { return; }
            isChecked = value;
            Invalidate();
            if (CheckedChanged != null) { CheckedChanged(this, EventArgs.Empty); }
        }
    }

    protected override void OnTextChanged(EventArgs e)
    {
        base.OnTextChanged(e);
        Invalidate();
    }

    protected override void OnEnabledChanged(EventArgs e)
    {
        base.OnEnabledChanged(e);
        Invalidate();
    }

    protected override void OnGotFocus(EventArgs e)
    {
        base.OnGotFocus(e);
        Invalidate();
    }

    protected override void OnLostFocus(EventArgs e)
    {
        base.OnLostFocus(e);
        Invalidate();
    }

    protected override bool IsInputKey(Keys keyData)
    {
        if (keyData == Keys.Space || keyData == Keys.Enter) { return true; }
        return base.IsInputKey(keyData);
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        if (Enabled && (e.KeyCode == Keys.Space || e.KeyCode == Keys.Enter))
        {
            Checked = !Checked;
            e.Handled = true;
        }
        base.OnKeyDown(e);
    }

    protected override void OnMouseClick(MouseEventArgs e)
    {
        base.OnMouseClick(e);
        if (!Enabled) { return; }
        Checked = !Checked;
        Focus();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.Clear(BackColor);

        int trackWidth = 36;
        int trackHeight = 18;
        int trackX = 2;
        int trackY = (Height - trackHeight) / 2;

        Color trackColor;
        if (!Enabled) { trackColor = Color.FromArgb(62, 64, 70); }
        else if (isChecked) { trackColor = Color.FromArgb(47, 111, 208); }
        else { trackColor = Color.FromArgb(86, 90, 98); }

        Rectangle track = new Rectangle(trackX, trackY, trackWidth, trackHeight);
        using (GraphicsPath path = RoundedRect(track, trackHeight / 2))
        using (SolidBrush brush = new SolidBrush(trackColor))
        {
            g.FillPath(brush, path);
        }

        int knobSize = 14;
        int knobX = isChecked ? trackX + trackWidth - knobSize - 2 : trackX + 2;
        int knobY = trackY + (trackHeight - knobSize) / 2;
        using (SolidBrush brush = new SolidBrush(Enabled ? Color.White : Color.FromArgb(175, 178, 184)))
        {
            g.FillEllipse(brush, knobX, knobY, knobSize, knobSize);
        }

        Color textColor = Enabled ? ForeColor : Color.FromArgb(125, 128, 134);
        Rectangle textRect = new Rectangle(trackX + trackWidth + 10, 0, Width - (trackX + trackWidth + 10), Height);
        TextRenderer.DrawText(
            g,
            Text,
            Font,
            textRect,
            textColor,
            TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPadding);

        if (Focused && Enabled)
        {
            using (Pen pen = new Pen(Color.FromArgb(90, 169, 230), 1f))
            {
                pen.DashStyle = DashStyle.Dot;
                g.DrawRectangle(pen, textRect.X, 2, textRect.Width - 2, Height - 5);
            }
        }
    }

    private static GraphicsPath RoundedRect(Rectangle rect, int radius)
    {
        GraphicsPath path = new GraphicsPath();
        int d = radius * 2;
        path.AddArc(rect.X, rect.Y, d, d, 180, 90);
        path.AddArc(rect.Right - d, rect.Y, d, d, 270, 90);
        path.AddArc(rect.Right - d, rect.Bottom - d, d, d, 0, 90);
        path.AddArc(rect.X, rect.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }
}
'@

    $references = @()
    try { $references += [System.Windows.Forms.Form].Assembly.Location } catch { }
    try { $references += [System.Drawing.Bitmap].Assembly.Location } catch { }
    try { $references += [System.Linq.Enumerable].Assembly.Location } catch { }

    Add-Type -TypeDefinition $code -ReferencedAssemblies $references -Language CSharp
}

function Load-UiImage {
    param([string]$Path)

    try {
        if ([System.IO.Path]::GetExtension($Path).ToLowerInvariant() -eq '.ico') {
            $icon = New-Object System.Drawing.Icon -ArgumentList $Path
            return $icon.ToBitmap()
        }

        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $stream = New-Object System.IO.MemoryStream
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Position = 0
        return [System.Drawing.Image]::FromStream($stream)
    } catch {
        return $null
    }
}

function Get-UiProgramIcon {
    param($File)

    if ($File.icon) {
        $iconPath = Resolve-LocalPath $File.icon
        if (Test-Path -LiteralPath $iconPath -PathType Leaf) {
            $image = Load-UiImage -Path $iconPath
            if ($image) { return $image }
        }
    }

    $installed = Resolve-InstalledPath -File $File
    if ($installed) {
        try {
            $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($installed)
            if ($icon) { return $icon.ToBitmap() }
        } catch { }
    }
    return $null
}

function Get-UiBadgeColor {
    param($File)

    $value = [string]$File.badgeColor
    if ($value -match '^#[0-9A-Fa-f]{6}$') {
        try { return [System.Drawing.ColorTranslator]::FromHtml($value) } catch { }
    }

    $palette = @{
        'python'    = '#3776AB'
        'notepadpp' = '#3E9A2E'
        '7zip'      = '#1E88E5'
        'git'       = '#F05033'
        'vlc'       = '#FF7A00'
    }
    $key = ([string]$File.id).ToLowerInvariant()
    if ($palette.ContainsKey($key)) {
        return [System.Drawing.ColorTranslator]::FromHtml($palette[$key])
    }
    return [System.Drawing.Color]::FromArgb(88, 101, 242)
}

function Build-ProgramModels {
    param(
        $Config,
        [string[]]$SelectedIds = @(),
        [hashtable]$StatusMap = @{}
    )

    $models = New-Object 'System.Collections.Generic.List[ElvisProgram]'

    foreach ($file in @($Config.files)) {
        $model = New-Object ElvisProgram
        $model.Id = $file.id
        $model.Name = $file.name
        $model.Category = $file.category
        $model.BadgeText = $file.badgeText
        $model.BadgeColor = Get-UiBadgeColor -File $file
        $model.Icon = Get-UiProgramIcon -File $file
        $model.Selected = ($SelectedIds -contains $file.id)
        $model.Installed = [bool](Resolve-InstalledPath -File $file)

        if ($StatusMap -and $StatusMap.ContainsKey($file.id)) {
            $model.Status = [string]$StatusMap[$file.id].Text
            $model.StatusKind = [int]$StatusMap[$file.id].Kind
        } else {
            $model.Status = if ($model.Installed) { 'Instalado' } else { 'No instalado' }
            $model.StatusKind = if ($model.Installed) { 1 } else { 0 }
        }

        $models.Add($model)
    }

    return ,$models
}
