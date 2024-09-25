#!/bin/bash

# 获取当前脚本所在目录
root_dir="$(dirname "$(realpath "$0")")"

# 定义递归函数
check_and_create_empty_md() {
    local dir="$1"

    # 获取目录下的所有子项
    items=("$dir"/*)

    has_file=false
    has_dir=false

    for item in "${items[@]}"; do
        if [ -f "$item" ]; then
            has_file=true
        elif [ -d "$item" ]; then
            has_dir=true
        fi
    done

    if $has_file || $has_dir; then
        # 如果存在子目录，递归调用函数
        for item in "${items[@]}"; do
            if [ -d "$item" ]; then
                check_and_create_empty_md "$item"
            fi
        done
    else
        # 如果不存在文件且不存在子目录，则创建 Empty.md 文件
        touch "$dir/Empty.md"
        echo "create $dir/Empty.md"
    fi
}

# 调用递归函数
check_and_create_empty_md "$root_dir"