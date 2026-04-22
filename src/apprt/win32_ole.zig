//! Shared OLE drag-drop ABI types used by Win32 apprt modules.

const std = @import("std");
const windows = std.os.windows;

pub const HRESULT = windows.HRESULT;
pub const GUID = windows.GUID;
pub const BOOL = windows.BOOL;
pub const DWORD = u32;
pub const ULONG = u32;
pub const WORD = u16;

pub const FORMATETC = extern struct {
    cfFormat: WORD,
    ptd: ?*anyopaque,
    dwAspect: DWORD,
    lindex: i32,
    tymed: DWORD,
};

pub const STGMEDIUM = extern struct {
    tymed: DWORD,
    u: extern union {
        hGlobal: ?*anyopaque,
        raw: ?*anyopaque,
    },
    pUnkForRelease: ?*anyopaque,
};

pub const IDataObject = extern struct {
    vtbl: *const IDataObjectVtbl,
};

pub const IEnumFORMATETC = extern struct {
    vtbl: *const IEnumFORMATETCVtbl,
};

pub const IDataObjectVtbl = extern struct {
    QueryInterface: *const fn (*IDataObject, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*IDataObject) callconv(.winapi) ULONG,
    Release: *const fn (*IDataObject) callconv(.winapi) ULONG,
    GetData: *const fn (*IDataObject, *const FORMATETC, *STGMEDIUM) callconv(.winapi) HRESULT,
    GetDataHere: *const fn (*IDataObject, *const FORMATETC, *STGMEDIUM) callconv(.winapi) HRESULT,
    QueryGetData: *const fn (*IDataObject, *const FORMATETC) callconv(.winapi) HRESULT,
    GetCanonicalFormatEtc: *const fn (*IDataObject, *const FORMATETC, *FORMATETC) callconv(.winapi) HRESULT,
    SetData: *const fn (*IDataObject, *const FORMATETC, *STGMEDIUM, BOOL) callconv(.winapi) HRESULT,
    EnumFormatEtc: *const fn (*IDataObject, DWORD, *?*IEnumFORMATETC) callconv(.winapi) HRESULT,
    DAdvise: *const fn (*IDataObject, *const FORMATETC, DWORD, ?*anyopaque, *DWORD) callconv(.winapi) HRESULT,
    DUnadvise: *const fn (*IDataObject, DWORD) callconv(.winapi) HRESULT,
    EnumDAdvise: *const fn (*IDataObject, *?*anyopaque) callconv(.winapi) HRESULT,
};

pub const IEnumFORMATETCVtbl = extern struct {
    QueryInterface: *const fn (*IEnumFORMATETC, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*IEnumFORMATETC) callconv(.winapi) ULONG,
    Release: *const fn (*IEnumFORMATETC) callconv(.winapi) ULONG,
    Next: *const fn (*IEnumFORMATETC, ULONG, [*]FORMATETC, ?*ULONG) callconv(.winapi) HRESULT,
    Skip: *const fn (*IEnumFORMATETC, ULONG) callconv(.winapi) HRESULT,
    Reset: *const fn (*IEnumFORMATETC) callconv(.winapi) HRESULT,
    Clone: *const fn (*IEnumFORMATETC, *?*IEnumFORMATETC) callconv(.winapi) HRESULT,
};

comptime {
    const data_object_expected = 12 * @sizeOf(*anyopaque);
    if (@sizeOf(IDataObjectVtbl) != data_object_expected) {
        @compileError(std.fmt.comptimePrint(
            "IDataObjectVtbl size mismatch: got {d}, expected {d}",
            .{ @sizeOf(IDataObjectVtbl), data_object_expected },
        ));
    }

    const enum_format_expected = 7 * @sizeOf(*anyopaque);
    if (@sizeOf(IEnumFORMATETCVtbl) != enum_format_expected) {
        @compileError(std.fmt.comptimePrint(
            "IEnumFORMATETCVtbl size mismatch: got {d}, expected {d}",
            .{ @sizeOf(IEnumFORMATETCVtbl), enum_format_expected },
        ));
    }
}

test "shared OLE vtable layouts match COM slot counts" {
    const testing = std.testing;

    try testing.expectEqual(12 * @sizeOf(*anyopaque), @sizeOf(IDataObjectVtbl));
    try testing.expectEqual(7 * @sizeOf(*anyopaque), @sizeOf(IEnumFORMATETCVtbl));
}
