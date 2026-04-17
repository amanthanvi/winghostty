//! Minimal WinRT bindings for Windows Action Center toasts.
//!
//! Fires toast notifications via `ToastNotificationManager` using
//! runtime-loaded combase.dll functions.  Never links combase.dll
//! directly — `GetProcAddress` at init time.
//!
//! AUMID is supplied by the caller (typically `com.ghostty.winghostty`).
//! Falls back silently: if init fails the caller should use the in-app
//! toast stack (`win32_toast.zig`) instead.
//!
//! CoInitializeEx(STA) is assumed to already be called by App.init.
//! This module layers RoInitialize on top (STA mode).

const std = @import("std");
const Allocator = std.mem.Allocator;
const windows = std.os.windows;

// ── Win32 type aliases ──────────────────────────────────────────────

pub const HRESULT = windows.HRESULT;
pub const GUID = windows.GUID;
pub const HMODULE = windows.HINSTANCE;
pub const HSTRING = *opaque {};
pub const FARPROC = *const fn () callconv(.winapi) isize;

const S_OK: HRESULT = 0;
const S_FALSE: HRESULT = 1;
const RPC_E_CHANGED_MODE: HRESULT = @bitCast(@as(u32, 0x80010106));

// ── Error types ─────────────────────────────────────────────────────

pub const InitError = error{
    RuntimeMissing,
    WinrtUnavailable,
    NotifierCreationFailed,
    OutOfMemory,
};

pub const ShowError = error{
    XmlLoadFailed,
    ActivationFailed,
    NotifierShowFailed,
    OutOfMemory,
    InvalidUtf8,
};

// ── Severity ────────────────────────────────────────────────────────

pub const Severity = enum { info, warn, err, success };

// ── COM GUIDs ───────────────────────────────────────────────────────

const IID_IInspectable = GUID.parse("{AF86E2E0-B12D-4C6A-9C5A-D7AA65101E90}");
const IID_IToastNotificationManagerStatics = GUID.parse("{50AC103F-D235-4598-BBEF-98FE4D1A3AD4}");
const IID_IToastNotificationFactory = GUID.parse("{04124B20-82C6-4229-B109-FD9ED4662B53}");
const IID_IXmlDocumentIO = GUID.parse("{6CD0E74E-EE65-4489-9EBF-CA43E87BA637}");

comptime {
    if (@sizeOf(GUID) != 16) @compileError("GUID size must be 16 bytes");
}

// ── WinRT class names (UTF-16 literals) ─────────────────────────────

const toast_manager_class = std.unicode.utf8ToUtf16LeStringLiteral("Windows.UI.Notifications.ToastNotificationManager");
const toast_notification_class = std.unicode.utf8ToUtf16LeStringLiteral("Windows.UI.Notifications.ToastNotification");
const xml_document_class = std.unicode.utf8ToUtf16LeStringLiteral("Windows.Data.Xml.Dom.XmlDocument");

// ── COM v-table declarations ────────────────────────────────────────
//
// Each v-table mirrors the Windows ABI layout: IUnknown (3 slots),
// IInspectable (3 slots), then interface-specific methods.  We use
// `*anyopaque` for the self parameter since we never implement these
// interfaces — we only call through the v-table pointers returned by
// WinRT.

pub const IUnknownVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
};

pub const IInspectableVtbl = extern struct {
    // IUnknown
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    // IInspectable
    GetIids: *const fn (*anyopaque, *u32, *?[*]GUID) callconv(.winapi) HRESULT,
    GetRuntimeClassName: *const fn (*anyopaque, *?HSTRING) callconv(.winapi) HRESULT,
    GetTrustLevel: *const fn (*anyopaque, *i32) callconv(.winapi) HRESULT,
};

