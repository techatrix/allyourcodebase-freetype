const std = @import("std");

pub fn build(b: *std.Build) !void {
    const upstream = b.dependency("freetype", .{});
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const linkage = b.option(std.builtin.LinkMode, "linkage", "Link mode") orelse .static;
    const strip = b.option(bool, "strip", "Omit debug information");
    const pic = b.option(bool, "pic", "Produce Position Independent Code");

    const zlib = b.option(bool, "zlib", "Support reading gzip-compressed font files") orelse true;
    const bzip2 = b.option(bool, "bzip2", "Support reading bzip2-compressed font files") orelse false;
    const png = b.option(bool, "png", "Support color bitmap glyph formats in the PNG format") orelse false;
    const harfbuzz = b.option(enum { true, false, dynamic }, "harfbuzz", "Use Harfbuzz library to improve auto-hinting") orelse .false;
    const brotli = b.option(bool, "brotli", "Use Brotli library to support decompressing WOFF2 fonts") orelse false;

    const mmap = b.option(bool, "mmap", "Use mmap() to open font files for faster parsing");
    const error_strings = b.option(bool, "error-strings", "Enable support for meaningful error descriptions") orelse false;

    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .pic = pic,
        .link_libc = true,
        .sanitize_c = .off, // why is this needed?
    });
    mod.addIncludePath(upstream.path("include"));
    mod.addCMacro("FT2_BUILD_LIBRARY", "1");
    if (target.result.os.tag == .windows and linkage == .dynamic) mod.addCMacro("DLL_EXPORT", "1");

    const process_ftoption_h = b.addExecutable(.{
        .name = "process-ftoption-h",
        .root_module = b.createModule(.{
            .root_source_file = b.path("process_ftoption_h.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            .single_threaded = true,
        }),
    });

    const ftoption_command = b.addRunArtifact(process_ftoption_h);
    ftoption_command.addFileArg(upstream.path("include/freetype/config/ftoption.h"));
    const ftoption_h = ftoption_command.addPrefixedOutputFileArg("--output=", "ftoption.h");
    if (error_strings) ftoption_command.addArg("--enable=FT_CONFIG_OPTION_ERROR_STRINGS");
    mod.addIncludePath(ftoption_h.dirname());
    mod.addCMacro("FT_CONFIG_OPTIONS_H", "<ftoption.h>");

    const flags: []const []const u8 = &.{
        "-fvisibility=hidden",
    };

    if (zlib) {
        ftoption_command.addArg("--enable=FT_CONFIG_OPTION_USE_ZLIB");
        if (b.systemIntegrationOption("zlib", .{})) {
            mod.linkSystemLibrary("z", .{});
            ftoption_command.addArg("--enable=FT_CONFIG_OPTION_SYSTEM_ZLIB");
        } else if (b.lazyDependency("zlib", .{
            .target = target,
            .optimize = optimize,
        })) |zlib_dependency| {
            mod.linkLibrary(zlib_dependency.artifact("z"));
        }
    } else {
        ftoption_command.addArg("--disable=FT_CONFIG_OPTION_USE_ZLIB");
    }

    if (bzip2) {
        ftoption_command.addArg("--enable=FT_CONFIG_OPTION_USE_BZIP2");
        if (b.systemIntegrationOption("bzip2", .{})) {
            mod.linkSystemLibrary("bz2", .{});
        } else if (b.lazyDependency("bzip2", .{
            .target = target,
            .optimize = optimize,
        })) |bzip2_dependency| {
            mod.linkLibrary(bzip2_dependency.artifact("bz"));
        }
        mod.addCSourceFile(.{
            .file = upstream.path("src/bzip2/ftbzip2.c"),
            .flags = flags,
        });
    }

    if (png) {
        ftoption_command.addArg("--enable=FT_CONFIG_OPTION_USE_PNG");
        if (b.systemIntegrationOption("libpng", .{})) {
            mod.linkSystemLibrary("png", .{});
        } else if (b.lazyDependency("libpng", .{
            .target = target,
            .optimize = optimize,
        })) |libpng_dependency| {
            mod.linkLibrary(libpng_dependency.artifact("png"));
        }
    }

    switch (harfbuzz) {
        .false => {},
        .true => {
            ftoption_command.addArg("--enable=FT_CONFIG_OPTION_USE_HARFBUZZ");
            if (b.systemIntegrationOption("harfbuzz", .{})) {
                mod.linkSystemLibrary("harfbuzz", .{});
            } else if (b.lazyDependency("harfbuzz", .{
                .target = target,
                .optimize = optimize,
                .@"enable-freetype" = false,
            })) |harfbuzz_dependency| {
                mod.linkLibrary(harfbuzz_dependency.artifact("harfbuzz"));
            }
        },
        .dynamic => {
            if (target.result.os.tag != .windows) {
                mod.linkSystemLibrary("dl", .{});
            }
            ftoption_command.addArg("--enable=FT_CONFIG_OPTION_USE_HARFBUZZ");
            ftoption_command.addArg("--enable=FT_CONFIG_OPTION_USE_HARFBUZZ_DYNAMIC");
        },
    }

    if (brotli) {
        ftoption_command.addArg("--enable=FT_CONFIG_OPTION_USE_BROTLI");
        if (b.systemIntegrationOption("brotli", .{})) {
            mod.linkSystemLibrary("brotlidec", .{});
        } else {
            const msg = "TODO: Port brotli to the zig build system. Consider using '-fsys=brotli' to link against a system provided library";
            @panic(msg);
        }
    }

    mod.addCSourceFiles(.{
        .root = upstream.path("src"),
        .files = sources,
        .flags = flags,
    });

    const ftsystem_c, const use_unix_ftsystem_c = blk: {
        if (mmap == false) {
            break :blk .{ upstream.path("src/base/ftsystem.c"), false };
        } else if (target.result.os.tag == .windows) {
            break :blk .{ upstream.path("builds/windows/ftsystem.c"), false };
        } else {
            const have_mmap = target.result.os.tag != .windows; // unistd.h, fcntl.h, sys/mman.h
            if (have_mmap) {
                break :blk .{ upstream.path("builds/unix/ftsystem.c"), true };
            } else if (mmap == true) {
                std.process.fatal("mmap was enabled via options but is not available required headers were not found!", .{});
            } else {
                break :blk .{ upstream.path("src/base/ftsystem.c"), false };
            }
        }
    };

    mod.addCSourceFile(.{
        .file = ftsystem_c,
        .flags = flags,
    });
    if (target.result.os.tag == .windows) {
        mod.addCSourceFile(.{
            .file = upstream.path("builds/windows/ftdebug.c"),
            .flags = flags,
        });
        mod.addWin32ResourceFile(.{
            .file = upstream.path("src/base/ftver.rc"),
            .flags = &.{},
        });
    } else {
        mod.addCSourceFile(.{
            .file = upstream.path("src/base/ftdebug.c"),
            .flags = flags,
        });
    }

    const lib = b.addLibrary(.{
        .name = "freetype",
        .linkage = linkage,
        .root_module = mod,
    });
    b.installArtifact(lib);
    lib.installHeader(ftoption_h, "freetype/config/ftoption.h");

    if (use_unix_ftsystem_c) {
        const ftconfig_command = b.addRunArtifact(process_ftoption_h);
        ftconfig_command.addFileArg(upstream.path("builds/unix/ftconfig.h.in"));
        const ftconfig_h = ftconfig_command.addPrefixedOutputFileArg("--output=", "ftconfig.h");
        ftconfig_command.addArg("--enable=HAVE_UNISTD_H"); // standard posix header
        ftconfig_command.addArg("--enable=HAVE_FCNTL_H"); // standard posix header
        mod.addIncludePath(ftconfig_h.dirname());
        mod.addCMacro("FT_CONFIG_CONFIG_H", "<ftconfig.h>");

        lib.installHeader(ftconfig_h, "freetype/config/ftconfig.h");
    } else {
        lib.installHeader(upstream.path("include/freetype/config/ftconfig.h"), "freetype/config/ftconfig.h");
    }

    for (&[_][]const u8{
        "ft2build.h",
        "freetype/freetype.h",
        "freetype/ftadvanc.h",
        "freetype/ftbbox.h",
        "freetype/ftbdf.h",
        "freetype/ftbitmap.h",
        "freetype/ftbzip2.h",
        "freetype/ftcache.h",
        "freetype/ftchapters.h",
        "freetype/ftcid.h",
        "freetype/ftcolor.h",
        "freetype/ftdriver.h",
        "freetype/fterrdef.h",
        "freetype/fterrors.h",
        "freetype/ftfntfmt.h",
        "freetype/ftgasp.h",
        "freetype/ftglyph.h",
        "freetype/ftgxval.h",
        "freetype/ftgzip.h",
        "freetype/ftimage.h",
        "freetype/ftincrem.h",
        "freetype/ftlcdfil.h",
        "freetype/ftlist.h",
        "freetype/ftlogging.h",
        "freetype/ftlzw.h",
        "freetype/ftmac.h",
        "freetype/ftmm.h",
        "freetype/ftmodapi.h",
        "freetype/ftmoderr.h",
        "freetype/ftotval.h",
        "freetype/ftoutln.h",
        "freetype/ftparams.h",
        "freetype/ftpfr.h",
        "freetype/ftrender.h",
        "freetype/ftsizes.h",
        "freetype/ftsnames.h",
        "freetype/ftstroke.h",
        "freetype/ftsynth.h",
        "freetype/ftsystem.h",
        "freetype/fttrigon.h",
        "freetype/fttypes.h",
        "freetype/ftwinfnt.h",
        "freetype/otsvg.h",
        "freetype/t1tables.h",
        "freetype/ttnameid.h",
        "freetype/tttables.h",
        "freetype/tttags.h",
        "freetype/config/ftheader.h",
        "freetype/config/ftstdlib.h",
        "freetype/config/integer-types.h",
        "freetype/config/mac-support.h",
        "freetype/config/public-macros.h",
        "freetype/config/ftmodule.h", // TODO
    }) |path| {
        lib.installHeader(upstream.path(b.fmt("include/{s}", .{path})), path);
    }
}

