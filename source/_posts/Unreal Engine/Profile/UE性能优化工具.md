---
title: UE性能优化工具
abbrlink: 60595
categories:
  - Unreal Engine
  - Profile
date: 2025-01-04 15:19:42
tags:
---


# CPU
## Unreal Insight

[Unreal Insights](https://docs.unrealengine.com/en-US/Engine/Performance/UnrealInsights/Overview/index.html) 在 Unreal Engine 4.24.3版本中开始支持移动平台性能数据录取。数据直接写入文件，GUI工具采集结束后离线解析数据文件。

优势：可长时间录制数据，数据在时间轴上以进程调度的形式展示，比较容易分析Game、RenderThread与WorkerThread的调度情况，从整体上结合时间连贯性对CPU瓶颈进行初步的定位。也可用于分析有规律的卡顿掉帧的情况。

劣势：所记录的调用堆栈较浅（可手动打点），较难定位到具体出问题的代码，人工分析需要时间与经验。

## Unreal Profiler

> UE5已删除此模块，建议使用 Unreal Insights

Unreal Engine 中的 [Profiler](https://docs.unrealengine.com/4.27/en-US/TestingAndOptimization/PerformanceAndProfiling/Profiler/)则是分析CPU端性能情况的一个老工具，与Unreal Insights相比它缺少了线程间调度情况的数据，优点在于其记录的调用堆栈深度较深，可与Insights结合使用 UE4引擎窗口中菜单DeveloperTools下SessionFrontend界面即为Profiler所在的窗口 可通过两种方法抓取数据：
1. 启动程序时增加参数：-messaging
2. 游戏中使用命令： stat startfile, stat stopfile

```
/sdcard/UE4Game/YourProject/UE4CommandLine.txt ../../../YourProject/YourProject.uproject -messaging # 数据存放于 /sdcard/UE4Game/FPSDemo/FPSDemo/Saved/Profiling/UnrealStats
```

通过Profiler数据就能看到更深的调用堆栈，比如这里就能看到GameEngine::Tick中不同代码的占用比例，左侧还有按类型分类的分组数据等，更多功能可参考Unreal[官方文档](https://docs.unrealengine.com/4.27/en-US/TestingAndOptimization/PerformanceAndProfiling/Profiler/)

## Simpleperf

Simpleperf可录制很深的CPU调用堆栈，可用于详细分析问题时间内的CPU代码执行情况，其将数据聚合，输出类似于Instrument TimeProfiler的形式，可以看到不同函数在一段时间内的贡献、占比情况，及调用次数，方便对其进行更有针对性的优化。但这种聚合模式没有单帧的概念，主要用于宏观统计。因此可以与Profiler、Insights等工具结合使用。

> 建议使用Test包进行数据分析  
> 避免Development版本额外代码所造成的性能压力影响真实数据

原理简介：

与Instrument TimeProfiler相同，使用[采样](https://jvns.ca/blog/2016/03/12/how-does-perf-work-and-some-questions/)的概念进行CPU数据分析 现代CPU拥有[PMU（Performance Monitor Unit）](https://developer.arm.com/documentation/ddi0433/c/performance-monitoring-unit/about-the-performance-monitoring-unit?lang=en)单元，通过Counter寄存器可得到精确的Cycle Count等CPU Performance数据

[simpleperf](https://android.googlesource.com/platform/system/extras/+/master/simpleperf/doc/README.md)基于linux的[perf](https://man7.org/linux/man-pages/man2/perf_event_open.2.html)改造而来，要记录与代码相关的性能数据，就需要记录目标线程的[寄存器](https://github.com/torvalds/linux/blob/v4.3/arch/x86/kernel/perf_regs.c#L114-L118) 因此存储寄存器数据就是采样的主要工作之一，存储的频率就是采样的频率，采样的频率不能太高，是为了性能与存储的角度考虑的 理论上数据量越大，基于采样的数据经过统计学处理后就越接近真实数据

可通过NDK中的工具进行真机数据录制，UE427建议使用 NDK r21d 版本

通过下方Python脚本即可自动采集并生成火焰图与Android Studio可打开的Perf数据：

```python
# python simpleperf.py ndkpath symbolpath/symbolfile -duration=10[optional] -app=com.tencent.dummy[optional]

import os
import fnmatch
import sys
import subprocess
import re
import shutil

def parseargs(args):
    ndkpath_ = args[1]
    symbolpath_ = args[2]
    app_ = 'com.tencent.dummy'
    duration_ = 10

    if (len(args) > 2):
        for arg in args[3:]:
            words_ = arg.split('=')
            if (len(words_) < 2):
                continue
            if (words_[0] == '-duration'):
                duration_ = int(words_[1])
            elif (words_[0] == '-app'):
                app_ = words_[1]

    return ndkpath_, symbolpath_, app_, duration_

def find_files(directory, pattern):
    for root, dirs, files in os.walk(directory):
        for basename in files:
            if fnmatch.fnmatch(basename, pattern):
                filename = os.path.join(root, basename)
                yield filename

def readforpackagename(filepath, packagename):
    perftxt_ = open(filepath, 'r')
    if (perftxt_ is None):
        print('failed to read file {0}!'.format(filepath))
        return

    lines_ = perftxt_.readlines()
    perftxt_.close()

    # Android 10
    for line in lines_[1:]:
        match = re.search('/data/app/' + packagename + '\\S+', line)
        if match:
            return match.group(0)

    # Android 11
    for line in lines_[1:]:
        match = re.search('/data/app/\\S+' + packagename + '\\S+', line)
        if match:
            return match.group(0)

    return ''

def start(args):
    ndkpath_, symbolpath_, app_, duration_ = parseargs(args)

    if (os.path.isfile(symbolpath_) is False):
        for possiblesymbol in find_files(symbolpath_, '*.so'):
            symbolpath_ = possiblesymbol
            break

    print('ndk: {0}\nsymobl: {1}\napp: {2}\nduration: {3}\n'.format(ndkpath_, symbolpath_, app_, duration_))

    perfpath_ = ndkpath_ + '/simpleperf/bin/android/arm64/simpleperf'
    if (os.path.isfile(perfpath_) is False):
        print('file {0} not found!'.format(perfpath_))
        return

    # push simplerperf executable to mobile
    subprocess.call('adb push ' + perfpath_ + ' /data/local/tmp', shell=True)
    # setup simpleperf permission
    subprocess.call('adb shell chmod a+x /data/local/tmp/simpleperf', shell=True)
    # fix 'too many open files' error
    subprocess.call('adb shell ulimit -n 2048', shell=True)

    # -f 6000, higher sampling frequency for more accurate profiling
    subprocess.call(
        'adb shell \"cd /data/local/tmp/ && simpleperf record -g --app {0} --duration {1} -f 6000 & exit\"'.format(app_, duration_), shell=True)

    # pull perf.data
    subprocess.call('adb pull /data/local/tmp/perf.data perf.data', shell=True)

    perfexe_ = ndkpath_ + '/simpleperf/bin/windows/x86_64/simpleperf.exe'
    if (os.path.isfile(perfexe_) is False):
        print('file {0} not found!'.format(perfexe_))
        return

    # setup binary_cache folder
    subprocess.call(perfexe_ + ' report -i perf.data -o perf.txt')

    packagename_ = readforpackagename('perf.txt', app_)
    if packagename_ == '':
        print('package {0} not found!'.format(app_))
        return

    print('package name: {0}'.format(packagename_))

    bianrycachepath_ = ndkpath_ + '/simpleperf/binary_cache/' + packagename_.replace('libUE4.so', '')
    print('package name: {0}\nbinary cache: {1}'.format(packagename_, bianrycachepath_))

    shutil.rmtree(ndkpath_ + '/simpleperf/binary_cache/', ignore_errors=True)
    os.makedirs(bianrycachepath_)

    shutil.copy2(symbolpath_, bianrycachepath_)

    curfolder_ = os.path.abspath(os.getcwd())

    subprocess.call(perfexe_ + ' report -i perf.data -o perf.caller.txt -g caller -n --full-callgraph --symfs ' + ndkpath_ + '/simpleperf/binary_cache/')
    subprocess.call(perfexe_ + ' report -i perf.data -o perf.callee.txt -g callee -n --full-callgraph --symfs ' + ndkpath_ + '/simpleperf/binary_cache/')
    subprocess.call('python report_html.py -i {0}/perf.data -o {0}/perf.html --no_browser'.format(curfolder_, curfolder_), cwd=ndkpath_+'/simpleperf/', shell=True)
    # convert perf.data to Android Studio openable perf.trace
    subprocess.call(perfexe_ + ' report-sample --protobuf --show-callchain -i perf.data -o perf.trace')

if len(sys.argv) <= 1:
    print('Usage: python simpleperf.py `ndk path` `libUE4.so symbol path` -app=com.tencent.dummy[optional] -duration=10[optional, in seconds]')
else:
    start(sys.argv)
```

### Android Studio

使用Android Studio的 [ProfileAPK](https://developer.android.com/studio/profile/apk-profiler) 功能，即可较为自动的生成性能数据

### Perfetto

[https://perfetto.dev/](https://perfetto.dev/)

可以拿到simpleperf、systrace等数据

可用于分析APP、系统整体CPU调度，渲染节奏等问题

## CacheSim

虚幻引擎设计成熟，核心代码流程上，算法、结构层面的优化已难以挖掘水分

对于一些自行实现或引擎自身模块，在算法层面无优化手段后，可针对性的进行Cache优化

使用软件模拟AMD CPU指令集，统计出出现Cache Miss的**代码行**，助力深度CPU性能分析

缺点：仅可在Windows、Linux平台进行软件模拟

[挤掉Cache Miss的水分：Cascade粒子系统的优化（一）]

[GDC2017 | Cold, Hard Cache: Insomniac's Cache Simulator]


## Arm Streamline

[Arm Mobile Studio 2022](https://developer.arm.com/Tools%20and%20Software/Arm%20Mobile%20Studio)版本除了常见CPU Counter的采集之外，与CacheSim一样支持了针对代码行的Cache分析

优势：真机跑数据，硬件Counter更准确，参考价值更高

[Arm Streamline Performance Analyzer](https://developer.arm.com/Tools%20and%20Software/Streamline%20Performance%20Analyzer) 支持采集Arm芯片的GPU、CPU Counter数据，支持CI 并支持结合Event采样，将Counter数据与源码建立联系 [官方教学视频](https://developer.arm.com/Additional%20Resources/Video%20Tutorials/Arm%20Mali%20GPU%20Training%20-%20EP3-3)

通过此工具可分析移动平台真机CPU指令执行过程中的Cache、Branch等情况，以更深入且精准的优化游戏CPU端性能表现

**建议使用Test包进行数据采集**

【1】选择需要采集的Counter：

右上角有模板，针对你的需要，选择CPU Cache（Cache Miss）、Branching（分支预测失败）、Clock（执行时间）等模板：

红色圈圈代表对此Counter进行Event-based sampling，即将Counter与执行代码结合 当Counter触发 Threshold（默认是1000）次后，进行一次执行堆栈的采样 Cache Miss相关Counter的介绍：

【2】设置采集参数

将带符号表的libUE4.so添加到Program Images中

Frequency：Normal（采样率越高，对频繁调用的小函数侦听越准确，但数据量与性能会大大下降，可根据采集结果权衡设置）

Buffer Mode：Streaming

打开堆栈回溯（打开no-omit-frame-pointer编译选项）

最终根据Counter数据，生成的报告所采取的采样比率，同样是越高越精准

**数据解析**

> 可先拉起游戏运行至需要测试的玩法、地点，尽可能短时的采集数据

开始采集后，点击左侧Stop按钮🛑停止采集，将自动生成报告

【1】Call Paths

以调用堆栈的形式展示所选Counter Sample Event的命中情况：精确到函数

双击可跳转至 Code 页签

【2】Functions

以函数列表形式展示Counter Sample Event命中情况

双击可跳转至 Code 页签

【3】Code

工具支持Counter（Cache Miss）数据归因（Attribution），即指明发生Cache Miss的位置 但因为现代CPU乱序执行等优化手段，加上基于堆栈采样的数据聚合原理，数据仅供参考 但已足够分析出问题函数中问题代码的位置：

如上图中大概是PrimitiveProxy的获取不连续，导致的CacheMiss，需要结合上下文进行分析，确认真正问题所在

> 看上去行号不能精确对上？  
> 解释见此[文章](https://community.arm.com/support-forums/f/graphics-gaming-and-vr-forum/54427/streamline-analyze-performance)

## XCode Timeprofiler

[https://developer.apple.com/videos/play/wwdc2019/411/](https://developer.apple.com/videos/play/wwdc2019/411/)

与Simpleperf原理相同的CPU性能分析工具，功能强大

## Best Practice

粗粒度工具：FramePro、UnrealInsight 用于开发期CI暴漏明显问题

发现问题后，使用细粒度工具进行深度分析：Simpleperf、Streamline、TimeProfiler

建议使用Test包，排除Cache、冗余代码、Profiler本身对性能的影响

尝试：离线计算、ParallelFor、异步化、SOA化等方案

并使用CacheSim、Streamline进行 Cache Miss 分析，压榨出最后的水分

实例一：GC垃圾回收

**偶发大负载任务，充分利用可能空闲的线程**

**ParallelFor 进行 LockFree 优化**

UE垃圾回收扫描引用时，将引用分析抛到多个Task线程处理

但GC时通常会阻塞Game、RHI、Render等线程，可充分利用可能空闲的这些大核线程，进一步提升性能：

### 实例二：全局变量与Cache Miss

将其挪出ParallelFor中的Lambda：

# GPU

现代Mobile GPU通常使用 [TBR、TBDR](https://blog.imaginationtech.com/understanding-powervr-series5xt-powervr-tbdr-and-architecture-efficiency-part-4/) 硬件架构

在有限的功耗下提供尽可能多的性能空间

除了控制 运算负载、动态分支、全精度运算 等天然GPU不友好的指标之外

Mobile GPU因其On-chip Memory较小的原因

需要严格控制寄存器数量，避免Register Spill产生额外IO带宽

## Adreno GPU

[https://developer.qualcomm.com/sites/default/files/docs/adreno-gpu/developer-guide/gpu/gpu.html](https://developer.qualcomm.com/sites/default/files/docs/adreno-gpu/developer-guide/gpu/gpu.html)

介绍Adreno GPU counter指标与建议值

使用Snapdragon Profiler进行Counter数据抓取

提供python脚本进行Counter数据汇总与分类

其次选择Realtime项，打开app后

在下方双击System分组的所有GPU相关指标，即可自动开始记录Counter数据：

> 高通不建议使用Process分组的指标，经测试发现会导致865频率降低的bug，直接采集全屏游戏时System组的性能数据

采集完毕后点击暂停按钮：

后点击csv按钮输出Counter数据，即可通过python脚本进行简单的数据分析

**Counter介绍**

- `% Anisotropic Filtered`  
    Percent of texels filtered using the ‘Anisotropic’ sampling method.  
    各向异性过滤比例，尽量多使用双线性过滤，当然一些比如地形之类的贴图还是需要使用各向异性过滤，保证在30%以下
    
- `% Linear Filtered`  
    Percent of texels filtered using the ‘Linear’ sampling method.  
    双线性过滤比例，尽量使用它
    
- `% Nearest Filtered`  
    Percent of texels filtered using the ‘Nearest’ sampling method.  
    Nearest过滤比例
    
- `% Non-Base Level Textures`  
    Percent of texels coming from a non-base MIP level.  
    采样到非第零级mipmap的比例，越高越好，使用次级mip可以减少内存带宽的使用
    
- `% Prims Clipped`  
    Percentage of primitives clipped by the GPU (where new  
    primitives are generated).  
    For a primitive to be clipped, it has to have a visible portion inside  
    the viewport but extend outside the ‘guardband’ an area that surrounds  
    the viewport and significantly reduces the number of primitives the  
    hardware has to clip.  
    GPU剔除掉的面数比例，即模型有一部分摄像机看不到，硬件帮你剔除的情况
    
- `% Prims Trivially Rejected`  
    Percentage of primitives that are trivially rejected.  
    A primitive can be trivially rejected if it is outside the visible  
    region of the render surface. These primitives are ignored by the  
    rasterizer.  
    完全没有贡献的面。即完全不在相机里的面，尽量将此类模型在CPU上就剔除掉
    
- `% Shader ALU Capacity Utilized`  
    Percent of maximum shader capacity (ALU operations) utilized.  
    For each cycle that the shaders are working, the average percentage of  
    the total shader ALU capacity that is utilized for that cycle.  
    ALU的利用率，一般情况下越高越好，因为你充分利用了GPU的数学运算能力
    
- `% Shaders Busy`  
    Percentage of time that all Shader cores are busy.  
    Shader Core有工作的比例，包括ALU、TPU、LoadStore的情况。当然，也包括Memory Fetch Stall时等待的比例  
    现代的GPU会在发生Stall时，尝试去切换线程，让GPU一致忙起来，以此来“掩盖”这种内存导致的Stall
    
- `% Stalled on System Memory`  
    Percentage of cycles the L2 cache is stalled waiting for data from system memory.  
    L2 cache未命中，等待DRAM数据时产生的延迟的比例  
    如果此指标过高，可能是你采样的数据的空间连续性比较差，减少Dependent Texture Fetch等
    
- `% Texture Fetch Stall`  
    Percentage of clock cycles where the shader processors cannot  
    make any more requests for texture data.  
    A high value for this metric implies the shaders cannot get texture data  
    from the texture pipe (L1, L2 cache or memory) fast enough, and  
    rendering performance may be negatively affected.  
    Shader Core因为正在等待贴图相关内存IO而产生空转的比例  
    可能是没开Mipmap或使用的贴图分辨率过大，或采样贴图的UV空间连续性太差了
    
- `% Texture L1 Miss`  
    Number of L1 texture cache misses divided by L1 texture cache  
    requests.  
    This metric does not consider how many texture requests are made per  
    time period (like the ‘% GPU L1 Texture cache miss’ metric), but is  
    simple miss to request ratio.  
    贴图L1 cache未命中的比例
    
- `% Texture L2 Miss`  
    Number of L2 texture cache misses divided by L2 texture cache requests.  
    This metric does not consider how many texture requests are made per time period, but is simple miss to request ratio.  
    贴图L2 cache未命中的比例
    
- `% Time ALUs Working`  
    Percentage of time the ALUs are working while the Shaders are busy.  
    Shader Core busy时，ALU在工作的比例，理想的这个比例应该尽可能地高
    
- `% Time Compute`  
    Amount of time spent in compute work compared to the total time spent shading everything.  
    Shader Core busy时，Compute计算单元工作的比例
    
- `% Time EFUs Working`  
    Percentage of time the EFUs are working while the Shaders are busy.  
    Elementary functional unit (复杂函数sin、log等运算单元)，理想的此比例应该尽可能地低
    
- `% Time Shading Fragments`  
    Amount of time spent shading fragments compared to the total time spent shading everything.  
    渲染Fragment运算时的比例
    
- `% Time Shading Vertices`  
    Amount of time spent shading vertices compared to the total time spent shading everything.  
    处理Vertices运算时的比例
    
- `% Vertex Fetch Stall`  
    Percentage of clock cycles where the GPU cannot make any more  
    requests for vertex data.  
    A high value for this metric implies the GPU cannot get vertex data from  
    memory fast enough, and rendering performance may be negatively  
    affected.  
    当GPU因为内存IO问题无法获取vertex数据时的比例。可能是场景顶点数过多的缘故，理想的输入GPU的顶点数应保持在300K-500K的数量级
    
- `ALU / Fragment`  
    Average number of scalar fragment shader ALU instructions  
    issued per shaded fragment, expressed as full precision ALUs (2 mediump =  
    1 fullp).  
    Includes interpolation instruction. Does not include vertex shader  
    instructions.  
    平均处理每个Fragment的运算中，ALU相关的指令数（记录全精度ALU，也包括interpolation的指令）
    
- `ALU / Vertex`  
    Average number of vertex scalar shader ALU instructions issued per shaded vertex.  
    Does not include fragment shader instructions.  
    平均处理每个Vertex的运算中，ALU相关的指令数
    
- `Average Polygon Area`  
    Average number of pixels per polygon.  
    Adreno’s binning architecture will count a primitive for each ‘bin’ it  
    covers, so this metric may not exactly match expectations.  
    每个面平均有多少像素，这个值可能不太准，理想的10-15像素/面
    
- `Average Vertices / Polygon`  
    Average number of vertices per polygon.  
    This will be around 3 for triangles, and close to 1 for triangle strips.  
    平均每个面有多少顶点
    
- `Avg Bytes / Fragment`  
    Average number of bytes transferred from main memory for each fragment.  
    每个Fragment运算过程中传输到DRAM的内存的字节数
    
- `Avg Bytes / Vertex`  
    Average number of bytes transferred from main memory for each vertex.  
    每个Vertext运算过程中传输到DRAM的内存的字节数
    
- `Avg Preemption Delay`  
    Average time (us) from the preemption request to preemption start.  
    GPU线程抢占（类似CPU线程调度，将数据写入DRAM）所产生的延迟的比例
    
- `Clocks / Second`  
    Number of GPU clocks per second.  
    GPU的频率，满频时采集数据比较有参考性
    
- `EFU / Fragment`  
    Average number of scalar fragment shader EFU instructions issued per shaded fragment.  
    Does not include Vertex EFU instructions  
    每个Fragment中EFU复杂运算的平均数量，越低越好
    
- `EFU / Vertex`  
    Average number of scalar vertex shader EFU instructions issued per shaded vertex.  
    Does not include fragment EFU instructions  
    每个Vertex中EFU复杂运算的平均数量，越低越好
    
- `Fragment ALU Instructions / Sec (Full)`  
    Total number of full precision fragment shader instructions issued, per second.  
    Does not include medium precision instructions or texture fetch instructions.  
    Fragment中每秒里全精度ALU指令的平均数量，**移动GPU要尽全力使用半精度运算**，Fragment中除了位置运算，基本用半精度就足够  
    既能加快运算，也能降低带宽也能减少发生register spill的比例
    
- `Fragment ALU Instructions / Sec (Half)`  
    Total number of half precision Scalar fragment shader instructions issued, per second.  
    Does not include full precision instructions or texture fetch instructions.  
    Fragment中每秒里半精度ALU指令的平均数量，**移动GPU要尽全力使用半精度运算**
    
- `Fragment EFU Instructions / Second`  
    Total number of Scalar fragment shader Elementary Function Unit (EFU) instructions issued, per second.  
    These include math functions like sin, cos, pow, etc.  
    Fragment中每秒里EFU指令数，当然是越少越好
    
- `Fragment Instructions / Second`  
    Total number of fragment shader instructions issued, per  
    second.  
    Reported as full precision scalar ALU instructions 2 medium precision  
    instructions equal 1 full precision instruction. Also includes  
    interpolation instructions (which are executed on the ALU hardware) and  
    EFU (Elementary Function Unit) instructions. Does not include texture  
    fetch instructions.  
    Fragment中每秒的所有指令数（ALU计算的是全精度，也包含interpolation与EFU，不包含贴图fetch指令）
    
- `Fragments Shaded / Second`  
    Number of fragments submitted to the shader engine, per second.  
    每秒提交到Shader Core中的Fragmenet数量，理论上与分辨率，MSAA等有关
    
- `GPU % Bus Busy`  
    Approximate Percentage of time the GPU’s bus to system memory is busy.  
    大致计算的GPU等待DRAM IO的情况，如果比例较高，就是带宽过大了，如果目标时60FPS，保证带宽在80M/frame，3-5G/sec
    
- `GPU % Utilization`  
    Percentage of GPU utilized as measured at peak GPU clock(585Mhz) and capacity  
    GPU满频率跑时的比例
    
- `GPU Frequency`  
    GPU frequency in Hz
    
- `L1 Texture Cache Miss Per Pixel`  
    Average number of Texture L1 cache misses per pixel.  
    Lower values for this metric imply better memory coherency. If this  
    value is high, consider using compressed textures, reducing texture  
    usage, etc.  
    每个像素L1 Texture Cache未命中的数量。缓存利用率与数据请求的内存相关性有关  
    L1 Cache大致建议在20%左右
    
- `Pre-clipped Polygons/Second`  
    Number of polygons submitted to the GPU, per second, before any hardware clipping.  
    每秒提交到GPU准备进行Culling的面数，可见面数/提交总面数的比例高于50%时是比较健康的  
    否则，给SOC、HOC一些压力，多在渲染前剔除无用的数据
    
- `Preemptions / second`  
    The number of GPU preemptions that occurred, per second.  
    每秒发生GPU抢占的次数，抢占过多可能是GPU负载太重了
    
- `Read Total (Bytes/sec)`  
    Total number of bytes read by the GPU from memory, per second.  
    每秒总读带宽，读带宽一般比写带宽高一些，因为Vertex分Tile需要将数据写入DRAM并多次读出，贴图的读取也属于读带宽
    
- `Reused Vertices / Second`  
    Number of vertices used from the post-transform vertex buffer  
    cache.  
    A vertex may be used in multiple primitives; a high value for this  
    metric (compared to number of vertices shaded) indicates good re-use of  
    transformed vertices, reducing vertex shader workload.  
    复用的顶点的比例，模型的大部分顶点都可以焊接起来，这样不同的三角形就可以公用顶点，减少数据量与Shader负载  
    这个值相比于总处理的顶点数，占比越高当然越好，如果比较低，就处理一下模型，尽量公用顶点
    
- `SP Memory Read (Bytes/Second)`  
    Bytes of data read from memory by the Shader Processors, per second.  
    Shader Processor每秒所读取的内存总数
    
- `Texture Memory Read BW (Bytes/Second)`  
    Bytes of texture data read from memory per second.  
    Includes bytes of platform compressed texture data read from memory.  
    贴图总读带宽，一般都是贴图读带宽是读带宽中比较高的
    
- `Textures / Fragment`  
    Average number of textures referenced per fragment.  
    每个Frament平均使用的贴图数量
    
- `Textures / Vertex`  
    Average number of textures referenced per vertex.  
    每个Vertex平均使用的贴图的数量
    
- `Vertex Instructions / Second`  
    Total number of scalar vertex shader instructions issued, per  
    second.  
    Includes full precision ALU vertex instructions and EFU vertex  
    instructions. Does not include medium precision instructions (since  
    they are not used for vertex shaders). Does not include vertex fetch or  
    texture fetch instructions.  
    每秒Vertex shader指令总数（不包含Vertex fetch和贴图fetch指令）
    
- `Vertex Memory Read (Bytes/Second)`  
    Bytes of vertex data read from memory per second.  
    每秒从DRAM中读取的顶点数据的总大小
    
- `Vertices Shaded / Second`  
    Number of vertices submitted to the shader engine, per second.  
    每秒提交给Shader Core的顶点数
    
- `Write Total (Bytes/sec)`  
    Total number of bytes written by the GPU to memory, per second.  
    总写带宽，写带宽如果高于读带宽，就是不正常的，关注一下Shader的Register Spill，load/store，image store等  
    甚至可能是GPU驱动的BUG，或Shader写法触发的编译器的BUG
    

> Snapdragon Profiler Snapshot 可查看 DrawCall 所执行的 Shader 寄存器使用信息

## Mali GPU

[【公司】MTK技术专场研讨会回顾（1112）]

下方的 Midgard/Bifrost/Valhall ISA Config标明了不同架构GPU的可用线程数与可用寄存器的信息

比如Mali-G78，可用Work寄存器是64个（每个32bit，即一个vec4）

> 当你的Shader使用的Work寄存器数量大于64时，就会发生Register Spill，会有额外的带宽消耗与性能损耗

Uniform寄存器的的上限是128/Draw，它是独立的资源，被一个Shader Program所发起的所有线程共享

> 当你的Shader使用的Uniform寄存器数量大于128时，GPU会需要从LSC中读取超出的寄存器数据，产生额外带宽消耗

可使用Mali-offline-compiler查看Shader的寄存器信息：

PerfDog也支持输出部分Mali GPU counter数据：

> 与 HWCPipe使用相同硬件接口

### G77 GPU Counters介绍

**GPU Activity**

从整体上分析GPU队列的处理情况，并且看到Fragment和非Fragment处理的比例

G77上的任务负载通过 Job Manager管理调度

它为驱动层暴漏了两个FIFO的任务队列，叫Job Slots

一个Slot为非Fragment任务服务（Compute、Vertex），一个为Fragment着色任务服务

这两个队列和CPU的交互是异步的，并且他们可以并行执行

下图展示了不同任务下GPU处理数据的路径，以及与路径相关的性能Counter

注意有的Counter统计的是整个数据路径下的情况，并不代表某个硬件单元

比如Fragment queue active cycles会在GPU任何硬件单元有运行fragment任务时增加cycle count

另外，有些Counter会统计到多条数据路径的表现信息

比如Fragment/Non-Fragment着色程序都是在Unified执行核心上运行的

下面这张游道图就展示了顶层Job Manager的Counter在有重叠的渲染流程中增加计数的

这张图用不同的蓝色展示了每帧里出现的两个渲染流程

每个流程都先有Non-Fragment Work开始，以Fragment Work结束（因为要先VS才能FS）

每段任务结束后，GPU都会通知到CPU

注意，只要队列里有任务，GPU active cycles就会增加

**GPU Usage**

本组Counter从宏观上量化了GPU的整体负载

并区分了Fragment与Non-Fragment任务

本组Counter可以用来判断是否GPU瓶颈，它表示GPU有任务的总时间

也可以看出两大任务队列的任务分布比例

**GPU Active Cycles**

这个Counter会在GPU的任意队列中有未完成的任务时自增

即使GPU正在因为读取System Memory而产生延迟时，也会自增

即它表示了用户程序给到GPU整体的负载压力

**Non-fragment queue active cycles**

当GPU在Non-fragment队列中有未完成的任务时，此计数器会自增

可以量化：vertex shaders, tessellation shaders, geometry shaders, fixed function tiling, compute shaders 的整体负载情况，但无法区分

同理，当产生系统内存IO延迟时，所消耗的时钟也会记录在这个Counter中

**Fragment queue active cycles**

当GPU在Fragment队列中有未完成的任务时，此计数器会自增

对大多数图形程序来讲，Fragment的负载肯定是多于Vertex的负载

因此这个队列的负载一般是最高的

**当你的程序的 Fragment queue active cycles 与 GPU active cycles 值大致接近时**

**你很有可能出现了瓶颈在Fragment处理上的GPU瓶颈**

同理，当产生系统内存IO延迟时，所消耗的时钟也会记录在这个Counter中

**Tiler active cycles**

当分块器的队列中有未完成的任务时，此计数器会自增

分快器可以和Vertex、Fragment着色任务并行进行

当此计数器很高时，不一定代表有瓶颈出现

除非Shader Core模块的Non-fragment active cycles与它对比起来低很多时

才有可能是瓶颈

**Interrupt pending cycles**

当GPU结束任务，给CPU发送Interrupt中断指令，等待CPU回复时，计数器自增

注意这些等待的Cycle并不意味着性能的损耗，因为GPU可以并行处理队列中其他任务

只有当此计数器占据了GPU active cycles中很高的比例时，才有可能有问题

也许出现了一些影响CPU处理中断效率的问题，可能是驱动层出了问题

**GPU utilization**

这组Counter数据提供了队列中任务相关cycle与GPU总cycle的归一化后的比例

对于GPU Bound的情况，理论上某条队列应该会有接近100%的利用率

因此负载最重的队列就是我们应该优先优化的目标

当你是GPU瓶颈，且GPU总是Busy，但也不是每时每刻都有队列在运行

则有可能是程序层API的使用影响了队列的并行表现

当我们想优化此类没有排满任务的情况时（GPU Bubbles），在优化最重的队列之前

首先要保证当前的负载是可以被不同的队列并行执行的

GPU Bubbles出现的可能的原因：

- CPU程序在等待GPU任务执行完毕，比如说在请求一个还未完成的数据结果。这也许会导致一个或多个队列接不到新的任务去处理
    
- 程序提交的渲染相关负载存在数据耦合，影响了并行的表现。比如一个 Fragment->Compute->Fragment 的数据输入会导致当Compute Shader执行时，不能去处理Fragment队列中的有依赖的任务
    

手机GPU系统实现了动态电压调节和频率缩放系统（DVFS，dynamic voltage and frequency scaling）在执行轻度任务时，通过降低电压和频率来降低能耗

当你看到GPU Utilization比较高时，一定先看看GPU active cycles 计数器

因为GPU可能只是因为为了省电运行在一个比较低的频率下

**Non-fragment queue utilization**

此Counter记录了None-Fragment队列相对于整体GPU active cycles的利用率

在GPU瓶颈时，期望的是GPU的不同队列都是并行运行的，因此最重负载的队列利用率应接近100%

如果没有一个负载突出的队列存在，并且GPU仍然接近100%利用率

那就表明有一些序列化或依赖问题导致队列并行效率不够理想

**Fragment queue utilization**

此Counter记录了Fragment队列相对于整体GPU active cycles的利用率

**Tiler utilization**

此Counter记录了Tiler（TBR分块模块）相对于整体GPU active cycles的利用率

注意此Counter包含了索引驱动的Vertex着色过程（IDVS）的负载，与分块固定管线的负载

不仅仅代表分块固定管线的消耗

**Interrupt pending utilization**

此Counter记录的中断请求（[IRQ](https://en.wikipedia.org/wiki/Interrupt_request_%28PC_architecture))）模块相对于整体GPU active cycles的利用率

**在一个设计精良的系统下，IRQ的利用率应该低于2%**

如果此值比较高，则可能有一些系统问题导致CPU无法高效的处理中断请求

**External memory bandwidth**

此类Counters记录了GPU和下游内存系统之间的内存带宽使用情况

也许是直接和外部的DRAM交互，也许是和GPU外部的Cache系统交互

访问外部DRAM是非常费电的，比较理想的情况是每 GB/s 的带宽需要100mW（0.1Watt）

对于高端设备[来讲](https://community.arm.com/developer/tools-software/graphics/f/discussions/49127/arm---mali---g78-mp14-power-consumption---30fps)（2021年4月）想以稳定频率持续运行的（CPU+GPU+memory）能耗预算大致为3.5Watts，可以出现峰值 6-8 Watts的情况，但如果长时间运行在峰值，设备就会过热

> 记住降低带宽是一个很好的优化方向

DRAM的IO是非常费电的，即使CPU、GPU Idle的情况下也需要消耗大致 1.4 Watts / S

目前量产的 **SOC** 可提供总共 **6-10GB/s的DRAM带宽**

Arm专家推荐 **GPU使用3-5GB/s** 的DRAM带宽，及如果目标是60FPS，那就是 **每帧80MB** 的预算

以及**32 Bytes/Vertex**的数据用量

可以看到不论是HSR还是Vertex Shading，处理完顶点后有一步写入

> 此顶点数据的IO操作对DRAM也有很大的影响  
> 参考：[Vulkanised 2023: Getting started on mobile and best practices for Arm GPUs](https://youtu.be/BD1zXW7Uz8Q?t=2505)

**当Load/Store单元最大的压力是DRAM带宽时**

> 需要控制面数，面的密度。以及VertexShader中Varying参数的大小  
> （尽量用半精度，理论上只有position、depth需要全精度）  
> 以控制外部DRAM写入带宽

**Output external read bytes**

此Counter记录了GPU对外的总体读带宽：

**Output external write bytes**

此Counter记录了GPU对外的总体写带宽：

**External memory stalls**

此类Counters记录了当GPU想要从下游读写内存时，产生的等待情况的比例

如果Stall比例较高，则表明我们请求了过多的下游内存数据，超出了硬件系统可提供的范围

因此需要做一些优化内存带宽的工作

**Output external read stall rate**

此Counter记录了下游内存读取操作时产生等待的时间的比例

**Output external write stall rate**

此Counter记录了下游内存写入操作时产生等待的时间的比例

**External memory read latency**

此类Counters记录了GPU内存在进行读操作时产生的延迟比例

如果读延迟达到256cycles以上，则表明我们请求了太多内存数据，导致内存系统超负荷工作

此时就需要优化带宽

**Content behavior**

渲染性能低下通常由以下三点问题导致：

- 要处理的内容很高效的被写入，但对于目标设备来讲花费了过多的机能去运算
    
- 内容写入不高效，有一些冗余的数据也被传输到渲染系统中，导致其比正常渲染更慢
    
- CPU侧的代码对API的使用导致了高负载的任务，或者因为GPU、驱动问题导致等待的GPU Bubbles
    

Streamline中此类别的Counter模板就是为了解决前两种问题

来量化提交的负载的大小和效率

**Geometry usage**

GPU渲染管线会首先处理顶点数据流

此类计数器记录了提交的Geometry总量与被剔除的总量

Geometry是GPU数据中最昂贵的输入之一，因为顶点需要32-64 bytes大小的数据读取操作，而内存读取是非常昂贵的

因此，高顶点数的高精度模型应该只在需要的时候再去提交它

倾向使用Normal Map而不是高精度的模型，多利用LOD，远处不要用太复杂的模型

**Total input primitives**

**Total culled primitives**

**Visible primitives**

**Geometry culling**

所有输入的Geomerty都必须经过剔除处理后才能知道它在相机裁剪空间的位置

因此被剔除的物体就是一项额外的消耗，即使其没有对最终的画面有贡献

这组Counters可以帮助我们了解为何三角形被剔除掉了

帮助你正确的找到出问题的地方

> [Mali建议](https://community.arm.com/developer/tools-software/graphics/f/discussions/49160/shader-data-path-utilization-counters)Visible primitives after culling保持在50%的水平  
> Sample test cull rate过高则表示有太多密度过高的模型存在，导致其虽然在视锥中，且面向相机  
> 但因为太小了没有对目标像素有贡献，从而被硬件剔除掉，浪费了GPU算力与带宽  
> 利用好LOD设置，建议一个三角形大约能覆盖10-15个像素

Mali的剔除管线流程如下图，下面介绍的Counters则表示了每一步里被干掉的模型比例

**IDVS shading**

Mali Bifrost GPU 使用了优化后的 IDVS（index-driven vertex shading） 处理管线

顶点着色被分为两步：Position、Varying Shading

Varying Shading仅发生在剔除存活后的三角形上

此组Counters记录了IDVS管线输入给Shader Core的顶点着色任务量

此管线存在变换后的顶点缓存，保存了近期被着色的顶点数据，来避免相同顶点的重复着色

**当模型的Index Buffer空间相关性比较差时，会导致顶点被着色多次**，因为他可能已经被Cache刷掉

> 考虑检测模型顶点的空间相关性，统一做自动化处理，减少重复着色？

**Position shader thread invocations**

**Varying shader thread invocations** **Fragment overview**

此类Counters记录了这些GPU相关的工作负载：

被着色的像素总数、平均花费在一个像素上的GPU Cycles 数量，以及每个像素着色平均有多少面的贡献

可以设置一个Cycle预算给你们的APP，使用Cycles/Pixel为单位

利用下面的公式计算：

```bash
// 以安卓高配上游设备 Mali-G77MC9 为例，频率836MHz，9核
// 1368x648，60FPS
shaderCyclesPerSecond = MaliCoreCount MaliFrequency
pixelsPerSecond = Screen_Resolution * Target_FPS

shaderCyclesPerSecond = 9 * 836 * 1000000
pixelsPerSecond = 1368 * 648 * 60

// Max cycle budget assuming perfect execution
maxBudget = shaderCyclesPerSecond / pixelsPerSecond
maxBudget = 141

// Real-world cycle budget assuming 85% utilization
realBudget = 0.85 * maxBudget
realBudget = 120
```

**Pixels**

此Counter表示所有RenderPass所着色的像素数量

注意这个值可能和实际值有出入，因为内部计数硬件会对Screen宽高做Round，让他是32的倍数

即使那些像素不在屏幕里或者被裁剪掉了，也会计算上去

**Cycles per pixel**

此Counter表示每渲染一个像素所消耗的GPU cycles数量，包括顶点着色的消耗

可以用上面的公式估算出来预算

**Fragments per pixel**

此Counter表示每个像素一共有多少片元（Fragment）有贡献，即Overdraw的情况

注意：此Counter认为 tile 大小是 16x16，对于大于256bit每像素的Pass

Tile大小会自动调小，这个值就不准确了 。。。

G76： `($MaliCoreWarpsFragmentWarps * 8) / ($MaliCoreTilesTiles * 256)`

G77： `($MaliCoreWarpsFragmentWarps * 16) / ($MaliCoreTilesTiles * 256)`

**Fragment depth and stencil testing**

此组Counters用来看Fragment的Quads在着色时，与Early-ZS/Late-ZS（Depth、Stencil）模块工作的情况

让尽可能多的Fragments被Early-ZS剔除掉这很重要，因为它比Late-ZS要高效得多

**因此Mali GPU建议将不透明物体由近至远进行排序再提交渲染**

**Early ZS tested quad percentage**

此Counter表示进行Early ZS测试的光栅化后的Quads的比例

**Early ZS updated quad percentage**

此Counter表示更新了FrameBuffer的光栅化后的Quads的比例

**Early ZS killed quad percentage**

**FPK killed quad percentage**

此Counter表示被Forward Pixel Kill（FPK）Hidden Surface Removal干掉的光栅化后的Quads的比例

**Late ZS tested quad percentage**

**Late ZS killed quad percentage**

此Counter表示被Late ZS干掉的光栅化后的Quads的比例

进行Late ZS检测的Quads在被干掉前，将执行部分Fragment Shader运算

因此如果Late ZS可以干掉很多Quads，意味着这里有不少的性能开销与能耗的浪费

你应该将Late ZS的Quads数量降到最低

导致Late ZS的主要原因有：

- 明确使用了Discard命令
    
- 隐式使用了Discard命令（Alpha-to-coverage）
    
- 片元的Depth数值是Shader计算出来的
    
- 影响共享资源，如共享的 Storage Buffer、图片、原子变量等
    

当你在Pass开始渲染时忘记清理Framebuffer的depth时，会导致驱动生成预加载ZS值的Wrap

这些额外消耗将被计算到 Late ZS 的Counter中，因此如果不需要，一定先Clear数据再渲染

**Shader core data path**

此组Counters与执行Fragment、NonFragment负载的Mali Shader Core线程发起单元有关

Non-fragment负载包含：vertex shading, geometry shading, tessellation shading, compute shading

**Shader core workload**

此组Counters表示为这两种负载发起的Wraps总数量

每个Wrap表示N个以帧同步执行的Shader线程，Wrap宽度（N）与具体GPU有关

对于Mali G76来讲，Wrap宽度是8

**Non-fragment warps**

对Compute Shader来讲，为了更全面的利用机能

所有的Compute任务组数量应该是Wrap大小的倍数

**Fragment warps**

**Shader core throughput**

此组Counters表示ShaderCore平均执行一个线程所花费的Cycles数量

注意这里指的是平均的吞吐量，而不是消耗

因此Cycles中也包含了与其相关的延迟消耗（比如内存相关延迟）

**Non-fragment cycles per thread**

此Counter表示ShaderCore平均处理一个Non-fragment线程所花费的Cycles数量

注意这里测量的是吞吐量，当值很高时不一定代表性能消耗很大

有可能是过高的内存读写延迟导致的高Cycles数量

并且还包含并行执行的Fragment、None-Fragment任务之间通信交流的消耗

因此此Counter是一个指示性的指标，不代表准确的消耗

**Fragment cycles per thread**

**Shader data path utilization**

此类Counters与ShaderCore中活动（Activity）层面的数据路径相关

帮助我们定位该关心的负载类型，以及这其中是否有任何任务安排上的问题

**Non-fragment utilization**

**Fragment utilization**

**Fragment FPK buffer active percentage**

此Counter表示花费在执行核心（Execution Core）之前的

Forward Pixel Kill Quad Buffer上的Cycle百分比，其包含至少一个Quad

根据[Arm的提示](https://community.arm.com/developer/tools-software/graphics/f/discussions/49160/shader-data-path-utilization-counters)，应保持此percentage尽可能地高

**Execution core utilization**

此Counter描述了可编程执行核心的利用率百分比

如果利用率比较低，则可能表示有性能损耗

因为我们有额外的Shader Core Cycle可以被用来做运算

在一些情况下，此额外消耗是无法避免的

因为Render Pass确实是有一些区域不需要进行Shader运算

**将优化的重点放在那些有大量冗余Geomerty的屏幕区域**

**因为Fragment前端无法更高效的生成Wrap**

**导致了可编程核心没有任务去执行**

这有可能是有大量的三角形被ZS或HSR剔除掉了

或者因为三角形的密度过高导致可生成的线程数量有限

**Shader core functional units**

此组Counters为我们展示了可编程Shader Core中不同的可编程、固定管线运算单元的执行情况

都是与执行Shader程序相关的硬件单元

**Shader unit utilization**

此组Counters以归一化的指标，描述了Shader Core中不同硬件单元的任务执行情况

负载最重的硬件单元是我们要关注的优化重点

当然，降低其中任意单元的负载也会对发热和功耗提供不少的帮助

**Execution engine utilization**

**Varying unit utilization**

**Texture unit utilization**

**Load/store unit utilization**

负责从L2/外部DRAM读取、写入数据

> 即不包括从LSC（Shader Core中的Load/Store Leve 1 Cache）的消耗，LSC一般是16KB的配置

L2缓存是共享的缓存，包括shaders, descriptors, buffers, textures等数据，一般是2-4MiB的配置

**Shader workload properties**

此组Countes以归一化的指标，告诉我们可能影响负载执行效率的数据

也会提示我们一些潜在的有优化空间的地方

**Partial coverage rate**

此Counter表示包含没有覆盖率的Wraps的比例

如果这个比例比较高，即表示你的资源三角形密度过高，这是很耗费性能的

为了避免这种情况，使用LOD技术，让远处的资源使用精简的模型

**Full quad warp rate**

此Counter表示Quads是否完全利用了所有Wrap的比例

如果有很多Wrap没有完全利用，那么性能可能就会比较低下

因为Wrap中的可用线程没有被完全利用起来

提高Full Wrap可能的方法：

- Compute Shader 使用Wrap宽度倍数的WorkGrouops
    
- DrawCall避免出现高密度的模型
    

**Warp divergence percentage**

此Counter表示了Wrap中有出现执行分支情况的指令数的比例（G77）

**Diverged instruction issue rate**

此Counter表示了Wrap中有出现执行分支情况的指令数的比例（G76）

**All registers warp rate**

此Counter表示需要多于32个寄存器的Wrap的比例

当这个值比较高时，无法开启更多线程将会导致GPU持续忙碌

尤其是在同时内存延迟很高的情况下

**Constant tile kill rate**

此Counter表示被[TE](https://developer.arm.com/documentation/101897/0200/fragment-shading/transaction-elimination) CRC（[Transaction Elimination](https://www.arm.com/why-arm/technologies/graphics-technologies/transaction-elimination)）检查所干掉的Tile比例

如果这个值的比例比较高，就意味着你的Framebuffer每一帧都有大量的区域没有改变

尝试考虑使用裁剪矩形（Scissor Rectangles）来减少重绘的区域

与其相关的[GL扩展](https://community.arm.com/cn/b/blog/posts/flush)：

- [EGL_KHR_partial_update](https://www.khronos.org/registry/EGL/extensions/KHR/EGL_KHR_partial_update.txt)
    
- EGL_EXT_swap_buffers_with_damage
    

**TE是Mali的一项用于优化带宽的技术，它可以计算Tile是否相较于上一帧有所改变**

**从而重复利用那些没有改变的Tile数据，来节约运算机能的技术**

**Shader core varying unit**

此组Counters描述Varying Unit的使用情况

此硬件单元被用于Fragment Shader之间的插值上

此插值器有32-bit宽度的数据通道，因此16-bit的插值性能理论上是32-bit数据的两倍

因此建议在Fragment shader中使用中精度Varying的数据格式

并且建议将16-bit的值Pack到vec2/vec4中

**Varying unit usage**

**Varying cycles**

**16-bit interpolation active**

**32-bit interpolation active**

当你的Varying unit是瓶颈时，考虑给Fragment Shader输入更多的16-bit数值以提升性能

**Shader core texture unit**

此组Counters描述了贴图单元的使用情况 包含了所有贴图采样以及过滤操作的负载

**Texture unit usage**

此组Counters表示贴图单元的使用情况，即每个指令所消耗的平均Cycle数

不同的GPU Cycles/Sample的性能不同，比如Mali G76的最佳性能时0.5 Cycles/Sample（双线性过滤）

**Texture filtering cycles**

此Counter表示所有与贴图过滤有关的Cycle总数

有的指令需要多于一个Cycle才可以完成，因为需要获取数据、并且做过滤

一次4个采样的Quad的消耗为：

- 2D双线性过滤 2 Cycles
    
- 2D三线性过滤 4 Cycles
    
- 3D双线性过滤 4 Cycles
    
- 3D三线性过滤 8 Cycles
    

**Texture filtering cycles per instruction**

此Counter表示每个指令平均花费在贴图采样上的Cycles总数

对于贴图单元是瓶颈的情况，当他的CPI比Texture samples per cycle低时

考虑使用Cycles消耗更小的贴图过滤器

不同过滤操作的更详细的性能数据见Texture issue cycles小结

**Texture unit workload properties**

此类Counters表示贴图单元中数据的表现情况

比如使用贴图压缩、Mipmap、三线性过滤等操作的数量

**Texture accesses using trilinear filter percentage**

**Texture accesses using mipmapped texture percentage**

**Texture unit memory usage**

此类Counter表示平均一个贴图采样操作所产生的L2 Cache或外部内存读取的数据大小

**Texture bytes read from L2 per texture cycle**

此Counter表示平均每个过滤Cycle中L2内存读取的数据大小

通过此Counter可判断贴图的L1 Cache情况有多好

如果每次内存读取都需要很大的L2内存带宽，你就需要看一下当前的贴图设置情况：

- 离线的贴图打开mipmap
    
- 使用ASTC、ETC压缩离线贴图
    
- 修改运行时生成的FrameBuffer、贴图格式为更小的格式
    
- 降低为了锐化贴图的负的LOD偏移
    
- 降低各向异性过滤的MAX_ANISOTROPY等级
    

**Texture bytes read from external memory per texture cycle**

此Counter表示平均每个过滤Cycle中系统内存读取的数据大小

通过此Counter可判断贴图的L2 Cache情况有多好

如果每次内存读取都需要很大的系统内存带宽，你就需要看一下当前的贴图设置情况

**Shader core load/store unit**

此组Counters表示了Load/Store单元中数据使用情况

此单元负责所有Shader 内存IO操作，除贴图和Framebuffer写回之外

表示Shader Core独有的LSC（Load/Store L1 Cache，16K）

**Load/store unit usage**

此Counters描述了Load/Store单元进行读写操作的总次数

以及这些加载操作是否利用了可用数据路径的所有宽度

Compute Shader中一个关键的内存IO优化就是，更高效的利用Load/Store硬件提供的数据宽度

我们推荐在线程中向量化内存IO操作

并且保证相同Wrap中不同线程里的有交叠或依赖的内存时，只读取64Byte范围内的数据

**Load/store total issues**

此Counter表示产生Load/Store操作的Cycles数

注意此Counter会忽略Cache Miss的情况，因此它提供了一个最佳情况下的Cycle消耗数据

**Load/store full read issues**

此Counter表示所有全宽Load/Store的缓存读取操作的Cycles数

**Load/store partial read issues**

此Counter表示所有未完全利用Load/Store数据路径宽度的缓存读取操作的Cycles数量

这种情况未完全利用硬件性能，可通过如下Shader修改提高利用率：

- 使用向量化的数据加载
    
- Avoid padding in strided data accesses
    
- Compute Shader中一个Wrap中相邻的线程使用相邻的内存地址区域
    

**Load/store full write issues**

此Counter表示所有全宽Load/Store的缓存写入操作的Cycles数

**Load/store partial write issues**

此Counter表示所有未完全利用Load/Store数据路径宽度的缓存写入操作的Cycles数量

这种情况未完全利用硬件性能，可通过如下Shader修改提高利用率

**Load/store atomic issues**

此Counter表示所有Load/Store原子操作相关的Cycles总数

原子内存读写在Wrap中的每个线程里通常是多Cycle的操作

因此它天生很耗时，避免在性能要求较高的地方使用原子内存操作

**Load/store unit memory usage**

此组Counters表示每个Load/Store读或写操作中平均写入或读出L2Cache的数据大小

可用于评估负载对L1、L2Cache的利用情况

**Load/store bytes read from L2 per access cycle**

此Counter表示每个Load/Store读操作中平均读出L2Cache的数据大小

可用于评估数据在L1 Load/Store Cache中缓存命中的情况

如果每次获取数据都有很高的Bytes流量，则有可能与Buffer格式有关

检查一下数据类型和数据获取的方式

**Load/store bytes read from external memory per access cycle**

此Counter表示每个Load/Store读操作中平均读出系统内存的数据大小

可用于评估数据在L2 Load/Store Cache中缓存命中的情况

如果每次获取数据都有很高的Bytes流量，则可能与你的贴图格式有关

同样检查一下数据类型和数据获取的方式

**Load/store bytes written to L2 per access cycle**

此Counter表示Load/Store单元每个写Cycle中平均写入L2缓存的数据大小

**Shader core memory traffic**

此类Counters表示不同ShaderCore模块里对L2和系统内存产生的内存IO操作的总数据大小

可用于判断内存瓶颈具体在哪里

**Load/store read bytes from L2 cache**

此Counter表示Load/Store单元中从L2缓存中读取的数据总大小

**Texture read bytes from L2 cache**

此Counter表示贴图单元中从L2缓存中读取的数据总大小

**Load/store read bytes from external memory**

此Counter表示Load/Store单元中从系统内存中读取的数据总大小

**Texture read bytes from external memory**

此Counter表示贴图单元中从系统内存中读取的数据总大小

**Load/store write bytes**

此Couner表示Load/Store单元中写入L2缓存的数据总大小

**Tile buffer write bytes**

此Counter表示TileBuffer写回单元中写入L2缓存的数据总大小

## Android GPU Inspector (AGI)

[https://developer.android.com/agi](https://developer.android.com/agi)

Android 12系统的部分硬件：[https://developer.android.com/agi/supported-devices](https://developer.android.com/agi/supported-devices)

可直接使用AGI输出Adreno、Mali设备的GPU Counter

> 在设备允许的前提下优先使用 AGI 进行GPU性能分析

## Metal GPU

**Metal Counters**可以让我们非常**精确**的**了解GPU**的使用率，并能指引我们**发现Metal游戏**的**性能瓶颈**以及**优化方向**

[《Optimize Metal apps and games with GPU counters》](https://developer.apple.com/videos/play/wwdc2020/10603/)主要介绍 Instrument 中 Metal System Trace 与 XCode 12 中的 Metal Debugger 的使用方法

在**抓到数据**后，告诉你如何**甄别**GPU运算管线中 **过度使用** 和 **未充分利用**的 部分

[【公司】Apple 芯片和渲染性能优化技术专场]

**WWDC 2021**

- [Optimize high-end games for Apple GPUs](https://developer.apple.com/videos/play/wwdc2021/10148/)
    

**WWDC 2020**

- [Bring your Metal app to Apple silicon Macs](https://developer.apple.com/videos/play/wwdc2020/10631)
    
- [Gain insights into your Metal app with Xcode 12](https://developer.apple.com/videos/play/wwdc2020/10605)
    
- [Harness Apple GPUs with Metal](https://developer.apple.com/videos/play/wwdc2020/10602)
    
- [Optimize Metal Performance for Apple silicon Macs](https://developer.apple.com/videos/play/wwdc2020/10632)
    

**WWDC 2019**

- [Delivering Optimized Metal Apps and Games](https://developer.apple.com/videos/play/wwdc2019/606)
    

**WWDC 2018**

- [Metal Shader Debugging and Profiling](https://developer.apple.com/videos/play/wwdc2018/608)
    

## Best Practice

降低复杂度、降低 Uber Shader 的使用（会增加寄存器压力，寄存器使用量是编译时确定的数据）

提升半精度指令的比率：包括Varing变量、Sampler、UniformBuffer

优先使用离线方案、隔帧、降频渲染、VRS

确保所有资产使用贴图压缩（ASTC、ETC2），利用硬件提供的无损、有损Framebuffer、RT压缩方案

### 实例一：UE4.27 DirectX Shader Compiler Mobile 半精度支持

大致从UE4.25开始，虚幻引擎开始逐步将Shader交叉编译器从HLSLCC（基于Mesa3d的方案）替换为DXC（Shader Conductor），本文介绍移动平台使用DXC时所做的一些优化：



> xinhou & normanyin 合作撰写的相关章节 将发布于《游戏开发精粹3》中，尽请期待

### 实例二：使用 Variable Rate Shading 插件降低 GPU 负载



[https://community.arm.com/arm-community-blogs/b/graphics-gaming-and-vr-blog/posts/arm-immortalis-g715-developer-overview](https://community.arm.com/arm-community-blogs/b/graphics-gaming-and-vr-blog/posts/arm-immortalis-g715-developer-overview)

# 内存

Android、iOS内存管理核心：

1. 分页（Paging）
    
2. 内存映射（Memory Mapping）
    

CPU & GPU 公用一套内存硬件（GPU有少量OnChip Memory）

当内存不足时触发分页（Page Out）释放内存：

1. 触发 **内存压缩**
2.  删除Clean Page

当剩余内存低于阈值，系统将开始杀进程

**Android：**

**iOS：**

## 堆内存分析

### Android Studio

Android Studio 支持 Native（C++） 堆内存分配的分析工作

[https://developer.android.com/studio/profile/memory-profiler](https://developer.android.com/studio/profile/memory-profiler)

Perfetto组件可使用Heapperfd进行Native内存分析工作：

[https://perfetto.dev/docs/design-docs/heapprofd-design](https://perfetto.dev/docs/design-docs/heapprofd-design)

### LoliProfiler

支持整合至 [UE、Unity](https://github.com/Tencent/loli_profiler/blob/master/docs/GAME_ENGINE_CN.md) 引擎分析 Native（C++）内存

[https://github.com/Tencent/loli_profiler](https://github.com/Tencent/loli_profiler)

### Custom Built Profiler

基于LoliProfiler开发经验

堆内存分析器需要解决的核心问题：

1. 堆栈回溯速度：基于Framepointer方案即可
    
2. 符号翻译速度：离线翻译符号、二分排序搜索加速
    
3. 运行时内存占用 or 网络带宽占用
    

LoliProfiler 源码均已提供对应解决方案，可整合至引擎内部

在内存中存储PersistentMap，实测内存Overhead：350 MiB，性能Overhead基本不变

输出 LoliProfiler 兼容的数据格式，即可通过 LoliProfiler打开CI数据，分析内存过大、泄漏等问题

#### UE5 Memory Insights

[https://docs.unrealengine.com/5.0/en-US/memory-insights-in-unreal-engine/](https://docs.unrealengine.com/5.0/en-US/memory-insights-in-unreal-engine/)

UE5实现了类似上述方案的基于堆栈回溯堆内存分析器

### Unity Mono 内存

Mono虚拟机（IL2CPP）提供内存快照接口

UnityMemPerf用C++&QT完美还原了Unity IL2CPP内存工具PerfAssist的体验，无需Unity、无需SDK，连接USB拉起APP即可抓取托管内存快照，进行内存分析、快照Diff



### Memreport

提供 UE4 Memreport 数据解析、Diff与可视化功能：



### RHI Memory

可针对性的对 UE Vulkan、GL、Metal RHI层内存申请接口结合 FRHIResource 的DebugName

实现一套数据Dump机制，以链接 RHI 内存与 UE RHI资源，深入分析RHI内存

### XCode Allocations

类似 Simpleperf 在 iOS 可查看堆内存分配数据的工具

[iOS Memory Deep Dive](https://developer.apple.com/videos/play/wwdc2018/416/)

[https://developer.apple.com/documentation/xcode/gathering-information-about-memory-use](https://developer.apple.com/documentation/xcode/gathering-information-about-memory-use)

#### Instrument Allocations Helper



## Best Practice

内存常驻数据ZSTD、Oodle压缩、文件[FileIO转Mmap](https://github.com/EpicGames/UnrealEngine/commit/771724018cc1a2c54af7be709cad0f094053b3ff)

浮点数归一化，Lazy Load、减少UObject数量、LRU机制、Streaming

### 案例一：运行时生成资产的 Streaming 支持

手游有包体的限制，但又有变装、涂装的需求，既要又要

对于Mesh组装，我们可以将组装后的Mesh序列化到手机SD卡中，使其能够随时被Stream In、Out

对于ASTC（4x4、8x8）、ETC2贴图，可按Block进行拼装

> 也可使用Compute Shader进行压缩，就可以支持 6x6 BlockSize的合并  
> 代价是吞吐量有限，吞吐效率也有限

拼装后的数据同样序列化至SD卡中，支持Stream In、Out

支持了既要又要的需求，在包体不变的情况下，运行时的DrawCall也降到了最低

### 案例二：Mesh顶点数据的归一化压缩

Mesh Position数据存在于其 Bounding Box 空间内

可通过存储 Bounding Box Center、Extent，将 Position 归一化至 ， 的数区间

Cook时使用半精度浮点数（16位）存储归一化数据

运行时仅需一个 MAD（Multiply Add）操作，即可实时解压

可以做到 Lazy Decompress，以节省相关模块的内存 

# 功耗

手机硬件集成度高，重度手游发热明显，发热与功耗的关系越来越受到开发者的重视

推荐观看：[移动游戏能耗发热分析与优化]

功耗统计难点：

1. 硬件集成度高，被动散热上限低
    
2. 难以测量单模块功耗
    
3. 静态、动态功耗叠加
    
4. 能耗和利用率、频率呈线性关系，和电压呈二次关系
    

综合导致：功耗数据获取难度大，功耗数据体现非线性，数据分析难度也很大

工欲善其事，必先利其器，介绍常用的功耗测量方案，结合上述视频使用更佳：

## 硬件方案

### 电流计

优点：不需破坏手机

缺点：必须满电量测试

淘宝购买硬件设备（50RMB）

设备充满电（100%），将电流计与充电头连接。

在系统的蓝牙管理面板中查找名为“UC96_SPP”的设备，配对连接并且获取其Mac地址记下。

> 分析蓝牙协议后，可实现脚本数据采集

安卓设备建议参考WeTest方案中的方法对设备进行锁频

iOS暂无锁频方案，测试时将风扇准备上

### Wetest方案

移除设备电池，通过单片机供电并统计传输供电数据

优点：更准确

缺点：需要移除手机电池

> 已知问题：  
> 某些高通SoC，尤其是888，发热严重的，达到一定的温度阈值会触发SoC温控驱动自我保护机制，强制将频率控制在最低，导致我们的锁频功能失效。  
> 解决方案是避免使用888这种发热严重的SoC，可以选用870等，也可以参考网上“删除android温控驱动”教程，删除驱动有极大风险，操作需谨慎。

## 软件方案

Perfdog支持基于驱动上报的功耗数据获取

使用方便，准确度比硬件方案低

iOS直接解析了XCode Energy的数据

## Best Practice

统计优化前后的帧功耗：AvgPower = 平均功耗 mW/s

减少运算量：最好的优化就是离线化，GPU带宽压缩（ASTC、AFBC）等

### 案例一：预计算遮挡剔除 PVS

根据可达路径自动均匀铺设 PVS Cell

去除将需要每帧实时计算的遮挡剔除（OC）流程

降低 CPU 功耗

[https://docs.unrealengine.com/4.27/en-US/RenderingAndGraphics/VisibilityCulling/PrecomputedVisibilityVolume/](https://docs.unrealengine.com/4.27/en-US/RenderingAndGraphics/VisibilityCulling/PrecomputedVisibilityVolume/)

### 案例二：Framepacing

在游戏图像展示在显示屏的过程中

有一个比较影响用户体验的同步过程：

游戏逻辑和渲染循环 与 安卓系统和显示屏硬件之间有一个同步的关系

这个同步过程我们称为帧节奏（**Frame Pacing**）

即引擎与CPU、GPU配合产生图像的帧率 与 显示屏刷新率之间的同步关系

安卓的显示系统可避免**画面撕裂**（ScreenTearing）的问题

即当显示器正在刷新数据时，新的数据被Push到显示设备时的情况

其通过以下措施避免撕裂（Tearing）：

- 将历史帧数据缓存住  
    
- 自动检测有延迟的帧数据提交  
    
- 当提交有延迟时，重复渲染历史帧数据
    

通过Buffer缓存帧数据，当显示器刷新时，如果有新数据传输，直接将其缓存即可

如此设计，就不会有VSYNC的阻塞式等待的问题，不增大影响游戏逻辑的输入延迟

虽然带来了一定的画面延迟，但可以避免画面撕裂问题

见[移动游戏能耗发热分析与优化]P150

[什么？FPS不是越高越好吗]

# 包体

包体的大小、首包资源的大小对于玩家有较大影响

尽可能减少包体大小，也是开发者需要关注的重点问题

## SizeMap

[https://docs.unrealengine.com/en-US/Engine/Basics/AssetsAndPackages/AssetManagement/CookingAndChunking/index.html#sizemap](https://docs.unrealengine.com/en-US/Engine/Basics/AssetsAndPackages/AssetManagement/CookingAndChunking/index.html#sizemap)

打开后点击AddChunks，将本地的pak包加载进窗口：

即可打开此pak的SizeMap窗口，可以看到SizeMap以TreeMap图的形式将资源分类，我们可以点击任意分类进入更深的层级来分析数据：

## Unreal PakViewer

[https://github.com/jashking/UnrealPakViewer](https://github.com/jashking/UnrealPakViewer)

## Custom Built Profiler With CI

Asset Registry 中包含资源的 Meta 信息（AssetRegistrySearchable）

可在Cook & Package 结束后使用 Commandlet 分析此信息

得出进包资产的压缩数据，输出CI报告监控包体

## Best Practice

冗余资源不进包，贴图压缩（ASTC、ETC2）、充分利用 ASTC 8x8

ZSTD压缩、Oodle压缩，数据 [RDO](https://en.wikipedia.org/wiki/Rate%E2%80%93distortion_optimization) 压缩

### 案例一：GLSL、SPIRV Shader数据压缩

GLSL可通过 ZSTD+字典 的形式做到极致的包体压缩

[基于ZSTD字典的Shader压缩方案]

Vulkan SPIRV可使用 [SMOL-V](https://github.com/aras-p/smol-v) 进行 RDO 优化，从而达到极致的包体压缩

# 代码崩溃 & 稳定性

疑难崩溃通常发生于非第一现场，需要花费大量**人力**和**精力**和**心情**❤去分析

是性价比最低的开发工作之一 😢

除了提升代码质量之外，如何提前发现可能的疑难崩溃，将其尽可能早的暴漏出来

是大型项目开发过程中需要考虑与解决的重点问题之一

Tips：可通过addr2line翻译崩溃符号至具体代码行号

```bash
# android-ndk-r21d\toolchains\aarch64-linux-android-4.9\prebuilt\windows-x86_64\bin\aarch64-linux-android-addr2line.exe
addr2line.exe -f -C -e path/to/libUE4.so 0x009988ff
```

## Address Santizer

Android、iOS平台原生支持 ASan，UE也已整合至引擎中

日常通过冒烟测试ASan包，提前发现内存越界、Use-after-free等常见内存问题

将不属于你的崩溃，提前拒之门外，降低开发负担

[安卓平台使用ASan检查UE4内存问题]

## StompAllocator

Windows平台也支持ASan，不行的是至少4.27版本的引擎仍旧无法正常使用ASan功能

可使用替代品，UE内部的 Stomp Allocator（会占用巨量虚拟内存（60G+））

[https://pzurita.wordpress.com/2015/06/29/memory-stomp-allocator-for-unreal-engine-4/](https://pzurita.wordpress.com/2015/06/29/memory-stomp-allocator-for-unreal-engine-4/)

通过Page可以设置Read、Write保护的特性，在每次申请内存时，使用Page读写保护来保护内存区域

当越界读写时，就会触发保护，从而崩溃在问题出现的第一现场

### 案例一：StompAllocator崩溃分析

打开Stomp Allocator崩溃于第一现场

基类获取了Hits数组的地址

当其所在vector容器扩容时，会产生realloc，导致基类中的指向Hits的地址失效

正常情况下，realloc，老地址回Malloc池，如果这块内存仍未立即被使用，这块代码仍可正常执行

当这块老代码被其他模块使用，而Hits数据再次被修改时，就会出错

解决方法：

这种指向自己成员内存地址的对象，放在vector、TArray容器里再resize后都会有风险

临时修的话加个resize0，或者resize后assign(size, T())

**最好避免这种写法**

## Vulkan

Vulkan RHI在较新的移动设备中已全面支持

其RHI性能、驱动内存占用，可玩性、以及可优化性 远超 OpenGL RHI

### Vulkan Validation

> Device Lost崩溃时绝望有多少、这张图就有多大

想要避免Device Lost问题？首先要确保项目中已清空 Validation Error

[在UE4中吃好Vulkan的螃蟹-vulkan-validation-layer]

Validation Layer是Debug Vulkan RHI行为的必备工具

在UE4中以Log的形式报告出RHI层的错误用法以及潜在的性能问题：

### Vulkan Command Replay

> 优先选择寻找崩溃设备的厂商进行支持

Vulkan 作为新兴 RHI，有一系列辅助开发的工具，其中就包含Command的Trace工具

[https://github.com/LunarG/gfxreconstruct](https://github.com/LunarG/gfxreconstruct)

发现崩溃问题时，可通过Trace工具记录完整Command数据

通过二分回放定位问题Command

回放功能兼容UE4、5的重点在于处理好进程的信号处理接口

因为其数据采集部分功能基于此接口实现

[https://github.com/LunarG/gfxreconstruct/issues/990](https://github.com/LunarG/gfxreconstruct/issues/990)