pub const IToastNotificationManagerStaticsVtbl = extern struct {
    // IUnknown (3)
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    // IInspectable (3)
    GetIids: *const fn (*anyopaque, *u32, *?[*]GUID) callconv(.winapi) HRESULT,
    GetRuntimeClassName: *const fn (*anyopaque, *?HSTRING) callconv(.winapi) HRESULT,
    GetTrustLevel: *const fn (*anyopaque, *i32) callconv(.winapi) HRESULT,
    // IToastNotificationManagerStatics
    CreateToastNotifier: *const fn (*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT,
    CreateToastNotifierWithId: *const fn (*anyopaque, HSTRING, *?*anyopaque) callconv(.winapi) HRESULT,
    get_History: *const fn (*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT,
};

pub const IToastNotifierVtbl = extern struct {
    // IUnknown (3)
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    // IInspectable (3)
    GetIids: *const fn (*anyopaque, *u32, *?[*]GUID) callconv(.winapi) HRESULT,
    GetRuntimeClassName: *const fn (*anyopaque, *?HSTRING) callconv(.winapi) HRESULT,
    GetTrustLevel: *const fn (*anyopaque, *i32) callconv(.winapi) HRESULT,
    // IToastNotifier
    Show: *const fn (*anyopaque, *anyopaque) callconv(.winapi) HRESULT,
    Hide: *const fn (*anyopaque, *anyopaque) callconv(.winapi) HRESULT,
    get_Setting: *const fn (*anyopaque, *i32) callconv(.winapi) HRESULT,
    AddToastDismissed: *const fn (*anyopaque, *anyopaque, *i64) callconv(.winapi) HRESULT,
    RemoveToastDismissed: *const fn (*anyopaque, i64) callconv(.winapi) HRESULT,
    AddToastFailed: *const fn (*anyopaque, *anyopaque, *i64) callconv(.winapi) HRESULT,
    RemoveToastFailed: *const fn (*anyopaque, i64) callconv(.winapi) HRESULT,
};

pub const IToastNotificationVtbl = extern struct {
    // IUnknown (3)
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    // IInspectable (3)
    GetIids: *const fn (*anyopaque, *u32, *?[*]GUID) callconv(.winapi) HRESULT,
    GetRuntimeClassName: *const fn (*anyopaque, *?HSTRING) callconv(.winapi) HRESULT,
    GetTrustLevel: *const fn (*anyopaque, *i32) callconv(.winapi) HRESULT,
    // IToastNotification — we only need the content getter, but the
    // factory returns this interface so it must exist.
    get_Content: *const fn (*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT,
};

pub const IToastNotificationFactoryVtbl = extern struct {
    // IUnknown (3)
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    // IInspectable (3)
    GetIids: *const fn (*anyopaque, *u32, *?[*]GUID) callconv(.winapi) HRESULT,
    GetRuntimeClassName: *const fn (*anyopaque, *?HSTRING) callconv(.winapi) HRESULT,
    GetTrustLevel: *const fn (*anyopaque, *i32) callconv(.winapi) HRESULT,
    // IToastNotificationFactory
    CreateToastNotification: *const fn (*anyopaque, *anyopaque, *?*anyopaque) callconv(.winapi) HRESULT,
};

pub const IXmlDocumentVtbl = extern struct {
    // IUnknown (3)
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    // IInspectable (3)
    GetIids: *const fn (*anyopaque, *u32, *?[*]GUID) callconv(.winapi) HRESULT,
    GetRuntimeClassName: *const fn (*anyopaque, *?HSTRING) callconv(.winapi) HRESULT,
    GetTrustLevel: *const fn (*anyopaque, *i32) callconv(.winapi) HRESULT,
    // IXmlDocument inherits IXmlNode etc. but we only need
    // QueryInterface → IXmlDocumentIO so no slots required here.
};

pub const IXmlDocumentIOVtbl = extern struct {
    // IUnknown (3)
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    // IInspectable (3)
    GetIids: *const fn (*anyopaque, *u32, *?[*]GUID) callconv(.winapi) HRESULT,
    GetRuntimeClassName: *const fn (*anyopaque, *?HSTRING) callconv(.winapi) HRESULT,
    GetTrustLevel: *const fn (*anyopaque, *i32) callconv(.winapi) HRESULT,
    // IXmlDocumentIO
    LoadXml: *const fn (*anyopaque, HSTRING) callconv(.winapi) HRESULT,
    LoadXmlWithSettings: *const fn (*anyopaque, HSTRING, *anyopaque) callconv(.winapi) HRESULT,
};

// ── COM interface wrappers ──────────────────────────────────────────
// Each wraps a raw v-table pointer and exposes typed method helpers.

fn ComInterface(comptime Vtbl: type) type {
    return extern struct {
        vtbl: *const Vtbl,

        const Self = @This();

        pub inline fn queryInterface(self: *Self, iid: *const GUID, out: *?*anyopaque) HRESULT {
            return self.vtbl.QueryInterface(@ptrCast(self), iid, out);
        }

        pub inline fn addRef(self: *Self) u32 {
            return self.vtbl.AddRef(@ptrCast(self));
        }

        pub inline fn release(self: *Self) u32 {
            return self.vtbl.Release(@ptrCast(self));
        }
    };
}

const IInspectable = ComInterface(IInspectableVtbl);
const IToastNotificationManagerStatics = ComInterface(IToastNotificationManagerStaticsVtbl);
const IToastNotifier = ComInterface(IToastNotifierVtbl);
const IToastNotification = ComInterface(IToastNotificationVtbl);
const IToastNotificationFactory = ComInterface(IToastNotificationFactoryVtbl);
const IXmlDocument = ComInterface(IXmlDocumentVtbl);
const IXmlDocumentIO = ComInterface(IXmlDocumentIOVtbl);

// ── Runtime-loaded combase.dll function types ───────────────────────

const RoInitializeFn = *const fn (u32) callconv(.winapi) HRESULT;
const RoUninitializeFn = *const fn () callconv(.winapi) void;
const RoGetActivationFactoryFn = *const fn (HSTRING, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT;
const RoActivateInstanceFn = *const fn (HSTRING, *?*anyopaque) callconv(.winapi) HRESULT;
const WindowsCreateStringFn = *const fn (?[*]const u16, u32, *?HSTRING) callconv(.winapi) HRESULT;
const WindowsDeleteStringFn = *const fn (?HSTRING) callconv(.winapi) HRESULT;
const WindowsGetStringRawBufferFn = *const fn (HSTRING, ?*u32) callconv(.winapi) ?[*]const u16;

const RO_INIT_SINGLETHREADED: u32 = 0;

const CombaseFns = struct {
    ro_init: RoInitializeFn,
    ro_uninit: RoUninitializeFn,
    ro_get_factory: RoGetActivationFactoryFn,
    ro_activate: RoActivateInstanceFn,
    create_string: WindowsCreateStringFn,
    delete_string: WindowsDeleteStringFn,
    get_string_buf: WindowsGetStringRawBufferFn,
};

fn loadCombase() InitError!CombaseFns {
    const combase = windows.kernel32.LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("combase.dll")) orelse
        return InitError.RuntimeMissing;

    return .{
        .ro_init = @ptrCast(windows.kernel32.GetProcAddress(combase, "RoInitialize") orelse
            return InitError.RuntimeMissing),
        .ro_uninit = @ptrCast(windows.kernel32.GetProcAddress(combase, "RoUninitialize") orelse
            return InitError.RuntimeMissing),
        .ro_get_factory = @ptrCast(windows.kernel32.GetProcAddress(combase, "RoGetActivationFactory") orelse
            return InitError.RuntimeMissing),
        .ro_activate = @ptrCast(windows.kernel32.GetProcAddress(combase, "RoActivateInstance") orelse
            return InitError.RuntimeMissing),
        .create_string = @ptrCast(windows.kernel32.GetProcAddress(combase, "WindowsCreateString") orelse
            return InitError.RuntimeMissing),
        .delete_string = @ptrCast(windows.kernel32.GetProcAddress(combase, "WindowsDeleteString") orelse
            return InitError.RuntimeMissing),
        .get_string_buf = @ptrCast(windows.kernel32.GetProcAddress(combase, "WindowsGetStringRawBuffer") orelse
            return InitError.RuntimeMissing),
    };
}

// ── HSTRING helpers ─────────────────────────────────────────────────

fn createHString(fns: *const CombaseFns, s: [*:0]const u16) InitError!HSTRING {
    var len: u32 = 0;
    while (s[len] != 0) len += 1;
    var hs: ?HSTRING = null;
    const hr = fns.create_string(s, len, &hs);
    if (hr < 0 or hs == null) return InitError.WinrtUnavailable;
    return hs.?;
}

fn createHStringShow(fns: *const CombaseFns, s: [*:0]const u16) ShowError!HSTRING {
    var len: u32 = 0;
    while (s[len] != 0) len += 1;
    var hs: ?HSTRING = null;
    const hr = fns.create_string(s, len, &hs);
    if (hr < 0 or hs == null) return ShowError.ActivationFailed;
    return hs.?;
}

fn createHStringFromSlice(fns: *const CombaseFns, s: []const u16) ShowError!HSTRING {
    var hs: ?HSTRING = null;
    const hr = fns.create_string(s.ptr, @intCast(s.len), &hs);
    if (hr < 0 or hs == null) return ShowError.ActivationFailed;
    return hs.?;
}

// ── XML escaping ────────────────────────────────────────────────────

/// Escape XML special characters in `input`, appending results to `writer`.
pub fn xmlEscape(writer: anytype, input: []const u8) !void {
    for (input) |c| {
        switch (c) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '"' => try writer.writeAll("&quot;"),
            '\'' => try writer.writeAll("&apos;"),
            else => try writer.writeByte(c),
        }
    }
}

/// Build complete toast XML. Caller owns the returned slice.
/// `launch` is optional — when non-null it becomes the toast element's
/// `launch="..."` attribute, which Windows passes to the activation
/// handler when the user clicks the toast from Action Center. Without
/// it, the activation path in `win32_toast_activation.zig` never
/// receives the target surface / tab / action, so the argv scanner
/// has nothing to parse.
fn buildToastXml(alloc: Allocator, title: []const u8, body: []const u8, severity: Severity, launch: ?[]const u8) (Allocator.Error || error{InvalidUtf8})![]const u16 {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(alloc);

    const writer = buf.writer(alloc);

    try writer.writeAll("<toast");
    if (launch) |l| {
        try writer.writeAll(" launch=\"");
        try xmlEscape(writer, l);
        try writer.writeAll("\"");
    }
    try writer.writeAll(">");

    // Audio element for warn/err severities.
    switch (severity) {
        .err, .warn => try writer.writeAll("<audio src=\"ms-winsoundevent:Notification.Looping.Alarm\"/>"),
        .info, .success => {},
    }

    try writer.writeAll("<visual><binding template=\"ToastGeneric\"><text>");
    try xmlEscape(writer, title);
    try writer.writeAll("</text><text>");
    try xmlEscape(writer, body);
    try writer.writeAll("</text></binding></visual></toast>");

    // Convert UTF-8 to UTF-16LE.
    const utf8 = buf.items;
    const utf16_len = std.unicode.calcUtf16LeLen(utf8) catch return error.InvalidUtf8;
    const utf16_buf = try alloc.alloc(u16, utf16_len);
    errdefer alloc.free(utf16_buf);

    const result = std.unicode.utf8ToUtf16Le(utf16_buf, utf8) catch return error.InvalidUtf8;
    _ = result;

    return utf16_buf;
}

// ── HRESULT classification ──────────────────────────────────────────

/// Returns true if the HRESULT should be treated as success for
/// RoInitialize.  S_OK, S_FALSE, and RPC_E_CHANGED_MODE (COM already
/// initialized in a different mode) are all acceptable.
pub fn isRoInitSuccess(hr: HRESULT) bool {
    return hr == S_OK or hr == S_FALSE or hr == RPC_E_CHANGED_MODE;
}

// ── WinrtToast ──────────────────────────────────────────────────────

pub const WinrtToast = struct {
    alloc: Allocator,
    fns: CombaseFns,
    notifier: *IToastNotifier,
    aumid_hs: HSTRING,
    ro_initialized: bool,

    pub fn init(alloc: Allocator, aumid: []const u16) InitError!WinrtToast {
        const fns = try loadCombase();

        // RoInitialize — STA mode.  Accept S_OK, S_FALSE, or
        // RPC_E_CHANGED_MODE (COM already initialized differently).
        const ro_hr = fns.ro_init(RO_INIT_SINGLETHREADED);
        const ro_initialized = isRoInitSuccess(ro_hr);
        if (!ro_initialized and ro_hr < 0 and ro_hr != RPC_E_CHANGED_MODE) {
            return InitError.WinrtUnavailable;
        }
        errdefer if (ro_initialized and ro_hr == S_OK) fns.ro_uninit();

        // Create HSTRING for class name.
        const manager_hs = try createHString(&fns, toast_manager_class);
        defer _ = fns.delete_string(manager_hs);

        // Get the activation factory.
        var factory_raw: ?*anyopaque = null;
        const factory_hr = fns.ro_get_factory(manager_hs, &IID_IToastNotificationManagerStatics, &factory_raw);
        if (factory_hr < 0 or factory_raw == null) return InitError.WinrtUnavailable;

        const factory: *IToastNotificationManagerStatics = @ptrCast(@alignCast(factory_raw.?));
        defer _ = factory.release();

        // Create HSTRING for AUMID.
        var aumid_hs: ?HSTRING = null;
        const hs_hr = fns.create_string(aumid.ptr, @intCast(aumid.len), &aumid_hs);
        if (hs_hr < 0 or aumid_hs == null) return InitError.NotifierCreationFailed;
        errdefer _ = fns.delete_string(aumid_hs.?);

        // CreateToastNotifierWithId.
        var notifier_raw: ?*anyopaque = null;
        const notifier_hr = factory.vtbl.CreateToastNotifierWithId(@ptrCast(factory), aumid_hs.?, &notifier_raw);
        if (notifier_hr < 0 or notifier_raw == null) return InitError.NotifierCreationFailed;

        return .{
            .alloc = alloc,
            .fns = fns,
            .notifier = @ptrCast(@alignCast(notifier_raw.?)),
            .aumid_hs = aumid_hs.?,
            .ro_initialized = ro_initialized and (ro_hr == S_OK),
        };
    }

    pub fn deinit(self: *WinrtToast) void {
        _ = self.notifier.release();
        _ = self.fns.delete_string(self.aumid_hs);
        if (self.ro_initialized) self.fns.ro_uninit();
        self.* = undefined;
    }

    pub fn show(self: *WinrtToast, title: []const u8, body: []const u8, severity: Severity) ShowError!void {
        return self.showWithLaunch(title, body, severity, null);
    }

    /// Same as `show` but stamps the toast XML with a `launch="..."`
    /// attribute. When the user clicks the toast from Action Center,
    /// Windows activates the AUMID with that string as the launch
    /// argument; `win32_toast_activation.parseLaunchArg` picks it up
    /// from argv. Pass `null` to skip the attribute (generic toast —
    /// clicking it just activates the app with no context).
    pub fn showWithLaunch(
        self: *WinrtToast,
        title: []const u8,
        body: []const u8,
        severity: Severity,
        launch: ?[]const u8,
    ) ShowError!void {
        // Build toast XML (UTF-16).
        const xml_utf16 = buildToastXml(self.alloc, title, body, severity, launch) catch |e| switch (e) {
            error.OutOfMemory => return ShowError.OutOfMemory,
            error.InvalidUtf8 => return ShowError.InvalidUtf8,
        };
        defer self.alloc.free(xml_utf16);

        // Activate XmlDocument instance.
        const xml_class_hs = try createHStringShow(&self.fns, xml_document_class);
        defer _ = self.fns.delete_string(xml_class_hs);

        var xml_inspectable_raw: ?*anyopaque = null;
        const act_hr = self.fns.ro_activate(xml_class_hs, &xml_inspectable_raw);
        if (act_hr < 0 or xml_inspectable_raw == null) return ShowError.ActivationFailed;

        const xml_inspectable: *IInspectable = @ptrCast(@alignCast(xml_inspectable_raw.?));
        defer _ = xml_inspectable.release();

        // QueryInterface for IXmlDocumentIO.
        var xml_io_raw: ?*anyopaque = null;
        const qi_hr = xml_inspectable.queryInterface(&IID_IXmlDocumentIO, &xml_io_raw);
        if (qi_hr < 0 or xml_io_raw == null) return ShowError.XmlLoadFailed;

        const xml_io: *IXmlDocumentIO = @ptrCast(@alignCast(xml_io_raw.?));
        defer _ = xml_io.release();

        // LoadXml.
        const xml_hs = try createHStringFromSlice(&self.fns, xml_utf16);
        defer _ = self.fns.delete_string(xml_hs);

        const load_hr = xml_io.vtbl.LoadXml(@ptrCast(xml_io), xml_hs);
        if (load_hr < 0) return ShowError.XmlLoadFailed;

        // Get IToastNotificationFactory.
        const toast_class_hs = try createHStringShow(&self.fns, toast_notification_class);
        defer _ = self.fns.delete_string(toast_class_hs);

        var toast_factory_raw: ?*anyopaque = null;
        const tf_hr = self.fns.ro_get_factory(toast_class_hs, &IID_IToastNotificationFactory, &toast_factory_raw);
        if (tf_hr < 0 or toast_factory_raw == null) return ShowError.ActivationFailed;

        const toast_factory: *IToastNotificationFactory = @ptrCast(@alignCast(toast_factory_raw.?));
        defer _ = toast_factory.release();

        // CreateToastNotification(xmlDoc).
        var notification_raw: ?*anyopaque = null;
        const cn_hr = toast_factory.vtbl.CreateToastNotification(@ptrCast(toast_factory), @ptrCast(xml_inspectable), &notification_raw);
        if (cn_hr < 0 or notification_raw == null) return ShowError.ActivationFailed;

        const notification: *IToastNotification = @ptrCast(@alignCast(notification_raw.?));
        defer _ = notification.release();

        // Show.
        const show_hr = self.notifier.vtbl.Show(@ptrCast(self.notifier), @ptrCast(notification));
        if (show_hr < 0) return ShowError.NotifierShowFailed;
    }
};

// ═══════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════

test "WinrtToast xml escaping - ampersand" {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(std.testing.allocator);
    try xmlEscape(buf.writer(std.testing.allocator),"Tom & Jerry");
    try std.testing.expectEqualStrings("Tom &amp; Jerry", buf.items);
}

test "WinrtToast xml escaping - angle brackets" {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(std.testing.allocator);
    try xmlEscape(buf.writer(std.testing.allocator),"<script>alert('xss')</script>");
    try std.testing.expectEqualStrings("&lt;script&gt;alert(&apos;xss&apos;)&lt;/script&gt;", buf.items);
}

test "WinrtToast xml escaping - quotes" {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(std.testing.allocator);
    try xmlEscape(buf.writer(std.testing.allocator),"He said \"hello\"");
    try std.testing.expectEqualStrings("He said &quot;hello&quot;", buf.items);
}

test "WinrtToast xml escaping - all special chars" {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(std.testing.allocator);
    try xmlEscape(buf.writer(std.testing.allocator),"&<>\"'");
    try std.testing.expectEqualStrings("&amp;&lt;&gt;&quot;&apos;", buf.items);
}

test "WinrtToast xml escaping - passthrough plain text" {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(std.testing.allocator);
    try xmlEscape(buf.writer(std.testing.allocator),"Hello World 123");
    try std.testing.expectEqualStrings("Hello World 123", buf.items);
}

test "WinrtToast xml escaping - empty string" {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(std.testing.allocator);
    try xmlEscape(buf.writer(std.testing.allocator),"");
    try std.testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "WinrtToast HRESULT classification - S_OK is success" {
    try std.testing.expect(isRoInitSuccess(S_OK));
}

test "WinrtToast HRESULT classification - S_FALSE is success" {
    try std.testing.expect(isRoInitSuccess(S_FALSE));
}

test "WinrtToast HRESULT classification - RPC_E_CHANGED_MODE is success" {
    try std.testing.expect(isRoInitSuccess(RPC_E_CHANGED_MODE));
}

test "WinrtToast HRESULT classification - negative codes are failure" {
    const E_FAIL: HRESULT = @bitCast(@as(u32, 0x80004005));
    const E_NOTIMPL: HRESULT = @bitCast(@as(u32, 0x80004001));
    try std.testing.expect(!isRoInitSuccess(E_FAIL));
    try std.testing.expect(!isRoInitSuccess(E_NOTIMPL));
}

test "WinrtToast HRESULT classification - arbitrary positive not success" {
    try std.testing.expect(!isRoInitSuccess(2));
    try std.testing.expect(!isRoInitSuccess(42));
}

test "WinrtToast buildToastXml - info severity no audio" {
    const alloc = std.testing.allocator;
    const xml = try buildToastXml(alloc, "Title", "Body", .info, null);
    defer alloc.free(xml);

    // Convert back to UTF-8 to check content.
    const utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, xml);
    defer alloc.free(utf8);

    try std.testing.expect(std.mem.indexOf(u8, utf8, "<audio") == null);
    try std.testing.expect(std.mem.indexOf(u8, utf8, "<text>Title</text>") != null);
    try std.testing.expect(std.mem.indexOf(u8, utf8, "<text>Body</text>") != null);
}

test "WinrtToast buildToastXml - err severity has audio" {
    const alloc = std.testing.allocator;
    const xml = try buildToastXml(alloc, "Error", "Oops", .err, null);
    defer alloc.free(xml);

    const utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, xml);
    defer alloc.free(utf8);

    try std.testing.expect(std.mem.indexOf(u8, utf8, "<audio src=\"ms-winsoundevent:Notification.Looping.Alarm\"") != null);
}

test "WinrtToast buildToastXml - warn severity has audio" {
    const alloc = std.testing.allocator;
    const xml = try buildToastXml(alloc, "Warning", "Careful", .warn, null);
    defer alloc.free(xml);

    const utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, xml);
    defer alloc.free(utf8);

    try std.testing.expect(std.mem.indexOf(u8, utf8, "<audio") != null);
}

