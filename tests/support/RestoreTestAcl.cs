using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

// Test-fixture DACL restoration only. Never enables token privileges or changes ownership.
public static class SidebarTestAcl {
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(string s, uint revision, out IntPtr descriptor, out uint size);
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern bool GetSecurityDescriptorDacl(IntPtr sd, out bool present, out IntPtr acl, out bool defaulted);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode)]
    static extern uint SetNamedSecurityInfo(string name, uint type, uint flags, IntPtr owner, IntPtr group, IntPtr dacl, IntPtr sacl);
    [DllImport("kernel32.dll")]
    static extern IntPtr LocalFree(IntPtr p);
    public static void Restore(string path, string sddl, bool isProtected) {
        IntPtr descriptor; uint size;
        if (!ConvertStringSecurityDescriptorToSecurityDescriptor(sddl, 1, out descriptor, out size)) throw new Win32Exception();
        try {
            bool present, defaulted; IntPtr acl;
            if (!GetSecurityDescriptorDacl(descriptor, out present, out acl, out defaulted) || !present) throw new Win32Exception();
            uint error = SetNamedSecurityInfo(path, 1, 4u | (isProtected ? 0x80000000u : 0x20000000u), IntPtr.Zero, IntPtr.Zero, acl, IntPtr.Zero);
            if (error != 0) throw new Win32Exception((int)error);
        } finally { LocalFree(descriptor); }
    }
}
