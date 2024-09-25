# 获取当前脚本所在目录
$rootDir = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent

# 定义递归函数
function Check-AndCreateEmptyMd($dir) {
    # 获取目录下的所有子项
    $items = Get-ChildItem -Path $dir -Recurse -Force

    # 检查是否存在文件或子目录
    $hasFile = $items | Where-Object { !$_.PSIsContainer } | Select-Object -First 1 | Measure-Object | Where-Object { $_.Count -gt 0 }
    $hasDir = $items | Where-Object { $_.PSIsContainer } | Select-Object -First 1 | Measure-Object | Where-Object { $_.Count -gt 0 }

    if (-not $hasFile -and -not $hasDir) {
        # 如果不存在文件且不存在子目录，则创建 Empty.md 文件
        New-Item -Path "$dir\Empty.md" -ItemType File
        Write-Output "create $($dir)\Empty.md"
    } else {
        # 如果存在子目录，递归调用函数
        foreach ($item in $items) {
            if ($item.PSIsContainer) {
                Check-AndCreateEmptyMd -dir $item.FullName
            }
        }
    }
}

# 调用递归函数
Check-AndCreateEmptyMd -dir $rootDir