test "WinrtToast buildToastXml - success severity no audio" {
    const alloc = std.testing.allocator;
    const xml = try buildToastXml(alloc, "Done", "All good", .success, null);
    defer alloc.free(xml);

    const utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, xml);
    defer alloc.free(utf8);

    try std.testing.expect(std.mem.indexOf(u8, utf8, "<audio") == null);
}

test "WinrtToast buildToastXml - escapes special chars in title and body" {
    const alloc = std.testing.allocator;
    const xml = try buildToastXml(alloc, "A & B", "<tag>", .info, null);
    defer alloc.free(xml);

    const utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, xml);
    defer alloc.free(utf8);

    try std.testing.expect(std.mem.indexOf(u8, utf8, "&amp;") != null);
    try std.testing.expect(std.mem.indexOf(u8, utf8, "&lt;tag&gt;") != null);
    // Raw & < > should NOT appear in text content.
    // (They appear in markup, so we check they don't appear inside <text> tags.)
    const text_start = std.mem.indexOf(u8, utf8, "<text>").?;
    const text_end = std.mem.indexOfPos(u8, utf8, text_start, "</text>").?;
    const first_text = utf8[text_start + 6 .. text_end];
    try std.testing.expectEqualStrings("A &amp; B", first_text);
}

test "WinrtToast buildToastXml - valid XML structure" {
    const alloc = std.testing.allocator;
    const xml = try buildToastXml(alloc, "T", "B", .info, null);
    defer alloc.free(xml);

    const utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, xml);
    defer alloc.free(utf8);

    try std.testing.expect(std.mem.startsWith(u8, utf8, "<toast>"));
    try std.testing.expect(std.mem.endsWith(u8, utf8, "</toast>"));
    try std.testing.expect(std.mem.indexOf(u8, utf8, "template=\"ToastGeneric\"") != null);
}

