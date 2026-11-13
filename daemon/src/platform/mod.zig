const builtin = @import("builtin");

pub const types = @import("shared").types;
pub const is_windows = builtin.os.tag == .windows;
pub const is_linux = builtin.os.tag == .linux;

pub const backend = @import("platform_backend");

pub const files = backend.files;
pub const system = backend.system;
pub const metrics = backend.metrics;
pub const processes = backend.processes;
pub const services = backend.services;
pub const sites = backend.sites;
pub const firewall = backend.firewall;
pub const cron = backend.cron;
pub const logs = backend.logs;
pub const packages = backend.packages;
pub const nix = backend.nix;
pub const ssh = backend.ssh;
pub const software = backend.software;
pub const fail2ban = backend.fail2ban;
pub const waf = backend.waf;
pub const terminal = backend.terminal;

pub const MetricsState = backend.metrics.State;
pub const Terminal = backend.terminal.Terminal;

pub fn spawnTerminal(cols: u16, rows: u16) !Terminal {
    return backend.terminal.spawn(cols, rows);
}
