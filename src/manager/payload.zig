const build_options = @import("build_options");

/// 构建时编进来的静态 wslb-agent 新建发行版时推进去
pub const agent: []const u8 = @embedFile("agent_bin");

/// tools/build-netdistro.sh 的产物 构建时用 -Dnetdistro 指定 没指定则为空
pub const netdistro: []const u8 = if (build_options.has_netdistro) @embedFile("netdistro") else "";