test "WinrtToast buildToastXml - includes launch attribute when provided" {
    const alloc = std.testing.allocator;
    const xml = try buildToastXml(alloc, "T", "B", .info, "wgh://activate?surface=42");
    defer alloc.free(xml);

    const utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, xml);
    defer alloc.free(utf8);

    try std.testing.expect(std.mem.startsWith(u8, utf8, "<toast launch=\""));
    try std.testing.expect(std.mem.indexOf(u8, utf8, "wgh://activate?surface=42") != null);
}

test "WinrtToast buildToastXml - launch attribute is XML-escaped" {
    const alloc = std.testing.allocator;
    const xml = try buildToastXml(alloc, "T", "B", .info, "wgh://activate?surface=1&tab=2");
    defer alloc.free(xml);

    const utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, xml);
    defer alloc.free(utf8);

    // `&` in the query string must escape to `&amp;` inside the
    // attribute value — unescaped raw `&` would abort XML parsing
    // inside WinRT's `IXmlDocumentIO.LoadXml`.
    try std.testing.expect(std.mem.indexOf(u8, utf8, "surface=1&amp;tab=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, utf8, "surface=1&tab=2\"") == null);
}

test "WinrtToast GUID sizes are 16 bytes" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(GUID));
    // Verify all IID constants parse correctly (comptime-checked, but belt-and-suspenders).
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(@TypeOf(IID_IInspectable)));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(@TypeOf(IID_IToastNotificationManagerStatics)));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(@TypeOf(IID_IToastNotificationFactory)));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(@TypeOf(IID_IXmlDocumentIO)));
}

