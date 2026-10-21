const std = @import("std");
const debug = std.debug;
const heap = std.heap;
const mem = std.mem;
const ResolvedTarget = std.Build.ResolvedTarget;
const LazyPath = std.Build.LazyPath;
const Query = std.Target.Query;
const builtin = @import("builtin");
const Translator = @import("translate_c").Translator;

fn getTarget(original_target: ResolvedTarget) ResolvedTarget {
    var tmp = original_target;

    if (tmp.result.isGnuLibC()) {
        const min_glibc_version = std.SemanticVersion{
            .major = 2,
            .minor = 28,
            .patch = 0,
        };
        const ver = tmp.result.os.version_range.linux.glibc;
        if (ver.order(min_glibc_version) == .lt) {
            std.debug.panic("sqlite requires glibc version >= 2.28", .{});
        }
    }

    return tmp;
}

const TestTarget = struct {
    query: Query,
    single_threaded: bool = false,
};

const ci_targets = switch (builtin.target.cpu.arch) {
    .x86_64 => switch (builtin.target.os.tag) {
        .linux => [_]TestTarget{
            TestTarget{ .query = .{ .cpu_arch = .x86_64, .abi = .musl } },
            TestTarget{ .query = .{ .cpu_arch = .x86, .abi = .musl } },
            TestTarget{ .query = .{ .cpu_arch = .aarch64, .abi = .musl } },
        },
        .windows => [_]TestTarget{
            TestTarget{ .query = .{ .cpu_arch = .x86_64, .abi = .gnu } },
            // Disabled due to https://github.com/ziglang/zig/issues/20047
            // TestTarget{ .query = .{ .cpu_arch = .x86, .abi = .gnu } },
        },
        .macos => [_]TestTarget{
            TestTarget{ .query = .{ .cpu_arch = .x86_64 } },
        },
        else => [_]TestTarget{},
    },
    else => [_]TestTarget{},
};

const all_test_targets = switch (builtin.target.cpu.arch) {
    .x86_64 => switch (builtin.target.os.tag) {
        .linux => [_]TestTarget{
            TestTarget{ .query = .{} },
            TestTarget{ .query = .{ .cpu_arch = .x86_64, .abi = .musl } },
            TestTarget{ .query = .{ .cpu_arch = .x86, .abi = .musl } },
            TestTarget{ .query = .{ .cpu_arch = .aarch64, .abi = .musl } },
            TestTarget{ .query = .{ .cpu_arch = .riscv64, .abi = .musl } },
            // Disabled because it fails for some unknown reason
            // TestTarget{ .query = .{ .cpu_arch = .mips, .abi = .musl } },
            TestTarget{ .query = .{ .cpu_arch = .x86_64, .os_tag = .windows } },
            // Disabled due to https://github.com/ziglang/zig/issues/20047
            // TestTarget{ .query = .{ .cpu_arch = .x86, .os_tag = .windows } },
            TestTarget{ .query = .{ .cpu_arch = .x86_64, .os_tag = .macos } },
            TestTarget{ .query = .{ .cpu_arch = .aarch64, .os_tag = .macos } },
        },
        .windows => [_]TestTarget{
            TestTarget{ .query = .{ .cpu_arch = .x86_64, .abi = .gnu } },
            // Disabled due to https://github.com/ziglang/zig/issues/20047
            // TestTarget{ .query = .{ .cpu_arch = .x86, .abi = .gnu } },
        },
        .freebsd => [_]TestTarget{
            TestTarget{ .query = .{} },
            TestTarget{ .query = .{ .cpu_arch = .x86_64 } },
        },
        .macos => [_]TestTarget{
            TestTarget{ .query = .{ .cpu_arch = .x86_64 } },
        },
        else => [_]TestTarget{
            TestTarget{ .query = .{} },
        },
    },
    .aarch64 => switch (builtin.target.os.tag) {
        .linux, .windows, .freebsd, .macos => [_]TestTarget{
            TestTarget{ .query = .{} },
        },
        else => [_]TestTarget{
            TestTarget{ .query = .{} },
        },
    },
    else => [_]TestTarget{
        TestTarget{ .query = .{} },
    },
};

