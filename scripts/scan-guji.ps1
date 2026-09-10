# 扫描本地古籍目录，生成站点数据：
#   data/catalog.json              目录（分类/书/章节清单，不含正文）
#   data/books/<书名>/原文/*.md    直接拷贝的原文 Markdown
#   data/books/<书名>/译文/*.md    直接拷贝的译文 Markdown（如有）
# 前端直接加载 Markdown 并渲染，换行等格式以源文件为准。
#
# 用法：在 PowerShell 中执行 .\scripts\scan-guji.ps1 [-GujiRoot <古籍目录>]
# 排序：编辑本仓库根目录的 排序.txt 后重跑本脚本即可。格式：
#   [分类]        -> 分类顺序
#   [分类名]      -> 该分类下的书籍顺序
#   [书名]        -> 该书的篇章顺序（自动为多篇章书籍生成，可手动调整）

param(
    [string]$GujiRoot = ""
)

$ErrorActionPreference = "Continue"

Write-Host "脚本启动..."

# --- 定位古籍目录 ---
if (-not $GujiRoot) {
    $candidates = @(
        (Join-Path $PSScriptRoot "..\..\古籍"),
        (Join-Path $PSScriptRoot "..\..\..\古文整理本地\古籍")
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { $GujiRoot = (Resolve-Path $c).Path; break }
    }
}
if (-not $GujiRoot -or -not (Test-Path $GujiRoot)) {
    Write-Error "找不到古籍目录，请用 -GujiRoot 指定"
    exit 1
}

$OutputDir = Join-Path $PSScriptRoot "..\data"
$CatalogFile = Join-Path $OutputDir "catalog.json"
$BooksOutDir = Join-Path $OutputDir "books"
$OrderFile = Join-Path $PSScriptRoot "..\排序.txt"

Write-Host "GujiRoot: $GujiRoot"
Write-Host "OutputDir: $OutputDir"
Write-Host "OrderFile: $OrderFile"

function Get-Slug ($name) {
    # 去掉前导数字编号，如 "01_太上老君说常清静经" -> "太上老君说常清静经"
    $name -replace '^\d+[-_]', ''
}

function Convert-ChineseNumber ($text) {
    # 正确解析中文数字：一=1 ... 十=10, 十一=11, 二十=20, 二十一=21, 一百二十三=123
    $digits = @{ '零' = 0; '一' = 1; '二' = 2; '两' = 2; '三' = 3; '四' = 4; '五' = 5; '六' = 6; '七' = 7; '八' = 8; '九' = 9 }
    $units = @{ '十' = 10; '百' = 100; '千' = 1000 }
    $total = 0; $number = 0
    foreach ($c in $text.ToCharArray()) {
        $s = $c.ToString()
        if ($digits.ContainsKey($s)) { $number = $digits[$s] }
        elseif ($units.ContainsKey($s)) {
            if ($number -eq 0) { $number = 1 }
            $total += $number * $units[$s]
            $number = 0
        } else { return -1 }
    }
    return $total + $number
}

function Get-SortKey ($name) {
    $base = [System.IO.Path]::GetFileNameWithoutExtension($name)

    # 1. 前导阿拉伯数字，如 "01_xxx"
    if ($base -match '^(\d+)') { return [int]$matches[1] }

    # 2. "第N" 编号（可出现在任意位置），如 "道原第一" "第十二章"
    if ($base -match '第([零一二两三四五六七八九十百千]+|\d+)') {
        $n = $matches[1]
        if ($n -match '^\d+$') { return [int]$n }
        $v = Convert-ChineseNumber $n
        if ($v -ge 0) { return $v }
    }

    # 3. 前导中文数字（可带 卷/篇 前缀），如 "一宇" "卷三"
    if ($base -match '^[卷篇]?([零一二两三四五六七八九十百千]+)') {
        $v = Convert-ChineseNumber $matches[1]
        if ($v -ge 0) { return $v }
    }

    return [int]::MaxValue
}

function Read-TextFile ($path) {
    $reader = New-Object System.IO.StreamReader($path, $true)
    $text = $reader.ReadToEnd()
    $reader.Close()
    return $text
}

# ======= 读取手动排序文件 =======
# 所有区域先读进通用字典，扫描时再按名称分发：
#   '分类' -> 分类顺序；分类名 -> 书籍顺序；书名 -> 篇章顺序
$sections = @{}
$sectionOrder = @()

if (Test-Path $OrderFile) {
    $section = $null
    foreach ($raw in (Read-TextFile $OrderFile) -split "\r?\n") {
        $line = $raw.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        if ($line -match '^\[(.+)\]$') {
            $section = $matches[1].Trim()
            if (-not $sections.ContainsKey($section)) {
                $sections[$section] = @()
                $sectionOrder += $section
            }
            continue
        }
        if ($section) { $sections[$section] += $line }
    }
    Write-Host "已读取排序文件: $($sectionOrder.Count) 个区域"
} else {
    $sections['分类'] = @('道源', '玄契', '炼性', '金丹')
    Write-Host "未找到排序文件，使用默认分类顺序，稍后将生成: $OrderFile"
}

$userCatOrder = if ($sections.ContainsKey('分类')) { $sections['分类'] } else { @() }

# ======= 主流程 =======
if (-not (Test-Path $BooksOutDir)) {
    New-Item -ItemType Directory -Path $BooksOutDir -Force | Out-Null
}

$categories = @()
$categoryDirs = Get-ChildItem $GujiRoot -Directory | Sort-Object { Get-SortKey $_.Name }

