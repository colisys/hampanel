const std = @import("std");

pub const SystemInfo = struct {
    hostname: []const u8,
    os: []const u8,
    kernel: []const u8,
    arch: []const u8,
    cpu_model: []const u8,
    cores: usize,
    uptime_seconds: u64,
};

pub const CpuMetrics = struct {
    usage_percent: f64,
    cores: u32,
    load1: f64,
    load5: f64,
    load15: f64,
};

pub const MemoryMetrics = struct {
    total_bytes: u64,
    available_bytes: u64,
    used_bytes: u64,
    percent: f64,
    swap_total_bytes: u64,
    swap_used_bytes: u64,
};

pub const DiskMetrics = struct {
    mount: []const u8,
    filesystem: []const u8,
    total_bytes: u64,
    used_bytes: u64,
    available_bytes: u64,
    percent: f64,
};

pub const NetworkMetrics = struct {
    rx_bytes: u64,
    tx_bytes: u64,
    rx_rate_bps: f64,
    tx_rate_bps: f64,
};

pub const Metrics = struct {
    cpu: CpuMetrics,
    memory: MemoryMetrics,
    uptime_seconds: u64,
    disks: []DiskMetrics,
    network: NetworkMetrics,
};

pub const ProcessInfo = struct {
    pid: u32,
    ppid: u32,
    name: []const u8,
    state: []const u8,
    rss_bytes: u64,
    cpu_ticks: u64,
    command: []const u8,
};

pub const ProcessList = struct {
    total: usize,
    processes: []const ProcessInfo,
};

pub const ServiceInfo = struct {
    unit: []const u8,
    load: []const u8,
    active: []const u8,
    sub: []const u8,
    description: []const u8,
};

pub const Outcome = struct {
    ok: bool = true,
    output: []const u8 = "",
};

pub const SiteInfo = struct {
    name: []const u8,
    path: []const u8,
    enabled: bool,
    domains: []const []const u8,
    root: []const u8,
    listen: []const u8,
};

pub const SiteList = struct {
    available: bool,
    dir: []const u8,
    sites: []const SiteInfo,
};

pub const SiteRequest = struct {
    name: []const u8,
    domains: []const []const u8,
    root: []const u8,
    port: u16,
};

pub const FirewallRule = struct {
    id: []const u8,
    to: []const u8,
    action: []const u8,
    from: []const u8,
    raw: []const u8,
};

pub const FirewallStatus = struct {
    available: bool,
    active: bool,
    rules: []const FirewallRule,
    output: []const u8 = "",
};

pub const CronEntry = struct {
    id: []const u8,
    schedule: []const u8,
    command: []const u8,
    line: []const u8,
    kind: []const u8 = "user",
};

pub const LogSource = struct {
    id: []const u8,
    label: []const u8,
    path: []const u8,
    available: bool,
};

pub const UnsupportedError = error{Unsupported};

pub fn unsupported() UnsupportedError {
    return error.Unsupported;
}
