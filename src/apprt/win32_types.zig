//! Shared Win32 ABI types used by multiple apprt modules.

const std = @import("std");
const windows = std.os.windows;
const geometry = @import("win32_geometry.zig");

pub const HWND = windows.HWND;
pub const HINSTANCE = windows.HINSTANCE;
pub const LPCWSTR = [*:0]const u16;
pub const UINT = u32;
pub const LRESULT = isize;
pub const WPARAM = usize;
pub const LPARAM = isize;
pub const BOOL = windows.BOOL;
pub const ATOM = u16;
pub const LONG_PTR = isize;
pub const UINT_PTR = usize;
pub const DWORD = u32;
pub const WORD = u16;
pub const BYTE = u8;
pub const COLORREF = u32;
pub const HBRUSH = ?*anyopaque;
pub const HCURSOR = ?*anyopaque;
pub const HDC = ?*anyopaque;
pub const HGDIOBJ = ?*anyopaque;
pub const HGLRC = ?*anyopaque;
pub const HICON = ?*anyopaque;
pub const HMENU = ?*anyopaque;
pub const HMODULE = ?*anyopaque;
pub const INTRESOURCE = ?*const anyopaque;

pub const POINT = geometry.Point;
pub const RECT = geometry.Rect;

pub const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;

pub const PAINTSTRUCT = extern struct {
    hdc: HDC,
    fErase: BOOL,
    rcPaint: RECT,
    fRestore: BOOL,
    fIncUpdate: BOOL,
    rgbReserved: [32]u8,
};

pub const CREATESTRUCTW = extern struct {
    lpCreateParams: ?*anyopaque,
    hInstance: HINSTANCE,
    hMenu: HMENU,
    hwndParent: ?HWND,
    cy: i32,
    cx: i32,
    y: i32,
    x: i32,
    style: i32,
    lpszName: ?LPCWSTR,
    lpszClass: ?LPCWSTR,
    dwExStyle: u32,
};

pub const WNDCLASSEXW = extern struct {
    cbSize: u32,
    style: u32,
    lpfnWndProc: WNDPROC,
    cbClsExtra: i32,
    cbWndExtra: i32,
    hInstance: HINSTANCE,
    hIcon: HICON,
    hCursor: HCURSOR,
    hbrBackground: HBRUSH,
    lpszMenuName: ?LPCWSTR,
    lpszClassName: LPCWSTR,
    hIconSm: HICON,
};

test "shared Win32 type layouts" {
    const testing = std.testing;

    try testing.expectEqual(@as(usize, 8), @sizeOf(POINT));
    try testing.expectEqual(@as(usize, 16), @sizeOf(RECT));
    try testing.expectEqual(@alignOf(?*anyopaque), @alignOf(PAINTSTRUCT));
    try testing.expectEqual(@alignOf(?*anyopaque), @alignOf(CREATESTRUCTW));
    try testing.expectEqual(@alignOf(?*anyopaque), @alignOf(WNDCLASSEXW));
}
