"""A stand-in for the framework import rules in rules_apple.

Those rules hand the compile action a framework search path through the
`framework_includes` field of a `CcInfo` compilation context, which the
toolchain turns into `-F`, and cover the framework's headers with a module
map so `layering_check` can see them -- a check that is module maps all the
way down treats an unmapped framework header as a layering violation.
Recreating both here keeps the test from depending on rules_apple.
"""

load("@rules_cc//cc:defs.bzl", "cc_library")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")

def _fake_framework_rule_impl(ctx):
    framework = CcInfo(
        compilation_context = cc_common.create_compilation_context(
            headers = depset(ctx.files.hdrs),
            framework_includes = depset([ctx.label.package]),
        ),
    )

    # The module map covering `hdrs` rides along inside the wrapped
    # cc_library's compilation context. It has to be merged as a *direct*
    # CcInfo: only an exporting merge re-exports the dep's module map to
    # whoever depends on this target, which is what `layering_check` walks.
    return [cc_common.merge_cc_infos(
        direct_cc_infos = [framework] + [dep[CcInfo] for dep in ctx.attr.deps],
    )]

_fake_framework = rule(
    implementation = _fake_framework_rule_impl,
    attrs = {
        "hdrs": attr.label_list(allow_files = True),
        "deps": attr.label_list(providers = [CcInfo]),
    },
    doc = "Exposes `hdrs` through a framework search path, like an imported framework.",
)

def fake_framework(name, hdrs):
    """An imported framework: a search path for `-F`, plus a module map.

    Args:
        name: Name of the resulting target.
        hdrs: Header files under `<name>.framework/Headers`.
    """
    cc_library(
        name = name + "_module",
        hdrs = hdrs,
    )
    _fake_framework(
        name = name,
        hdrs = hdrs,
        deps = [":" + name + "_module"],
    )
