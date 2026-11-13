const build_info = @import("build_info");

pub const number = "0.1.0";
pub const commit = build_info.commit;
pub const version = build_info.version;
pub const protocol_version: u32 = 1;
pub const user_agent = "hampaneld/" ++ version;
pub const default_client_cn_prefix = "hampanel-client";
