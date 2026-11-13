/* Hampanel Windows driver companion.
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include <ntddk.h>
#include "hampanel_ioctl.h"

#define HAMPANEL_DEVICE_NAME L"\\Device\\Hampanel"
#define HAMPANEL_SYMLINK_NAME L"\\DosDevices\\Hampanel"
#define HAMPANEL_DRIVER_VERSION 0x00010000

static PDEVICE_OBJECT g_device_object = NULL;
static UNICODE_STRING g_device_name;
static UNICODE_STRING g_symlink_name;

DRIVER_UNLOAD HampanelUnload;
DRIVER_DISPATCH HampanelCreateClose;
DRIVER_DISPATCH HampanelDeviceControl;

static NTSTATUS HampanelCreateClose(PDEVICE_OBJECT DeviceObject, PIRP Irp)
{
    UNREFERENCED_PARAMETER(DeviceObject);
    Irp->IoStatus.Status = STATUS_SUCCESS;
    Irp->IoStatus.Information = 0;
    IoCompleteRequest(Irp, IO_NO_INCREMENT);
    return STATUS_SUCCESS;
}

static NTSTATUS HampanelDeviceControl(PDEVICE_OBJECT DeviceObject, PIRP Irp)
{
    UNREFERENCED_PARAMETER(DeviceObject);

    PIO_STACK_LOCATION stack = IoGetCurrentIrpStackLocation(Irp);
    NTSTATUS status = STATUS_INVALID_DEVICE_REQUEST;
    ULONG information = 0;

    switch (stack->Parameters.DeviceIoControl.IoControlCode) {
    case IOCTL_HAMPANEL_PING:
        status = STATUS_SUCCESS;
        break;

    case IOCTL_HAMPANEL_GET_VERSION:
        if (stack->Parameters.DeviceIoControl.OutputBufferLength >= sizeof(HAMPANEL_VERSION_INFO)) {
            PHAMPANEL_VERSION_INFO info = (PHAMPANEL_VERSION_INFO)Irp->AssociatedIrp.SystemBuffer;
            info->protocol_version = HAMPANEL_PROTOCOL_VERSION;
            info->driver_version = HAMPANEL_DRIVER_VERSION;
            info->reserved = 0;
            information = sizeof(HAMPANEL_VERSION_INFO);
            status = STATUS_SUCCESS;
        } else {
            status = STATUS_BUFFER_TOO_SMALL;
        }
        break;

    default:
        break;
    }

    Irp->IoStatus.Status = status;
    Irp->IoStatus.Information = information;
    IoCompleteRequest(Irp, IO_NO_INCREMENT);
    return status;
}

static VOID HampanelUnload(PDRIVER_OBJECT DriverObject)
{
    UNREFERENCED_PARAMETER(DriverObject);
    IoDeleteSymbolicLink(&g_symlink_name);
    if (g_device_object != NULL) {
        IoDeleteDevice(g_device_object);
        g_device_object = NULL;
    }
}

NTSTATUS DriverEntry(PDRIVER_OBJECT DriverObject, PUNICODE_STRING RegistryPath)
{
    UNREFERENCED_PARAMETER(RegistryPath);

    RtlInitUnicodeString(&g_device_name, HAMPANEL_DEVICE_NAME);
    RtlInitUnicodeString(&g_symlink_name, HAMPANEL_SYMLINK_NAME);

    NTSTATUS status = IoCreateDevice(
        DriverObject,
        0,
        &g_device_name,
        FILE_DEVICE_UNKNOWN,
        FILE_DEVICE_SECURE_OPEN,
        FALSE,
        &g_device_object);
    if (!NT_SUCCESS(status)) {
        return status;
    }

    status = IoCreateSymbolicLink(&g_symlink_name, &g_device_name);
    if (!NT_SUCCESS(status)) {
        IoDeleteDevice(g_device_object);
        g_device_object = NULL;
        return status;
    }

    DriverObject->MajorFunction[IRP_MJ_CREATE] = HampanelCreateClose;
    DriverObject->MajorFunction[IRP_MJ_CLOSE] = HampanelCreateClose;
    DriverObject->MajorFunction[IRP_MJ_DEVICE_CONTROL] = HampanelDeviceControl;
    DriverObject->DriverUnload = HampanelUnload;

    return STATUS_SUCCESS;
}