foreach ($catDir in $categoryDirs) {
    $categoryName = $catDir.Name
    $categoryId = Get-Slug $categoryName
    $books = @()

    $bookDirs = Get-ChildItem $catDir.FullName -Directory | Sort-Object { Get-SortKey $_.Name }
    foreach ($bookDir in $bookDirs) {
        $bookName = $bookDir.Name
        $bookId = (Get-Slug $bookName) -replace '\.', '-'
        $sourceDir = Join-Path $bookDir.FullName "原文"
        $transDir = Join-Path $bookDir.FullName "译文"

        if (-not (Test-Path $sourceDir)) { continue }
        $sourceFiles = Get-ChildItem $sourceDir -Filter "*.md" | Sort-Object { Get-SortKey $_.Name }
        if ($sourceFiles.Count -eq 0) { continue }

        # 重建输出目录并拷贝 Markdown
        $outBookDir = Join-Path $BooksOutDir $bookId
        if (Test-Path $outBookDir) { Remove-Item $outBookDir -Recurse -Force }
        $outSrc = Join-Path $outBookDir "原文"
        $outTrans = Join-Path $outBookDir "译文"
        New-Item -ItemType Directory -Path $outSrc -Force | Out-Null

        $chapters = @()
        foreach ($sf in $sourceFiles) {
            Copy-Item $sf.FullName (Join-Path $outSrc $sf.Name)

            $transFile = Join-Path $transDir $sf.Name
            $hasTrans = Test-Path $transFile
            if ($hasTrans) {
                if (-not (Test-Path $outTrans)) { New-Item -ItemType Directory -Path $outTrans -Force | Out-Null }
                Copy-Item $transFile (Join-Path $outTrans $sf.Name)
            }

            $chapters += [ordered]@{
                id = (Get-Slug $sf.BaseName) -replace '\.', '-'
                title = Get-Slug $sf.BaseName
                file = $sf.Name
                hasTrans = $hasTrans
            }
        }

        # 篇章排序：优先排序文件中的 [书名] 区域，未列入的按默认规则排在后面
        $bookTitle = Get-Slug $bookName
        $chapOrder = $sections[$bookTitle]
        $chapters = @($chapters | Sort-Object {
            $i = -1
            if ($chapOrder) { $i = [array]::IndexOf($chapOrder, $_.title) }
            if ($i -ge 0) { $i } else { 10000 }
        }, { Get-SortKey $_.file })

        $books += [ordered]@{
            id = $bookId
            title = $bookTitle
            category = $categoryName
            categoryId = $categoryId
            chapterCount = $chapters.Count
            chapters = $chapters
        }
    }

    if ($books.Count -gt 0) {
        # 按手动顺序排序；未列入的按默认规则排在后面
        $orderList = $sections[$categoryName]
        $books = @($books | Sort-Object {
            $i = -1
            if ($orderList) { $i = [array]::IndexOf($orderList, $_.title) }
            if ($i -ge 0) { $i } else { 10000 }
        }, { Get-SortKey $_.title })

        $categories += [ordered]@{
            id = $categoryId
            name = $categoryName
            books = $books
        }
    }
}

# 分类排序
$categories = @($categories | Sort-Object {
    $i = [array]::IndexOf($userCatOrder, $_.name)
    if ($i -ge 0) { $i } else { 10000 }
}, { Get-SortKey $_.name })

# ======= 回写排序文件（保留用户顺序，追加新增条目） =======
$orderLines = @()
$orderLines += '# 玄门正典 · 排序文件'
$orderLines += '# 修改方法：调整下面各行的先后顺序，保存后重新运行 scripts\scan-guji.ps1 并提交推送即可生效'
$orderLines += '# [分类] 区域：分类顺序'
$orderLines += '# [分类名] 区域：该分类下的书籍顺序'
$orderLines += '# [书名] 区域：该书的篇章顺序（仅多篇章书籍有此区域）'
$orderLines += '# 新增的分类/书籍/篇章会自动追加到对应区域末尾，可再手动调整位置'
$orderLines += ''
$orderLines += '[分类]'
foreach ($c in $categories) { $orderLines += $c.name }
foreach ($c in $categories) {
    $orderLines += ''
    $orderLines += "[$($c.name)]"
    foreach ($b in $c.books) { $orderLines += $b.title }
}
$orderLines += ''
$orderLines += '# ======= 篇章顺序 ======='
foreach ($c in $categories) {
    foreach ($b in $c.books) {
        if ($b.chapters.Count -le 1) { continue }
        $orderLines += ''
        $orderLines += "[$($b.title)]"
        foreach ($ch in $b.chapters) { $orderLines += $ch.title }
    }
}
($orderLines -join "`r`n") | Out-File -FilePath $OrderFile -Encoding UTF8
Write-Host "已更新排序文件: $OrderFile"

# ======= 清理已删除书籍的过期数据 =======
$generatedIds = @{}
foreach ($c in $categories) { foreach ($b in $c.books) { $generatedIds[$b.id] = $true } }

Get-ChildItem $BooksOutDir -ErrorAction SilentlyContinue | Where-Object {
    -not ($_.PSIsContainer -and $generatedIds.ContainsKey($_.Name))
} | ForEach-Object {
    Write-Host "清理过期数据: $($_.Name)"
    Remove-Item $_.FullName -Recurse -Force
}

# ======= 输出目录 =======
$catalog = [ordered]@{
    generatedAt = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
    totalCategories = $categories.Count
    totalBooks = ($categories | ForEach-Object { $_.books.Count } | Measure-Object -Sum).Sum
    categories = $categories
}

$catalog | ConvertTo-Json -Depth 10 | Out-File -FilePath $CatalogFile -Encoding UTF8

Write-Host "已生成目录: $CatalogFile"
Write-Host "已拷贝书籍 Markdown: $BooksOutDir ($($generatedIds.Count) 本)"
foreach ($c in $categories) {
    Write-Host "  $($c.name): $($c.books.Count) 本"
}
