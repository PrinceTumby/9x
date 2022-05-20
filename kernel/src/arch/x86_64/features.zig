const root = @import("root");
const OverridenNamespace = root.zig_extensions.overriding_namespace.OverridenNamespace;
const feature_overrides = root.arch.build_options.feature_overrides;

pub var clocks = OverridenNamespace(struct {
    const constant_tsc: bool = false;
}, feature_overrides.clocks){};
