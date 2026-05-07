//! ziglint - A linter for Zig source code

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
pub const version = build_options.version;

const FileConfig = @import("Config.zig");
const Linter = @import("Linter.zig");
const ModuleGraph = @import("ModuleGraph.zig");
const rules = @import("rules.zig");
const TypeResolver = @import("TypeResolver.zig");

pub const Config = struct {
    zig_lib_path: ?[]const u8 = null,
    paths: []const []const u8 = &.{},
    only_rules: []const rules.Rule = &.{},
    ignored_rules: []const rules.Rule = &.{},
    file_config: FileConfig = .{},
    verbose: bool = false,
};

/// Compatibility shim for the removed std.time.Timer in Zig 0.16.
/// Wraps std.Io.Timestamp + monotonic clock with a Timer-like read() interface.
const VerboseTimer = struct {
    start: std.Io.Timestamp,

    fn init(io: std.Io) VerboseTimer {
        return .{ .start = std.Io.Timestamp.now(io, .awake) };
    }

    fn read(self: *VerboseTimer, io: std.Io) u64 {
        const elapsed = self.start.durationTo(std.Io.Timestamp.now(io, .awake));
        return @intCast(@max(elapsed.nanoseconds, 0));
    }
};

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    const io = init.io;
    const environ_map = init.environ_map;

    // Process-lifetime arena for CLI paths, detected `zig env` lib dir, and
    // FileConfig dupes. These all live until end-of-main, so an arena is the
    // simplest leak-free pattern (avoids hand-tracking individual frees in
    // the catch/return paths).
    var config_arena: std.heap.ArenaAllocator = .init(allocator);
    defer config_arena.deinit();
    const cfg_alloc = config_arena.allocator();

    const stderr_file = std.Io.File.stderr();
    const use_color = detectColorSupport(stderr_file, io, environ_map);

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    defer stdout.end() catch {};

    var stderr_buf: [4096]u8 = undefined;
    var stderr = stderr_file.writer(io, &stderr_buf);
    defer stderr.end() catch {};

    var config = parseArgs(cfg_alloc, init.minimal.args, &stderr.interface) catch |err| switch (err) {
        error.HelpOrVersion => return 0,
        error.InvalidArgs => return 1,
        else => return err,
    };

    // Load config file from first CLI path (or current directory)
    const start_path = if (config.paths.len > 0) config.paths[0] else null;
    config.file_config = FileConfig.load(io, cfg_alloc, start_path) catch .{};

    applyOnlyRules(&config);

    // Use CLI paths, then config file paths, then default to "."
    if (config.paths.len == 0) {
        if (config.file_config.paths.len > 0) {
            config.paths = config.file_config.paths;
        } else {
            config.paths = &.{"."};
        }
    }

    const zig_lib_path = config.zig_lib_path orelse detectZigLibPath(cfg_alloc, allocator, io, &stderr.interface) catch null;

    var total_timer = if (config.verbose) VerboseTimer.init(io) else null;

    var total_issues: usize = 0;
    for (config.paths) |path| {
        const abs_path_z = std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator) catch null;
        defer if (abs_path_z) |p| allocator.free(p);
        const abs_path: []const u8 = if (abs_path_z) |p| p else path;
        const project_root = findProjectRoot(io, abs_path);
        total_issues += try lintPath(allocator, io, path, zig_lib_path, &config, use_color, project_root, &stderr.interface);
    }

    if (config.verbose and total_timer != null) {
        const total_ms = @as(f64, @floatFromInt(total_timer.?.read(io))) / 1_000_000.0;
        const dim = if (use_color) "\x1b[2m" else "";
        const cyan = if (use_color) "\x1b[36m" else "";
        const reset = if (use_color) "\x1b[0m" else "";
        try stderr.interface.print("\n{s}{s}Total time:{s} {s}{d:.2}ms{s}\n", .{ dim, cyan, reset, cyan, total_ms, reset });
    }

    return if (total_issues > 0) 1 else 0;
}

