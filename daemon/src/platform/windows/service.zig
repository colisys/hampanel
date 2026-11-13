const std = @import("std");

const c = @import("windows_c");

pub const ServeFn = *const fn () anyerror!void;

var serve_fn: ServeFn = undefined;
var status_handle: c.SERVICE_STATUS_HANDLE = null;
var service_status: c.SERVICE_STATUS = std.mem.zeroes(c.SERVICE_STATUS);
var stop_event: c.HANDLE = null;
var service_name: [9:0]u16 = .{ 'H', 'a', 'm', 'p', 'a', 'n', 'e', 'l', 0 };

pub fn run(serve: ServeFn) !void {
    serve_fn = serve;

    var table = [_]c.SERVICE_TABLE_ENTRYW{
        .{ .lpServiceName = @ptrCast(&service_name), .lpServiceProc = serviceMain },
        .{ .lpServiceName = null, .lpServiceProc = null },
    };

    if (c.StartServiceCtrlDispatcherW(&table) == 0) {
        return error.ServiceDispatchFailed;
    }
}

fn serviceMain(argc: c.DWORD, argv: [*c]c.LPWSTR) callconv(.winapi) void {
    _ = argc;
    _ = argv;

    status_handle = c.RegisterServiceCtrlHandlerW(@ptrCast(&service_name), controlHandler) orelse {
        return;
    };

    service_status.dwServiceType = c.SERVICE_WIN32_OWN_PROCESS;
    service_status.dwCurrentState = c.SERVICE_START_PENDING;
    service_status.dwControlsAccepted = 0;
    service_status.dwWin32ExitCode = 0;
    service_status.dwServiceSpecificExitCode = 0;
    service_status.dwCheckPoint = 0;
    service_status.dwWaitHint = 3000;
    _ = c.SetServiceStatus(status_handle, &service_status);

    stop_event = c.CreateEventW(null, 1, 0, null);
    if (stop_event == null) {
        service_status.dwCurrentState = c.SERVICE_STOPPED;
        service_status.dwWin32ExitCode = 1;
        _ = c.SetServiceStatus(status_handle, &service_status);
        return;
    }

    const thread = std.Thread.spawn(.{}, serveThread, .{}) catch {
        service_status.dwCurrentState = c.SERVICE_STOPPED;
        service_status.dwWin32ExitCode = 1;
        _ = c.SetServiceStatus(status_handle, &service_status);
        return;
    };
    thread.detach();

    reportState(c.SERVICE_RUNNING);
    _ = c.WaitForSingleObject(stop_event, c.INFINITE);

    service_status.dwCurrentState = c.SERVICE_STOP_PENDING;
    service_status.dwControlsAccepted = 0;
    _ = c.SetServiceStatus(status_handle, &service_status);

    c.ExitProcess(0);
}

fn serveThread() void {
    serve_fn() catch {};
}

fn controlHandler(control: c.DWORD) callconv(.winapi) void {
    switch (control) {
        c.SERVICE_CONTROL_STOP, c.SERVICE_CONTROL_SHUTDOWN => {
            service_status.dwCurrentState = c.SERVICE_STOP_PENDING;
            service_status.dwControlsAccepted = 0;
            _ = c.SetServiceStatus(status_handle, &service_status);
            if (stop_event != null) _ = c.SetEvent(stop_event);
        },
        else => {},
    }
}

fn reportState(state: c.DWORD) void {
    service_status.dwCurrentState = state;
    service_status.dwControlsAccepted = if (state == c.SERVICE_RUNNING) c.SERVICE_ACCEPT_STOP else 0;
    service_status.dwCheckPoint = 0;
    service_status.dwWaitHint = 0;
    _ = c.SetServiceStatus(status_handle, &service_status);
}
