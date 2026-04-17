//! Windows UIA control-type / property IDs.
//!
//! Values come from uiautomationclient.h. Only the IDs we actually use
//! from this codebase are declared; the full tables live in the SDK.

// ── Control types ───────────────────────────────────────────────────────
// UIA_ControlTypeId values. 50000-series.

pub const UIA_ButtonControlTypeId: i32 = 50000;
pub const UIA_EditControlTypeId: i32 = 50004;
pub const UIA_ListControlTypeId: i32 = 50008;
pub const UIA_ListItemControlTypeId: i32 = 50007;
pub const UIA_MenuControlTypeId: i32 = 50009;
pub const UIA_PaneControlTypeId: i32 = 50033;
pub const UIA_TabControlTypeId: i32 = 50018;
pub const UIA_TabItemControlTypeId: i32 = 50019;
pub const UIA_TitleBarControlTypeId: i32 = 50037;
pub const UIA_ToolBarControlTypeId: i32 = 50021;
pub const UIA_WindowControlTypeId: i32 = 50032;

// ── Properties ──────────────────────────────────────────────────────────
// UIA_PropertyId values. 30000-series.

pub const UIA_ControlTypePropertyId: i32 = 30003;
pub const UIA_LocalizedControlTypePropertyId: i32 = 30004;
pub const UIA_NamePropertyId: i32 = 30005;
pub const UIA_HelpTextPropertyId: i32 = 30013;
pub const UIA_IsKeyboardFocusablePropertyId: i32 = 30009;
pub const UIA_HasKeyboardFocusPropertyId: i32 = 30008;
pub const UIA_IsEnabledPropertyId: i32 = 30010;
pub const UIA_AutomationIdPropertyId: i32 = 30011;
pub const UIA_ClassNamePropertyId: i32 = 30012;
pub const UIA_OrientationPropertyId: i32 = 30023;
pub const UIA_FrameworkIdPropertyId: i32 = 30024;
pub const UIA_IsControlElementPropertyId: i32 = 30016;
pub const UIA_IsContentElementPropertyId: i32 = 30017;

// ── Patterns (unused in P1 skeleton; listed for future phases) ─────────
// UIA_PatternId values. 10000-series.

pub const UIA_InvokePatternId: i32 = 10000;
pub const UIA_SelectionPatternId: i32 = 10001;
pub const UIA_ValuePatternId: i32 = 10002;
pub const UIA_SelectionItemPatternId: i32 = 10010;
pub const UIA_WindowPatternId: i32 = 10009;
pub const UIA_TextPatternId: i32 = 10014;

// ── Event IDs ──────────────────────────────────────────────────────────

pub const UIA_AutomationFocusChangedEventId: i32 = 20005;
pub const UIA_StructureChangedEventId: i32 = 20002;
pub const UIA_Selection_InvalidatedEventId: i32 = 20013;