fn detectColorSupport(file: std.Io.File, io: std.Io, environ_map: *const std.process.Environ.Map) bool {
    // NO_COLOR takes precedence (https://no-color.org/)
    if (environ_map.get("NO_COLOR")) |_| return false;
    if (environ_map.get("FORCE_COLOR")) |_| return true;
    // Otherwise, use color if stdout is a TTY
    return file.isTty(io) catch false;
}

fn findProjectRoot(io: std.Io, start_path: []const u8) ?[]const u8 {
    var path = start_path;
    while (true) {
        // Check if build.zig exists in this directory
        const build_zig = std.fs.path.join(std.heap.page_allocator, &.{ path, "build.zig" }) catch return null;
        defer std.heap.page_allocator.free(build_zig);

        if (std.Io.Dir.cwd().access(io, build_zig, .{})) |_| {
            return std.heap.page_allocator.dupe(u8, path) catch null;
        } else |_| {}

        // Move up one directory
        const parent = std.fs.path.dirname(path) orelse return null;
        if (std.mem.eql(u8, parent, path)) return null; // at root
        path = parent;
    }
}

fn makeRelativePath(path: []const u8, project_root: ?[]const u8) []const u8 {
    const root = project_root orelse return path;
    if (std.mem.startsWith(u8, path, root)) {
        var rel = path[root.len..];
        // Skip leading path separator
        if (rel.len > 0 and rel[0] == std.fs.path.sep) {
            rel = rel[1..];
        }
        if (rel.len > 0) return rel;
    }
    return path;
}

fn parseArgs(allocator: std.mem.Allocator, args: std.process.Args, writer: *std.Io.Writer) !Config {
    var iter = try args.iterateAllocator(allocator);
    defer iter.deinit();

    var config: Config = .{};
    var paths: std.ArrayList([]const u8) = .empty;
    var only_rules: std.ArrayList(rules.Rule) = .empty;
    var ignored_rules: std.ArrayList(rules.Rule) = .empty;

    // Skip program name (argv[0])
    _ = iter.skip();

    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--zig-lib-path")) {
            const next = iter.next() orelse {
                try writer.writeAll("error: --zig-lib-path requires a path argument\n");
                return error.InvalidArgs;
            };
            config.zig_lib_path = try allocator.dupe(u8, next);
        } else if (std.mem.eql(u8, arg, "--only")) {
            const next = iter.next() orelse {
                try writer.writeAll("error: --only requires a rule code (e.g., Z001)\n");
                return error.InvalidArgs;
            };
            if (parseRuleCode(next)) |rule| {
                try only_rules.append(allocator, rule);
            } else {
                try writer.print("error: unknown rule code '{s}'\n", .{next});
                return error.InvalidArgs;
            }
        } else if (std.mem.eql(u8, arg, "--ignore")) {
            const next = iter.next() orelse {
                try writer.writeAll("error: --ignore requires a rule code (e.g., Z001)\n");
                return error.InvalidArgs;
            };
            if (parseRuleCode(next)) |rule| {
                try ignored_rules.append(allocator, rule);
            } else {
                try writer.print("error: unknown rule code '{s}'\n", .{next});
                return error.InvalidArgs;
            }
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            config.verbose = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printUsage(writer);
            return error.HelpOrVersion;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            try printVersion(writer);
            return error.HelpOrVersion;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try writer.print("error: unknown option '{s}'\n", .{arg});
            return error.InvalidArgs;
        } else {
            try paths.append(allocator, try allocator.dupe(u8, arg));
        }
    }

    config.paths = paths.items;
    config.only_rules = only_rules.items;
    config.ignored_rules = ignored_rules.items;
    return config;
}

fn parseRuleCode(code: []const u8) ?rules.Rule {
    inline for (std.meta.fields(rules.Rule)) |field| {
        if (std.mem.eql(u8, code, field.name)) {
            return @enumFromInt(field.value);
        }
    }
    return null;
}

fn applyOnlyRules(config: *Config) void {
    if (config.only_rules.len == 0) return;

    inline for (std.meta.fields(rules.Rule)) |field| {
        const rule: rules.Rule = @enumFromInt(field.value);
        config.file_config.setRuleEnabled(rule, false);
    }

    for (config.only_rules) |rule| {
        config.file_config.setRuleEnabled(rule, true);
    }

    // Keep --ignore behavior consistent when used with --only.
    for (config.ignored_rules) |rule| {
        config.file_config.setRuleEnabled(rule, false);
    }
}

