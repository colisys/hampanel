const std = @import("std");
const backend = @import("backend.zig");
const service = @import("windows_service");

comptime {
    _ = &backend.files.resolve;
    _ = &backend.files.stat;
    _ = &backend.files.secureDir;
    _ = &backend.files.secureFile;

    _ = &backend.system.info;

    _ = &backend.metrics.sample;

    _ = &backend.processes.list;

    _ = &backend.services.list;
    _ = &backend.services.action;
    _ = &backend.services.logs;

    _ = &backend.sites.list;
    _ = &backend.sites.create;
    _ = &backend.sites.toggle;
    _ = &backend.sites.destroy;
    _ = &backend.sites.reload;

    _ = &backend.firewall.status;
    _ = &backend.firewall.add;
    _ = &backend.firewall.remove;

    _ = &backend.cron.list;
    _ = &backend.cron.add;
    _ = &backend.cron.remove;

    _ = &backend.logs.sources;

    _ = &backend.terminal.spawn;
    _ = &backend.terminal.Terminal.read;
    _ = &backend.terminal.Terminal.writeAll;
    _ = &backend.terminal.Terminal.resize;
    _ = &backend.terminal.Terminal.close;

    _ = &backend.packages.list;
    _ = &backend.packages.install;
    _ = &backend.packages.refresh;

    _ = &backend.nix.status;
    _ = &backend.nix.build;
    _ = &backend.nix.run;

    _ = &backend.ssh.status;
    _ = &backend.ssh.apply;
    _ = &backend.ssh.listKeys;
    _ = &backend.ssh.addKey;
    _ = &backend.ssh.removeKey;
    _ = &backend.ssh.loggingStatus;
    _ = &backend.ssh.setLogging;
    _ = &backend.ssh.logs;

    _ = &backend.software.list;
    _ = &backend.software.initialize;

    _ = &backend.fail2ban.status;
    _ = &backend.fail2ban.initialize;
    _ = &backend.fail2ban.ban;
    _ = &backend.fail2ban.unban;
    _ = &backend.fail2ban.setLimits;

    _ = &backend.waf.status;
    _ = &backend.waf.install;
    _ = &backend.waf.configure;
    _ = &backend.waf.start;
    _ = &backend.waf.stop;
    _ = &backend.waf.logs;

    _ = &backend.security.scanStatus;
    _ = &backend.security.installScan;
    _ = &backend.security.startScan;
    _ = &backend.security.stopScan;
    _ = &backend.security.ingest;
    _ = &backend.security.unban;
    _ = &backend.hardening.status;
    _ = &backend.hardening.pruneDangling;
    _ = &backend.hardening.setUmask;
    _ = &backend.hardening.restrictScheduler;
    _ = &backend.hardening.hardenSudo;
    _ = &backend.hardening.setKernel;
    _ = &backend.selinux.status;
    _ = &backend.selinux.setMode;
    _ = &backend.selinux.setBoolean;
    _ = &backend.tamper.status;
    _ = &backend.tamper.protect;
    _ = &backend.tamper.unprotect;

    _ = &service.run;
}