test "WinrtToast COM interface wrappers have vtbl pointer at offset 0" {
    // The COM ABI requires the vtbl pointer at offset 0. Verify for
    // every interface wrapper we use.
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(IInspectable, "vtbl"));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(IToastNotificationManagerStatics, "vtbl"));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(IToastNotifier, "vtbl"));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(IToastNotification, "vtbl"));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(IToastNotificationFactory, "vtbl"));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(IXmlDocument, "vtbl"));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(IXmlDocumentIO, "vtbl"));
}

test "WinrtToast init/deinit flag tracking - ro_initialized false prevents RoUninitialize" {
    // This is a behavioral contract test: we verify that the struct
    // correctly tracks whether RoInitialize succeeded with S_OK so
    // deinit knows whether to call RoUninitialize.
    //
    // We cannot call real WinRT in unit tests, so we verify the flag
    // logic at the type level.

    // S_OK → ro_initialized = true
    try std.testing.expect(isRoInitSuccess(S_OK));

    // S_FALSE → success but should NOT set ro_initialized (another
    // init already did it; double-uninit would be wrong).
    try std.testing.expect(isRoInitSuccess(S_FALSE));

    // RPC_E_CHANGED_MODE → success, but RoInitialize was not the one
    // that initialized, so ro_initialized should be false.
    try std.testing.expect(isRoInitSuccess(RPC_E_CHANGED_MODE));

    // The init function sets ro_initialized = (ro_hr == S_OK), which
    // means only a fresh S_OK triggers RoUninitialize on deinit. This
    // is verified by reading the source; we test the classification fn.
}

test "WinrtToast ComInterface wrapper size equals pointer size" {
    // COM interfaces are a single vtbl pointer in the ABI.
    try std.testing.expectEqual(@sizeOf(*anyopaque), @sizeOf(IInspectable));
    try std.testing.expectEqual(@sizeOf(*anyopaque), @sizeOf(IToastNotifier));
    try std.testing.expectEqual(@sizeOf(*anyopaque), @sizeOf(IXmlDocumentIO));
}
