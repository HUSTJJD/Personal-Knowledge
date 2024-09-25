使用UGit管理项目，设置定时任务每日自动唤醒计算机并执行该脚本。

```
@echo off
setlocal enabledelayedexpansion

rem 获取脚本所在目录
set "script_dir=%~dp0"

rem 定义一个数组来存储所有仓库的相对路径
set "repos[0]=XXXXX\"
set "repos[1]=XXXXX\Plugins\"
set "repos[2]=YYYYY\"
set "repos[3]=XXXXX_common\"
set "repos[4]=XXXXX\Content\Feature\ZZZZZ\"

rem 初始化仓库计数器
set "repo_count=0"

rem 计算数组的长度
:SymLoop 
if defined repos[%repo_count%] ( 
    set /a "repo_count+=1"
   GOTO :SymLoop 
)

echo Processing %repo_count% repositories.

set /a "repo_count-=1"

taskkill /F /IM UE4Editor.exe /T

taskkill /F /IM rider64.exe /T

rem 遍历所有仓库
for /l %%i in (0, 1, %repo_count%) do (

    rem 构建仓库的完整路径
    set "repo_path=!script_dir!!repos[%%i]!"

    echo Processing repository: !repo_path!

    rem 进入仓库目录
    cd /d "!repo_path!"

    rem 删除所有锁文件
    del ".git\index.lock"

    rem 获取当前 Git 分支名
    for /f %%i in ('git rev-parse --abbrev-ref HEAD') do (
        set branch_name=%%i
    )

    echo "Current branch: !branch_name!"

    rem 拉取最新代码
    call git fetch --progress --recurse-submodules=on-demand origin %branch_name%
    call git pull origin %branch_name%
)

echo All repositories processed.

rem 返回上级目录
cd /d "!script_dir!"

echo Start Building...
!script_dir!YYYYY\Engine\Build\BatchFiles\Build.bat -Target="XXXXXEditor Win64 Development -Project=\"!script_dir!XXXXX\XXXXX.uproject\"" -Target="ShaderCompileWorker Win64 Development -Quiet" -WaitMutex -FromMsBuild
echo End   Building...

pause 30

rider64.exe "!script_dir!XXXXX\XXXXX.sln"

pause 30

code "!script_dir!XXXXX\XXXXX.code-workspace"

pause 30

start !script_dir!YYYYY\Engine\Binaries\Win64\UE4Editor.exe !script_dir!XXXXX\XXXXX.uproject

endlocal

```