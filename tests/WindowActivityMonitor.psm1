Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-HwpSilentActivityMonitor {
    if ($null -eq ('HwpSilentActivityMonitor' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;

public sealed class HwpSilentActivityMonitor : IDisposable
{
    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    private readonly HashSet<int> baselineHwpProcessIds;
    private readonly HashSet<int> baselineWinwordProcessIds;
    private readonly HashSet<int> baselineExplorerProcessIds;
    private readonly HashSet<long> baselineWindowHandles;
    private readonly long baselineForegroundHandle;
    private readonly ConcurrentDictionary<int, byte> newHwpProcessIds = new ConcurrentDictionary<int, byte>();
    private readonly ConcurrentDictionary<int, byte> newWinwordProcessIds = new ConcurrentDictionary<int, byte>();
    private readonly ConcurrentDictionary<int, byte> newExplorerProcessIds = new ConcurrentDictionary<int, byte>();
    private readonly ConcurrentDictionary<long, byte> newWindowHandles = new ConcurrentDictionary<long, byte>();
    private readonly ConcurrentDictionary<int, byte> newWindowProcessIds = new ConcurrentDictionary<int, byte>();
    private Thread worker;
    private volatile bool running;
    private volatile bool foregroundCapturedByHwp;
    private volatile bool foregroundChanged;

    public HwpSilentActivityMonitor()
    {
        baselineHwpProcessIds = GetProcessIds("Hwp");
        baselineWinwordProcessIds = GetProcessIds("WINWORD");
        baselineExplorerProcessIds = GetProcessIds("explorer");
        baselineWindowHandles = new HashSet<long>(GetVisibleTopLevelWindows().Keys);
        baselineForegroundHandle = GetForegroundWindow().ToInt64();
    }

    public int[] NewProcessIds
    {
        get
        {
            return newHwpProcessIds.Keys
                .Concat(newWinwordProcessIds.Keys)
                .Concat(newExplorerProcessIds.Keys)
                .Distinct()
                .OrderBy(x => x)
                .ToArray();
        }
    }
    public int[] NewHwpProcessIds { get { return newHwpProcessIds.Keys.OrderBy(x => x).ToArray(); } }
    public int[] NewWinwordProcessIds { get { return newWinwordProcessIds.Keys.OrderBy(x => x).ToArray(); } }
    public int[] NewExplorerProcessIds { get { return newExplorerProcessIds.Keys.OrderBy(x => x).ToArray(); } }
    public long[] NewVisibleWindowHandles { get { return newWindowHandles.Keys.OrderBy(x => x).ToArray(); } }
    public int[] NewVisibleWindowProcessIds { get { return newWindowProcessIds.Keys.OrderBy(x => x).ToArray(); } }
    public bool ForegroundCapturedByHwp { get { return foregroundCapturedByHwp; } }
    public bool ForegroundChanged { get { return foregroundChanged; } }

    public void Start()
    {
        if (running) throw new InvalidOperationException("Monitor already started.");
        running = true;
        worker = new Thread(Watch);
        worker.IsBackground = true;
        worker.Name = "hwp-silent-window-monitor";
        worker.Start();
    }

    public void Stop()
    {
        running = false;
        if (worker != null) worker.Join(2000);
        Snapshot();
    }

    private void Watch()
    {
        while (running)
        {
            Snapshot();
            Thread.Sleep(5);
        }
    }

    private void Snapshot()
    {
        HashSet<int> hwpProcessIds = GetProcessIds("Hwp");
        CaptureNewProcesses(hwpProcessIds, baselineHwpProcessIds, newHwpProcessIds);
        CaptureNewProcesses(GetProcessIds("WINWORD"), baselineWinwordProcessIds, newWinwordProcessIds);
        CaptureNewProcesses(GetProcessIds("explorer"), baselineExplorerProcessIds, newExplorerProcessIds);

        Dictionary<long, int> windows = GetVisibleTopLevelWindows();
        foreach (KeyValuePair<long, int> window in windows)
        {
            if (!baselineWindowHandles.Contains(window.Key))
            {
                newWindowHandles.TryAdd(window.Key, 0);
                if (window.Value > 0) newWindowProcessIds.TryAdd(window.Value, 0);
            }
        }

        long foreground = GetForegroundWindow().ToInt64();
        if (foreground != baselineForegroundHandle)
        {
            foregroundChanged = true;
            int foregroundProcessId;
            if (windows.TryGetValue(foreground, out foregroundProcessId) && hwpProcessIds.Contains(foregroundProcessId))
            {
                foregroundCapturedByHwp = true;
            }
        }
    }

    private static void CaptureNewProcesses(
        HashSet<int> current,
        HashSet<int> baseline,
        ConcurrentDictionary<int, byte> destination)
    {
        foreach (int id in current)
        {
            if (!baseline.Contains(id)) destination.TryAdd(id, 0);
        }
    }

    private static HashSet<int> GetProcessIds(string processName)
    {
        HashSet<int> result = new HashSet<int>();
        foreach (Process process in Process.GetProcessesByName(processName))
        {
            try { result.Add(process.Id); }
            catch { }
            finally { process.Dispose(); }
        }
        return result;
    }

    private static Dictionary<long, int> GetVisibleTopLevelWindows()
    {
        Dictionary<long, int> result = new Dictionary<long, int>();
        EnumWindows((hWnd, lParam) =>
        {
            if (!IsWindowVisible(hWnd)) return true;

            uint processId;
            GetWindowThreadProcessId(hWnd, out processId);
            result[hWnd.ToInt64()] = (int)processId;
            return true;
        }, IntPtr.Zero);
        return result;
    }

    public void Dispose()
    {
        Stop();
    }
}
'@
    }

    [HwpSilentActivityMonitor]::new()
}

Export-ModuleMember -Function New-HwpSilentActivityMonitor
