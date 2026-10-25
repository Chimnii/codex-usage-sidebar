using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;

namespace UsageSidebar {
    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    internal class ShellLink { }
    // Explicit Unicode shell API; independent of WScript.Shell's automation setters.
    // https://learn.microsoft.com/windows/win32/api/shobjidl_core/nn-shobjidl_core-ishelllinkw
    [ComImport, Guid("000214F9-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IShellLinkW {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path, int size, IntPtr data, uint flags);
        void GetIDList(out IntPtr list);
        void SetIDList(IntPtr list);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder text, int size);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string text);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path, int size);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string path);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder text, int size);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string text);
        void GetHotkey(out ushort key);
        void SetHotkey(ushort key);
        void GetShowCmd(out int command);
        void SetShowCmd(int command);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path, int size, out int index);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string path, int index);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string path, uint reserved);
        void Resolve(IntPtr window, uint flags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string path);
    }
    public sealed class ShortcutInfo {
        public string TargetPath;
        public string Arguments;
        public string WorkingDirectory;
        public string Description;
        public string IconPath;
        public int IconIndex;
    }
    [StructLayout(LayoutKind.Sequential)]
    internal struct PropertyKey {
        public Guid format;
        public uint id;
        public PropertyKey(uint value) { format = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"); id = value; }
    }
    [StructLayout(LayoutKind.Explicit, Size = 24)]
    internal struct PropVariant {
        [FieldOffset(0)] public ushort type;
        [FieldOffset(8)] public IntPtr value;
    }
    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IPropertyStore {
        void GetCount(out uint count);
        void GetAt(uint index, out PropertyKey key);
        void GetValue(ref PropertyKey key, out PropVariant value);
        void SetValue(ref PropertyKey key, ref PropVariant value);
        void Commit();
    }
    public static class ShortcutProperties {
        public const string DisplayName = "ChatGPT with Usage";
        [DllImport("ole32.dll")] private static extern int PropVariantClear(ref PropVariant value);
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        private static extern void SHChangeNotify(uint eventId, uint flags, string item1, IntPtr item2);
        private static void Set(IPropertyStore store, uint id, string text) {
            PropertyKey key = new PropertyKey(id);
            PropVariant value = new PropVariant { type = 31, value = Marshal.StringToCoTaskMemUni(text) };
            try { store.SetValue(ref key, ref value); } finally { PropVariantClear(ref value); }
        }
        public static void Create(string linkPath, string executable, string workingDirectory) {
            object link = new ShellLink();
            try {
                IShellLinkW target = (IShellLinkW)link;
                target.SetPath(executable);
                target.SetArguments("");
                target.SetWorkingDirectory(workingDirectory);
                target.SetIconLocation(executable, 0);
                target.SetDescription(DisplayName);
                ((IPersistFile)link).Save(linkPath, true);
            } finally { Marshal.FinalReleaseComObject(link); }
        }
        public static ShortcutInfo Read(string linkPath) {
            object link = new ShellLink();
            try {
                ((IPersistFile)link).Load(linkPath, 0);
                IShellLinkW target = (IShellLinkW)link;
                StringBuilder path = new StringBuilder(32768), arguments = new StringBuilder(32768), directory = new StringBuilder(32768);
                StringBuilder description = new StringBuilder(32768), icon = new StringBuilder(32768);
                int iconIndex;
                target.GetPath(path, path.Capacity, IntPtr.Zero, 0);
                target.GetArguments(arguments, arguments.Capacity);
                target.GetWorkingDirectory(directory, directory.Capacity);
                target.GetDescription(description, description.Capacity);
                target.GetIconLocation(icon, icon.Capacity, out iconIndex);
                return new ShortcutInfo { TargetPath = path.ToString(), Arguments = arguments.ToString(), WorkingDirectory = directory.ToString(),
                    Description = description.ToString(), IconPath = icon.ToString(), IconIndex = iconIndex };
            } finally { Marshal.FinalReleaseComObject(link); }
        }
        public static void Apply(string linkPath, string id, string executable) {
            object link = new ShellLink();
            try {
                IPersistFile file = (IPersistFile)link;
                file.Load(linkPath, 2);
                IPropertyStore store = (IPropertyStore)link;
                Set(store, 5, id);
                Set(store, 2, "\"" + executable + "\"");
                Set(store, 3, executable + ",0");
                Set(store, 4, DisplayName);
                store.Commit();
                file.Save(linkPath, true);
            } finally { Marshal.FinalReleaseComObject(link); }
            SHChangeNotify(0x2000, 0x1005, linkPath, IntPtr.Zero);
        }
        public static string ReadAppId(string linkPath) {
            return ReadProperty(linkPath, 5);
        }
        public static string ReadDisplayName(string linkPath) {
            return ReadProperty(linkPath, 4);
        }
        private static string ReadProperty(string linkPath, uint id) {
            object link = new ShellLink();
            try {
                ((IPersistFile)link).Load(linkPath, 0);
                PropertyKey key = new PropertyKey(id);
                PropVariant value;
                ((IPropertyStore)link).GetValue(ref key, out value);
                try { return value.type == 31 ? Marshal.PtrToStringUni(value.value) : null; }
                finally { PropVariantClear(ref value); }
            } finally { Marshal.FinalReleaseComObject(link); }
        }
    }
}