fn computeTestTargets(isNative: bool, ci: ?bool) ?[]const TestTarget {
    if (ci != null and ci.?) return &ci_targets;

    if (isNative) {
        // If the target is native we assume the user didn't change it with -Dtarget and run all test targets.
        return &all_test_targets;
    }

    // Otherwise we run a single test target.
    return null;
}

/// The name of the `sqlite_config` header in `config_dir`.
const config_header = "zig_sqlite_config.h";

/// The C API, translated with the translate-c package from sqlite3.h in
/// `include` and c/workaround.h. With a `config_dir`, its config header is
/// included first, so the bindings see the compile-time options the library
/// was built with (SQLITE_OMIT_DEPRECATED, for one, removes declarations).
fn translateSQLite(b: *std.Build, include: LazyPath, config_dir: ?LazyPath, target: ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const header = b.addWriteFiles().add("sqlite3_c.h", if (config_dir != null)
        "#include \"" ++ config_header ++ "\"\n#include \"sqlite3.h\"\n#include \"workaround.h\"\n"
    else
        "#include \"sqlite3.h\"\n#include \"workaround.h\"\n");

    const t: Translator = .init(b.dependency("translate_c", .{}), .{
        .name = "sqlite3_c",
        .c_source_file = header,
        .target = target,
        .optimize = optimize,
        // Struct fields default to zero, as with @cImport, so struct literals such as
        // vtab.zig's sqlite3_module compile against every SQLite version.
        .default_init = true,
    });
    if (config_dir) |dir| t.addIncludePath(dir);
    t.addIncludePath(include);
    t.addIncludePath(b.path("c"));

    return t.mod;
}

/// A static library with c/workaround.c, plus SQLite itself when `sqlite_src`
/// (the amalgamation's directory) is given, built with the config header in
/// `config_dir` as its SQLITE_CUSTOM_INCLUDE.
fn makeSQLiteLib(b: *std.Build, sqlite_src: ?LazyPath, config_dir: ?LazyPath, c_flags: []const []const u8, target: ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = if (sqlite_src != null) "sqlite" else "zig-sqlite-workaround",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    lib.root_module.addIncludePath(b.path("c"));
    if (sqlite_src) |src| {
        lib.root_module.addIncludePath(src);
        var src_flags: []const []const u8 = c_flags;
        if (config_dir) |dir| {
            lib.root_module.addIncludePath(dir);
            src_flags = std.mem.concat(b.allocator, []const u8, &.{ c_flags, &.{"-DSQLITE_CUSTOM_INCLUDE=" ++ config_header} }) catch @panic("OOM");
        }
        lib.root_module.addCSourceFile(.{
            .file = src.path(b, "sqlite3.c"),
            .flags = src_flags,
        });
    }
    lib.root_module.addCSourceFile(.{
        .file = b.path("c/workaround.c"),
        .flags = c_flags,
    });

    return lib;
}

/// Gives `mod` (rooted at sqlite.zig) its C API: the `sqlite3_c` import and
/// the library with SQLite (or, for a caller's SQLite, only c/workaround.c).
fn addCApi(b: *std.Build, mod: *std.Build.Module, include: LazyPath, config_dir: ?LazyPath, lib: *std.Build.Step.Compile, target: ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    mod.addImport("sqlite3_c", translateSQLite(b, include, config_dir, target, optimize));
    mod.linkLibrary(lib);
}