/// `out_alloc` owns the returned slice (process-lifetime arena);
/// `tmp_alloc` owns the temporary `zig env` stdout/stderr buffers.
fn detectZigLibPath(out_alloc: std.mem.Allocator, tmp_alloc: std.mem.Allocator, io: std.Io, writer: *std.Io.Writer) !?[]const u8 {
    const result = std.process.run(tmp_alloc, io, .{
        .argv = &.{ "zig", "env" },
        .stdout_limit = .limited(64 * 1024),
    }) catch |err| {
        try writer.print("warning: could not run 'zig env': {}\n", .{err});
        return null;
    };
    defer tmp_alloc.free(result.stdout);
    defer tmp_alloc.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }

    return parseLibDirFromZigEnv(out_alloc, result.stdout);
}

fn parseLibDirFromZigEnv(allocator: std.mem.Allocator, output: []const u8) ?[]const u8 {
    const needle = ".lib_dir = \"";
    const start_idx = std.mem.indexOf(u8, output, needle) orelse return null;
    const value_start = start_idx + needle.len;
    const end_idx = std.mem.indexOfPos(u8, output, value_start, "\"") orelse return null;
    return allocator.dupe(u8, output[value_start..end_idx]) catch null;
}

fn lintPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8, zig_lib_path: ?[]const u8, config: *const Config, use_color: bool, project_root: ?[]const u8, writer: *std.Io.Writer) !usize {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| {
        if (err == error.IsDir) {
            return lintDirectory(allocator, io, path, zig_lib_path, config, use_color, project_root, writer);
        }
        try writer.print("error: cannot access '{s}': {}\n", .{ path, err });
        return 0;
    };

    if (stat.kind == .directory) {
        return lintDirectory(allocator, io, path, zig_lib_path, config, use_color, project_root, writer);
    }

    return lintFile(allocator, io, path, zig_lib_path, config, use_color, project_root, writer);
}

