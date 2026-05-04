const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    const mod = b.addModule("syndiff", .{
        // The root source file is the "entry point" of this module. Users of
        // this module will only be able to access public declarations contained
        // in this file, which means that if you have declarations that you
        // intend to expose to consumers that were defined in other files part
        // of this module, you will have to make sure to re-export them from
        // the root file.
        .root_source_file = b.path("src/root.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
    });

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    const exe = b.addExecutable(.{
        .name = "syndiff",
        .root_module = b.createModule(.{
            // b.createModule defines a new module just like b.addModule but,
            // unlike b.addModule, it does not expose the module to consumers of
            // this package, which is why in this case we don't have to give it a name.
            .root_source_file = b.path("src/main.zig"),
            // Target and optimization levels must be explicitly wired in when
            // defining an executable or library (in the root module), and you
            // can also hardcode a specific target for an executable or library
            // definition if desireable (e.g. firmware for embedded devices).
            .target = target,
            .optimize = optimize,
            // List of modules available for import in source files part of the
            // root module.
            .imports = &.{
                // Here "syndiff" is the name you will use in your source code to
                // import this module (e.g. `@import("syndiff")`). The name is
                // repeated because you are allowed to rename your imports, which
                // can be extremely useful in case of collisions (which can happen
                // importing modules from different packages).
                .{ .name = "syndiff", .module = mod },
            },
        }),
    });

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

    // Benchmark binary. Uses ReleaseFast by default for honest numbers; can
    // be overridden via -Dbench-optimize=...
    const bench_optimize = b.option(
        std.builtin.OptimizeMode,
        "bench-optimize",
        "Optimize mode for `zig build bench` (default: ReleaseFast)",
    ) orelse .ReleaseFast;
    const bench_exe = b.addExecutable(.{
        .name = "syndiff-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = bench_optimize,
        }),
    });
    const bench_run = b.addRunArtifact(bench_exe);
    if (b.args) |args| bench_run.addArgs(args);
    const bench_step = b.step("bench", "Run microbenchmarks");
    bench_step.dependOn(&bench_run.step);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // Snapshot tests for `syndiff --review` NDJSON output. Compiles a third
    // test executable rooted at `tests/review_snapshots.zig`, which imports
    // the public `syndiff` module.
    const review_snap_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/review_snapshots.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "syndiff", .module = mod },
            },
        }),
    });
    const run_review_snap = b.addRunArtifact(review_snap_tests);

    // Golden regression tests for `--format json|yaml`. A separate test
    // executable rooted at `tests/golden_regression.zig`. Independent from
    // `review_snap_tests` so that golden assertions still run even if the
    // review snapshot harness is failing to compile (which it does by design
    // until Task 1.5 lands the `review` module).
    const golden_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/golden_regression.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "syndiff", .module = mod },
            },
        }),
    });
    const run_golden_tests = b.addRunArtifact(golden_tests);

    // Shared module for the vendored draft-07 validator. Referenced by both
    // the unit-test harness (`tests/schema_validator_unit.zig`) and the
    // integration walker (`tests/schema_validation.zig`).
    const schema_validator_mod = b.createModule(.{
        .root_source_file = b.path("src/schema_validator.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Schema integration tests: every line of every fixture is validated
    // against `schemas/review-v1.json` using the vendored draft-07 validator.
    const schema_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/schema_validation.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "schema_validator", .module = schema_validator_mod },
            },
        }),
    });
    const run_schema_tests = b.addRunArtifact(schema_tests);

    // Schema-validator unit tests. Imports `src/schema_validator.zig` as a
    // standalone module so the unit tests can exercise its primitives in
    // isolation (separate from the integration walker in
    // `tests/schema_validation.zig`).
    const schema_validator_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/schema_validator_unit.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "schema_validator", .module = schema_validator_mod },
            },
        }),
    });
    const run_schema_validator_tests = b.addRunArtifact(schema_validator_tests);

    // Multi-file Run integration tests for review-mode pipeline.
    const run_multi_file_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/run_multi_file.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "syndiff", .module = mod },
            },
        }),
    });
    const run_run_multi_file_tests = b.addRunArtifact(run_multi_file_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_review_snap.step);
    test_step.dependOn(&run_golden_tests.step);
    test_step.dependOn(&run_schema_tests.step);
    test_step.dependOn(&run_schema_validator_tests.step);
    test_step.dependOn(&run_run_multi_file_tests.step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}