pub fn build(b: *std.Build) !void {
    const in_memory = b.option(bool, "in_memory", "Should the tests run with sqlite in memory (default true)") orelse true;
    const dbfile = b.option([]const u8, "dbfile", "Always use this database file instead of a temporary one");
    const ci = b.option(bool, "ci", "Build and test in the CI on GitHub");

    // SQLite from the caller. With `sqlite_include`, this package fetches and
    // compiles no SQLite: the `sqlite` module gets bindings of the caller's
    // sqlite3.h, and the caller links its own SQLite library to it
    // (`dep.module("sqlite").linkLibrary(lib)`).
    const sqlite_include = b.option(LazyPath, "sqlite_include", "Directory with the sqlite3.h of a SQLite the caller compiles and links itself");
    // A header with SQLite's compile-time options (#define SQLITE_...): it is
    // included before sqlite3.h in the bindings and, with the bundled SQLite,
    // compiled in as SQLITE_CUSTOM_INCLUDE.
    const sqlite_config = b.option(LazyPath, "sqlite_config", "Header with SQLite's compile-time options, for the bindings and the bundled SQLite");
    const config_dir: ?LazyPath = if (sqlite_config) |path| blk: {
        const wf = b.addWriteFiles();
        _ = wf.addCopyFile(path, config_header);
        break :blk wf.getDirectory();
    } else null;

    const query = b.standardTargetOptionsQueryOnly(.{});
    const target = b.resolveTargetQuery(query);
    const optimize = b.standardOptimizeOption(.{});

    // Define C flags to use

    var flags: std.ArrayList([]const u8) = .empty;
    defer flags.deinit(b.allocator);
    try flags.append(b.allocator, "-std=c99");

    const enable_info = @typeInfo(EnableOptions).@"struct";
    inline for (enable_info.field_names, enable_info.field_attrs) |field_name, field_attrs| {
        const opt = b.option(bool, field_name, "Enable " ++ field_name) orelse field_attrs.defaultValue(bool).?;

        if (opt) {
            var buf: [field_name.len]u8 = undefined;
            const name = std.ascii.upperString(&buf, field_name);
            const flag = try std.fmt.allocPrint(b.allocator, "-DSQLITE_ENABLE_{s}", .{name});

            try flags.append(b.allocator, flag);
        }
    }

    inline for (@typeInfo(BoolFeatureOptions).@"enum".field_names) |field_name| {
        comptime var buf: [field_name.len]u8 = undefined;
        const name = comptime std.ascii.upperString(&buf, field_name);
        const opt = b.option(bool, field_name, "Set SQLITE_" ++ name);

        if (opt) |v| {
            const flag_value = if (v) "1" else "0";
            const flag = try std.fmt.allocPrint(b.allocator, "-DSQLITE_" ++ name ++ "={s}", .{flag_value});

            try flags.append(b.allocator, flag);
        }
    }

    inline for (@typeInfo(DefineFeatureOptions).@"enum".field_names) |field_name| {
        comptime var buf: [field_name.len]u8 = undefined;
        const name = comptime std.ascii.upperString(&buf, field_name);
        const opt = b.option(bool, field_name, "Set SQLITE_" ++ name) orelse false;

        if (opt) {
            const flag = try std.fmt.allocPrint(b.allocator, "-DSQLITE_" ++ name, .{});

            try flags.append(b.allocator, flag);
        }
    }

    const int_info = @typeInfo(IntFeatureOptions).@"struct";
    inline for (int_info.field_names, int_info.field_types) |field_name, field_type| {
        comptime var buf: [field_name.len]u8 = undefined;
        const name = comptime std.ascii.upperString(&buf, field_name);
        const opt = b.option(field_type, field_name, "Set SQLITE_" ++ name);

        if (opt) |v| {
            const flag = try std.fmt.allocPrint(b.allocator, "-DSQLITE_" ++ name ++ "={}", .{v});

            try flags.append(b.allocator, flag);
        }
    }

    const c_flags = flags.items;

    //
    // Main module, on the caller's SQLite
    //

    if (sqlite_include) |include| {
        const mod = b.addModule("sqlite", .{
            .root_source_file = b.path("sqlite.zig"),
            .link_libc = true,
        });
        addCApi(b, mod, include, config_dir, makeSQLiteLib(b, null, null, c_flags, target, optimize), target, optimize);
        return;
    }

    //
    // Main library and module, on the bundled SQLite (a lazy dependency)
    //

    const sqlite_dep = b.lazyDependency("sqlite", .{}) orelse return;
    const sqlite_src = sqlite_dep.path(".");

    const sqlite_lib = makeSQLiteLib(b, sqlite_src, config_dir, c_flags, target, optimize);
    {
        const mod = b.addModule("sqlite", .{
            .root_source_file = b.path("sqlite.zig"),
            .link_libc = true,
        });
        addCApi(b, mod, sqlite_src, config_dir, sqlite_lib, target, optimize);
    }
    b.installArtifact(sqlite_lib);

    //
    // Tests
    //

    const test_targets = computeTestTargets(query.isNative(), ci) orelse &[_]TestTarget{.{
        .query = query,
    }};
    const test_step = b.step("test", "Run library tests");

    // By default the tests will only be execute for native test targets, however they will be compiled
    // for _all_ targets defined in `test_targets`.
    //
    // If you want to execute tests for other targets you can pass -fqemu, -fdarling, -fwine, -frosetta.

    for (test_targets) |test_target| {
        const cross_target = getTarget(b.resolveTargetQuery(test_target.query));
        const single_threaded_txt = if (test_target.single_threaded) "single" else "multi";
        const test_name = b.fmt("{s}-{s}-{s}", .{
            try cross_target.result.zigTriple(b.allocator),
            @tagName(optimize),
            single_threaded_txt,
        });

        const test_sqlite_lib = makeSQLiteLib(b, sqlite_src, config_dir, c_flags, cross_target, optimize);

        const mod = b.createModule(.{
            .target = cross_target,
            .optimize = optimize,
            .root_source_file = b.path("sqlite.zig"),
            .single_threaded = test_target.single_threaded,
        });
        addCApi(b, mod, sqlite_src, config_dir, test_sqlite_lib, cross_target, optimize);

        const tests = b.addTest(.{
            .name = test_name,
            .root_module = mod,
        });

        const tests_options = b.addOptions();
        tests.root_module.addImport("build_options", tests_options.createModule());

        tests_options.addOption(bool, "in_memory", in_memory);
        tests_options.addOption(?[]const u8, "dbfile", dbfile);

        const run_tests = b.addRunArtifact(tests);
        test_step.dependOn(&run_tests.step);
    }
}