fn lintDirectory(allocator: std.mem.Allocator, io: std.Io, path: []const u8, zig_lib_path: ?[]const u8, config: *const Config, use_color: bool, project_root: ?[]const u8, writer: *std.Io.Writer) !usize {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
        try writer.print("error: cannot open directory '{s}': {}\n", .{ path, err });
        return 0;
    };
    defer dir.close(io);

    const gitignore = loadGitignore(io, allocator, dir);
    defer if (gitignore) |g| allocator.free(g);

    // Collect all .zig files first
    var files: std.ArrayList([]const u8) = .empty;
    defer {
        for (files.items) |f| allocator.free(f);
        files.deinit(allocator);
    }

    var walker = dir.walk(allocator) catch |err| {
        try writer.print("error: cannot walk directory '{s}': {}\n", .{ path, err });
        return 0;
    };
    defer walker.deinit();

    while (walker.next(io) catch null) |entry| {
        if (shouldSkip(entry.path, gitignore)) continue;
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

        const full_path = std.fs.path.join(allocator, &.{ path, entry.path }) catch continue;
        files.append(allocator, full_path) catch {
            allocator.free(full_path);
            continue;
        };
    }

    if (files.items.len == 0) return 0;

    const dim = if (use_color) "\x1b[2m" else "";
    const cyan = if (use_color) "\x1b[36m" else "";
    const reset = if (use_color) "\x1b[0m" else "";

    if (config.verbose) {
        try writer.print("{s}┌─ {s}{s}{s} ({d} files)\n", .{ dim, reset, path, reset, files.items.len });
    }

    var timer = if (config.verbose) VerboseTimer.init(io) else null;

    // Build module graph once using first file as root, then add all others
    const graph_start = if (timer) |*t| t.read(io) else 0;
    var graph = ModuleGraph.init(io, allocator, files.items[0], zig_lib_path) catch {
        // Fall back to per-file linting without semantics
        if (config.verbose) {
            try writer.print("{s}│ module graph failed, using simple linting{s}\n", .{ dim, reset });
        }
        var total: usize = 0;
        for (files.items) |file_path| {
            total += try lintFileSimple(allocator, io, file_path, config, use_color, project_root, writer);
        }
        return total;
    };
    defer graph.deinit();

    if (config.verbose and timer != null) {
        const elapsed = timer.?.read(io) - graph_start;
        try writer.print("{s}│ module graph:  {s}{d:>7.2}ms{s}\n", .{ dim, cyan, @as(f64, @floatFromInt(elapsed)) / 1_000_000.0, reset });
    }

    // Add remaining files to the graph
    const add_start = if (timer) |*t| t.read(io) else 0;
    for (files.items[1..]) |file_path| {
        graph.addModulePublic(file_path);
    }

    if (config.verbose and timer != null and files.items.len > 1) {
        const elapsed = timer.?.read(io) - add_start;
        try writer.print("{s}│ add files:     {s}{d:>7.2}ms{s} ({d} files)\n", .{ dim, cyan, @as(f64, @floatFromInt(elapsed)) / 1_000_000.0, reset, files.items.len - 1 });
    }

    const resolver_start = if (timer) |*t| t.read(io) else 0;
    var resolver: TypeResolver = .init(allocator, &graph);
    defer resolver.deinit();

    if (config.verbose and timer != null) {
        const elapsed = timer.?.read(io) - resolver_start;
        try writer.print("{s}│ type resolver: {s}{d:>7.2}ms{s}\n", .{ dim, cyan, @as(f64, @floatFromInt(elapsed)) / 1_000_000.0, reset });
    }

    var total: usize = 0;
    for (files.items) |file_path| {
        total += try lintFileWithGraph(allocator, io, file_path, &graph, &resolver, config, use_color, project_root, writer);
    }

    if (config.verbose and timer != null) {
        const total_time = timer.?.read(io);
        try writer.print("{s}└─ total:        {s}{d:>7.2}ms{s}\n", .{ dim, cyan, @as(f64, @floatFromInt(total_time)) / 1_000_000.0, reset });
    }

    return total;
}

fn shouldSkip(path: []const u8, gitignore: ?[]const u8) bool {
    var iter = std.mem.splitScalar(u8, path, std.fs.path.sep);
    while (iter.next()) |component| {
        if (std.mem.startsWith(u8, component, ".")) return true;
        if (std.mem.eql(u8, component, "zig-cache")) return true;
        if (std.mem.eql(u8, component, "zig-out")) return true;
    }

    if (gitignore) |patterns| {
        var lines = std.mem.splitScalar(u8, patterns, '\n');
        while (lines.next()) |line| {
            const pattern = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (pattern.len == 0 or pattern[0] == '#') continue;
            if (matchesGitignore(path, pattern)) return true;
        }
    }

    return false;
}

fn matchesGitignore(path: []const u8, pattern: []const u8) bool {
    const clean_pattern = if (std.mem.endsWith(u8, pattern, "/"))
        pattern[0 .. pattern.len - 1]
    else
        pattern;

    if (std.mem.startsWith(u8, clean_pattern, "/")) {
        return std.mem.startsWith(u8, path, clean_pattern[1..]);
    }

    var iter = std.mem.splitScalar(u8, path, std.fs.path.sep);
    while (iter.next()) |component| {
        if (std.mem.eql(u8, component, clean_pattern)) return true;
    }

    return std.mem.indexOf(u8, path, clean_pattern) != null;
}

fn loadGitignore(io: std.Io, allocator: std.mem.Allocator, dir: std.Io.Dir) ?[]const u8 {
    return dir.readFileAlloc(io, ".gitignore", allocator, .limited(1024 * 64)) catch null;
}

