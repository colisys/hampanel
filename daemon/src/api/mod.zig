const std = @import("std");
const router = @import("../http/router.zig");
const request = @import("../http/request.zig");

const health = @import("health.zig");
const system = @import("system.zig");
const metrics = @import("metrics.zig");
const processes = @import("processes.zig");
const files = @import("files.zig");
const terminal = @import("terminal.zig");
const services = @import("services.zig");
const sites = @import("sites.zig");
const docker = @import("docker.zig");
const docker_jobs = @import("docker_jobs.zig");
const docker_terminal = @import("docker_terminal.zig");
const docker_files = @import("docker_files.zig");
const docker_compose = @import("docker_compose.zig");
const docker_images = @import("docker_images.zig");
const docker_registries = @import("docker_registries.zig");
const docker_networks = @import("docker_networks.zig");
const docker_volumes = @import("docker_volumes.zig");
const firewall = @import("firewall.zig");
const cron = @import("cron.zig");
const logs = @import("logs.zig");
const store = @import("store.zig");
const ssh = @import("ssh.zig");
const software = @import("software.zig");
const recycle = @import("recycle.zig");
const versions = @import("versions.zig");
const waf = @import("waf.zig");
const update = @import("update.zig");
const notifications = @import("notifications.zig");
const runtimes = @import("runtimes.zig");
const host = @import("host.zig");