// See https://www.sqlite.org/compile.html for flags
const EnableOptions = struct {
    api_armor: bool = false,
    atomic_write: bool = false,
    batch_atomic_write: bool = false,
    carray: bool = false,
    column_metadata: bool = false,
    dbpage_vtab: bool = false,
    dbstat_vtab: bool = false,
    explain_comments: bool = false,
    // https://www.sqlite.org/fts5.html
    fts5: bool = false,
    geopoly: bool = false,
    hidden_columns: bool = false,
    icu: bool = false,
    math_functions: bool = false,
    memsys3: bool = false,
    memsys5: bool = false,
    null_trim: bool = false,
    offset_sql_func: bool = false,
    percentile: bool = false,
    preupdate_hook: bool = false,
    RBU: bool = false,
    rtree: bool = false,
    session: bool = false,
    sorter_reference: bool = false,
    stmtvtab: bool = false,
    stat4: bool = false,
};

/// `false` = won't be defined
/// `true` = will be defined
const DefineFeatureOptions = enum {
    like_doesnt_match_blobs,
    omit_decltype,
    omit_deprecated,
    omit_progress_callback,
    omit_shared_cache,
    omit_autoinit,
    use_alloca,
    zero_malloc,
    debug,
    memdebug,
    win32_malloc,
    win32_heap_create,
    win32_malloc_validate,
};

/// - `null` = default
/// - `true` = `1`
/// - `false` = `0`
const BoolFeatureOptions = enum {
    default_memstatus,
    strict_subtype,
    os_other,
};

/// The compile-time options with an int argument.
const IntFeatureOptions = struct {
    DQS: std.math.IntFittingRange(0, 3),
    threadsafe: std.math.IntFittingRange(0, 2),
    default_wal_synchronous: std.math.IntFittingRange(0, 3),
    max_expr_depth: c_int,
};
