//! AppUserModelID (AUMID) registration for winghostty.
//!
//! AUMID is the Windows identity that drives:
//!   * Taskbar grouping (duplicates collapse under one icon).
//!   * Action Center toast attribution (toasts fired by this process
//!     show up with our display name + icon, not "Application Host").
//!   * Cold-start toast activation (Windows launches the Start Menu
//!     shortcut; the shortcut's AUMID property routes the click back
//!     to us instead of spawning a generic new process).
//!
//! Two-part registration:
//!   1. Per-process: `SetCurrentProcessExplicitAppUserModelID` — must
//!      run BEFORE any window creation. Cheap, no disk I/O.
//!   2. Per-user registry: `HKCU\Software\Classes\AppUserModelId\<aumid>`
//!      with `DisplayName` + `IconUri` + `ShowInSettings=1`. Written
//!      once at first-run; kept out of the Start Menu-shortcut writer
//!      because some corporate lockdowns block shortcut creation but
//!      allow HKCU writes, and the registry entry alone is enough for
//!      warm-start toast attribution to look correct.
//!
//! The AUMID string `com.ghostty.winghostty` is deliberately distinct
//! from upstream Ghostty's `com.ghostty.ghostty` so a side-by-side
//! install doesn't collide. If upstream ever unifies packaging with
//! this fork, bump the second segment on the fork side.
//!
//! Start Menu shortcut creation is intentionally NOT here — it's
//! installer-side work that belongs in `scripts/package-windows.ps1`,
//! not in our runtime init path. A packaged build writes the shortcut
//! once with the correct AUMID property via Inno Setup; dev builds
//! run without a shortcut and fall back to explicit-AUMID-only toast
//! attribution (still works for warm-start, fails for cold-start).

const std = @import("std");
const windows = std.os.windows;

const HRESULT = i32;
const BOOL = windows.BOOL;
const LPCWSTR = [*:0]const u16;
const HKEY = *opaque {};
const REGSAM = u32;
const DWORD = u32;

const HKEY_CURRENT_USER: HKEY = @ptrFromInt(0x80000001);
const KEY_WRITE: REGSAM = 0x20006;
const KEY_READ: REGSAM = 0x20019;
const REG_OPTION_NON_VOLATILE: DWORD = 0;
const REG_SZ: DWORD = 1;
const REG_DWORD: DWORD = 4;
const ERROR_SUCCESS: i32 = 0;

extern "shell32" fn SetCurrentProcessExplicitAppUserModelID(AppID: LPCWSTR) callconv(.winapi) HRESULT;

extern "advapi32" fn RegCreateKeyExW(
    hKey: HKEY,
    lpSubKey: LPCWSTR,
    Reserved: DWORD,
    lpClass: ?LPCWSTR,
    dwOptions: DWORD,
    samDesired: REGSAM,
    lpSecurityAttributes: ?*anyopaque,
    phkResult: *HKEY,
    lpdwDisposition: ?*DWORD,
) callconv(.winapi) i32;

extern "advapi32" fn RegSetValueExW(
    hKey: HKEY,
    lpValueName: LPCWSTR,
    Reserved: DWORD,
    dwType: DWORD,
    lpData: [*]const u8,
    cbData: DWORD,
) callconv(.winapi) i32;

extern "advapi32" fn RegCloseKey(hKey: HKEY) callconv(.winapi) i32;

const aumid_wide: [*:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("com.ghostty.winghostty");
pub const aumid_utf8 = "com.ghostty.winghostty";

/// Set the AUMID for the current process. Must run before any HWND is
/// created; Windows copies the identity into the process's taskbar-
/// integration state at first window-creation time. Return value is
/// advisory — we log and proceed on failure rather than abort, since
/// toasts are not essential for the app to function.
pub fn setProcessAumid() void {
    const hr = SetCurrentProcessExplicitAppUserModelID(aumid_wide);
    if (hr < 0) {
        std.log.warn("AUMID: SetCurrentProcessExplicitAppUserModelID failed hr=0x{x:0>8}", .{@as(u32, @bitCast(hr))});
    }
}

/// Write `HKCU\Software\Classes\AppUserModelId\com.ghostty.winghostty`
/// with DisplayName + ShowInSettings. Idempotent; writes every launch
/// (cost is negligible and this keeps the display-name synchronised
/// even if it changes). Icon wiring is deferred — extracting the exe
/// icon to a stable file path requires shell32's
/// `SHGetStockIconInfo` / icon-resource-extraction which we don't
/// need for the unshortcut'd dev path.
pub fn registerAumidDisplayName() void {
    const subkey = std.unicode.utf8ToUtf16LeStringLiteral(
        "Software\\Classes\\AppUserModelId\\com.ghostty.winghostty",
    );

    var hkey: HKEY = undefined;
    const open_rc = RegCreateKeyExW(
        HKEY_CURRENT_USER,
        subkey,
        0,
        null,
        REG_OPTION_NON_VOLATILE,
        KEY_WRITE,
        null,
        &hkey,
        null,
    );
    if (open_rc != ERROR_SUCCESS) {
        std.log.warn("AUMID: RegCreateKeyExW failed rc={d}", .{open_rc});
        return;
    }
    defer _ = RegCloseKey(hkey);

    const display_name = std.unicode.utf8ToUtf16LeStringLiteral("Ghostty");
    // REG_SZ takes byte count including the trailing null. The literal
    // is a *const [N:0]u16 whose length is known at comptime.
    const name_bytes = (display_name.len + 1) * @sizeOf(u16);
    const set_rc = RegSetValueExW(
        hkey,
        std.unicode.utf8ToUtf16LeStringLiteral("DisplayName"),
        0,
        REG_SZ,
        @ptrCast(display_name),
        @intCast(name_bytes),
    );
    if (set_rc != ERROR_SUCCESS) {
        std.log.warn("AUMID: write DisplayName failed rc={d}", .{set_rc});
    }

    var show_in_settings: u32 = 1;
    const show_rc = RegSetValueExW(
        hkey,
        std.unicode.utf8ToUtf16LeStringLiteral("ShowInSettings"),
        0,
        REG_DWORD,
        @ptrCast(&show_in_settings),
        @sizeOf(u32),
    );
    if (show_rc != ERROR_SUCCESS) {
        std.log.warn("AUMID: write ShowInSettings failed rc={d}", .{show_rc});
    }
}

test "aumid string shape" {
    const testing = std.testing;
    try testing.expectEqualStrings("com.ghostty.winghostty", aumid_utf8);
}