pub const routes = [_]router.Route{
    .{ .method = .GET, .pattern = "/api/v1/health", .handler = health.index },

    .{ .method = .GET, .pattern = "/api/v1/update", .handler = update.index },
    .{ .method = .POST, .pattern = "/api/v1/update/check", .handler = update.check },
    .{ .method = .PUT, .pattern = "/api/v1/update/config", .handler = update.configure },
    .{ .method = .POST, .pattern = "/api/v1/update/apply", .handler = update.apply },
    .{ .method = .POST, .pattern = "/api/v1/update/schedule", .handler = update.schedule },
    .{ .method = .DELETE, .pattern = "/api/v1/update/schedule", .handler = update.unschedule },
    .{ .method = .GET, .pattern = "/api/v1/notifications", .handler = notifications.index },
    .{ .method = .PUT, .pattern = "/api/v1/notifications", .handler = notifications.update },
    .{ .method = .POST, .pattern = "/api/v1/notifications/test", .handler = notifications.testSend },

    .{ .method = .GET, .pattern = "/api/v1/runtimes", .handler = runtimes.index },
    .{ .method = .POST, .pattern = "/api/v1/runtimes", .handler = runtimes.create },
    .{ .method = .GET, .pattern = "/api/v1/runtimes/catalog", .handler = runtimes.catalogIndex },
    .{ .method = .GET, .pattern = "/api/v1/runtimes/catalog/:runtime/tags", .handler = runtimes.tags },
    .{ .method = .GET, .pattern = "/api/v1/runtimes/:id/logs", .handler = runtimes.logs },
    .{ .method = .GET, .pattern = "/api/v1/runtimes/:id/config", .handler = runtimes.configIndex },
    .{ .method = .PUT, .pattern = "/api/v1/runtimes/:id/config", .handler = runtimes.configSave },
    .{ .method = .GET, .pattern = "/api/v1/runtimes/:id/extensions", .handler = runtimes.extensionsIndex },
    .{ .method = .PUT, .pattern = "/api/v1/runtimes/:id/extensions", .handler = runtimes.extensionsSave },
    .{ .method = .GET, .pattern = "/api/v1/runtimes/:id/processes", .handler = runtimes.processesIndex },
    .{ .method = .POST, .pattern = "/api/v1/runtimes/:id/processes/:name/:action", .handler = runtimes.processAction },
    .{ .method = .POST, .pattern = "/api/v1/runtimes/:id/start", .handler = runtimes.start },
    .{ .method = .POST, .pattern = "/api/v1/runtimes/:id/stop", .handler = runtimes.stop },
    .{ .method = .POST, .pattern = "/api/v1/runtimes/:id/restart", .handler = runtimes.restart },
    .{ .method = .POST, .pattern = "/api/v1/runtimes/:id/rebuild", .handler = runtimes.rebuild },
    .{ .method = .DELETE, .pattern = "/api/v1/runtimes/:id", .handler = runtimes.remove },
    .{ .method = .GET, .pattern = "/api/v1/docker/settings", .handler = runtimes.dockerSettings },
    .{ .method = .PUT, .pattern = "/api/v1/docker/settings", .handler = runtimes.dockerSettingsSave },

    .{ .method = .GET, .pattern = "/api/v1/host/settings", .handler = host.settings },
    .{ .method = .POST, .pattern = "/api/v1/host/swap", .handler = host.swap },
    .{ .method = .POST, .pattern = "/api/v1/host/swap-device", .handler = host.swapDevice },
    .{ .method = .POST, .pattern = "/api/v1/host/ntp", .handler = host.ntp },
    .{ .method = .PUT, .pattern = "/api/v1/host/hosts", .handler = host.hosts },
    .{ .method = .POST, .pattern = "/api/v1/host/grub", .handler = host.grub },

    .{ .method = .GET, .pattern = "/api/v1/system", .handler = system.index },
    .{ .method = .GET, .pattern = "/api/v1/metrics", .handler = metrics.index },
    .{ .method = .GET, .pattern = "/api/v1/processes", .handler = processes.index },
    .{ .method = .GET, .pattern = "/api/v1/processes/:pid", .handler = processes.detail },
    .{ .method = .POST, .pattern = "/api/v1/processes/:pid/kill", .handler = processes.terminate },

    .{ .method = .GET, .pattern = "/api/v1/files", .handler = files.list },
    .{ .method = .GET, .pattern = "/api/v1/files/content", .handler = files.content },
    .{ .method = .PUT, .pattern = "/api/v1/files/content", .handler = files.write },
    .{ .method = .POST, .pattern = "/api/v1/files/mkdir", .handler = files.mkdir },
    .{ .method = .POST, .pattern = "/api/v1/files/rename", .handler = files.rename },
    .{ .method = .POST, .pattern = "/api/v1/files/delete", .handler = files.delete },
    .{ .method = .GET, .pattern = "/api/v1/files/download", .handler = files.download },
    .{ .method = .POST, .pattern = "/api/v1/files/upload", .handler = files.upload },

    .{ .method = .GET, .pattern = "/api/v1/terminal/ws", .handler = terminal.ws },

    .{ .method = .GET, .pattern = "/api/v1/services", .handler = services.index },
    .{ .method = .POST, .pattern = "/api/v1/services/:name/:action", .handler = services.action },
    .{ .method = .GET, .pattern = "/api/v1/services/:name/logs", .handler = services.logs },

    .{ .method = .GET, .pattern = "/api/v1/sites", .handler = sites.index },
    .{ .method = .POST, .pattern = "/api/v1/sites", .handler = sites.create },
    .{ .method = .POST, .pattern = "/api/v1/sites/reload", .handler = sites.reload },
    .{ .method = .POST, .pattern = "/api/v1/sites/:name/toggle", .handler = sites.toggle },
    .{ .method = .GET, .pattern = "/api/v1/sites/:name", .handler = sites.show },
    .{ .method = .PUT, .pattern = "/api/v1/sites/:name", .handler = sites.update },
    .{ .method = .DELETE, .pattern = "/api/v1/sites/:name", .handler = sites.destroy },
    .{ .method = .POST, .pattern = "/api/v1/sites/:name/certificate", .handler = sites.uploadCertificate },
    .{ .method = .POST, .pattern = "/api/v1/sites/:name/basic-auth", .handler = sites.updateBasicAuth },
    .{ .method = .GET, .pattern = "/api/v1/sites/:name/logs", .handler = sites.logs },

    .{ .method = .GET, .pattern = "/api/v1/docker/containers", .handler = docker.containers },
    .{ .method = .POST, .pattern = "/api/v1/docker/containers", .handler = docker.create },
    .{ .method = .GET, .pattern = "/api/v1/docker/images", .handler = docker.images },
    .{ .method = .GET, .pattern = "/api/v1/docker/images/search", .handler = docker_images.search },
    .{ .method = .POST, .pattern = "/api/v1/docker/images/pull", .handler = docker_images.pull },
    .{ .method = .POST, .pattern = "/api/v1/docker/images/push", .handler = docker_images.push },
    .{ .method = .POST, .pattern = "/api/v1/docker/images/update", .handler = docker_images.update },
    .{ .method = .POST, .pattern = "/api/v1/docker/images/tag", .handler = docker_images.tag },
    .{ .method = .DELETE, .pattern = "/api/v1/docker/images/:id", .handler = docker_images.remove },
    .{ .method = .POST, .pattern = "/api/v1/docker/images/prune", .handler = docker_images.prune },
    .{ .method = .POST, .pattern = "/api/v1/docker/images/export", .handler = docker_images.exportImage },
    .{ .method = .POST, .pattern = "/api/v1/docker/images/import", .handler = docker_images.importImage },
    .{ .method = .POST, .pattern = "/api/v1/docker/images/build", .handler = docker_images.build },
    .{ .method = .POST, .pattern = "/api/v1/docker/images/build/git", .handler = docker_images.buildGit },
    .{ .method = .POST, .pattern = "/api/v1/docker/images/build/upload", .handler = docker_images.buildUpload },
    .{ .method = .POST, .pattern = "/api/v1/docker/build-cache/prune", .handler = docker_images.pruneCache },
    .{ .method = .GET, .pattern = "/api/v1/docker/registries", .handler = docker_registries.index },
    .{ .method = .POST, .pattern = "/api/v1/docker/registries", .handler = docker_registries.create },
    .{ .method = .PUT, .pattern = "/api/v1/docker/registries/:id", .handler = docker_registries.update },
    .{ .method = .DELETE, .pattern = "/api/v1/docker/registries/:id", .handler = docker_registries.destroy },
    .{ .method = .POST, .pattern = "/api/v1/docker/registries/:id/sync", .handler = docker_registries.sync },
    .{ .method = .GET, .pattern = "/api/v1/docker/networks", .handler = docker_networks.index },
    .{ .method = .POST, .pattern = "/api/v1/docker/networks", .handler = docker_networks.create },
    .{ .method = .POST, .pattern = "/api/v1/docker/networks/prune", .handler = docker_networks.prune },
    .{ .method = .DELETE, .pattern = "/api/v1/docker/networks/:name", .handler = docker_networks.destroy },
    .{ .method = .GET, .pattern = "/api/v1/docker/volumes", .handler = docker_volumes.index },
    .{ .method = .POST, .pattern = "/api/v1/docker/volumes", .handler = docker_volumes.create },
    .{ .method = .POST, .pattern = "/api/v1/docker/volumes/prune", .handler = docker_volumes.prune },
    .{ .method = .DELETE, .pattern = "/api/v1/docker/volumes/:name", .handler = docker_volumes.destroy },
    .{ .method = .GET, .pattern = "/api/v1/docker/overview", .handler = docker.overview },
    .{ .method = .GET, .pattern = "/api/v1/docker/info", .handler = docker.info },
    .{ .method = .POST, .pattern = "/api/v1/docker/test-connection", .handler = docker.testConnection },
    .{ .method = .GET, .pattern = "/api/v1/docker/notes", .handler = docker.notes },
    .{ .method = .PUT, .pattern = "/api/v1/docker/notes/:name", .handler = docker.noteSave },
    .{ .method = .GET, .pattern = "/api/v1/docker/containers/:id", .handler = docker.detail },
    .{ .method = .POST, .pattern = "/api/v1/docker/containers/:id/recreate", .handler = docker.recreate },
    .{ .method = .POST, .pattern = "/api/v1/docker/containers/:id/commit", .handler = docker.commit },
    .{ .method = .POST, .pattern = "/api/v1/docker/containers/:id/:action", .handler = docker.action },
    .{ .method = .GET, .pattern = "/api/v1/docker/containers/:id/logs", .handler = docker.logs },
    .{ .method = .GET, .pattern = "/api/v1/docker/containers/:id/terminal/ws", .handler = docker_terminal.ws },
    .{ .method = .GET, .pattern = "/api/v1/docker/containers/:id/files", .handler = docker_files.list },
    .{ .method = .GET, .pattern = "/api/v1/docker/containers/:id/files/content", .handler = docker_files.content },
    .{ .method = .PUT, .pattern = "/api/v1/docker/containers/:id/files/content", .handler = docker_files.write },
    .{ .method = .POST, .pattern = "/api/v1/docker/containers/:id/files/mkdir", .handler = docker_files.mkdir },
    .{ .method = .POST, .pattern = "/api/v1/docker/containers/:id/files/rename", .handler = docker_files.rename },
    .{ .method = .POST, .pattern = "/api/v1/docker/containers/:id/files/delete", .handler = docker_files.delete },
    .{ .method = .POST, .pattern = "/api/v1/docker/containers/:id/files/upload", .handler = docker_files.upload },
    .{ .method = .GET, .pattern = "/api/v1/docker/containers/:id/files/download", .handler = docker_files.download },
    .{ .method = .GET, .pattern = "/api/v1/docker/jobs/:id", .handler = docker_jobs.index },
    .{ .method = .DELETE, .pattern = "/api/v1/docker/jobs/:id", .handler = docker_jobs.cancel },
    .{ .method = .GET, .pattern = "/api/v1/docker/jobs/:id/download", .handler = docker_jobs.download },
    .{ .method = .GET, .pattern = "/api/v1/docker/compose", .handler = docker_compose.index },
    .{ .method = .POST, .pattern = "/api/v1/docker/compose", .handler = docker_compose.create },
    .{ .method = .POST, .pattern = "/api/v1/docker/compose/adopt", .handler = docker_compose.adopt },
    .{ .method = .GET, .pattern = "/api/v1/docker/compose/:name", .handler = docker_compose.detail },
    .{ .method = .PUT, .pattern = "/api/v1/docker/compose/:name", .handler = docker_compose.update },
    .{ .method = .DELETE, .pattern = "/api/v1/docker/compose/:name", .handler = docker_compose.destroy },
    .{ .method = .POST, .pattern = "/api/v1/docker/compose/:name/:action", .handler = docker_compose.action },
    .{ .method = .GET, .pattern = "/api/v1/docker/compose/:name/logs", .handler = docker_compose.logs },

    .{ .method = .GET, .pattern = "/api/v1/firewall", .handler = firewall.index },
    .{ .method = .POST, .pattern = "/api/v1/firewall/rules", .handler = firewall.add },
    .{ .method = .POST, .pattern = "/api/v1/firewall/rules/delete", .handler = firewall.remove },

    .{ .method = .GET, .pattern = "/api/v1/cron", .handler = cron.index },
    .{ .method = .POST, .pattern = "/api/v1/cron", .handler = cron.add },
    .{ .method = .POST, .pattern = "/api/v1/cron/delete", .handler = cron.remove },

    .{ .method = .GET, .pattern = "/api/v1/logs/sources", .handler = logs.sources },
    .{ .method = .GET, .pattern = "/api/v1/logs/tail", .handler = logs.tail },
    .{ .method = .GET, .pattern = "/api/v1/audit", .handler = logs.audit },

    .{ .method = .GET, .pattern = "/api/v1/store/apps", .handler = store.apps },
    .{ .method = .GET, .pattern = "/api/v1/store/apps/:slug", .handler = store.appDetail },
    .{ .method = .POST, .pattern = "/api/v1/store/apps/:slug/deploy", .handler = store.deploy },
    .{ .method = .POST, .pattern = "/api/v1/store/apps/:slug/start", .handler = store.start },
    .{ .method = .POST, .pattern = "/api/v1/store/apps/:slug/stop", .handler = store.stop },
    .{ .method = .GET, .pattern = "/api/v1/store/apps/:slug/logs", .handler = store.logs },
    .{ .method = .DELETE, .pattern = "/api/v1/store/apps/:slug", .handler = store.remove },

    .{ .method = .GET, .pattern = "/api/v1/store/packages", .handler = store.packages },
    .{ .method = .POST, .pattern = "/api/v1/store/packages/refresh", .handler = store.refreshPackages },
    .{ .method = .POST, .pattern = "/api/v1/store/packages/custom", .handler = store.installCustom },
    .{ .method = .POST, .pattern = "/api/v1/store/packages/:id/install", .handler = store.installPackage },

    .{ .method = .GET, .pattern = "/api/v1/store/nix", .handler = store.nixStatus },
    .{ .method = .POST, .pattern = "/api/v1/store/nix/build", .handler = store.nixBuild },
    .{ .method = .POST, .pattern = "/api/v1/store/nix/run", .handler = store.nixRun },

    .{ .method = .GET, .pattern = "/api/v1/ssh", .handler = ssh.status },
    .{ .method = .POST, .pattern = "/api/v1/ssh/config", .handler = ssh.apply },
    .{ .method = .GET, .pattern = "/api/v1/ssh/keys", .handler = ssh.listKeys },
    .{ .method = .POST, .pattern = "/api/v1/ssh/keys", .handler = ssh.addKey },
    .{ .method = .POST, .pattern = "/api/v1/ssh/keys/delete", .handler = ssh.removeKey },
    .{ .method = .GET, .pattern = "/api/v1/ssh/logging", .handler = ssh.logging },
    .{ .method = .POST, .pattern = "/api/v1/ssh/logging", .handler = ssh.setLogging },
    .{ .method = .GET, .pattern = "/api/v1/ssh/logs", .handler = ssh.logs },

    .{ .method = .GET, .pattern = "/api/v1/software", .handler = software.list },
    .{ .method = .POST, .pattern = "/api/v1/software/:id/initialize", .handler = software.initialize },

    .{ .method = .GET, .pattern = "/api/v1/fail2ban", .handler = software.fail2banStatus },
    .{ .method = .POST, .pattern = "/api/v1/fail2ban/ban", .handler = software.fail2banBan },
    .{ .method = .POST, .pattern = "/api/v1/fail2ban/unban", .handler = software.fail2banUnban },
    .{ .method = .POST, .pattern = "/api/v1/fail2ban/config", .handler = software.fail2banLimits },

    .{ .method = .GET, .pattern = "/api/v1/recycle", .handler = recycle.list },
    .{ .method = .POST, .pattern = "/api/v1/recycle/restore", .handler = recycle.restore },
    .{ .method = .POST, .pattern = "/api/v1/recycle/delete", .handler = recycle.purge },
    .{ .method = .POST, .pattern = "/api/v1/recycle/empty", .handler = recycle.empty },

    .{ .method = .GET, .pattern = "/api/v1/files/versions", .handler = versions.list },
    .{ .method = .GET, .pattern = "/api/v1/files/versions/content", .handler = versions.content },
    .{ .method = .POST, .pattern = "/api/v1/files/versions/restore", .handler = versions.restore },

    .{ .method = .GET, .pattern = "/api/v1/waf", .handler = waf.status },
    .{ .method = .POST, .pattern = "/api/v1/waf/install", .handler = waf.install },
    .{ .method = .POST, .pattern = "/api/v1/waf/config", .handler = waf.configure },
    .{ .method = .POST, .pattern = "/api/v1/waf/start", .handler = waf.start },
    .{ .method = .POST, .pattern = "/api/v1/waf/stop", .handler = waf.stop },
    .{ .method = .GET, .pattern = "/api/v1/waf/logs", .handler = waf.logs },
    .{ .method = .POST, .pattern = "/api/v1/waf/typesafe/key", .handler = waf.setTypesafeKey },
    .{ .method = .DELETE, .pattern = "/api/v1/waf/typesafe/key", .handler = waf.clearTypesafeKey },
    .{ .method = .GET, .pattern = "/api/v1/waf/geo/catalog", .handler = waf.geoCatalog },
};
