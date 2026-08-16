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

    private readonly HashSet<int> baselineProcessIds;
    private readonly HashSet<long> baselineWindowHandles;
    private readonly long baselineForegroundHandle;
    private readonly ConcurrentDictionary<int, byte> newProcessIds = new ConcurrentDictionary<int, byte>();
    private readonly ConcurrentDictionary<long, byte> newWindowHandles = new ConcurrentDictionary<long, byte>();
    private Thread worker;
    private volatile bool running;
    private volatile bool foregroundCapturedByHwp;

    public HwpSilentActivityMonitor()
    {
        baselineProcessIds = GetHwpProcessIds();
        baselineWindowHandles = GetVisibleHwpWindowHandles(baselineProcessIds);
        baselineForegroundHandle = GetForegroundWindow().ToInt64();
    }

    public int[] NewProcessIds { get { return newProcessIds.Keys.OrderBy(x => x).ToArray(); } }
    public long[] NewVisibleWindowHandles { get { return newWindowHandles.Keys.OrderBy(x => x).ToArray(); } }
    public bool ForegroundCapturedByHwp { get { return foregroundCapturedByHwp; } }

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
        HashSet<int> processIds = GetHwpProcessIds();
        foreach (int id in processIds)
        {
            if (!baselineProcessIds.Contains(id))
            {
                newProcessIds.TryAdd(id, 0);
            }
        }

        HashSet<long> windowHandles = GetVisibleHwpWindowHandles(processIds);
        foreach (long handle in windowHandles)
        {
            if (!baselineWindowHandles.Contains(handle))
            {
                newWindowHandles.TryAdd(handle, 0);
            }
        }

        long foreground = GetForegroundWindow().ToInt64();
        if (foreground != baselineForegroundHandle && windowHandles.Contains(foreground))
        {
            foregroundCapturedByHwp = true;
        }
    }

    private static HashSet<int> GetHwpProcessIds()
    {
        return new HashSet<int>(Process.GetProcessesByName("Hwp").Select(p => p.Id));
    }

    private static HashSet<long> GetVisibleHwpWindowHandles(HashSet<int> hwpProcessIds)
    {
        HashSet<long> result = new HashSet<long>();
        EnumWindows((hWnd, lParam) =>
        {
            if (!IsWindowVisible(hWnd))
            {
                return true;
            }

            uint processId;
            GetWindowThreadProcessId(hWnd, out processId);
            if (hwpProcessIds.Contains((int)processId))
            {
                result.Add(hWnd.ToInt64());
            }
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
