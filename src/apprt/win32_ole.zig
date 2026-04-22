//! Shared OLE drag-drop ABI types used by Win32 apprt modules.

const std = @import("std");
const windows = std.os.windows;
const win32_types = @import("win32_types.zig");

pub const HRESULT = windows.HRESULT;
pub const GUID = windows.GUID;
pub const BOOL = win32_types.BOOL;
pub const DWORD = win32_types.DWORD;
pub const ULONG = u32;
pub const WORD = win32_types.WORD;

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

const formatetc_size = 32;
const formatetc_cf_format_offset = 0;
const formatetc_ptd_offset = 8;
const formatetc_tymed_offset = 24;

const stgmedium_size = 24;
const stgmedium_tymed_offset = 0;
const stgmedium_u_offset = 8;
const stgmedium_release_offset = 16;

comptime {
    if (@sizeOf(FORMATETC) != formatetc_size or
        @offsetOf(FORMATETC, "cfFormat") != formatetc_cf_format_offset or
        @offsetOf(FORMATETC, "ptd") != formatetc_ptd_offset or
        @offsetOf(FORMATETC, "tymed") != formatetc_tymed_offset)
    {
        @compileError("FORMATETC layout mismatch");
    }

    if (@sizeOf(STGMEDIUM) != stgmedium_size or
        @offsetOf(STGMEDIUM, "tymed") != stgmedium_tymed_offset or
        @offsetOf(STGMEDIUM, "u") != stgmedium_u_offset or
        @offsetOf(STGMEDIUM, "pUnkForRelease") != stgmedium_release_offset)
    {
        @compileError("STGMEDIUM layout mismatch");
    }

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

test "shared OLE payload layouts match Win32 ABI" {
    const testing = std.testing;

    try testing.expectEqual(@as(usize, formatetc_size), @sizeOf(FORMATETC));
    try testing.expectEqual(@as(usize, formatetc_cf_format_offset), @offsetOf(FORMATETC, "cfFormat"));
    try testing.expectEqual(@as(usize, formatetc_ptd_offset), @offsetOf(FORMATETC, "ptd"));
    try testing.expectEqual(@as(usize, formatetc_tymed_offset), @offsetOf(FORMATETC, "tymed"));

    try testing.expectEqual(@as(usize, stgmedium_size), @sizeOf(STGMEDIUM));
    try testing.expectEqual(@as(usize, stgmedium_tymed_offset), @offsetOf(STGMEDIUM, "tymed"));
    try testing.expectEqual(@as(usize, stgmedium_u_offset), @offsetOf(STGMEDIUM, "u"));
    try testing.expectEqual(@as(usize, stgmedium_release_offset), @offsetOf(STGMEDIUM, "pUnkForRelease"));
}
