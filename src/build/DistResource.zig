const std = @import("std");

/// A dist resource is a resource that is built and distributed as part
/// of the source tarball with Ghostty. These aren't committed to the Git
/// repository but are built as part of the `zig build dist` command.
/// The purpose is to limit the number of build-time dependencies required
/// for downstream users and packagers.
pub const Resource = struct {
    /// The relative path in the source tree where the resource will be
    /// if it was pre-built. These are not checksummed or anything because the
    /// assumption is that the source tarball itself is checksummed and signed.
    dist: []const u8,

    /// The path to the generated resource in the build system. By depending
    /// on this you'll force it to regenerate. This does NOT point to the
    /// "path" above.
    generated: std.Build.LazyPath,

    /// Returns the path to use for this resource.
    pub fn path(self: *const Resource, b: *std.Build) std.Build.LazyPath {
        // If the dist path exists at build compile time then we use it.
        if (self.exists(b)) {
            return b.path(self.dist);
        }

        // Otherwise we use the generated path.
        return self.generated;
    }

    /// Returns true if the dist path exists at build time.
    pub fn exists(self: *const Resource, b: *std.Build) bool {
        if (b.build_root.handle.access(self.dist, .{})) {
            // If we have a ".git" directory then we're a git checkout
            // and we never want to use the dist path. This shouldn't happen
            // so show a warning to the user.
            if (b.build_root.handle.access(".git", .{})) {
                std.log.warn(
                    "dist resource '{s}' should not be in a git checkout",
                    .{self.dist},
                );
                return false;
            } else |_| {}

            return true;
        } else |_| {
            return false;
        }
    }
};