fn lintFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8, zig_lib_path: ?[]const u8, config: *const Config, use_color: bool, project_root: ?[]const u8, writer: *std.Io.Writer) !usize {
    var timer = if (config.verbose) VerboseTimer.init(io) else null;

    const dim = if (use_color) "\x1b[2m" else "";
    const cyan = if (use_color) "\x1b[36m" else "";
    const reset = if (use_color) "\x1b[0m" else "";

    if (config.verbose) {
        try writer.print("{s}┌─ {s}{s}{s}\n", .{ dim, reset, path, reset });
    }

    const graph_start = if (timer) |*t| t.read(io) else 0;
    var graph = ModuleGraph.init(io, allocator, path, zig_lib_path) catch {
        return lintFileSimple(allocator, io, path, config, use_color, project_root, writer);
    };
    defer graph.deinit();

    if (config.verbose and timer != null) {
        const elapsed = timer.?.read(io) - graph_start;
        try writer.print("{s}│ module graph:  {s}{d:>7.2}ms{s}\n", .{ dim, cyan, @as(f64, @floatFromInt(elapsed)) / 1_000_000.0, reset });
    }

    const resolver_start = if (timer) |*t| t.read(io) else 0;
    var resolver: TypeResolver = .init(allocator, &graph);
    defer resolver.deinit();

    if (config.verbose and timer != null) {
        const elapsed = timer.?.read(io) - resolver_start;
        try writer.print("{s}│ type resolver: {s}{d:>7.2}ms{s}\n", .{ dim, cyan, @as(f64, @floatFromInt(elapsed)) / 1_000_000.0, reset });
    }

    const result = try lintFileWithGraph(allocator, io, path, &graph, &resolver, config, use_color, project_root, writer);

    if (config.verbose and timer != null) {
        const total = timer.?.read(io);
        try writer.print("{s}└─ total:        {s}{d:>7.2}ms{s}\n", .{ dim, cyan, @as(f64, @floatFromInt(total)) / 1_000_000.0, reset });
    }

    return result;
}

fn lintFileSimple(allocator: std.mem.Allocator, io: std.Io, path: []const u8, config: *const Config, use_color: bool, project_root: ?[]const u8, writer: *std.Io.Writer) !usize {
    const source = std.Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        allocator,
        .limited(1024 * 1024 * 16),
        .@"1",
        0,
    ) catch |err| {
        try writer.print("error: cannot read '{s}': {}\n", .{ path, err });
        return 0;
    };
    defer allocator.free(source);

    var linter: Linter = .init(allocator, source, path, &config.file_config);
    defer linter.deinit();
    linter.lint();
    return writeDiagnostics(allocator, linter.diagnostics.items, config, use_color, project_root, writer);
}

fn lintFileWithGraph(allocator: std.mem.Allocator, io: std.Io, path: []const u8, graph: *ModuleGraph, resolver: *TypeResolver, config: *const Config, use_color: bool, project_root: ?[]const u8, writer: *std.Io.Writer) !usize {
    const mod = graph.getModule(path) orelse {
        return lintFileSimple(allocator, io, path, config, use_color, project_root, writer);
    };

    const dim = if (use_color) "\x1b[2m" else "";
    const cyan = if (use_color) "\x1b[36m" else "";
    const reset = if (use_color) "\x1b[0m" else "";

    var linter: Linter = .initWithSemantics(allocator, mod.source, mod.path, resolver, mod.path, &config.file_config);
    defer linter.deinit();

    linter.verbose = config.verbose;
    linter.use_color = use_color;

    var timer = if (config.verbose) VerboseTimer.init(io) else null;
    linter.lint();

    if (config.verbose and timer != null) {
        const elapsed = timer.?.read(io);
        try writer.print("{s}│ linting:       {s}{d:>7.2}ms{s}\n", .{ dim, cyan, @as(f64, @floatFromInt(elapsed)) / 1_000_000.0, reset });
    }

    return writeDiagnostics(allocator, linter.diagnostics.items, config, use_color, project_root, writer);
}

