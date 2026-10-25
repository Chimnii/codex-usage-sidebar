using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

namespace UsageSidebar {
    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    internal class ShellLink { }
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
        [DllImport("ole32.dll")] private static extern int PropVariantClear(ref PropVariant value);
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        private static extern void SHChangeNotify(uint eventId, uint flags, string item1, IntPtr item2);
        private static void Set(IPropertyStore store, uint id, string text) {
            PropertyKey key = new PropertyKey(id);
            PropVariant value = new PropVariant { type = 31, value = Marshal.StringToCoTaskMemUni(text) };
            try { store.SetValue(ref key, ref value); } finally { PropVariantClear(ref value); }
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
                Set(store, 4, "Codex Usage Sidebar");
                store.Commit();
                file.Save(linkPath, true);
            } finally { Marshal.FinalReleaseComObject(link); }
            SHChangeNotify(0x2000, 0x1005, linkPath, IntPtr.Zero);
        }
    }
}