const sources: []const []const u8 = &.{
    "base/ftbase.c",
    "base/ftinit.c",

    // python builds/meson/parse_modules_cfg.py --format=base-extensions-list modules.cfg
    "base/ftbbox.c",
    "base/ftbdf.c",
    "base/ftbitmap.c",
    "base/ftcid.c",
    "base/ftfstype.c",
    "base/ftgasp.c",
    "base/ftglyph.c",
    "base/ftgxval.c",
    "base/ftmm.c",
    "base/ftotval.c",
    "base/ftpatent.c",
    "base/ftpfr.c",
    "base/ftstroke.c",
    "base/ftsynth.c",
    "base/fttype1.c",
    "base/ftwinfnt.c",

    // python builds/meson/parse_modules_cfg.py --format=main-modules modules.cfg
    "truetype/truetype.c",
    "type1/type1.c",
    "cff/cff.c",
    "cid/type1cid.c",
    "pfr/pfr.c",
    "type42/type42.c",
    "winfonts/winfnt.c",
    "pcf/pcf.c",
    "bdf/bdf.c",
    "sfnt/sfnt.c",
    "autofit/autofit.c",
    "pshinter/pshinter.c",
    "smooth/smooth.c",
    "raster/raster.c",
    "svg/svg.c",
    "sdf/sdf.c",

    // python builds/meson/parse_modules_cfg.py --format=aux-modules modules.cfg
    "cache/ftcache.c",
    "gzip/ftgzip.c",
    "lzw/ftlzw.c",
    "psaux/psaux.c",
    "psnames/psnames.c",
};
