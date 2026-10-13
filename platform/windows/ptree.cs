// ptree.exe <win32-pid>: the Win32 parent chain of a process, one
// "pid<TAB>parent-pid<TAB>image-path" row per hop, up to 16 hops, the same rows
// proc.sh would otherwise ask pwsh's Get-Process for. One ToolHelp snapshot
// answers every hop. A parent created after its child is a reused pid, not the
// parent, so the chain stops there with parent 0, as Get-Process's Parent does.
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

static class PTree {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  struct ProcessEntry {
    public uint Size; public uint Usage; public uint Pid; public IntPtr Heap; public uint Module;
    public uint Threads; public uint ParentPid; public int Priority; public uint Flags;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string ExeFile;
  }

  [DllImport("kernel32.dll")] static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32FirstW(IntPtr snap, ref ProcessEntry e);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32NextW(IntPtr snap, ref ProcessEntry e);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool QueryFullProcessImageNameW(IntPtr h, uint flags, StringBuilder name, ref uint size);
  [DllImport("kernel32.dll")] static extern bool GetProcessTimes(IntPtr h, out long created, out long exited, out long kernel, out long user);

  const uint QueryLimitedInformation = 0x1000;

  static long Created(uint pid) {
    IntPtr h = OpenProcess(QueryLimitedInformation, false, pid);
    if (h == IntPtr.Zero) return -1;
    long created, exited, kernel, user;
    bool ok = GetProcessTimes(h, out created, out exited, out kernel, out user);
    CloseHandle(h);
    return ok ? created : -1;
  }

  static string ImagePath(uint pid, string name) {
    IntPtr h = OpenProcess(QueryLimitedInformation, false, pid);
    if (h == IntPtr.Zero) return name;
    var path = new StringBuilder(1024);
    uint size = (uint)path.Capacity;
    bool ok = QueryFullProcessImageNameW(h, 0, path, ref size);
    CloseHandle(h);
    return ok ? path.ToString() : name;
  }

  static int Main(string[] args) {
    uint pid;
    if (args.Length != 1 || !uint.TryParse(args[0], out pid)) return 2;
    var parent = new Dictionary<uint, uint>();
    var name = new Dictionary<uint, string>();
    IntPtr snap = CreateToolhelp32Snapshot(2, 0);
    if (snap == new IntPtr(-1)) return 1;
    var e = new ProcessEntry();
    e.Size = (uint)Marshal.SizeOf(typeof(ProcessEntry));
    for (bool more = Process32FirstW(snap, ref e); more; more = Process32NextW(snap, ref e)) {
      parent[e.Pid] = e.ParentPid;
      name[e.Pid] = e.ExeFile.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? e.ExeFile.Substring(0, e.ExeFile.Length - 4) : e.ExeFile;
    }
    CloseHandle(snap);
    var rows = new StringBuilder();
    for (int hop = 0; hop < 16 && name.ContainsKey(pid); hop++) {
      uint up = parent[pid];
      if (up == 0 || !name.ContainsKey(up)) {
        up = 0;
      } else {
        long mine = Created(pid), theirs = Created(up);
        if (mine >= 0 && theirs >= 0 && theirs > mine) up = 0;
      }
      rows.Append(pid).Append('\t').Append(up).Append('\t').Append(ImagePath(pid, name[pid])).Append('\n');
      if (up == 0) break;
      pid = up;
    }
    Console.Out.Write(rows.ToString());
    return 0;
  }
}