fn writeDiagnostics(allocator: std.mem.Allocator, diagnostics: []const Linter.Diagnostic, config: *const Config, use_color: bool, project_root: ?[]const u8, writer: *std.Io.Writer) !usize {
    var count: usize = 0;
    var rule_counts: std.AutoHashMapUnmanaged(rules.Rule, usize) = .empty;
    defer rule_counts.deinit(allocator);

    for (diagnostics) |diag| {
        // Track rule counts for verbose output
        if (config.verbose) {
            const entry = rule_counts.getOrPut(allocator, diag.rule) catch continue;
            if (!entry.found_existing) {
                entry.value_ptr.* = 0;
            }
            entry.value_ptr.* += 1;
        }

        // Check CLI ignore list
        var ignored = false;
        for (config.ignored_rules) |ignored_rule| {
            if (diag.rule == ignored_rule) {
                ignored = true;
                break;
            }
        }
        // Check config file rule enabled state
        if (!ignored and !config.file_config.isRuleEnabled(diag.rule)) {
            ignored = true;
        }
        if (!ignored) {
            const display_path = makeRelativePath(diag.path, project_root);
            try diag.write(writer, use_color, display_path);
            count += 1;
        }
    }

    // Print rule summary if verbose
    if (config.verbose and rule_counts.count() > 0) {
        const dim = if (use_color) "\x1b[2m" else "";
        const yellow = if (use_color) "\x1b[33m" else "";
        const reset = if (use_color) "\x1b[0m" else "";

        try writer.print("{s}│ rules:{s}\n", .{ dim, reset });
        var iter = rule_counts.iterator();
        while (iter.next()) |entry| {
            try writer.print("{s}│   {s}{s}{s}: {d}{s}\n", .{ dim, yellow, entry.key_ptr.code(), reset, entry.value_ptr.*, reset });
        }
    }

    return count;
}

fn printUsage(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\Usage: ziglint [options] <paths...>
        \\
        \\Lint Zig source files for style and correctness issues.
        \\
        \\Options:
        \\  --only <rule>         Lint only this rule (e.g., Z001). Can be repeated.
        \\  --ignore <rule>       Ignore a rule (e.g., Z001). Can be repeated.
        \\  --zig-lib-path <path> Override the path to the Zig standard library.
        \\                        Auto-detected from 'zig env' if not specified.
        \\  --verbose             Show detailed timing and progress information.
        \\  -h, --help            Show this help message.
        \\  -v, --version         Show version.
        \\
        \\Directories are scanned recursively for .zig files.
        \\
    );
}

fn printVersion(writer: *std.Io.Writer) !void {
    try writer.writeAll("ziglint " ++ version ++ "\n");
}

test {
    _ = Linter;
    _ = ModuleGraph;
    _ = FileConfig;
    _ = @import("rules.zig");
    _ = @import("doc_comments.zig");
    _ = @import("TypeResolver.zig");
    _ = @import("doc_tests.zig");
}

test "parseLibDirFromZigEnv" {
    const output =
        \\.{
        \\    .zig_exe = "/usr/bin/zig",
        \\    .lib_dir = "/usr/lib/zig",
        \\    .std_dir = "/usr/lib/zig/std",
        \\}
    ;
    const result = parseLibDirFromZigEnv(std.testing.allocator, output);
    defer if (result) |r| std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("/usr/lib/zig", result.?);
}

test "parseLibDirFromZigEnv: missing field" {
    const output = ".{ .zig_exe = \"/usr/bin/zig\" }";
    try std.testing.expectEqual(null, parseLibDirFromZigEnv(std.testing.allocator, output));
}

test "applyOnlyRules enables selected rules" {
    var config: Config = .{
        .only_rules = &.{ .Z001, .Z033 },
    };

    applyOnlyRules(&config);

    try std.testing.expect(config.file_config.isRuleEnabled(.Z001));
    try std.testing.expect(config.file_config.isRuleEnabled(.Z033));
    try std.testing.expect(!config.file_config.isRuleEnabled(.Z002));
}

test "applyOnlyRules keeps ignore precedence" {
    var config: Config = .{
        .only_rules = &.{ .Z001, .Z002 },
        .ignored_rules = &.{.Z002},
    };

    applyOnlyRules(&config);

    try std.testing.expect(config.file_config.isRuleEnabled(.Z001));
    try std.testing.expect(!config.file_config.isRuleEnabled(.Z002));
    try std.testing.expect(!config.file_config.isRuleEnabled(.Z003));
}
