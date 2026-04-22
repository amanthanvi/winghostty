/// See `font-synthetic-style` for documentation.
pub const FontSyntheticStyle = packed struct {
    bold: bool = true,
    italic: bool = true,
    @"bold-italic": bool = true,
};

/// See `freetype-load-flags` for documentation.
pub const FreetypeLoadFlags = packed struct {
    // The defaults here at the time of writing this match the defaults
    // for Freetype itself. Ghostty hasn't made any opinionated changes
    // to these defaults. (Strictly speaking, `light` isn't FreeType's
    // own default, but appears to be the effective default with most
    // Fontconfig-aware software using FreeType, so until Ghostty
    // implements Fontconfig support we default to `light`.)
    hinting: bool = true,
    @"force-autohint": bool = false,
    monochrome: bool = false,
    autohint: bool = true,
    light: bool = true,
};
