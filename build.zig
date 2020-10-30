const mem = @import("std").mem;
const Builder = @import("std").build.Builder;

pub fn build(b: *Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const examples = b.option(
        bool,
        "examples",
        "Set to true to build examples",
    ) orelse false;

    {
        const scanner = b.addExecutable("scanner", "scanner.zig");
        scanner.setTarget(target);
        scanner.setBuildMode(mode);

        scanner.install();
    }

    {
        const test_files = [_][]const u8{ "scanner.zig", "src/common_core.zig" };

        const test_step = b.step("test", "Run the tests");
        for (test_files) |file| {
            const t = b.addTest(file);
            t.setTarget(target);
            t.setBuildMode(mode);

            test_step.dependOn(&t.step);
        }
    }

    if (examples) {
        const example_names = [_][]const u8{ "globals", "listener", "seats" };
        for (example_names) |example| {
            const path = mem.concat(b.allocator, u8, &[_][]const u8{ "example/", example, ".zig" }) catch unreachable;
            const exe = b.addExecutable(example, path);
            exe.setTarget(target);
            exe.setBuildMode(mode);

            exe.linkLibC();
            exe.linkSystemLibrary("wayland-client");

            // Requires the scanner to have been run for this to build
            // TODO: integrate scanner with build system
            exe.addPackagePath("wayland", "wayland.zig");

            exe.install();
        }
    }
}

pub const ScanProtocolsStep = struct {
    const Target = enum {
        client,
        server,
        both,
    };

    builder: *Builder,
    step: std.build.Step,

    /// Relative path to the root of the zig wayland repo from the user's build.zig
    zig_wayland_path: []const u8,

    /// Whether to generate bindings for wayland-client, wayland-server, or both
    target: Target,

    /// Slice of absolute paths of protocol xml files to be scanned
    protocol_paths: std.ArrayList([]const u8),

    pub fn create(builder: *Builder, zig_wayland_path: []const u8, target: Target) *ScanProtocolsStep {
        const self = builder.allocator.create(ScanProtocolsStep) catch unreachable;
        self.* = .{
            .builder = builder,
            .step = std.build.Step.init(.Custom, "Scan Protocols", builder.allocator, make),
            .zig_wayland_path = zig_wayland_path,
            .target = target,
            .protocol_paths = std.ArrayList([]const u8).init(builder.allocator),
        };
        return self;
    }

    /// Generate bindings from the protocol xml at the given path
    pub fn addProtocolPath(self: *ScanProtocolsStep, path: []const u8) void {
        self.protocol_paths.append(path) catch unreachable;
    }

    /// Generate bindings from protocol xml provided by the wayland-protocols
    /// package given the relative path (e.g. "stable/xdg-shell/xdg-shell.xml")
    pub fn addSystemProtocol(self: *ScanProtocolsStep, relative_path: []const u8) void {
        const protocol_dir = std.fmt.trim(try self.builder.exec(
            &[_][]const u8{ "pkg-config", "--variable=pkgdatadir", "wayland-protocols" },
        ));
        self.addProtocolPath(std.fs.path.join(
            self.builder.allocator,
            &[_][]const u8{ protocol_dir, relative_path },
        ) catch unreachable);
    }

    fn make(step: *std.build.Step) !void {
        const self = @fieldParentPtr(ScanProtocolsStep, "step", step);
        const allocator = self.builder.allocator;

        for (self.protocol_paths.items) |path| {
            _ = try self.builder.exec(
                &[_][]const u8{ "wayland-scanner", "private-code", path, self.getCodePath(path) },
            );
        }
    }

    /// Link the given LibExeObjStep against libwayland and compile the
    /// necessary C code.
    pub fn link(self: *ScanProtocolsStep, obj: *std.build.LibExeObjStep) void {
        obj.linkLibC();

        switch (self.target) {
            .client => obj.linkSystemLibrary("wayland-client"),
            .server => obj.linkSystemLibrary("wayland-server"),
            .both => {
                obj.linkSystemLibrary("wayland-client");
                obj.linkSystemLibrary("wayland-server");
            },
        }

        for (self.protocol_paths.items) |path|
            obj.addCSourceFile(self.getCodePath(path), &[_][]const u8{"-std=c99"});
    }

    fn getCodePath(self: *ScanProtocolsStep, xml_in_path: []const u8) void {
        // Extension is .xml, so slice off the last 4 characters
        const basename = std.fs.path.basename(xml_in_path);
        const basename_no_ext = basename[0..(basename.len - 4)];

        return std.fmt.allocPrint(allocator, "{}-protocol.c", .{basename_no_ext}) catch unreachable;
    }
};
